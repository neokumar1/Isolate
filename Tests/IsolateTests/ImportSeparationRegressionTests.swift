import XCTest
import AVFoundation
import SwiftData
import UniformTypeIdentifiers
@testable import Isolate

@MainActor
final class ImportSeparationRegressionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func audio(frames: Int = 8192, rightGain: Float = 0.5, amplitude: Float = 0.5) throws -> URL {
        let url = directory.appending(path: "source.wav")
        let buffer = AVAudioPCMBuffer(pcmFormat: StreamingAudio.format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<frames {
            let sample = amplitude * sin(Float(frame) * 2 * .pi / 64)
            buffer.floatChannelData![0][frame] = sample
            buffer.floatChannelData![1][frame] = sample * rightGain
        }
        let file = try AVAudioFile(forWriting: url, settings: StreamingAudio.settings)
        try file.write(from: buffer)
        return url
    }

    func testOppositePhaseStereoDoesNotExplodeModelNormalization() throws {
        let source = try audio(rightGain: -1)
        let destination = directory.appending(path: "decoded.wav")
        let statistics = try StreamingAudio.decode(source, to: destination)
        XCTAssertEqual(statistics.mean, 0, accuracy: 1e-7)
        XCTAssertEqual(statistics.standardDeviation, 0.5 / sqrt(2), accuracy: 0.001)
        let file = try AVAudioFile(forReading: destination)
        let buffer = AVAudioPCMBuffer(pcmFormat: StreamingAudio.format, frameCapacity: 8192)!
        try file.read(into: buffer)
        for frame in 0..<Int(buffer.frameLength) {
            XCTAssertEqual(buffer.floatChannelData![0][frame], -buffer.floatChannelData![1][frame], accuracy: 1e-7)
            XCTAssertLessThanOrEqual(abs(buffer.floatChannelData![0][frame] / statistics.standardDeviation), 1.415)
        }
    }

    func testSilentAudioHasFiniteNormalization() throws {
        let source = try audio(amplitude: 0)
        let statistics = try StreamingAudio.decode(source, to: directory.appending(path: "decoded.wav"))
        XCTAssertEqual(statistics.frames, 8192)
        XCTAssertEqual(statistics.mean, 0)
        XCTAssertEqual(statistics.standardDeviation, 1e-4)
    }

    func testOppositePhaseStereoSeparatesIntoFiniteAudibleStems() async throws {
        let source = try audio(rightGain: -1)
        let stems: [URL]
        do {
            stems = try await DemucsEngine.shared.splitAudio(url: source) { _ in }
        } catch DemucsError.modelNotFound(let message) {
            if ProcessInfo.processInfo.environment["ISOLATE_REQUIRE_MODEL"] == "1" {
                XCTFail(message)
                return
            }
            throw XCTSkip("Install the model to run inference: \(message)")
        }
        defer {
            if let directory = stems.first?.deletingLastPathComponent(), StemCache.owns(directory) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        XCTAssertEqual(stems.count, 4)
        var peak: Float = 0
        for url in stems {
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.length, 8192)
            let buffer = AVAudioPCMBuffer(pcmFormat: StreamingAudio.format, frameCapacity: 8192)!
            try file.read(into: buffer)
            for channel in 0..<2 {
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = buffer.floatChannelData![channel][frame]
                    XCTAssertTrue(sample.isFinite)
                    peak = max(peak, abs(sample))
                }
            }
        }
        XCTAssertGreaterThan(peak, 0.001, "Opposite-phase source audio must not disappear during normalization.")
    }

    func testInteriorWindowsReuseBufferAndPreserveBothChannels() throws {
        let source = try audio()
        let file = try AVAudioFile(forReading: source)
        let buffer = AVAudioPCMBuffer(pcmFormat: StreamingAudio.format, frameCapacity: 1024)!
        for start in [0, 1025, 7168] {
            try StreamingAudio.readWindow(file: file, start: start, count: 1024, into: buffer)
            XCTAssertEqual(buffer.frameLength, 1024)
            for frame in 0..<1024 {
                let expected = Float(0.5) * sin(Float(start + frame) * 2 * .pi / 64)
                XCTAssertEqual(buffer.floatChannelData![0][frame], expected, accuracy: 1e-6)
                XCTAssertEqual(buffer.floatChannelData![1][frame], expected * 0.5, accuracy: 1e-6)
            }
        }
        XCTAssertThrowsError(try StreamingAudio.readWindow(file: file, start: 0, count: 0, into: buffer))
    }

    func testDropReservesImportSlotUntilProvidersResolve() async throws {
        let container = try ModelContainer(for: TrackModel.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let importer = ImportCoordinator()
        let engine = AudioEngineManager()
        // A non-audio URL exercises asynchronous provider resolution without a model or audio device.
        let url = directory.appending(path: "notes.txt")
        try Data("not audio".utf8).write(to: url)
        let provider = NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
        XCTAssertTrue(importer.acceptDrop([provider], context: container.mainContext, engine: engine))
        XCTAssertTrue(importer.isImporting)
        XCTAssertFalse(importer.acceptDrop([provider], context: container.mainContext, engine: engine))
        let deadline = Date.now.addingTimeInterval(5)
        while importer.isImporting, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(importer.isImporting)
        XCTAssertNotNil(engine.errorMessage)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<TrackModel>()), 0)
        XCTAssertFalse(importer.acceptDrop([NSItemProvider(object: "text" as NSString)], context: container.mainContext, engine: engine))
    }
}
