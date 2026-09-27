import XCTest
import AVFoundation
@testable import Isolate

@MainActor
final class AudioFeatureAnalyzerTests: XCTestCase {
    private let rate = 11_025.0

    func testSteadyBeatAndChordAreMeasured() {
        let count = Int(rate * 24)
        let beat = (0..<count).map { i -> Float in
            let time = Double(i) / rate
            let sinceBeat = time.truncatingRemainder(dividingBy: 0.5)
            return Float(0.7 * exp(-sinceBeat * 35) * sin(2 * .pi * 90 * sinceBeat))
        }
        let chord = (0..<count).map { i -> Float in
            let time = Double(i) / rate
            return Float(0.20 * sin(2 * .pi * 261.63 * time) +
                         0.17 * sin(2 * .pi * 329.63 * time) +
                         0.18 * sin(2 * .pi * 392.00 * time))
        }
        XCTAssertEqual(AudioFeatureAnalyzer.estimateTempo(in: (beat, rate)) ?? 0, 120, accuracy: 1.5)
        XCTAssertEqual(AudioFeatureAnalyzer.estimateKey(in: (chord, rate)), "C major")
    }

    func testSilenceAndSingleToneDoNotInventMetadata() {
        let silence = [Float](repeating: 0, count: Int(rate * 10))
        XCTAssertNil(AudioFeatureAnalyzer.estimateTempo(in: (silence, rate)))
        XCTAssertNil(AudioFeatureAnalyzer.estimateKey(in: (silence, rate)))
        let tone = (0..<Int(rate * 10)).map { i in
            Float(0.2 * sin(2 * .pi * 440 * Double(i) / rate))
        }
        XCTAssertNil(AudioFeatureAnalyzer.estimateTempo(in: (tone, rate)))
        XCTAssertNil(AudioFeatureAnalyzer.estimateKey(in: (tone, rate)))
    }

    func testSpeedAndPitchUpdateTheMeasuredDisplayValues() {
        let engine = AudioEngineManager()
        engine.trackBPM = "120.0 BPM"
        engine.trackMusicalKey = "C major"
        engine.playbackRate = 1.25
        engine.pitchShiftSemitones = 2
        XCTAssertEqual(engine.effectiveBPM, "150.0 BPM")
        XCTAssertEqual(engine.effectiveMusicalKey, "D major")
        engine.playbackRate = 0.5
        engine.pitchShiftSemitones = -1
        XCTAssertEqual(engine.effectiveBPM, "60.0 BPM")
        XCTAssertEqual(engine.effectiveMusicalKey, "B major")
    }

    func testUntaggedTrackPublishesMeasuredValuesAndCancelsOnUnload() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "IsolateAnalysis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 2, interleaved: false)!
        let original = folder.appending(path: "original.wav")
        let drums = folder.appending(path: "drums.wav")
        do {
            let originalWriter = try AVAudioFile(forWriting: original, settings: format.settings)
            let drumWriter = try AVAudioFile(forWriting: drums, settings: format.settings)
            let chordBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
            let drumBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
            chordBuffer.frameLength = chordBuffer.frameCapacity
            drumBuffer.frameLength = drumBuffer.frameCapacity
            for second in 0..<12 {
                for i in 0..<44_100 {
                    let time = Double(second) + Double(i) / 44_100
                    let chord = Float(0.20 * sin(2 * .pi * 261.63 * time) +
                                      0.17 * sin(2 * .pi * 329.63 * time) +
                                      0.18 * sin(2 * .pi * 392 * time))
                    let phase = time.truncatingRemainder(dividingBy: 0.5)
                    let beat = Float(0.7 * exp(-phase * 35) * sin(2 * .pi * 90 * phase))
                    for channel in 0..<2 {
                        chordBuffer.floatChannelData![channel][i] = chord
                        drumBuffer.floatChannelData![channel][i] = beat
                    }
                }
                try originalWriter.write(from: chordBuffer)
                try drumWriter.write(from: drumBuffer)
            }
        }
        let vocals = folder.appending(path: "vocals.wav")
        let bass = folder.appending(path: "bass.wav")
        let other = folder.appending(path: "other.wav")
        for stem in [vocals, bass, other] {
            try FileManager.default.createSymbolicLink(at: stem, withDestinationURL: original)
        }
        let track = TrackModel(id: original.path, title: "Synthetic", originalURL: original,
                               vocalStemURL: vocals, bassStemURL: bass,
                               drumStemURL: drums, otherStemURL: other)
        let engine = AudioEngineManager()
        addTeardownBlock(Hardening.disableAutoPlay())
        await engine.loadTrack(track)
        let analyzed = await Hardening.wait(timeout: .seconds(15)) {
            engine.trackBPM != "BPM UNKNOWN" && engine.trackMusicalKey != "KEY UNKNOWN"
        }
        XCTAssertTrue(analyzed, "Untagged audio should publish its measured tempo and key")
        XCTAssertEqual(Double(engine.trackBPM.replacingOccurrences(of: " BPM", with: "")) ?? 0,
                       120, accuracy: 0.5)
        XCTAssertEqual(engine.trackMusicalKey, "C major")
        engine.playbackRate = 1.5
        engine.pitchShiftSemitones = 2
        XCTAssertEqual(Double(engine.effectiveBPM.replacingOccurrences(of: " BPM", with: "")) ?? 0,
                       180, accuracy: 1)
        XCTAssertEqual(engine.effectiveMusicalKey, "D major")
        engine.unloadTrack()
        XCTAssertEqual(engine.trackBPM, "BPM UNKNOWN")
        XCTAssertEqual(engine.trackMusicalKey, "KEY UNKNOWN")
        await engine.loadTrack(track)
        engine.unloadTrack()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(engine.trackBPM, "BPM UNKNOWN", "A cancelled analysis must not update a later track")
        XCTAssertEqual(engine.trackMusicalKey, "KEY UNKNOWN")
    }
}
