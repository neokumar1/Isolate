import XCTest
import AppKit
import SwiftData
@testable import Isolate

/// Final-wave fixes for the library store, search, quitting and the move prompt.
@MainActor
final class FinalLibraryTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "FinalLibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "FinalLibraryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        // Undo flags, ACLs and permission changes a test made so the folder can be removed.
        runChmod(["-R", "-N", directory.path])
        if let enumerator = FileManager.default.enumerator(atPath: directory.path) {
            while let relative = enumerator.nextObject() as? String {
                let path = directory.appending(path: relative).path
                _ = Darwin.chflags(path, 0)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            }
        }
        try FileManager.default.removeItem(at: directory)
    }

    private func runChmod(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/chmod")
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func track(_ relativePath: String, title: String? = nil) -> TrackModel {
        let original = directory.appending(path: relativePath)
        let stems = directory.appending(path: "Stems/\(UUID().uuidString)")
        return TrackModel(id: original.path, title: title ?? original.deletingPathExtension().lastPathComponent,
                          originalURL: original,
                          vocalStemURL: stems.appending(path: "vocals.wav"), bassStemURL: stems.appending(path: "bass.wav"),
                          drumStemURL: stems.appending(path: "drums.wav"), otherStemURL: stems.appending(path: "other.wav"))
    }

    private func makeStore(at url: URL, trackCount: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let container = try ModelContainer(for: TrackModel.self, configurations: ModelConfiguration(url: url))
        for index in 0..<trackCount {
            container.mainContext.insert(track("Music/A/\(index).wav"))
        }
        try container.mainContext.save()
    }

    private func contents(_ url: URL) -> [String: Data] {
        var files: [String: Data] = [:]
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            files[suffix] = try? Data(contentsOf: file)
        }
        return files
    }

    private func writeDamagedStore(at store: URL, wal: Bool) throws -> Data {
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try garbage.write(to: store)
        if wal { try Data([1, 2, 3]).write(to: URL(fileURLWithPath: store.path + "-wal")) }
        return garbage
    }

    private var failingCreate: (URL) throws -> ModelContainer {
        { _ in throw CocoaError(.fileWriteOutOfSpace) }
    }

    // MARK: - library-2: search matches artist and album folders, not the shared path

    func testSearchMatchesArtistFoldersButNotThePathEveryTrackShares() {
        let library = [track("Music/Kanye West/Graduation/01 Good Morning.mp3", title: "Good Morning"),
                       track("Music/Kanye West/Greatest Hits/01 Intro.mp3", title: "Kanye Intro"),
                       track("Music/Daft Punk/Greatest Hits/01 Intro.mp3", title: "Daft Intro")]
        func titles(_ query: String) -> [String] { library.matchingLibrarySearch(query).map(\.title) }
        XCTAssertEqual(titles("kanye"), ["Good Morning", "Kanye Intro"], "The artist folder above the album is searchable")
        XCTAssertEqual(titles("kanye west"), ["Good Morning", "Kanye Intro"])
        XCTAssertEqual(titles("daft punk"), ["Daft Intro"])
        XCTAssertEqual(titles("kanye greatest"), ["Kanye Intro"])
        XCTAssertEqual(titles("greatest hits"), ["Kanye Intro", "Daft Intro"])
        XCTAssertEqual(titles("music"), [], "A folder every track shares must not match the whole library")
        XCTAssertEqual(titles(directory.lastPathComponent.lowercased()), [])
        XCTAssertEqual(titles("users"), [])

        let single = [track("Music/Kanye West/Graduation/01 Good Morning.mp3", title: "Good Morning")]
        XCTAssertEqual(single.matchingLibrarySearch("graduation").map(\.title), ["Good Morning"],
                       "A track's own folder stays searchable even when it is the shared one")
    }

    // MARK: - library-1: recovery never hides or strands the only copy of the library

    func testLibraryThatFailsToOpenButIsNotDamagedStaysInPlace() throws {
        let store = directory.appending(path: "Isolate/Library.store")
        try makeStore(at: store, trackCount: 3)
        // The -shm is SQLite's shared wal-index, which any reader updates.
        func data() -> [String: Data] { contents(store).filter { $0.key != "-shm" } }
        let before = data()

        // A full disk, a lock or a permission problem can pass by the next launch.
        let opened = LibraryStore.open(at: store, create: failingCreate)
        XCTAssertTrue(opened.container.configurations.allSatisfy { $0.isStoredInMemoryOnly })
        XCTAssertNil(opened.backup)
        let notice = try XCTUnwrap(opened.notice)
        XCTAssertTrue(notice.contains("will not be saved"), notice)
        XCTAssertTrue(notice.contains("left unchanged"), notice)
        XCTAssertEqual(data(), before, "The library files must not be moved or changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "Isolate/Library Backups").path))

        let reopened = LibraryStore.open(at: store)
        XCTAssertNil(reopened.notice)
        XCTAssertEqual(try reopened.container.mainContext.fetchCount(FetchDescriptor<TrackModel>()), 3)
    }

    func testUnreadableButIntactLibraryFileIsNotMovedAside() throws {
        let store = directory.appending(path: "Isolate/Library.store")
        try makeStore(at: store, trackCount: 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.path)

        let opened = LibraryStore.open(at: store)
        XCTAssertTrue(opened.container.configurations.allSatisfy { $0.isStoredInMemoryOnly })
        XCTAssertTrue(opened.notice?.contains("left unchanged") == true, opened.notice ?? "no notice")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "Isolate/Library Backups").path))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.path)
        let reopened = LibraryStore.open(at: store)
        XCTAssertEqual(try reopened.container.mainContext.fetchCount(FetchDescriptor<TrackModel>()), 2)
    }

    func testDamagedLibraryIsPutBackWhenNoNewLibraryCanBeStarted() throws {
        let store = directory.appending(path: "Isolate/Library.store")
        let garbage = try writeDamagedStore(at: store, wal: true)
        var attempts = 0
        let opened = LibraryStore.open(at: store, now: Date(timeIntervalSince1970: 1_800_000_000)) { url in
            attempts += 1
            // The failed second attempt leaves a new, empty store behind.
            if attempts == 2 { try Data().write(to: url) }
            throw CocoaError(.fileWriteOutOfSpace)
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(opened.container.configurations.allSatisfy { $0.isStoredInMemoryOnly })
        XCTAssertNil(opened.backup, "The library is back in place, so there is no backup to report")
        XCTAssertTrue(opened.notice?.contains("will not be saved") == true, opened.notice ?? "no notice")
        XCTAssertEqual(try Data(contentsOf: store), garbage)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path + "-wal")), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "Isolate/Library Backups").path),
                       "The emptied backup folder is removed")
    }

    func testDamagedLibraryThatCannotBePutBackNamesItsBackup() throws {
        let folder = directory.appending(path: "Isolate")
        let store = folder.appending(path: "Library.store")
        let garbage = try writeDamagedStore(at: store, wal: false)
        // The folder refuses new files but still lets existing ones be moved out.
        runChmod(["+a", "everyone deny add_file", folder.path])
        defer { runChmod(["-N", folder.path]) }

        let opened = LibraryStore.open(at: store, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(opened.container.configurations.allSatisfy { $0.isStoredInMemoryOnly })
        let backup = try XCTUnwrap(opened.backup, "The caller must keep reporting where the library went")
        let notice = try XCTUnwrap(opened.notice)
        XCTAssertTrue(notice.contains(backup.path), notice)
        XCTAssertTrue(notice.contains("will not be saved"), notice)
        XCTAssertEqual(try Data(contentsOf: backup.appending(path: "Library.store")), garbage)
    }

    func testRecoveryNoticeRepeatsUntilClosedOrTheBackupIsGone() throws {
        let store = directory.appending(path: "Isolate/Library.store")
        _ = try writeDamagedStore(at: store, wal: true)
        let opened = LibraryStore.open(at: store, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertFalse(opened.container.configurations.contains { $0.isStoredInMemoryOnly })
        let backup = try XCTUnwrap(opened.backup)
        XCTAssertTrue(opened.notice?.contains(backup.path) == true, opened.notice ?? "no notice")

        XCTAssertNil(LibraryStore.pendingRecoveryNotice(defaults: defaults))
        defaults.set(backup.path, forKey: LibraryStore.recoveryBackupKey)
        let pending = try XCTUnwrap(LibraryStore.pendingRecoveryNotice(defaults: defaults))
        XCTAssertTrue(pending.contains(backup.path), pending)
        LibraryStore.noticeDismissed("Export failed: something else", defaults: defaults)
        XCTAssertEqual(LibraryStore.pendingRecoveryNotice(defaults: defaults), pending, "Other toasts do not acknowledge it")
        LibraryStore.noticeDismissed(pending, defaults: defaults)
        XCTAssertNil(LibraryStore.pendingRecoveryNotice(defaults: defaults))

        defaults.set(backup.path, forKey: LibraryStore.recoveryBackupKey)
        try FileManager.default.removeItem(at: backup)
        XCTAssertNil(LibraryStore.pendingRecoveryNotice(defaults: defaults), "Nothing to point at once the backup is gone")
        XCTAssertNil(defaults.string(forKey: LibraryStore.recoveryBackupKey))
    }

    // MARK: - library-5: a partial move aside is rolled back

    func testPartialMoveAsideLeavesTheStoreWithItsSidecars() throws {
        let store = directory.appending(path: "Isolate/Library.store")
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("store".utf8).write(to: store)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: store.path + "-shm"))
        let before = contents(store)
        // The sidecars move first; the store itself then cannot be moved.
        XCTAssertEqual(Darwin.chflags(store.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = Darwin.chflags(store.path, 0) }

        XCTAssertThrowsError(try LibraryStore.moveStoreAside(at: store, now: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertEqual(contents(store), before, "The -wal and -shm must be moved back next to the store")
        let backups = directory.appending(path: "Isolate/Library Backups")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? [], [],
                       "No half-filled backup folder is left behind")
    }

    // MARK: - library-4: the legacy import is retried after a failure

    func testLegacyImportRetriesAFailedCopyAndReportsIt() throws {
        let legacy = directory.appending(path: "Shared/default.store")
        try makeStore(at: legacy, trackCount: 2)
        let memory = try ModelContainer(for: TrackModel.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let scratch = directory.appending(path: "Scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scratch.path)

        for attempt in 1..<LibraryStore.maxLegacyImportAttempts {
            let message = try XCTUnwrap(LibraryStore.importLegacyLibraryIfNeeded(from: legacy, into: memory.mainContext,
                                                                                 defaults: defaults, scratchDirectory: scratch))
            XCTAssertTrue(message.contains(legacy.path) && message.contains("try again"), message)
            XCTAssertFalse(defaults.bool(forKey: LibraryStore.legacyImportKey), "A failed copy must be tried again")
            XCTAssertEqual(defaults.integer(forKey: LibraryStore.legacyImportAttemptsKey), attempt)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.path)
        XCTAssertNil(LibraryStore.importLegacyLibraryIfNeeded(from: legacy, into: memory.mainContext,
                                                              defaults: defaults, scratchDirectory: scratch))
        XCTAssertTrue(defaults.bool(forKey: LibraryStore.legacyImportKey))
        XCTAssertEqual(defaults.integer(forKey: LibraryStore.legacyImportAttemptsKey), 0)
        XCTAssertEqual(try memory.mainContext.fetchCount(FetchDescriptor<TrackModel>()), 2)
    }

    func testLegacyImportStopsRetryingAfterRepeatedFailures() throws {
        let legacy = directory.appending(path: "Shared/default.store")
        try makeStore(at: legacy, trackCount: 1)
        let memory = try ModelContainer(for: TrackModel.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let scratch = directory.appending(path: "Scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scratch.path)

        var messages: [String] = []
        for _ in 0..<LibraryStore.maxLegacyImportAttempts {
            messages += [LibraryStore.importLegacyLibraryIfNeeded(from: legacy, into: memory.mainContext,
                                                                  defaults: defaults, scratchDirectory: scratch)].compactMap { $0 }
        }
        XCTAssertEqual(messages.count, LibraryStore.maxLegacyImportAttempts, "Every failure is reported")
        XCTAssertFalse(messages.last?.contains("try again") ?? true, messages.last ?? "")
        XCTAssertTrue(defaults.bool(forKey: LibraryStore.legacyImportKey))
        XCTAssertNil(LibraryStore.importLegacyLibraryIfNeeded(from: legacy, into: memory.mainContext,
                                                              defaults: defaults, scratchDirectory: scratch))
    }

    // MARK: - shell-1, export-2: a quit that waits for cleanup is always answered

    func testQuitReplyArrivesEvenInsideAMainQueueJob() {
        final class State { var done = false; var replies = 0 }
        let state = State()
        let finished = expectation(description: "replied")
        DispatchQueue.main.async {
            // Like terminate called from a MainActor Task: AppKit waits for the
            // reply in the modal-panel run-loop mode, inside this main-queue job.
            MainActor.assumeIsolated {
                IsolateAppDelegate.replyToTermination(within: .seconds(10), when: { state.done },
                                                      reply: { state.replies += 1 })
                state.done = true
                let deadline = Date().addingTimeInterval(5)
                while state.replies == 0 && Date() < deadline {
                    RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05))
                }
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(state.replies, 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(state.replies, 1, "The reply is sent once")
    }

    func testQuitIsAnsweredAtTheDeadlineIfCleanupNeverFinishes() {
        final class State { var replies = 0 }
        let state = State()
        let start = Date()
        IsolateAppDelegate.replyToTermination(within: .milliseconds(200), when: { false }, reply: { state.replies += 1 })
        while state.replies == 0 && Date().timeIntervalSince(start) < 5 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(state.replies, 1)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.2)
    }

    // MARK: - shell-3, shell-4: the Move to Applications card

    func testReplacementPromptCallsOutANewerInstalledCopy() {
        let downgrade = AppMoveHelper.replacementPrompt(installed: "1.10.0", running: "1.9.2")
        XCTAssertTrue(downgrade.contains("newer") && downgrade.contains("1.10.0") && downgrade.contains("1.9.2"), downgrade)
        XCTAssertEqual(AppMoveHelper.replacementPrompt(installed: "1.3.0", running: "1.3.0"),
                       "Isolate 1.3.0 is already in Applications. Replace it? The installed copy will be moved to the Trash.")
        XCTAssertFalse(AppMoveHelper.replacementPrompt(installed: "1.2.7", running: "1.3.0").contains("newer"))
        XCTAssertEqual(AppMoveHelper.replacementPrompt(installed: nil, running: "1.3.0"),
                       "Isolate is already in Applications. Replace it? The installed copy will be moved to the Trash.")
    }

    func testMoveCardStaysUpWhileInstalling() {
        let helper = AppMoveHelper.shared
        let saved = (helper.shouldShowMoveModal, helper.isMoving, helper.moveErrorMessage)
        defer { (helper.shouldShowMoveModal, helper.isMoving, helper.moveErrorMessage) = saved }
        helper.shouldShowMoveModal = true
        helper.isMoving = true
        helper.dismissMoveModal()
        XCTAssertTrue(helper.shouldShowMoveModal, "Escape or a backdrop click must not hide an install in progress")
        helper.isMoving = false
        helper.moveErrorMessage = "Could not install"
        helper.dismissMoveModal()
        XCTAssertFalse(helper.shouldShowMoveModal)
        XCTAssertNil(helper.moveErrorMessage)
    }

    // MARK: - shell-6: notification title

    func testBatchNotificationTitleIsSingularForOneTrack() {
        XCTAssertEqual(MenuBarManager.batchCompletionTitle(count: 1), "Stems Ready")
        XCTAssertEqual(MenuBarManager.batchCompletionTitle(count: 3), "Stems Ready (3 Tracks)")
    }
}
