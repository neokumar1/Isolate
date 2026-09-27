import XCTest
import AppKit
import CryptoKit
import MediaPlayer
import SQLite3
import SwiftData
import SwiftUI
@testable import Isolate

/// Stands in for another unsandboxed app's entity sharing default.store.
@Model
final class SharedStoreForeignModel {
    var endpoint: String
    init(endpoint: String) { self.endpoint = endpoint }
}

@MainActor
final class ShellFixTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ShellFixTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Undo any permission change a test made so the folder can be removed.
        if let enumerator = FileManager.default.enumerator(atPath: directory.path) {
            while let relative = enumerator.nextObject() as? String {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: directory.appending(path: relative).path)
            }
        }
        try FileManager.default.removeItem(at: directory)
    }

    private func track(_ id: String, title: String, folder: String, added: Date = .now) -> TrackModel {
        let original = directory.appending(path: "Music/\(folder)/\(id).wav")
        let stems = directory.appending(path: "Stems/\(id)")
        return TrackModel(id: original.path, title: title, originalURL: original, dateAdded: added,
                          vocalStemURL: stems.appending(path: "vocals.wav"), bassStemURL: stems.appending(path: "bass.wav"),
                          drumStemURL: stems.appending(path: "drums.wav"), otherStemURL: stems.appending(path: "other.wav"))
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func sqliteRowCount(_ url: URL, table: String) -> Int? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Library store (library-1, library-2)

    func testLibraryUsesItsOwnStoreInsteadOfSharedDefaultStore() {
        XCTAssertEqual(LibraryStore.legacyStoreURL.standardizedFileURL, ModelConfiguration().url.standardizedFileURL,
                       "The legacy location must be where SwiftData's default configuration kept the library")
        XCTAssertNotEqual(LibraryStore.storeURL, LibraryStore.legacyStoreURL)
        XCTAssertEqual(LibraryStore.storeURL.deletingLastPathComponent().lastPathComponent, "Isolate")
    }

    func testLegacyImportReadsCopyAndNeverMigratesSharedStore() throws {
        let legacy = directory.appending(path: "Shared/default.store")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The writer stays open, so the rows are still only in the -wal file.
        let writer = try ModelContainer(for: TrackModel.self, SharedStoreForeignModel.self,
                                        configurations: ModelConfiguration(url: legacy))
        let old = Date(timeIntervalSinceReferenceDate: 700_000_000)
        writer.mainContext.insert(track("a", title: "Legacy A", folder: "A", added: old))
        writer.mainContext.insert(track("b", title: "Legacy B", folder: "B", added: old))
        writer.mainContext.insert(SharedStoreForeignModel(endpoint: "https://example.com"))
        try writer.mainContext.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path + "-wal"))

        let opened = LibraryStore.open(at: directory.appending(path: "Isolate/Library.store"))
        XCTAssertNil(opened.notice)
        let context = opened.container.mainContext
        let existing = track("a", title: "Renamed in new library", folder: "A")
        context.insert(existing)
        try context.save()

        let scratch = directory.appending(path: "Scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        XCTAssertEqual(try LibraryStore.importLegacyLibrary(from: legacy, into: context, scratchDirectory: scratch), .imported(1))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [], "The copy must be removed")

        let tracks = try context.fetch(FetchDescriptor<TrackModel>(sortBy: [SortDescriptor(\.title)]))
        XCTAssertEqual(tracks.map(\.title), ["Legacy B", "Renamed in new library"],
                       "Rows already in the new library keep their newer values")
        let imported = try XCTUnwrap(tracks.first)
        let expected = track("b", title: "Legacy B", folder: "B")
        XCTAssertEqual(imported.id, expected.id)
        XCTAssertEqual(imported.originalURL, expected.originalURL)
        XCTAssertEqual(imported.vocalStemURL, expected.vocalStemURL)
        XCTAssertEqual(imported.drumStemURL, expected.drumStemURL)
        XCTAssertEqual(imported.dateAdded, old)

        // The shared store still holds the other app's table and every row.
        XCTAssertEqual(sqliteRowCount(legacy, table: "ZSHAREDSTOREFOREIGNMODEL"), 1)
        XCTAssertEqual(sqliteRowCount(legacy, table: "ZTRACKMODEL"), 2)
        XCTAssertEqual(try LibraryStore.importLegacyLibrary(from: legacy, into: context, scratchDirectory: scratch), .imported(0))
        _ = writer
    }

    func testLegacyImportLeavesAnotherAppsStoreByteForByte() throws {
        let legacy = directory.appending(path: "default.store")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(legacy.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in ["PRAGMA journal_mode=WAL",
                    "CREATE TABLE ZAPIREQUESTMODEL (Z_PK INTEGER PRIMARY KEY, ZURL VARCHAR)",
                    "INSERT INTO ZAPIREQUESTMODEL (ZURL) VALUES ('https://example.com')"] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertTrue(files.contains("default.store-wal"))
        let before = try files.map { try digest(directory.appending(path: $0)) }

        let memory = try ModelContainer(for: TrackModel.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let scratch = directory.appending(path: "Scratch")
        XCTAssertEqual(try LibraryStore.importLegacyLibrary(from: legacy, into: memory.mainContext, scratchDirectory: scratch),
                       .noLegacyLibrary)

        let after = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != "Scratch" }.sorted()
        XCTAssertEqual(after, files)
        XCTAssertEqual(try after.map { try digest(directory.appending(path: $0)) }, before)
        XCTAssertEqual(try memory.mainContext.fetchCount(FetchDescriptor<TrackModel>()), 0)
        XCTAssertEqual(try LibraryStore.importLegacyLibrary(from: directory.appending(path: "missing.store"),
                                                            into: memory.mainContext, scratchDirectory: scratch), .noLegacyLibrary)
    }

    func testUnreadableLibraryIsMovedToBackupAndReplaced() throws {
        let store = directory.appending(path: "Isolate/Library.store")
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try garbage.write(to: store)
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: store.path + "-wal"))

        let opened = LibraryStore.open(at: store, now: Date(timeIntervalSince1970: 1_800_000_000))
        let notice = try XCTUnwrap(opened.notice, "Recovery must be reported to the user")
        XCTAssertTrue(notice.contains("Library Backups"), notice)
        XCTAssertFalse(opened.container.configurations.contains { $0.isStoredInMemoryOnly },
                       "A new on-disk library must replace the unreadable one, not an in-memory store")

        let backups = try FileManager.default.contentsOfDirectory(
            at: store.deletingLastPathComponent().appending(path: "Library Backups"), includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backup.appending(path: "Library.store")), garbage)
        XCTAssertEqual(try Data(contentsOf: backup.appending(path: "Library.store-wal")), Data([1, 2, 3]))

        opened.container.mainContext.insert(track("new", title: "After recovery", folder: "A"))
        try opened.container.mainContext.save()
        let reopened = try ModelContainer(for: TrackModel.self, configurations: ModelConfiguration(url: store))
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<TrackModel>()), 1)
    }

    func testLibraryThatCannotBeCreatedIsReportedNotSilentlyInMemory() throws {
        let locked = directory.appending(path: "Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let opened = LibraryStore.open(at: locked.appending(path: "Isolate/Library.store"))
        XCTAssertTrue(opened.container.configurations.allSatisfy { $0.isStoredInMemoryOnly })
        XCTAssertTrue(opened.notice?.contains("will not be saved") == true, opened.notice ?? "no notice")
    }

    func testHealthyLibraryOpensWithoutNotice() throws {
        let store = directory.appending(path: "Isolate/Library.store")
        let opened = LibraryStore.open(at: store)
        XCTAssertNil(opened.notice)
        XCTAssertEqual(opened.container.configurations.first?.url.standardizedFileURL, store.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "Isolate/Library Backups").path))
    }

    // MARK: - Search, order and headers (library-6, library-10, library-12)

    func testSearchMatchesTitleFileAndFolderButNotStemNamesOrPath() {
        let library = [track("1", title: "Bass Down Low", folder: "Pop"),
                       track("2", title: "The Other Side", folder: "Pop"),
                       track("3", title: "Drummer Boy", folder: "Pop"),
                       track("4", title: "All of the Lights", folder: "Pop"),
                       track("5", title: "Runaway", folder: "Kanye")]
        func titles(_ query: String) -> [String] { library.matchingLibrarySearch(query).map(\.title) }
        XCTAssertEqual(titles("bass"), ["Bass Down Low"])
        XCTAssertEqual(titles("drum"), ["Drummer Boy"])
        XCTAssertEqual(titles("the other"), ["The Other Side"])
        XCTAssertEqual(titles("all"), ["All of the Lights"])
        XCTAssertEqual(titles("stems"), [])
        XCTAssertEqual(titles("vocals"), [])
        XCTAssertEqual(titles(directory.lastPathComponent.lowercased()), [], "Shared path segments must not match")
        XCTAssertEqual(titles("kanye"), ["Runaway"], "The folder shown as the group header is searchable")
        XCTAssertEqual(titles("lights of"), ["All of the Lights"])
        XCTAssertEqual(titles("  "), library.map(\.title))
    }

    func testNextAndPreviousFollowSidebarFolderOrder() {
        let a1 = track("a1", title: "a1", folder: "A", added: Date(timeIntervalSince1970: 1))
        let b1 = track("b1", title: "b1", folder: "B", added: Date(timeIntervalSince1970: 2))
        let a2 = track("a2", title: "a2", folder: "A", added: Date(timeIntervalSince1970: 3))
        let queryOrder = [a2, b1, a1] // @Query: newest first
        XCTAssertEqual(queryOrder.libraryFolderGroups().map { $0.folder.lastPathComponent }, ["A", "B"])
        XCTAssertEqual(queryOrder.libraryPlaybackOrder().map(\.title), ["a2", "a1", "b1"])

        let engine = AudioEngineManager()
        let manager = NowPlayingManager()
        var selected: [String] = []
        manager.configure(engineManager: engine, playlistProvider: { queryOrder.libraryPlaybackOrder() },
                          trackSelectHandler: { selected.append($0.title) })
        engine.currentTrackID = a2.id
        manager.playNextTrack()
        engine.currentTrackID = a1.id
        manager.playNextTrack()
        manager.playPreviousTrack()
        XCTAssertEqual(selected, ["a1", "b1", "a2"], "Next goes to the row below, not the next import")
    }

    func testFolderHeadersDisambiguateSameNamedFolders() {
        let base = URL(filePath: "/Users/someone/Music")
        let hitsA = base.appending(path: "Artist A/Greatest Hits")
        let hitsB = base.appending(path: "Artist B/Greatest Hits")
        let other = base.appending(path: "Artist A/Other")
        let mixUpper = base.appending(path: "One/Mix")
        let mixLower = base.appending(path: "Two/mix")
        let labels = LibraryView.folderLabels(for: [hitsA, hitsB, other, hitsA, mixUpper, mixLower])
        XCTAssertEqual(labels[hitsA], "Artist A / Greatest Hits")
        XCTAssertEqual(labels[hitsB], "Artist B / Greatest Hits")
        XCTAssertEqual(labels[other], "Other")
        XCTAssertEqual(labels[mixUpper], "One / Mix", "Headers are uppercased, so names differing by case collide")
        XCTAssertEqual(labels[mixLower], "Two / mix")
    }

    // MARK: - Rename bound (library-13)

    func testRenameTitleIsTrimmedAndBounded() {
        XCTAssertEqual(RenameModalCard.sanitizedTitle(String(repeating: "a", count: 2_000))?.count, RenameModalCard.maxTitleLength)
        XCTAssertEqual(RenameModalCard.sanitizedTitle("  My take  "), "My take")
        XCTAssertNil(RenameModalCard.sanitizedTitle(" \n "))
    }

    // MARK: - Now Playing (robustness-10, performance-9)

    func testNowPlayingKeepsNumbersThatArePartOfTheTitle() {
        let manager = NowPlayingManager.shared
        for title in ["7-Eleven", "22", "1-800-273-8255", "2-4-6-8 Motorway", "5-4-3-2-1", "99.9F°",
                      "7_11", "99 Problems", "1.5 Degrees", "12 - 3 AM"] {
            XCTAssertEqual(manager.cleanTrackTitle(title), title)
        }
        XCTAssertEqual(manager.cleanTrackTitle("01 - Intro"), "Intro")
        XCTAssertEqual(manager.cleanTrackTitle("03. Hey Jude.mp3"), "Hey Jude")
        XCTAssertEqual(manager.cleanTrackTitle("12_Outro"), "Outro")
    }

    func testNowPlayingProgressIsRepublishedOnlyWhenPlaybackDeparts() {
        let last = NowPlayingManager.PublishedProgress(elapsed: 10, duration: 180, rate: 1, uptime: 100)
        XCTAssertTrue(NowPlayingManager.progressNeedsPublish(nil, elapsed: 0, duration: 180, rate: 0, uptime: 0))
        XCTAssertFalse(NowPlayingManager.progressNeedsPublish(last, elapsed: 12.05, duration: 180, rate: 1, uptime: 102),
                       "Steady playback is extrapolated by the system")
        XCTAssertTrue(NowPlayingManager.progressNeedsPublish(last, elapsed: 60, duration: 180, rate: 1, uptime: 102), "Seek")
        XCTAssertTrue(NowPlayingManager.progressNeedsPublish(last, elapsed: 0.1, duration: 180, rate: 1, uptime: 150), "Loop wrap")
        XCTAssertTrue(NowPlayingManager.progressNeedsPublish(last, elapsed: 12, duration: 180, rate: 1.5, uptime: 102), "Rate")
        XCTAssertTrue(NowPlayingManager.progressNeedsPublish(last, elapsed: 12, duration: 200, rate: 1, uptime: 102), "Duration")
        let paused = NowPlayingManager.PublishedProgress(elapsed: 42, duration: 180, rate: 0, uptime: 100)
        XCTAssertFalse(NowPlayingManager.progressNeedsPublish(paused, elapsed: 42, duration: 180, rate: 0, uptime: 500))
    }

    func testNowPlayingReusesArtworkUntilTheImageChanges() throws {
        let manager = NowPlayingManager()
        defer { manager.clear() }
        func publishedArtwork(_ image: NSImage) throws -> MPMediaItemArtwork {
            manager.updateNowPlayingInfo(title: "Track", artwork: image, duration: 10, elapsed: 0, isPlaying: false)
            return try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        }
        let cover = NSImage(size: NSSize(width: 8, height: 8))
        let first = try publishedArtwork(cover)
        XCTAssertTrue(try publishedArtwork(cover) === first)
        XCTAssertFalse(try publishedArtwork(NSImage(size: NSSize(width: 8, height: 8))) === first)
    }

    // MARK: - Modals, quitting and windows (ui-2, concurrency-4, ui-3, ui-12, design-a11y-15)

    func testEscapeCannotCancelSeparationWhileAnotherCardIsOnTop() {
        XCTAssertNil(SplittingProgressModal.cancelShortcut(isCovered: true))
        XCTAssertEqual(SplittingProgressModal.cancelShortcut(isCovered: false), .cancelAction)
    }

    func testQuitAsksOnlyWhileSeparationOrExportIsRunning() {
        XCTAssertNil(IsolateAppDelegate.pendingWork(isSplitting: false, exportState: .idle))
        XCTAssertNil(IsolateAppDelegate.pendingWork(isSplitting: false, exportState: .completed))
        XCTAssertEqual(IsolateAppDelegate.pendingWork(isSplitting: true, exportState: .idle), .separation)
        XCTAssertEqual(IsolateAppDelegate.pendingWork(isSplitting: false, exportState: .exporting(stage: "RENDERING", percent: 0.4)),
                       .export)
        let delegate = IsolateAppDelegate()
        let engine = AudioEngineManager()
        delegate.engineManager = engine
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertTrue(delegate.engineManager === engine)
    }

    func testStatusMenuTargetsMainWindowNotStatusBarWindow() {
        let statusLike = NSWindow(contentRect: .init(x: 0, y: 0, width: 20, height: 20), styleMask: [.borderless],
                                  backing: .buffered, defer: true)
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 20, height: 20), styleMask: [.titled],
                            backing: .buffered, defer: true)
        let main = NSWindow(contentRect: .init(x: 0, y: 0, width: 20, height: 20),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        XCTAssertTrue(MenuBarManager.mainWindowCandidate(in: [statusLike, panel, main]) === main)
        XCTAssertNil(MenuBarManager.mainWindowCandidate(in: [statusLike, panel]))
    }

    func testAutomaticWindowTabbingIsDisabled() {
        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing, "A tab bar '+' would open a second main window")
    }

    func testStatusItemHasVoiceOverNameAndState() throws {
        let manager = MenuBarManager()
        manager.setEnabled(true)
        defer { manager.setEnabled(false) }
        let button = try XCTUnwrap(manager.statusItem?.button)
        XCTAssertEqual(button.accessibilityLabel(), "Isolate")
        XCTAssertEqual(button.accessibilityValue() as? String, "Paused")
        manager.updatePlaybackState(isPlaying: true)
        XCTAssertEqual(button.accessibilityValue() as? String, "Playing")
        manager.updatePlaybackState(isPlaying: false)
        XCTAssertEqual(button.accessibilityValue() as? String, "Paused")
    }

    // MARK: - Move to Applications (ui-11, robustness-7)

    private func fakeApp(at url: URL, version: String, identifier: String = "com.isolate.Isolate") throws {
        let contents = url.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: NSDictionary = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version]
        try plist.write(to: url.appending(path: "Contents/Info.plist"))
        try Data("binary \(version)".utf8).write(to: contents.appending(path: "Isolate"))
    }

    private func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    func testMoveNeverReplacesInstalledAppWithoutConfirmation() throws {
        let source = directory.appending(path: "Volume/Isolate.app")
        let applications = directory.appending(path: "Applications")
        let destination = applications.appending(path: "Isolate.app")
        let trash = directory.appending(path: "Trash")
        try fakeApp(at: source, version: "1.3.0")
        try fakeApp(at: destination, version: "9.9.0")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let executable = source.appending(path: "Contents/MacOS/Isolate")
        XCTAssertEqual(setxattr(executable.path, "com.apple.quarantine", "0081;00000000;Safari;", 21, 0, XATTR_NOFOLLOW), 0)

        XCTAssertThrowsError(try AppMoveHelper.install(from: source, to: destination, replacingExisting: false,
                                                       retire: { _ in XCTFail("Must not retire without confirmation") }))
        XCTAssertEqual(AppMoveHelper.installedInfo(at: destination)?.version, "9.9.0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["Isolate.app"],
                       "A refused install leaves no staging copy behind")

        try AppMoveHelper.install(from: source, to: destination, replacingExisting: true, retire: {
            try FileManager.default.moveItem(at: $0, to: trash.appending(path: $0.lastPathComponent))
        })
        XCTAssertEqual(AppMoveHelper.installedInfo(at: destination)?.version, "1.3.0")
        XCTAssertEqual(AppMoveHelper.installedInfo(at: trash.appending(path: "Isolate.app"))?.version, "9.9.0",
                       "The replaced copy is retired, not deleted")
        XCTAssertFalse(hasQuarantine(destination.appending(path: "Contents/MacOS/Isolate")),
                       "The installed copy must not be translocated again")
        XCTAssertTrue(hasQuarantine(executable), "The source is left untouched")
        XCTAssertEqual(AppMoveHelper.installedInfo(at: destination)?.identifier, "com.isolate.Isolate")
    }

    func testMoveInstallsWhenApplicationsHasNoCopy() throws {
        let source = directory.appending(path: "Volume/Isolate.app")
        let destination = directory.appending(path: "Applications/Isolate.app")
        try fakeApp(at: source, version: "1.3.0")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AppMoveHelper.install(from: source, to: destination, replacingExisting: false,
                                  retire: { _ in XCTFail("Nothing to retire") })
        XCTAssertEqual(AppMoveHelper.installedInfo(at: destination)?.version, "1.3.0")
    }

    func testLocationChecksHandleTranslocationAndWritableVolumes() {
        XCTAssertEqual(AppMoveHelper.originalURL(of: directory), directory)
        let lookalike = URL(filePath: "/private/var/folders/xx/T/AppTranslocation/\(UUID().uuidString)/d/Isolate.app")
        XCTAssertEqual(AppMoveHelper.originalURL(of: lookalike).path, lookalike.path,
                       "A path that is not really translocated resolves to itself")
        XCTAssertFalse(AppMoveHelper.isDiskImageLocation(directory))
        XCTAssertFalse(AppMoveHelper.isDiskImageLocation(URL(filePath: "/Applications/Isolate.app")))
    }
}
