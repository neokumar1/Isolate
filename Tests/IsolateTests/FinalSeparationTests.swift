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
}
