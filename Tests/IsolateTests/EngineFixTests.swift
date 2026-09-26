import XCTest
import AVFoundation
@testable import Isolate

@MainActor
final class EngineFixTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// Deterministic white noise. Stems written with scales 3, -1, -1, -1 sum to exact
    /// silence only while all four players render the same source frame.
    private func noise(_ url: URL, seconds: Double, scale: Float) throws {
        let frames = Int(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: StreamingAudio.format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = buffer.frameCapacity
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for frame in 0..<frames {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let sample = (Float(state >> 40) / Float(1 << 24) * 2 - 1) * 0.1 * scale
            buffer.floatChannelData![0][frame] = sample
            buffer.floatChannelData![1][frame] = sample
        }
        let file = try AVAudioFile(forWriting: url, settings: StreamingAudio.settings)
        try file.write(from: buffer)
    }

    private func cancellingTrack(seconds: Double = 6, title: String = "Sync Probe",
                                 folder: String = "stems") throws -> TrackModel {
        let stems = directory.appending(path: folder)
        try FileManager.default.createDirectory(at: stems, withIntermediateDirectories: true)
        let original = stems.appending(path: "original.wav")
        try noise(original, seconds: seconds, scale: 1)
        let scales: [Float] = [3, -1, -1, -1]
        let urls = DemucsEngine.stemNames.map { stems.appending(path: "\($0).wav") }
        for (url, scale) in zip(urls, scales) { try noise(url, seconds: seconds, scale: scale) }
        return TrackModel(id: original.path, title: title, originalURL: original,
                          vocalStemURL: urls[0], bassStemURL: urls[2], drumStemURL: urls[1], otherStemURL: urls[3])
    }

    private func requirePlayback(_ engine: AudioEngineManager) throws {
        guard engine.isPlaying else {
            throw XCTSkip("No audio output device: \(engine.errorMessage ?? "playback did not start")")
        }
    }

    /// Polls the live meters. Returns the loudest master waveform block and each stem's peak.
    private func observeMeters(_ engine: AudioEngineManager, for duration: Duration = .milliseconds(600)) async throws -> (master: Float, stems: [Float]) {
        var master: Float = 0
        var stems = [Float](repeating: 0, count: 4)
        let clock = ContinuousClock()
        let end = clock.now + duration
        while clock.now < end {
            try await Task.sleep(for: .milliseconds(15))
            master = max(master, engine.masterWaveformAmplitudes.max() ?? 0)
            for index in stems.indices { stems[index] = max(stems[index], engine.stemPeaks[index]) }
        }
        return (master, stems)
    }

    private func assertStemsAligned(_ engine: AudioEngineManager, _ label: String,
                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let reading = try await observeMeters(engine)
        // Every stem must be audible on its own, or silence would prove nothing.
        for (index, peak) in reading.stems.enumerated() {
            XCTAssertGreaterThan(peak, 0.05, "\(label): stem \(index) did not play", file: file, line: line)
        }
        // The waveform floor is 0.05; any inter-stem offset leaves uncancelled noise far above it.
        XCTAssertLessThan(reading.master, 0.06, "\(label): stems started out of sync", file: file, line: line)
    }

    func testStemsStaySampleAlignedAcrossStartSeekAndPauseResume() async throws {
        let engine = AudioEngineManager()
        await engine.loadTrack(try cancellingTrack())
        try requirePlayback(engine)
        try await assertStemsAligned(engine, "autoplay")

        engine.seek(toPercentage: 0.4)
        XCTAssertTrue(engine.isPlaying)
        try await assertStemsAligned(engine, "seek while playing")

        for cycle in 0..<4 {
            engine.togglePlayback()
            XCTAssertFalse(engine.isPlaying)
            try await Task.sleep(for: .milliseconds(60))
            engine.togglePlayback()
            XCTAssertTrue(engine.isPlaying)
            try await Task.sleep(for: .milliseconds(120))
            if cycle == 3 { try await assertStemsAligned(engine, "pause/resume") }
        }
        engine.unloadTrack()
    }

    func testPauseEndAndUnloadReleaseTheOutputDevice() async throws {
        let engine = AudioEngineManager()
        await engine.loadTrack(try cancellingTrack())
        try requirePlayback(engine)
        XCTAssertTrue(engine.isOutputRunning)
        engine.togglePlayback()
        XCTAssertFalse(engine.isOutputRunning, "A paused player must not keep the audio device awake")
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)
        XCTAssertTrue(engine.isOutputRunning)
        engine.unloadTrack()
        XCTAssertFalse(engine.isOutputRunning)

        await engine.loadTrack(try cancellingTrack(seconds: 0.4, folder: "short"))
        try requirePlayback(engine)
        try await Task.sleep(for: .milliseconds(1600))
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.playbackProgress, 1)
        XCTAssertFalse(engine.isOutputRunning, "The engine must idle once the track has ended")
        engine.unloadTrack()
    }

    func testImportPausesPlaybackBeforeSeparating() async throws {
        let model = try cancellingTrack(seconds: 1)
        let cache = StemCache.root.appending(path: try StemCache.key(for: model.originalURL))
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let stems = model.originalURL.deletingLastPathComponent()
        for name in DemucsEngine.stemNames + ["original"] {
            try FileManager.default.copyItem(at: stems.appending(path: "\(name).wav"), to: cache.appending(path: "\(name).wav"))
        }
        let engine = AudioEngineManager()
        await engine.loadTrack(model)
        try requirePlayback(engine)
        let request = Task { await engine.loadAndSplitAudio(url: model.originalURL) }
        let deadline = Date.now.addingTimeInterval(5)
        while !engine.isSplitting && Date.now < deadline { await Task.yield() }
        XCTAssertTrue(engine.isSplitting)
        XCTAssertFalse(engine.isPlaying, "Starting an import must pause the playing track")
        XCTAssertFalse(engine.isOutputRunning)
        let imported = await request.value
        XCTAssertEqual(imported?.title, "original")
        engine.unloadTrack()
    }

    func testReselectingTheLoadedTrackKeepsMixLoopAndSpeed() async throws {
        let track = try cancellingTrack()
        let engine = AudioEngineManager()
        await engine.loadTrack(track)
        engine.vocalVolume = 0.5
        engine.drumPan = -0.5
        engine.bassSolo = true
        engine.playbackRate = 0.75
        engine.setLoopStart(0.2)
        engine.setLoopEnd(0.4)
        let sameEntry = TrackModel(id: track.id, title: track.title, originalURL: track.originalURL,
                                   vocalStemURL: track.vocalStemURL, bassStemURL: track.bassStemURL,
                                   drumStemURL: track.drumStemURL, otherStemURL: track.otherStemURL)
        for selection in [track, sameEntry] {
            await engine.loadTrack(selection)
            XCTAssertEqual(engine.vocalVolume, 0.5)
            XCTAssertEqual(engine.drumPan, -0.5)
            XCTAssertTrue(engine.bassSolo)
            XCTAssertEqual(engine.playbackRate, 0.75)
            XCTAssertTrue(engine.isLooping)
            XCTAssertEqual(engine.loopStartProgress, 0.2, accuracy: 1e-9)
            XCTAssertEqual(engine.loopEndProgress, 0.4, accuracy: 1e-9)
        }
        engine.unloadTrack()
    }

    func testSelectingABrokenEntryKeepsTheCurrentTrack() async throws {
        let track = try cancellingTrack(seconds: 1)
        let engine = AudioEngineManager()
        await engine.loadTrack(track)
        engine.vocalVolume = 0.5
        let missing = directory.appending(path: "missing")
        let broken = TrackModel(id: missing.appending(path: "gone.mp3").path, title: "Gone",
                                originalURL: missing.appending(path: "gone.mp3"),
                                vocalStemURL: missing.appending(path: "vocals.wav"),
                                bassStemURL: missing.appending(path: "bass.wav"),
                                drumStemURL: missing.appending(path: "drums.wav"),
                                otherStemURL: missing.appending(path: "other.wav"))
        await engine.loadTrack(broken)
        XCTAssertTrue(engine.errorMessage?.contains("NOT FOUND") == true)
        XCTAssertEqual(engine.currentTrackID, track.id)
        XCTAssertTrue(engine.hasLoadedTrack)
        XCTAssertEqual(engine.vocalVolume, 0.5)
        engine.unloadTrack()
    }

    func testLoopMarkersUseAbsoluteMinimumAndStartNewRegions() async throws {
        // Six minutes: a 4 s phrase must keep its end marker (2% would force 7.2 s).
        XCTAssertEqual(AudioEngineManager.minimumLoopProgress(duration: 360), 0.5 / 360, accuracy: 1e-12)
        XCTAssertLessThan(AudioEngineManager.minimumLoopProgress(duration: 360), 4.0 / 360)
        XCTAssertEqual(AudioEngineManager.minimumLoopProgress(duration: 0.4), 0.5)
        XCTAssertEqual(AudioEngineManager.minimumLoopProgress(duration: nil), 0.02)

        let engine = AudioEngineManager()
        engine.setLoopEnd(0.3)
        engine.setLoopStart(0.8)
        XCTAssertEqual(engine.loopStartProgress, 0.8)
        XCTAssertEqual(engine.loopEndProgress, 1.0, "A start after the old end begins a new region")
        engine.resetLoop()
        XCTAssertFalse(engine.isLooping)
        engine.setLoopStart(0.6)
        engine.setLoopEnd(0.2)
        XCTAssertEqual(engine.loopStartProgress, 0)
        XCTAssertEqual(engine.loopEndProgress, 0.2, "An end before the old start begins a new region")
        XCTAssertTrue(engine.isLooping)

        await engine.loadTrack(try cancellingTrack())
        engine.resetLoop()
        engine.setLoopStart(0.5)
        engine.setLoopEnd(0.51)
        XCTAssertEqual(engine.loopEndProgress, 0.5 + 0.5 / 6, accuracy: 1e-9)
        engine.setLoopEnd(0.7)
        XCTAssertEqual(engine.loopEndProgress, 0.7, accuracy: 1e-9)
        engine.unloadTrack()
    }

    func testSeekingToTheEndWhileLoopingWrapsToTheLoopStart() async throws {
        let engine = AudioEngineManager()
        await engine.loadTrack(try cancellingTrack())
        try requirePlayback(engine)
        engine.setLoopStart(0.3)
        engine.seek(toPercentage: 1)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.playbackProgress, 0.3, accuracy: 1e-9)

        engine.togglePlayback()
        engine.seek(toPercentage: 1)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.playbackProgress, 1)
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.playbackProgress, 0.3, accuracy: 1e-9, "Play at the end resumes the loop, not 0:00")
        engine.unloadTrack()
    }
}
