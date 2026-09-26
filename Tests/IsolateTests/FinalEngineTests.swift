import XCTest
import AVFoundation
import IOKit.pwr_mgt
import os
@testable import Isolate

@MainActor
final class FinalEngineTests: XCTestCase {
    private var directory: URL!
    private var restoreAutoPlay: (() -> Void)?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Hosted tests share one preferences domain; these tests rely on autoplay.
        let key = "isAutoPlayDisabled"
        let previous = AppPreferences.defaults.object(forKey: key) as? Bool
        AppPreferences.defaults.set(false, forKey: key)
        restoreAutoPlay = {
            if let previous { AppPreferences.defaults.set(previous, forKey: key) }
            else { AppPreferences.defaults.removeObject(forKey: key) }
        }
    }

    override func tearDownWithError() throws {
        restoreAutoPlay?()
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    /// Deterministic white noise in every stem, scaled per stem in model order. Scales
    /// 3, -1, -1, -1 sum to exact silence only while all four players render the same frame.
    private func noiseTrack(seconds: Double, scales: [Float], folder: String = "stems") throws -> TrackModel {
        let stems = directory.appending(path: folder)
        try FileManager.default.createDirectory(at: stems, withIntermediateDirectories: true)
        func write(_ url: URL, scale: Float) throws {
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            try Hardening.write(url, frames: Int(44_100 * seconds)) { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * 0.1 * scale
            }
        }
        let original = stems.appending(path: "original.wav")
        try write(original, scale: 1)
        let urls = DemucsEngine.stemNames.map { stems.appending(path: "\($0).wav") }
        for (url, scale) in zip(urls, scales) { try write(url, scale: scale) }
        return TrackModel(id: original.path, title: "Timing Probe", originalURL: original,
                          vocalStemURL: urls[0], bassStemURL: urls[2], drumStemURL: urls[1], otherStemURL: urls[3])
    }

    /// Collects channel 0 of every tap buffer in delivery order.
    private final class TapRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []

        /// Formed outside the main actor: the tap runs on the audio engine's thread.
        var tap: AVAudioNodeTapBlock {
            { [self] buffer, _ in
                guard let channel = buffer.floatChannelData?[0] else { return }
                let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                lock.lock()
                samples.append(contentsOf: chunk)
                lock.unlock()
            }
        }

        /// Silent runs with audio on both sides, in seconds.
        func silentGaps() -> [Double] {
            lock.lock()
            defer { lock.unlock() }
            var gaps: [Double] = []
            var heardAudio = false
            var silent = 0
            for sample in samples {
                if abs(sample) < 1e-7 {
                    silent += 1
                } else {
                    if heardAudio && silent >= 32 { gaps.append(Double(silent) / 44_100) }
                    heardAudio = true
                    silent = 0
                }
            }
            return gaps
        }

        /// Stretches of audible output, in seconds; zero crossings within 256 frames do not split one.
        func audibleStretches() -> [Double] {
            lock.lock()
            defer { lock.unlock() }
            var stretches: [Double] = []
            var first: Int?
            var last = 0
            for (index, sample) in samples.enumerated() where abs(sample) >= 1e-3 {
                if let start = first, index - last > 256 {
                    stretches.append(Double(last - start + 1) / 44_100)
                    first = index
                } else if first == nil {
                    first = index
                }
                last = index
            }
            if let first { stretches.append(Double(last - first + 1) / 44_100) }
            return stretches
        }
    }

    /// Records what the master limiter renders while `body` runs.
    private func recordOutput(_ engine: AudioEngineManager, during body: () async throws -> Void) async throws -> TapRecorder {
        let recorder = TapRecorder()
        engine.masterLimiter.installTap(onBus: 0, bufferSize: 4096, format: nil, block: recorder.tap)
        defer { engine.masterLimiter.removeTap(onBus: 0) }
        try await body()
        // Let the tap deliver its last buffer (about 0.1 s) before reading.
        try await Task.sleep(for: .milliseconds(250))
        return recorder
    }

    /// The short gaps come from render-timeline starts. An output that never honored one
    /// makes the engine use host-time starts for good, which these measurements do not cover.
    private func requireRenderTimelineStarts(_ engine: AudioEngineManager) async throws {
        // Past the watchdog, which checks the start a quarter second after it was due.
        try await Task.sleep(for: .milliseconds(500))
        guard let report = engine.lastStartReport, report.usedRenderTimeline, report.watchdogRestarts == 0 else {
            throw XCTSkip("This output does not honor render-timeline starts: \(describe(engine))")
        }
    }

    private func describe(_ engine: AudioEngineManager) -> String {
        engine.lastStartReport.map {
            "attempts \($0.attempts), lead \(String(format: "%.3f", $0.lead)) s, together \($0.startedTogether), timeline \($0.usedRenderTimeline), watchdog restarts \($0.watchdogRestarts)"
        } ?? "no start report"
    }

    private func milliseconds(_ durations: [Double]) -> String {
        durations.map { String(format: "%.1f ms", $0 * 1000) }.joined(separator: ", ")
    }

    /// Loops the shortest region allowed, where a long gap costs the most, from `start`.
    /// The seek into it also flushes the time/pitch tail, so recordings begin after it.
    private func loopShortestRegion(_ engine: AudioEngineManager, from start: Double) async throws {
        let duration = try XCTUnwrap(engine.totalTrackDuration)
        engine.setLoopStart(start)
        engine.setLoopEnd(start + AudioEngineManager.minimumLoopSeconds / duration)
        engine.seek(toPercentage: start)
        try await Task.sleep(for: .milliseconds(150))
    }

    // MARK: - Short, aligned restarts

    func testLoopWrapsLeaveOnlyAShortSilentGap() async throws {
        let engine = AudioEngineManager()
        await engine.loadTrack(try noiseTrack(seconds: 6, scales: [1, 1, 1, 1]))
        try Hardening.requirePlayback(engine)
        try await requireRenderTimelineStarts(engine)
        try await loopShortestRegion(engine, from: 0.2)
        let gaps = try await recordOutput(engine) {
            try await Task.sleep(for: .milliseconds(2300))
        }.silentGaps()
        XCTAssertGreaterThanOrEqual(gaps.count, 3, "Expected a gap at each wrap: \(milliseconds(gaps))")
        // Each wrap waited about 0.11 s at a 512-frame buffer before the fix; the render-timeline
        // start needs about three IO cycles after the stop.
        let limit = max(0.06, 5 * engine.outputCycleDuration())
        print("Loop wrap gaps: \(milliseconds(gaps)); IO cycle \(String(format: "%.1f", engine.outputCycleDuration() * 1000)) ms")
        let median = gaps.sorted()[gaps.count / 2]
        XCTAssertLessThan(median, limit, "Loop wraps went silent too long: \(milliseconds(gaps)) (\(describe(engine)))")
        XCTAssertEqual(engine.lastStartReport?.watchdogRestarts, 0)
        engine.unloadTrack()
    }

    func testLoopWrapsStartTheStemsTogether() async throws {
        let engine = AudioEngineManager()
        await engine.loadTrack(try noiseTrack(seconds: 6, scales: [3, -1, -1, -1]))
        try Hardening.requirePlayback(engine)
        try await requireRenderTimelineStarts(engine)
        try await loopShortestRegion(engine, from: 0.5)
        var stems = [Float](repeating: 0, count: 4)
        let stretches = try await recordOutput(engine) {
            let clock = ContinuousClock()
            let end = clock.now + .milliseconds(2300)
            while clock.now < end {
                try await Task.sleep(for: .milliseconds(15))
                for index in stems.indices { stems[index] = max(stems[index], engine.stemMeters[index].peak) }
            }
        }.audibleStretches()
        // Every stem must be audible on its own, or a silent sum would prove nothing.
        for (index, peak) in stems.enumerated() {
            XCTAssertGreaterThan(peak, 0.05, "Stem \(index) did not play (\(describe(engine)))")
        }
        // Stopping the five players can span a render cycle or two as a pass ends; players
        // started on different frames would leave the whole next pass uncancelled.
        let limit = 4 * engine.outputCycleDuration()
        XCTAssertLessThan(stretches.max() ?? 0, limit, "A wrap started the stems apart: \(milliseconds(stretches)) (\(describe(engine)))")
        XCTAssertEqual(engine.lastStartReport?.watchdogRestarts, 0)
        engine.unloadTrack()
    }

    func testLoopWrapAfterAPauseStartsPromptly() async throws {
        let engine = AudioEngineManager()
        await engine.loadTrack(try noiseTrack(seconds: 6, scales: [1, 1, 1, 1]))
        try Hardening.requirePlayback(engine)
        try await requireRenderTimelineStarts(engine)
        try await loopShortestRegion(engine, from: 0.3)
        let gaps = try await recordOutput(engine) {
            // While paused the players' sample time stands still, but the host time reported with
            // it keeps counting, so a start derived from host time would come late by the pause.
            engine.togglePlayback()
            try await Task.sleep(for: .milliseconds(800))
            engine.togglePlayback()
            try await Task.sleep(for: .milliseconds(1300))
        }.silentGaps()
        print("Loop wrap gaps after a pause: \(milliseconds(gaps))")
        XCTAssertEqual(engine.lastStartReport?.watchdogRestarts, 0, "A start after the pause never took effect (\(describe(engine)))")
        XCTAssertFalse(gaps.isEmpty, "Expected a gap at each wrap")
        // A host-time start left about 0.4 s of silence here, until the watchdog restarted it.
        XCTAssertLessThan(gaps.max() ?? 0, 0.2, "A wrap after the pause went silent too long: \(milliseconds(gaps))")
        engine.unloadTrack()
    }

    // MARK: - Reselecting the loaded track

    func testReselectingAFinishedTrackPlaysItAgain() async throws {
        let short = try noiseTrack(seconds: 0.4, scales: [1, 1, 1, 1], folder: "short")
        let engine = AudioEngineManager()
        await engine.loadTrack(short)
        try Hardening.requirePlayback(engine)
        engine.vocalVolume = 0.5
        let ended = await Hardening.wait(timeout: .seconds(8)) { !engine.isPlaying && engine.playbackProgress == 1 }
        XCTAssertTrue(ended, "A 0.4 s track must play to its end")

        await engine.loadTrack(short)
        XCTAssertTrue(engine.isPlaying, "Selecting the finished track must play it again")
        XCTAssertLessThan(engine.playbackProgress, 1)
        XCTAssertEqual(engine.vocalVolume, 0.5, "Replaying keeps the mix")

        // Without autoplay, selecting only loads; a finished track stays where it ended.
        let endedAgain = await Hardening.wait(timeout: .seconds(8)) { !engine.isPlaying && engine.playbackProgress == 1 }
        XCTAssertTrue(endedAgain)
        AppPreferences.defaults.set(true, forKey: "isAutoPlayDisabled")
        await engine.loadTrack(short)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.playbackProgress, 1)
        AppPreferences.defaults.set(false, forKey: "isAutoPlayDisabled")

        // Mid-track, reselecting neither restarts nor resumes.
        let long = try noiseTrack(seconds: 6, scales: [1, 1, 1, 1], folder: "long")
        await engine.loadTrack(long)
        try Hardening.requirePlayback(engine)
        try await Task.sleep(for: .milliseconds(300))
        engine.togglePlayback()
        let position = engine.playbackProgress
        XCTAssertGreaterThan(position, 0)
        await engine.loadTrack(long)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.playbackProgress, position)
        engine.unloadTrack()
    }
}
