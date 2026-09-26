import XCTest
import AVFoundation
@testable import Isolate

/// Opt-in release gate that separates real music. Set `TEST_RUNNER_ISOLATE_REAL_AUDIO_DIR`
/// to a folder of audio files when invoking `xcodebuild test`; ordinary runs skip.
final class RealMusicSmokeTests: XCTestCase {
    private static let extensions: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "flac", "caf"]

    func testRealMusicSeparatesIntoAlignedStemsThatReconstructTheMix() async throws {
        guard let path = ProcessInfo.processInfo.environment["ISOLATE_REAL_AUDIO_DIR"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_ISOLATE_REAL_AUDIO_DIR to run real-music separation.")
        }
        let sources = try FileManager.default.contentsOfDirectory(at: URL(filePath: path), includingPropertiesForKeys: nil)
            .filter { Self.extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(sources.isEmpty, "No audio files found in \(path)")

        for source in sources {
            let start = CFAbsoluteTimeGetCurrent()
            let stems: [URL]
            do {
                stems = try await DemucsEngine.shared.splitAudio(url: source) { _ in }
            } catch DemucsError.modelIncompatibleWithSystem(let detail) {
                throw XCTSkip("Core ML on this macOS cannot run the model correctly: \(detail)")
            }
            let seconds = CFAbsoluteTimeGetCurrent() - start
            let directory = try XCTUnwrap(stems.first?.deletingLastPathComponent())
            defer { if StemCache.owns(directory) { try? FileManager.default.removeItem(at: directory) } }

            XCTAssertEqual(stems.map { $0.deletingPathExtension().lastPathComponent }, DemucsEngine.stemNames)
            let original = try AVAudioFile(forReading: directory.appending(path: "original.wav"))
            let frames = Int(original.length)
            XCTAssertGreaterThan(frames, 0)
            let files = try stems.map { try AVAudioFile(forReading: $0) }
            for (file, url) in zip(files, stems) {
                XCTAssertEqual(Int(file.length), frames, "\(url.lastPathComponent) must match the original length")
                XCTAssertEqual(file.processingFormat.sampleRate, 44_100)
                XCTAssertEqual(file.processingFormat.channelCount, 2)
            }

            // Stream through all files, measuring stem energy and how well the stem sum
            // reconstructs the decoded original. Misaligned hops, wrong scaling, or lost
            // stems collapse this ratio even when every sample is finite.
            let block: AVAudioFrameCount = 65_536
            let buffers = (0..<5).map { _ in AVAudioPCMBuffer(pcmFormat: StreamingAudio.format, frameCapacity: block)! }
            var stemEnergy = [Double](repeating: 0, count: 4)
            var signal = 0.0, error = 0.0, peak: Float = 0
            var remaining = frames
            while remaining > 0 {
                let count = AVAudioFrameCount(min(Int(block), remaining))
                try original.read(into: buffers[4], frameCount: count)
                for (index, file) in files.enumerated() { try file.read(into: buffers[index], frameCount: count) }
                for channel in 0..<2 {
                    let mix = buffers[4].floatChannelData![channel]
                    for frame in 0..<Int(count) {
                        var sum: Float = 0
                        for stem in 0..<4 {
                            let sample = buffers[stem].floatChannelData![channel][frame]
                            XCTAssertTrue(sample.isFinite)
                            if !sample.isFinite { return }
                            stemEnergy[stem] += Double(sample * sample)
                            peak = max(peak, abs(sample))
                            sum += sample
                        }
                        signal += Double(mix[frame] * mix[frame])
                        error += Double((sum - mix[frame]) * (sum - mix[frame]))
                    }
                }
                remaining -= Int(count)
            }
            let reconstructionDB = 10 * log10(signal / max(error, 1e-12))
            let rms = stemEnergy.map { sqrt($0 / Double(frames * 2)) }
            let duration = Double(frames) / 44_100
            print(String(format: "REAL-MUSIC %@: %.1fs audio in %.1fs (%.1fx realtime), reconstruction %.1f dB, peak %.3f, RMS v/d/b/o %.4f %.4f %.4f %.4f",
                         source.lastPathComponent, duration, seconds, duration / seconds, reconstructionDB, peak,
                         rms[0], rms[1], rms[2], rms[3]))
            XCTAssertGreaterThan(reconstructionDB, 10, "\(source.lastPathComponent): stems should sum back to the mix")
            XCTAssertTrue(rms.allSatisfy { $0 > 1e-4 }, "\(source.lastPathComponent): every stem of a full mix should carry audio")
        }
    }
}
