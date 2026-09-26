import XCTest
import AVFoundation
@testable import Isolate

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
