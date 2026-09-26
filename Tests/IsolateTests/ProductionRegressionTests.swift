import XCTest
import AVFoundation
import SwiftData
import MediaPlayer
@testable import Isolate

@MainActor
final class ProductionRegressionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func audio(_ name: String = "source.wav", seconds: Double = 0.2,
                       sampleRate: Double = 44_100, channels: AVAudioChannelCount = 2,
                       amplitude: Float = 0.2) throws -> URL {
        let url = directory.appending(path: name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: channels, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * seconds))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = amplitude * sin(Float(frame) * 2 * .pi * 440 / Float(sampleRate))
            }
        }
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        try writer.write(from: buffer)
        return url
    }

    private func samples(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return buffer
    }

    private func track(seconds: Double = 0.2) throws -> TrackModel {
        let original = try audio("original.wav", seconds: seconds)
        let urls = try DemucsEngine.stemNames.map { try audio("\($0).wav", seconds: seconds) }
        return TrackModel(id: original.path, title: "Regression", originalURL: original,
                          vocalStemURL: urls[0], bassStemURL: urls[2], drumStemURL: urls[1], otherStemURL: urls[3])
    }

    func testCacheKeyTracksContentAndAvoidsFilenameCollisions() throws {
        let first = try audio("first.wav")
        let copy = directory.appending(path: "renamed.wav")
        try FileManager.default.copyItem(at: first, to: copy)
        XCTAssertEqual(try StemCache.key(for: first), try StemCache.key(for: copy))
        let different = try audio("different.wav", amplitude: 0.4)
        XCTAssertNotEqual(try StemCache.key(for: first), try StemCache.key(for: different))
    }

    func testIncompleteOrMismatchedCacheIsRejected() throws {
        _ = try track()
        XCTAssertNotNil(StemCache.validFiles(in: directory))
        try FileManager.default.removeItem(at: directory.appending(path: "bass.wav"))
        XCTAssertNil(StemCache.validFiles(in: directory))
        _ = try audio("bass.wav", seconds: 0.1)
        XCTAssertNil(StemCache.validFiles(in: directory))
        XCTAssertFalse(StemCache.owns(directory))
    }

    func testStreamingDecodeResamplesMonoWithoutChangingChannelsOrDuration() throws {
        let source = try audio(sampleRate: 48_000, channels: 1)
        let destination = directory.appending(path: "decoded.wav")
        let stats = try StreamingAudio.decode(source, to: destination)
        XCTAssertEqual(stats.frames, 8820, accuracy: 2)
        XCTAssertEqual(stats.mean, 0, accuracy: 0.001)
        XCTAssertGreaterThan(stats.standardDeviation, 0.1)
        let output = try samples(destination)
        XCTAssertEqual(output.format.channelCount, 2)
        XCTAssertEqual(output.format.sampleRate, 44_100)
        for frame in 0..<Int(output.frameLength) {
            XCTAssertEqual(output.floatChannelData![0][frame], output.floatChannelData![1][frame], accuracy: 1e-6)
        }
    }

    func testStreamingDecodePreservesOriginalFloatSamples() throws {
        let source = try audio(amplitude: 0.99)
        let destination = directory.appending(path: "decoded.wav")
        _ = try StreamingAudio.decode(source, to: destination)
        let input = try samples(source)
        let output = try samples(destination)
        XCTAssertEqual(output.frameLength, input.frameLength)
        for i in 0..<Int(input.frameLength) {
            XCTAssertEqual(output.floatChannelData![0][i], input.floatChannelData![0][i], accuracy: 1e-6)
        }
    }

    func testReflectionRepeatsAtBothEdgesOfVeryShortTracks() throws {
        XCTAssertEqual((-4...6).map { StreamingAudio.reflectedIndex($0, count: 3) }, [0, 1, 2, 1, 0, 1, 2, 1, 0, 1, 2])
        XCTAssertEqual(StreamingAudio.reflectedIndex(-100, count: 1), 0)
        let url = try audio(seconds: 0.01)
        let file = try AVAudioFile(forReading: url)
        let input = try samples(url)
        let output = AVAudioPCMBuffer(pcmFormat: StreamingAudio.format, frameCapacity: 2048)!
        try StreamingAudio.readWindow(file: file, start: -900, count: 2048, into: output)
        for i in 0..<2048 {
            let index = StreamingAudio.reflectedIndex(i - 900, count: Int(file.length))
            XCTAssertEqual(output.floatChannelData![0][i], input.floatChannelData![0][index])
        }
    }

    func testShortAndEmptyFFTInputIsZeroPadded() {
        let fft = FFTAnalyzer()
        var short: [Float] = [1, 0, 0]
        XCTAssertTrue(fft.computeFFT(buffer: &short).allSatisfy(\.isFinite))
        var empty: [Float] = []
        XCTAssertEqual(fft.computeFFT(buffer: &empty), Array(repeating: 0, count: 512))
    }

    func testMetersIncludeAudioPannedFullyRight() throws {
        let left = AVAudioPCMBuffer(pcmFormat: StreamingAudio.format, frameCapacity: 1024)!
        let right = AVAudioPCMBuffer(pcmFormat: StreamingAudio.format, frameCapacity: 1024)!
        left.frameLength = 1024
        right.frameLength = 1024
        for frame in 0..<1024 {
            let sample = Float(0.2) * sin(Float(frame) * 2 * .pi * 440 / 44_100)
            left.floatChannelData![0][frame] = sample
            left.floatChannelData![1][frame] = 0
            right.floatChannelData![0][frame] = 0
            right.floatChannelData![1][frame] = sample
        }
        let leftReading = try XCTUnwrap(AudioMeterProcessor(bandCount: 32).process(left))
        let rightReading = try XCTUnwrap(AudioMeterProcessor(bandCount: 32).process(right))
        XCTAssertGreaterThan(leftReading.spectrum.max() ?? 0, 0.1)
        XCTAssertEqual(rightReading.spectrum, leftReading.spectrum)
        XCTAssertEqual(rightReading.waveform, leftReading.waveform)
        XCTAssertEqual(rightReading.peak, leftReading.peak)
    }

    func testFaderCalibrationMatchesDecibelLabels() {
        XCTAssertEqual(FaderScale.gain(at: 0), 0)
        XCTAssertEqual(FaderScale.gain(at: 60.0 / 66), 1, accuracy: 1e-9)
        XCTAssertEqual(20 * log10(FaderScale.gain(at: 54.0 / 66)), -6, accuracy: 1e-9)
        XCTAssertEqual(20 * log10(FaderScale.gain(at: 1)), 6, accuracy: 1e-9)
        for gain in [0.01, 0.1, 0.5, 1, 1.8] {
            XCTAssertEqual(FaderScale.gain(at: FaderScale.position(for: gain)), gain, accuracy: 1e-9)
        }
    }

    func testWAVAndFLACExportHaveCorrectLengthAndSignal() throws {
        let source = try audio()
        for format in AudioExporter.Format.allCases {
            let destination = directory.appending(path: "export.\(format.fileExtension)")
            try AudioExporter.render(sources: [.init(url: source)], to: destination, format: format)
            let file = try AVAudioFile(forReading: destination)
            XCTAssertEqual(file.length, 8820)
            if format == .wav {
                XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
            } else {
                // FLAC STREAMINFO stores (bits per sample - 1) across these five bits.
                let bytes = try Data(contentsOf: destination)
                XCTAssertEqual(String(decoding: bytes.prefix(4), as: UTF8.self), "fLaC")
                XCTAssertGreaterThanOrEqual(bytes.count, 42)
                XCTAssertEqual((Int(bytes[20] & 1) << 4 | Int(bytes[21] >> 4)) + 1, 24)
            }
            let output = try samples(destination)
            let peak = (0..<Int(output.frameLength)).map { abs(output.floatChannelData![0][$0]) }.max()!
            XCTAssertGreaterThan(peak, 0.15)
            XCTAssertLessThan(peak, 0.3)
        }
    }

    func testMixExportHonorsMutePanAndPlaybackRate() throws {
        let source = try audio(seconds: 0.5)
        let muted = directory.appending(path: "muted.wav")
        try AudioExporter.render(sources: [.init(url: source, gain: 0)], to: muted)
        let silence = try samples(muted)
        XCTAssertTrue((0..<Int(silence.frameLength)).allSatisfy { abs(silence.floatChannelData![0][$0]) < 1e-6 })
        let panned = directory.appending(path: "panned.wav")
        try AudioExporter.render(sources: [.init(url: source, pan: -1)], to: panned)
        let output = try samples(panned)
        let left = (0..<Int(output.frameLength)).reduce(Float(0)) { $0 + abs(output.floatChannelData![0][$1]) }
        let right = (0..<Int(output.frameLength)).reduce(Float(0)) { $0 + abs(output.floatChannelData![1][$1]) }
        XCTAssertGreaterThan(left, 10)
        XCTAssertLessThan(right, left * 0.01)
        let slower = directory.appending(path: "slower.wav")
        try AudioExporter.render(sources: [.init(url: source)], to: slower, rate: 0.5)
        // Stretched length plus the fixed time/pitch tail.
        XCTAssertEqual(try AVAudioFile(forReading: slower).length, 44_100 + 4096)
    }

    func testMixExportAppliesPositiveFaderGain() throws {
        let source = try audio()
        let destination = directory.appending(path: "boosted.wav")
        let gain = Float(FaderScale.gain(at: 1))
        try AudioExporter.render(sources: [.init(url: source, gain: gain)], to: destination)
        let output = try samples(destination)
        let peak = UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)).map(abs).max() ?? 0
        XCTAssertEqual(peak, 0.2 * gain, accuracy: 0.002, "The +6 dB fader must amplify the rendered audio")
    }

    func testExportRetainsFinalTransientWithTimePitchAndLimiter() throws {
        let source = directory.appending(path: "final-transient.wav")
        let buffer = AVAudioPCMBuffer(pcmFormat: StreamingAudio.format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for channel in 0..<2 {
            for frame in 0..<44_100 {
                buffer.floatChannelData![channel][frame] = frame < 42_777 ? 0 : 0.2 * sin(Float(frame) * 2 * .pi * 440 / 44_100)
            }
        }
        do {
            let file = try AVAudioFile(forWriting: source, settings: StreamingAudio.settings)
            try file.write(from: buffer)
        }
        for (index, controls) in [(Float(1), Float(0)), (0.5, 0), (1, 4), (2, 0)].enumerated() {
            let destination = directory.appending(path: "transient-\(index).wav")
            try AudioExporter.render(sources: [.init(url: source)], to: destination,
                                     rate: controls.0, pitch: controls.1, limitPeak: true)
            let output = try samples(destination)
            let peak = UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)).map(abs).max() ?? 0
            XCTAssertGreaterThan(peak, 0.01, "Final transient must survive export at rate \(controls.0), pitch \(controls.1)")
        }
    }

    func testInvalidCachePublicationPreservesPreviousGeneration() throws {
        _ = try track()
        let oldOriginal = try Data(contentsOf: directory.appending(path: "original.wav"))
        let incomplete = directory.appending(path: "partial")
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        XCTAssertThrowsError(try StemCache.publish(incomplete, to: directory))
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: "original.wav")), oldOriginal)
        XCTAssertNotNil(StemCache.validFiles(in: directory))
    }

    func testPlaybackControlsRejectNonFiniteValues() {
        let engine = AudioEngineManager()
        engine.pitchShiftSemitones = .nan
        engine.playbackRate = .infinity
        engine.setLoopStart(.nan)
        engine.setLoopEnd(.infinity)
        XCTAssertEqual(engine.pitchShiftSemitones, 0)
        XCTAssertEqual(engine.playbackRate, 1)
        XCTAssertFalse(engine.isLooping)
        XCTAssertEqual(engine.loopStartProgress, 0)
        XCTAssertEqual(engine.loopEndProgress, 1)
    }

    func testFailedExportDoesNotReplaceExistingDestination() throws {
        let destination = directory.appending(path: "existing.zip")
        let existing = Data("previous export".utf8)
        try existing.write(to: destination)
        let missing = AudioExporter.Source(url: directory.appending(path: "missing.wav"))
        XCTAssertThrowsError(try AudioExporter.archive(sources: Array(repeating: missing, count: 4), title: "Test", format: .wav, to: destination) { _ in })
        XCTAssertEqual(try Data(contentsOf: destination), existing)
    }

    func testArchiveContainsFourSanitizedNames() throws {
        let source = try audio()
        let destination = directory.appending(path: "stems.zip")
        try AudioExporter.archive(sources: Array(repeating: .init(url: source), count: 4), title: "../Bad:Name", format: .wav, to: destination) { _ in }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/unzip")
        process.arguments = ["-Z", "-1", destination.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let names = String(decoding: data, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(names.count, 4)
        XCTAssertTrue(names.allSatisfy { !$0.contains("/") && !$0.contains(":") && $0.hasSuffix(".wav") })
    }

    func testArchiveSupportsLongUnicodeTitles() throws {
        let source = try audio()
        let title = String(repeating: "音", count: 90) + "🎵"
        let destination = directory.appending(path: "unicode-stems.zip")
        // ZIP entries should extract on volumes with a 255-byte component limit.
        XCTAssertLessThanOrEqual((AudioExporter.safeFilename(title) + "_vocals.flac").utf8.count, 255)
        try AudioExporter.archive(sources: Array(repeating: .init(url: source), count: 4),
                                  title: title, format: .flac, to: destination) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPlaybackStopsAtEndAndSeekingClampsSafely() async throws {
        let engine = AudioEngineManager()
        await engine.loadTrack(try track())
        if !engine.isPlaying { engine.togglePlayback() }
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.playbackProgress, 1)
        engine.seek(toPercentage: -1)
        XCTAssertEqual(engine.playbackProgress, 0)
        engine.seek(toPercentage: .nan)
        XCTAssertEqual(engine.playbackProgress, 0)
        engine.seek(toPercentage: 2)
        XCTAssertEqual(engine.playbackProgress, 1)
        XCTAssertFalse(engine.isPlaying)
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)
        engine.unloadTrack()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(engine.isPlaying)
        XCTAssertNil(engine.currentTrackID)
    }

    func testUnknownMetadataIsNotFabricatedAndCannotArriveAfterUnload() async throws {
        let engine = AudioEngineManager()
        await engine.loadTrack(try track())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(engine.trackBPM, "BPM UNKNOWN")
        XCTAssertEqual(engine.trackMusicalKey, "KEY UNKNOWN")
        engine.unloadTrack()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(engine.trackTitle, "")
        XCTAssertNil(engine.albumArt)
    }

    func testImportPersistsInProvidedSwiftDataContext() async throws {
        let container = try ModelContainer(for: TrackModel.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let model = try track()
        let cache = StemCache.root.appending(path: try StemCache.key(for: model.originalURL))
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        for name in DemucsEngine.stemNames + ["original"] {
            try FileManager.default.copyItem(at: directory.appending(path: "\(name).wav"), to: cache.appending(path: "\(name).wav"))
        }
        context.insert(model)
        try context.save()
        let importer = ImportCoordinator()
        let engine = AudioEngineManager()
        importer.importFiles([model.originalURL], context: context, engine: engine)
        while importer.isImporting { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TrackModel>()), 1)
        XCTAssertEqual(engine.currentTrackID, model.id)
        XCTAssertEqual(model.vocalStemURL, cache.appending(path: "vocals.wav"))
        engine.unloadTrack()
    }

    func testCancelledImportPreservesLoadedTrackAndAllowsRetry() async throws {
        let model = try track(seconds: 0.4)
        let cache = StemCache.root.appending(path: try StemCache.key(for: model.originalURL))
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        for name in DemucsEngine.stemNames + ["original"] {
            try FileManager.default.copyItem(at: directory.appending(path: "\(name).wav"), to: cache.appending(path: "\(name).wav"))
        }
        let engine = AudioEngineManager()
        await engine.loadTrack(model)
        let request = Task { await engine.loadAndSplitAudio(url: model.originalURL) }
        // loadAndSplitAudio reserves the busy state before its first suspension.
        let deadline = Date.now.addingTimeInterval(5)
        while !engine.isSplitting && Date.now < deadline { await Task.yield() }
        XCTAssertTrue(engine.isSplitting)
        engine.cancelSplitAudio()
        let cancelled = await request.value
        XCTAssertNil(cancelled)
        XCTAssertTrue(engine.lastImportCancelled)
        XCTAssertFalse(engine.isSplitting)
        XCTAssertEqual(engine.currentTrackID, model.id)
        XCTAssertNotNil(StemCache.validFiles(in: cache))
        let retry = await engine.loadAndSplitAudio(url: model.originalURL)
        XCTAssertNotNil(retry)
        XCTAssertFalse(engine.lastImportCancelled)
        engine.unloadTrack()
    }

    func testLibraryReloadRetainsRenameAndCachedPlaybackWithoutOriginal() async throws {
        let source = try track()
        let originalURL = source.originalURL
        let configuration = ModelConfiguration(url: directory.appending(path: "library.store"))
        do {
            let container = try ModelContainer(for: TrackModel.self, configurations: configuration)
            container.mainContext.insert(source)
            source.title = "Renamed track"
            try container.mainContext.save()
        }
        // A source can be moved after import without invalidating its saved stems.
        try FileManager.default.removeItem(at: originalURL)
        let reloaded = try ModelContainer(for: TrackModel.self, configurations: configuration)
        let tracks = try reloaded.mainContext.fetch(FetchDescriptor<TrackModel>())
        XCTAssertEqual(tracks.count, 1)
        let saved = try XCTUnwrap(tracks.first)
        XCTAssertEqual(saved.title, "Renamed track")
        let engine = AudioEngineManager()
        await engine.loadTrack(saved)
        XCTAssertTrue(engine.hasLoadedTrack)
        XCTAssertEqual(engine.currentTrackName, "RENAMED TRACK")
        XCTAssertEqual(engine.trackTitle, "Renamed track")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(engine.trackTitle, "Renamed track", "Metadata fallback must preserve the library title")
        XCTAssertNil(engine.errorMessage)
        engine.unloadTrack()
    }

    func testRenameUpdatesNowPlayingAndSurvivesPendingMetadata() async throws {
        let source = try track()
        let engine = AudioEngineManager()
        await engine.loadTrack(source)
        engine.updateTrackTitle(id: source.id, newTitle: "My rehearsal")
        XCTAssertEqual(engine.trackTitle, "My rehearsal")
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "My rehearsal")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(engine.trackTitle, "My rehearsal")
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "My rehearsal")
        engine.updateTrackTitle(id: "another track", newTitle: "Unrelated")
        XCTAssertEqual(engine.trackTitle, "My rehearsal")
        engine.unloadTrack()
        await engine.loadTrack(source)
        XCTAssertEqual(engine.trackTitle, source.title, "A previous title override must not leak into the next load")
        engine.unloadTrack()
    }

    func testDetailedPlaybackTimeUsesConsistentRemainingDuration() {
        let times = AudioEngineManager.playbackTimecodes(elapsed: 3.7, duration: 10.2)
        XCTAssertEqual(times.detailed, "00:03.700 / -00:06.500")
        XCTAssertEqual(times.compact, "00:03 / -00:07")
        XCTAssertEqual(AudioEngineManager.playbackTimecodes(elapsed: 59.9996, duration: 60).detailed,
                       "01:00.000 / -00:00.000")
        XCTAssertEqual(AudioEngineManager.playbackTimecodes(elapsed: 11, duration: 10.2).detailed,
                       "00:10.200 / -00:00.000")
    }

    func testPitchTransposesCompactAndSpacedMusicalKeys() {
        let engine = AudioEngineManager()
        engine.pitchShiftSemitones = 2
        for (source, expected) in [("Am", "Bm"), ("F#m", "G#m"), ("Bb minor", "C minor"),
                                   ("E♭ major", "F major"), ("KEY UNKNOWN", "KEY UNKNOWN")] {
            engine.trackMusicalKey = source
            XCTAssertEqual(engine.effectiveMusicalKey, expected)
        }
        engine.pitchShiftSemitones = -2
        engine.trackMusicalKey = "C minor"
        XCTAssertEqual(engine.effectiveMusicalKey, "A# minor")
    }
}
