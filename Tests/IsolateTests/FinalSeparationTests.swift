import XCTest
import AVFoundation
import SwiftData
import os
@testable import Isolate

@MainActor
final class FinalSeparationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - iCloud prefetch window (separation-1)

    func testICloudPrefetchAsksOnlyForTheNextFile() {
        let files = (1...5).map { directory.appending(path: "\($0).flac") }
        XCTAssertEqual(ImportCoordinator.prefetchCount, 1)
        XCTAssertEqual(Array(ImportCoordinator.upcoming(after: 0, in: files)), [files[1]])
        XCTAssertEqual(Array(ImportCoordinator.upcoming(after: 3, in: files)), [files[4]])
        XCTAssertTrue(ImportCoordinator.upcoming(after: 4, in: files).isEmpty)
        XCTAssertTrue(ImportCoordinator.upcoming(after: 0, in: Array(files.prefix(1))).isEmpty)
        for index in files.indices {
            XCTAssertLessThanOrEqual(ImportCoordinator.upcoming(after: index, in: files).count, 1,
                                     "A batch must never ask iCloud Drive for the rest of the folder")
        }
    }

    // MARK: - Folder listing window (separation-3)

    func testFolderImportWaitsForASeparationStartedWhileListing() async throws {
        let restoreAutoPlay = Hardening.disableAutoPlay()
        defer { restoreAutoPlay() }
        let container = try ModelContainer(for: TrackModel.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let folder = directory.appending(path: "Album")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appending(path: "01 a.wav")
        let second = folder.appending(path: "02 b.wav")
        try Hardening.tone(first, frequency: 523)
        try Hardening.tone(second, frequency: 587)
        let caches = try [first, second].map { try Hardening.cacheStems(for: $0) }
        defer { caches.forEach { try? FileManager.default.removeItem(at: $0) } }
        let importer = ImportCoordinator()
        let engine = AudioEngineManager()
        importer.importFiles([folder], context: container.mainContext, engine: engine)
        // A library track's recovery split takes the engine before the listing returns.
        engine.isSplitting = true
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(importer.isImporting)
        XCTAssertEqual(importer.batchCount, 0, "The batch must not start while another separation runs")
        XCTAssertNil(engine.errorMessage)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<TrackModel>()), 0)
        engine.isSplitting = false
        await Hardening.finish(importer)
        XCTAssertNil(engine.errorMessage, "No file may be reported as failed")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<TrackModel>()), 2)
        engine.unloadTrack()
    }

    // MARK: - Staging lock (separation-2)

    func testSweepKeepsStagingThatALiveProcessLocks() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: StemCache.root, withIntermediateDirectories: true)
        let live = StemCache.root.appending(path: ".partial-\(UUID().uuidString)")
        let crashed = StemCache.root.appending(path: ".partial-\(UUID().uuidString)")
        let legacy = StemCache.root.appending(path: ".partial-\(UUID().uuidString)")
        for folder in [live, crashed, legacy] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("audio".utf8).write(to: folder.appending(path: "original.wav"))
        }
        defer { [live, crashed, legacy].forEach { try? fm.removeItem(at: $0) } }
        // flock locks taken through separate descriptors conflict even within one
        // process, so a held descriptor stands in for another running copy.
        let held = StemCache.lockStaging(live)
        XCTAssertGreaterThanOrEqual(held, 0)
        let released = StemCache.lockStaging(crashed)
        XCTAssertGreaterThanOrEqual(released, 0)
        close(released) // As when the owning process exits or crashes.
        XCTAssertTrue(StemCache.isStagingLocked(live))
        XCTAssertFalse(StemCache.isStagingLocked(crashed))
        StemCache.removeAbandonedStaging()
        XCTAssertTrue(fm.fileExists(atPath: live.appending(path: "original.wav").path))
        XCTAssertFalse(fm.fileExists(atPath: crashed.path))
        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "Staging from an older version has no lock and is abandoned")
        close(held)
        StemCache.removeAbandonedStaging()
        XCTAssertFalse(fm.fileExists(atPath: live.path))
    }

    func testPublishedCacheCarriesNoLockFile() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: StemCache.root, withIntermediateDirectories: true)
        let staging = StemCache.root.appending(path: ".partial-\(UUID().uuidString)")
        let destination = StemCache.root.appending(path: "published-\(UUID().uuidString)")
        defer { [staging, destination].forEach { try? fm.removeItem(at: $0) } }
        try Hardening.distinctStems(in: staging)
        let lock = StemCache.lockStaging(staging)
        XCTAssertGreaterThanOrEqual(lock, 0)
        defer { close(lock) }
        try StemCache.publish(staging, to: destination)
        XCTAssertNotNil(StemCache.validFiles(in: destination))
        XCTAssertFalse(fm.fileExists(atPath: destination.appending(path: ".lock").path))
        XCTAssertFalse(fm.fileExists(atPath: staging.path))
    }

    func testSeparationSurvivesASweepFromAnotherCopy() async throws {
        let source = directory.appending(path: "shared-cache.wav")
        try Hardening.tone(source, frequency: 392, amplitude: Float.random(in: 0.15...0.25), seconds: 1)
        let swept = OSAllocatedUnfairLock(initialState: false)
        let stems = try await Hardening.splitRequiringModel(source) { info in
            guard info.statusMessage == "SEPARATING STEMS...", !swept.withLock({ $0 }) else { return }
            // What a second running copy's launch sweep does mid-separation.
            StemCache.removeAbandonedStaging()
            swept.withLock { $0 = true }
        }
        defer { Hardening.removeCache(stems) }
        XCTAssertTrue(swept.withLock { $0 }, "The sweep must run while inference is under way")
        XCTAssertEqual(stems.count, 4)
        XCTAssertNotNil(StemCache.validFiles(in: try XCTUnwrap(stems.first).deletingLastPathComponent()))
    }
}
