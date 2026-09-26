import XCTest
import AVFoundation
@testable import Isolate

/// Inference checks that need the installed model. They skip only when no model is
/// installed (and fail then too with ISOLATE_REQUIRE_MODEL=1); a model that is present
/// but cannot load fails them.
@MainActor
final class HardeningModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "HardeningModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// A melody of 250 ms notes with harmonics, so no two 5 s hops look alike.
    private func melody(_ url: URL, seconds: Double) throws {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        let notes = (0..<Int(seconds * 4)).map { _ -> Double in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return 220 * pow(2, Double(state >> 60) / 12)
        }
        try Hardening.write(url, frames: Int(44_100 * seconds)) { frame in
            let note = notes[min(notes.count - 1, frame / 11_025)]
            let t = Double(frame) / 44_100
            let local = Double(frame % 11_025) / 11_025
            let envelope = min(1, local * 20) * (1 - 0.6 * local)
            let wave = sin(2 * .pi * note * t) + 0.5 * sin(4 * .pi * note * t) + 0.25 * sin(6 * .pi * note * t)
            return Float(0.2 * envelope * wave)
        }
    }

    func testSeparationReconstructsTheMixAcrossChunkBoundaries() async throws {
        // 12 s spans four overlapping chunks. A dropped, repeated or shifted hop would put
        // the wrong notes in the stems' sum for that stretch.
        let source = directory.appending(path: "melody.wav")
        try melody(source, seconds: 12)
        let stems = try await Hardening.splitRequiringModel(source)
        defer { Hardening.removeCache(stems) }
        let original = try Hardening.samples(source)
        let separated = try stems.map { try Hardening.samples($0) }
        XCTAssertTrue(separated.allSatisfy { $0.count == original.count }, "Every stem must match the source length")
        for second in 0..<12 {
            let range = (second * 44_100)..<((second + 1) * 44_100)
            var signal = 0.0, error = 0.0
            for frame in range {
                let sum = separated.reduce(Float(0)) { $0 + $1[frame] }
                signal += Double(original[frame] * original[frame])
                error += Double((original[frame] - sum) * (original[frame] - sum))
            }
            // The reference model measured 39.5-42.6 dB per second on this fixture; a hop
            // written in the wrong place sums to other notes, near 0 dB.
            let snr = 10 * log10(signal / max(error, 1e-12))
            XCTAssertGreaterThan(snr, 20, "Stems do not add back to the source in second \(second)")
        }
    }

    func testLowBassLineSeparatesIntoTheBassStem() async throws {
        // Swapped source labels (a conversion with another output order, or a mapping slip)
        // would put this in another file. Shape checks cannot see that.
        let source = directory.appending(path: "bassline.wav")
        try Hardening.write(source, frames: 44_100 * 6) { frame in
            let local = Double(frame % 22_050) / 44_100
            let note = [55.0, 73.4, 65.4, 49.0][(frame / 22_050) % 4]
            let t = Double(frame) / 44_100
            let wave = sin(2 * .pi * note * t) + 0.3 * sin(4 * .pi * note * t)
            return Float(0.35 * exp(-local * 3) * min(1, local * 200) * wave)
        }
        let stems = try await Hardening.splitRequiringModel(source)
        defer { Hardening.removeCache(stems) }
        XCTAssertEqual(stems.map(\.lastPathComponent), DemucsEngine.stemNames.map { "\($0).wav" })
        let levels = try stems.map { url -> Double in
            let samples = try Hardening.samples(url)
            return sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        }
        // With the reference model, bass.wav measured over 100 times the RMS of any other stem.
        for index in [0, 1, 3] {
            XCTAssertGreaterThan(levels[2], levels[index] * 10,
                                 "bass.wav must hold the bass line, not \(DemucsEngine.stemNames[index]).wav")
        }
    }
}
