import XCTest
import AVFoundation
@testable import Isolate

/// Collects progress reports made on the rendering thread.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

@MainActor
final class ExporterFixTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// Writes stereo Float32 audio, so samples above full scale are preserved like cached stems.
    private func audio(_ name: String, frames: Int, sample: (Int) -> Float) throws -> URL {
        let url = directory.appending(path: name)
        let buffer = AVAudioPCMBuffer(pcmFormat: StreamingAudio.format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<frames {
            let value = sample(frame)
            buffer.floatChannelData![0][frame] = value
            buffer.floatChannelData![1][frame] = value
        }
        let file = try AVAudioFile(forWriting: url, settings: StreamingAudio.settings)
        try file.write(from: buffer)
        return url
    }

    private func samples(_ url: URL, channel: Int = 0) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
    }

    private func energy<C: Collection>(_ values: C) -> Double where C.Element == Float {
        values.reduce(0) { $0 + Double($1) * Double($1) }
    }

    private func tone(_ frame: Int, amplitude: Float = 0.2) -> Float {
        amplitude * sin(Float(frame) * 2 * .pi * 440 / 44_100)
    }

    private func extract(_ archive: URL) throws -> URL {
        let folder = directory.appending(path: UUID().uuidString)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/unzip")
        process.arguments = ["-q", archive.path, "-d", folder.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return folder
    }

    private func stems(amplitudes: [Float], frequency: Float = 440) throws -> [AudioExporter.Source] {
        try amplitudes.enumerated().map { index, amplitude in
            .init(url: try audio("stem-\(index).wav", frames: 8820) {
                amplitude * sin(Float($0) * 2 * .pi * frequency / 44_100)
            })
        }
    }

    func testStemArchiveLowersAllStemsTogetherInsteadOfClipping() throws {
        // Cached Float32 stems can peak above 1.0; 24-bit output used to hard-clip them.
        let amplitudes: [Float] = [1.5, 0.75, 0.3, 0.15]
        let sources = try stems(amplitudes: amplitudes)
        for format in AudioExporter.Format.allCases {
            let archive = directory.appending(path: "stems.\(format.fileExtension).zip")
            let gain = try AudioExporter.archive(sources: sources, title: "Headroom", format: format, to: archive) { _ in }
            XCTAssertEqual(gain, AudioExporter.stemPeakCeiling / 1.5, accuracy: 1e-3)
            let folder = try extract(archive)
            var peaks: [Float] = []
            for stem in DemucsEngine.stemNames {
                let url = folder.appending(path: "Headroom_\(stem).\(format.fileExtension)")
                if format == .wav {
                    XCTAssertEqual(try AVAudioFile(forReading: url).fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
                }
                let left = try samples(url)
                let right = try samples(url, channel: 1)
                XCTAssertFalse(left.contains { abs($0) >= 0.999 }, "\(format) \(stem) must not reach full scale")
                peaks.append(max(left.map(abs).max() ?? 0, right.map(abs).max() ?? 0))
            }
            XCTAssertLessThanOrEqual(peaks[0], AudioExporter.stemPeakCeiling + 1e-6)
            XCTAssertEqual(peaks[0], AudioExporter.stemPeakCeiling, accuracy: 1e-3)
            for (peak, amplitude) in zip(peaks, amplitudes) {
                XCTAssertEqual(peak / peaks[0], amplitude / amplitudes[0], accuracy: 1e-3, "Relative stem balance must be kept")
            }
        }
    }

    func testStemArchiveMeasuresHeadroomAfterEQBoost() throws {
        var sources = try stems(amplitudes: [0.5, 0.1, 0.1, 0.1], frequency: 60)
        sources[0].eq = .init(low: 12)
        let archive = directory.appending(path: "boosted.zip")
        let gain = try AudioExporter.archive(sources: sources, title: "Boost", format: .wav, to: archive) { _ in }
        XCTAssertLessThan(gain, 0.9, "A +12 dB low shelf pushes a 0.5 bass stem well past full scale")
        let bass = try samples(try extract(archive).appending(path: "Boost_vocals.wav"))
        let peak = bass.map(abs).max() ?? 0
        XCTAssertLessThanOrEqual(peak, AudioExporter.stemPeakCeiling + 1e-6)
        XCTAssertGreaterThan(peak, 0.9)
    }

    func testStemArchiveLeavesStemsBelowFullScaleUnchanged() throws {
        let archive = directory.appending(path: "quiet.zip")
        let gain = try AudioExporter.archive(sources: try stems(amplitudes: [0.2, 0.2, 0.2, 0.2]),
                                             title: "Quiet", format: .wav, to: archive) { _ in }
        XCTAssertEqual(gain, 1)
        let output = try samples(try extract(archive).appending(path: "Quiet_drums.wav"))
        let input = try samples(directory.appending(path: "stem-1.wav"))
        XCTAssertEqual(output.count, input.count)
        for (exported, original) in zip(output, input) {
            XCTAssertEqual(exported, original, accuracy: 2e-7)
        }
    }

    func testMixRenderReportsThrottledProgressUpToCompletion() throws {
        let source = try audio("long.wav", frames: 441_000) { self.tone($0) }
        let log = ProgressLog()
        try AudioExporter.render(sources: [.init(url: source)], to: directory.appending(path: "mix.wav"),
                                 rate: 0.5, limitPeak: true) { log.append($0) }
        let values = log.values
        XCTAssertGreaterThan(values.count, 10, "Progress must move during the render, not only at the end")
        XCTAssertLessThanOrEqual(values.count, 100, "Reports are limited to one per whole percent")
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(Set(values).count, values.count)
        XCTAssertGreaterThan(values.first ?? 0, 0)
    }

    func testStemArchiveProgressMovesThroughRenderingAndEncoding() throws {
        let log = ProgressLog()
        try AudioExporter.archive(sources: try stems(amplitudes: [0.2, 0.2, 0.2, 0.2]), title: "Progress",
                                  format: .flac, to: directory.appending(path: "progress.zip")) { log.append($0) }
        let values = log.values
        XCTAssertEqual(values, values.sorted())
        XCTAssertTrue(values.contains { $0 > 0 && $0 < 0.4 }, "Stem rendering reports progress")
        XCTAssertTrue(values.contains { $0 > 0.4 && $0 < 0.8 }, "Stem encoding reports progress")
        XCTAssertTrue(values.contains(0.8), "The archive step starts at 80%")
        XCTAssertEqual(values.last, 1)
    }

    func testLimitedMixIsSampleAlignedAndKeepsItsLastFrames() throws {
        // An impulse at a known frame and a tone filling the final 200 frames.
        let source = try audio("aligned.wav", frames: 44_100) { frame in
            frame == 20_000 ? 0.5 : frame >= 43_900 ? self.tone(frame) : 0
        }
        let destination = directory.appending(path: "limited.wav")
        try AudioExporter.render(sources: [.init(url: source)], to: destination, limitPeak: true)
        let output = try samples(destination)
        let input = try samples(source)
        XCTAssertEqual(output.count, 44_100)
        let impulse = output.prefix(30_000).indices.max { abs(output[$0]) < abs(output[$1]) }
        XCTAssertEqual(impulse, 20_000, "The peak limiter's look-ahead must not delay the mix")
        XCTAssertGreaterThan(energy(output.suffix(200)), energy(input.suffix(200)) * 0.99,
                             "The limiter must not cut the final frames")
    }

    func testTimePitchExportKeepsTheFinalTransientEnergy() throws {
        // A 30 ms burst ends the file; the padded copy shows where time/pitch places all of it.
        let source = try audio("final.wav", frames: 44_100) { $0 < 42_777 ? 0 : self.tone($0) }
        let padded = try audio("padded.wav", frames: 88_200) { $0 < 42_777 || $0 >= 44_100 ? 0 : self.tone($0) }
        let settings: [(rate: Float, pitch: Float)] = [(1, 0), (0.5, 0), (1.5, 0), (2, 0), (1, 4), (1, -4)]
        for (index, controls) in settings.enumerated() {
            let exported = directory.appending(path: "export-\(index).wav")
            let reference = directory.appending(path: "reference-\(index).wav")
            try AudioExporter.render(sources: [.init(url: source)], to: exported,
                                     rate: controls.rate, pitch: controls.pitch, limitPeak: true)
            try AudioExporter.render(sources: [.init(url: padded)], to: reference,
                                     rate: controls.rate, pitch: controls.pitch, limitPeak: true)
            let expected = energy(try samples(reference))
            let kept = energy(try samples(exported))
            XCTAssertGreaterThan(expected, 1)
            XCTAssertGreaterThan(kept, expected * 0.999,
                                 "Final burst energy must survive export at rate \(controls.rate), pitch \(controls.pitch)")
            let stretched = AVAudioFramePosition(ceil(44_100 / Double(controls.rate)))
            let tail: AVAudioFramePosition = controls.rate == 1 && controls.pitch == 0 ? 0 : 4096
            XCTAssertEqual(try AVAudioFile(forReading: exported).length, stretched + tail)
        }
    }

    func testSafeFilenameNeverProducesHiddenOrWindowsInvalidNames() {
        XCTAssertEqual(AudioExporter.safeFilename("...Baby One More Time"), "Baby One More Time")
        XCTAssertEqual(AudioExporter.safeFilename(".38 Special - Hold On Loosely"), "38 Special - Hold On Loosely")
        XCTAssertEqual(AudioExporter.safeFilename("Where Is My Mind?"), "Where Is My Mind_")
        XCTAssertEqual(AudioExporter.safeFilename("The \"Heroes\" <*|>"), "The _Heroes_ ____")
        XCTAssertEqual(AudioExporter.safeFilename("Trailing dots... "), "Trailing dots")
        XCTAssertEqual(AudioExporter.safeFilename("Beyoncé"), "Beyoncé")
        for title in [".", "..", "...", " . . ", ""] {
            XCTAssertEqual(AudioExporter.safeFilename(title), "Isolate", "Title \(title.debugDescription)")
        }
        // Truncation must not leave a trailing space or dot either.
        let long = AudioExporter.safeFilename(String(repeating: "a", count: 119) + " tail")
        XCTAssertFalse(long.hasSuffix(" ") || long.hasSuffix("."))
        for title in ["..Hidden", "A?B*C\"D<E>F|G:H/I\\J", "Name. ", String(repeating: "音", count: 90) + "🎵"] {
            let name = AudioExporter.safeFilename(title)
            XCTAssertFalse(name.hasPrefix("."), name)
            XCTAssertFalse(name.hasSuffix(".") || name.hasSuffix(" "), name)
            XCTAssertNil(name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\\?*\"<>|")), name)
        }
    }
}
