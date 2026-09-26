import XCTest
import AVFoundation
import CoreML
import MediaPlayer
import SwiftData
@testable import Isolate

/// Coverage for paths the older suites only touched with identical fixtures or fixed sleeps:
/// adding new tracks, stem label order, tag metadata, rendered EQ, stem recovery,
/// output-device changes and engine teardown.
@MainActor
final class SuiteHardeningTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "SuiteHardening-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Tests that need sound start playback themselves.
        addTeardownBlock(Hardening.disableAutoPlay())
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - New imports and stem order (tests-2, tests-3)

    func testImportAddsNewTracksWithTheirOwnStems() async throws {
        let container = try ModelContainer(for: TrackModel.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let alpha = directory.appending(path: "Alpha.wav")
        let beta = directory.appending(path: "Beta.wav")
        try Hardening.tone(alpha, frequency: 220, amplitude: 0.21)
        try Hardening.tone(beta, frequency: 220, amplitude: 0.27)
        let caches = try [alpha, beta].map { try Hardening.cacheStems(for: $0) }
        defer { caches.forEach { try? FileManager.default.removeItem(at: $0) } }

        let importer = ImportCoordinator()
        let engine = AudioEngineManager()
        importer.importFiles([alpha, beta], context: context, engine: engine)
        await Hardening.finish(importer)

        XCTAssertNil(engine.errorMessage)
        let tracks = try context.fetch(FetchDescriptor<TrackModel>(sortBy: [SortDescriptor(\.title)]))
        XCTAssertEqual(tracks.map(\.title), ["Alpha", "Beta"], "Each new file must become its own library entry")
        for (track, (source, cache)) in zip(tracks, zip([alpha, beta], caches)) {
            XCTAssertEqual(track.id, source.path)
            XCTAssertEqual(track.originalURL, source)
            let stems = [track.vocalStemURL, track.drumStemURL, track.bassStemURL, track.otherStemURL]
            XCTAssertEqual(stems.map(\.lastPathComponent), DemucsEngine.stemNames.map { "\($0).wav" },
                           "\(track.title): a stem URL is stored under the wrong label")
            for (url, frequency) in zip(stems, Hardening.stemFrequencies) {
                XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, cache.standardizedFileURL)
                XCTAssertEqual(try Hardening.dominantFrequency(of: url), frequency, "\(url.lastPathComponent) holds another stem's audio")
            }
        }
        XCTAssertEqual(engine.currentTrackID, beta.path, "The last file of a batch is the one left loaded")
        XCTAssertEqual(engine.trackTitle, "Beta")
        engine.unloadTrack()
    }

    func testLoadedStemsDriveTheirOwnChannels() async throws {
        // Distinct levels per stem: a swapped file, player or mixer shows up on the wrong meter.
        let amplitudes: [Float] = [0.1, 0.2, 0.3, 0.4]
        let stems = try Hardening.distinctStems(in: directory.appending(path: "levels"), seconds: 3, amplitudes: amplitudes)
        let engine = AudioEngineManager()
        await engine.loadTrack(Hardening.track(title: "Levels", original: directory.appending(path: "levels/original.wav"), stems: stems))
        try Hardening.requirePlayback(engine)
        var peaks = [Float](repeating: 0, count: 4)
        let clock = ContinuousClock()
        let end = clock.now + .milliseconds(700)
        while clock.now < end {
            try await Task.sleep(for: .milliseconds(15))
            for index in peaks.indices { peaks[index] = max(peaks[index], engine.stemPeaks[index]) }
        }
        for (index, name) in DemucsEngine.stemNames.enumerated() {
            XCTAssertEqual(peaks[index], amplitudes[index], accuracy: 0.03, "The \(name) meter shows another stem")
        }
        engine.soloStem(1)
        // Let tap buffers rendered before the solo drain.
        try await Task.sleep(for: .milliseconds(300))
        var soloed = [Float](repeating: 0, count: 4)
        let soloEnd = clock.now + .milliseconds(400)
        while clock.now < soloEnd {
            try await Task.sleep(for: .milliseconds(15))
            for index in soloed.indices { soloed[index] = max(soloed[index], engine.stemPeaks[index]) }
        }
        XCTAssertEqual(soloed[1], amplitudes[1], accuracy: 0.03, "Solo DRUMS must keep the drums file audible")
        for index in [0, 2, 3] {
            XCTAssertLessThan(soloed[index], 0.01, "Solo DRUMS must silence \(DemucsEngine.stemNames[index])")
        }
        engine.unloadTrack()
    }

    func testStemArchiveNamesEachEntryAfterItsStem() throws {
        let stems = try Hardening.distinctStems(in: directory.appending(path: "archive"))
        let archive = directory.appending(path: "stems.zip")
        try AudioExporter.archive(sources: stems.map { .init(url: $0) }, title: "Order", format: .wav, to: archive) { _ in }
        let folder = directory.appending(path: "extracted")
        let unzip = Process()
        unzip.executableURL = URL(filePath: "/usr/bin/unzip")
        unzip.arguments = ["-q", archive.path, "-d", folder.path]
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        for (name, frequency) in zip(DemucsEngine.stemNames, Hardening.stemFrequencies) {
            XCTAssertEqual(try Hardening.dominantFrequency(of: folder.appending(path: "Order_\(name).wav")), frequency,
                           "Order_\(name).wav holds another stem's audio")
        }
    }

    // MARK: - Tag metadata (tests-6)

    private func taggedTrack(_ name: String, title: String, tags: Hardening.Tags) throws -> TrackModel {
        let source = directory.appending(path: "\(name).wav")
        try Hardening.taggedSource(source, tags: tags)
        let stems = try Hardening.distinctStems(in: directory.appending(path: "\(name)-stems"))
        return Hardening.track(title: title, original: source, stems: stems)
    }

    func testTaggedMetadataIsReadButTheLibraryTitleWins() async throws {
        let track = try taggedTrack("tagged", title: "Library Title", tags: .init())
        let engine = AudioEngineManager()
        await engine.loadTrack(track)
        let arrived = await Hardening.wait { engine.trackArtist == "Tag Artist" }
        XCTAssertTrue(arrived, "Tag metadata never arrived")
        XCTAssertEqual(engine.trackAlbum, "Tag Album")
        XCTAssertEqual(engine.trackBPM, "128.0 BPM")
        XCTAssertEqual(engine.trackMusicalKey, "F#m")
        XCTAssertNotNil(engine.albumArt, "Embedded artwork must be shown")
        XCTAssertEqual(engine.trackTitle, "Library Title", "A renamed library title outranks the tag title")
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "Library Title")
        XCTAssertEqual(info?[MPMediaItemPropertyArtist] as? String, "Tag Artist")
        engine.unloadTrack()
    }

    func testMetadataCannotArriveAfterUnload() async throws {
        let track = try taggedTrack("late", title: "Late", tags: .init())
        let engine = AudioEngineManager()
        await engine.loadTrack(track)
        engine.unloadTrack()
        await Hardening.settleMetadata(for: track.originalURL)
        XCTAssertEqual(engine.trackTitle, "")
        XCTAssertEqual(engine.trackArtist, "Isolate")
        XCTAssertEqual(engine.trackBPM, "BPM UNKNOWN")
        XCTAssertNil(engine.albumArt)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo, "An empty player must not publish Now Playing")

        // The same load left alone does deliver these tags, so the checks above are not vacuous.
        await engine.loadTrack(track)
        let arrived = await Hardening.wait { engine.trackArtist == "Tag Artist" }
        XCTAssertTrue(arrived)
        engine.unloadTrack()
    }

    func testMetadataOfTheLatestTrackWins() async throws {
        let first = try taggedTrack("first", title: "First", tags: .init(title: "One", artist: "First Artist", bpm: "90", key: "Am"))
        let second = try taggedTrack("second", title: "Second", tags: .init(title: "Two", artist: "Second Artist", bpm: "140", key: "C", artwork: false))
        let engine = AudioEngineManager()
        await engine.loadTrack(first)
        await engine.loadTrack(second)
        let arrived = await Hardening.wait { engine.trackArtist == "Second Artist" }
        XCTAssertTrue(arrived)
        // Give the replaced request time to finish, then check it changed nothing.
        await Hardening.settleMetadata(for: first.originalURL)
        XCTAssertEqual(engine.trackArtist, "Second Artist")
        XCTAssertEqual(engine.trackBPM, "140.0 BPM")
        XCTAssertEqual(engine.trackMusicalKey, "C")
        XCTAssertEqual(engine.trackTitle, "Second")
        XCTAssertNil(engine.albumArt, "The first track's artwork must not appear on the second")
        engine.unloadTrack()
    }

    // MARK: - Rendered EQ (tests-7)

    private func renderedGain(frequency: Double, eq: AudioExporter.EQ = .init(),
                              masterEQ: AudioExporter.EQ = .init()) throws -> Double {
        let amplitude: Float = 0.05
        let source = directory.appending(path: "tone-\(Int(frequency)).wav")
        if !FileManager.default.fileExists(atPath: source.path) {
            try Hardening.tone(source, frequency: frequency, amplitude: amplitude, seconds: 1)
        }
        let destination = directory.appending(path: "eq-\(UUID().uuidString).wav")
        try AudioExporter.render(sources: [.init(url: source, eq: eq)], to: destination, masterEQ: masterEQ)
        // Skip the filters' settling time.
        let peak = Hardening.peak(try Hardening.samples(destination).dropFirst(22_050))
        return 20 * log10(Double(peak / amplitude))
    }

    func testChannelAndMasterEQChangeTheRenderedAudio() throws {
        // The mid band peaks at 1 kHz, so a 1 kHz tone receives its full gain.
        XCTAssertEqual(try renderedGain(frequency: 1_000, eq: .init(mid: 12)), 12, accuracy: 0.5)
        XCTAssertEqual(try renderedGain(frequency: 1_000, eq: .init(mid: -12)), -12, accuracy: 0.5)
        XCTAssertEqual(try renderedGain(frequency: 1_000, masterEQ: .init(mid: 12)), 12, accuracy: 0.5,
                       "Master EQ must be rendered into mix exports")
        // Well inside each shelf the gain approaches its setting.
        XCTAssertGreaterThan(try renderedGain(frequency: 30, eq: .init(low: 12)), 9)
        XCTAssertLessThan(try renderedGain(frequency: 16_000, eq: .init(high: -12)), -9)
        XCTAssertGreaterThan(try renderedGain(frequency: 30, masterEQ: .init(low: 12)), 9)
        // Shelves leave the mid range alone.
        XCTAssertEqual(try renderedGain(frequency: 1_000, eq: .init(low: 12, high: -12)), 0, accuracy: 1)
    }

    func testFlatEQRenderIsSampleIdentical() throws {
        let source = directory.appending(path: "flat.wav")
        try Hardening.write(source, frames: 22_050) { 0.3 * sin(Float($0) * 0.37) * cos(Float($0) * 0.0021) }
        let destination = directory.appending(path: "flat-out.wav")
        try AudioExporter.render(sources: [.init(url: source)], to: destination)
        let input = try Hardening.samples(source)
        let output = try Hardening.samples(destination)
        XCTAssertEqual(output.count, input.count)
        // 24-bit output: one quantisation step is about 1.2e-7.
        let error = zip(input, output).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        XCTAssertLessThan(error, 2e-7, "A flat EQ must be bypassed, not rendered")
    }

    // MARK: - Stem recovery (tests-11)

    func testMissingStemsAreRebuiltFromTheSourceAndSaved() async throws {
        let source = directory.appending(path: "Recovered.wav")
        try Hardening.tone(source, frequency: 220, amplitude: 0.23)
        let cache = try Hardening.cacheStems(for: source)
        defer { try? FileManager.default.removeItem(at: cache) }
        // An older cache generation that lost three of its files, as after a partial cleanup.
        let stale = StemCache.root.appending(path: "stale-\(UUID().uuidString)")
        let staleStems = try Hardening.distinctStems(in: stale)
        for url in staleStems.dropFirst() { try FileManager.default.removeItem(at: url) }
        defer { try? FileManager.default.removeItem(at: stale) }

        let store = ModelConfiguration(url: directory.appending(path: "library.store"))
        let container = try ModelContainer(for: TrackModel.self, configurations: store)
        let track = Hardening.track(title: "Recovered", original: source, stems: staleStems)
        container.mainContext.insert(track)
        try container.mainContext.save()

        let engine = AudioEngineManager()
        await engine.loadTrack(track)
        XCTAssertNil(engine.errorMessage)
        XCTAssertTrue(engine.hasLoadedTrack)
        XCTAssertEqual(engine.currentTrackID, track.id)
        XCTAssertEqual(engine.trackTitle, "Recovered")
        let rebuilt = [track.vocalStemURL, track.drumStemURL, track.bassStemURL, track.otherStemURL]
        XCTAssertEqual(rebuilt.map(\.lastPathComponent), DemucsEngine.stemNames.map { "\($0).wav" })
        XCTAssertTrue(rebuilt.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == cache.standardizedFileURL })
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "The broken generation no track uses is removed")

        // The repair must survive a relaunch, or the song is re-separated every time.
        let reopened = try ModelContainer(for: TrackModel.self, configurations: store)
        let saved = try XCTUnwrap(try reopened.mainContext.fetch(FetchDescriptor<TrackModel>()).first)
        XCTAssertEqual(saved.drumStemURL.standardizedFileURL, cache.appending(path: "drums.wav").standardizedFileURL)
        XCTAssertEqual(saved.bassStemURL.standardizedFileURL, cache.appending(path: "bass.wav").standardizedFileURL)
        engine.unloadTrack()
        // The track's context belongs to this container.
        withExtendedLifetime(container) {}
    }

    // MARK: - Output device changes (tests-14)

    func testDeviceChangeResumesPlaybackWhereItWas() async throws {
        let stems = try Hardening.distinctStems(in: directory.appending(path: "device"), seconds: 2)
        let engine = AudioEngineManager()
        await engine.loadTrack(Hardening.track(title: "Device", original: directory.appending(path: "device/original.wav"), stems: stems))
        try Hardening.requirePlayback(engine)
        let output = try XCTUnwrap(engine.timePitchNode.engine)
        engine.seek(toPercentage: 0.5)
        XCTAssertTrue(engine.isPlaying)
        // Connecting AirPods or changing the sample rate halts the output unit and posts this
        // notification; the players keep their scheduled audio. (Switching this engine's output
        // device on a Mac with two outputs behaves that way. engine.stop() would also complete
        // the players' schedules, which a device change does not do.)
        output.pause()
        XCTAssertTrue(engine.isPlaying)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: output)
        let resumed = await Hardening.wait(timeout: .seconds(2)) { engine.isPlaying && engine.isOutputRunning }
        XCTAssertTrue(resumed, "Playback must resume on the new device")
        XCTAssertEqual(engine.playbackProgress, 0.5, accuracy: 0.15, "Playback must resume where it was, not restart")
        // The rescheduled players still reach the end of the track and stop.
        let ended = await Hardening.wait(timeout: .seconds(5)) { !engine.isPlaying }
        XCTAssertTrue(ended)
        XCTAssertEqual(engine.playbackProgress, 1)
        engine.unloadTrack()
    }

    func testDeviceChangeWithoutATrackStaysIdle() async throws {
        let engine = AudioEngineManager()
        let output = try XCTUnwrap(engine.timePitchNode.engine)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: output)
        // The handler hops to the main actor; let it run.
        for _ in 0..<10 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.isOutputRunning)
        XCTAssertNil(engine.errorMessage)
    }

    // MARK: - Teardown (tests-19)

    func testTeardownStopsTheEngineAndRemovesMeterTaps() async throws {
        let stems = try Hardening.distinctStems(in: directory.appending(path: "teardown"), seconds: 2)
        var manager: AudioEngineManager? = AudioEngineManager()
        await manager!.loadTrack(Hardening.track(title: "Teardown", original: directory.appending(path: "teardown/original.wav"), stems: stems))
        manager!.togglePlayback()
        let output = try XCTUnwrap(manager!.timePitchNode.engine)
        let stemMixers = [manager!.vocalEQ, manager!.drumEQ, manager!.bassEQ, manager!.otherEQ].compactMap {
            output.outputConnectionPoints(for: $0, outputBus: 0).first?.node
        }
        XCTAssertEqual(stemMixers.count, 4)
        weak var released: AudioEngineManager?
        released = manager
        manager = nil
        let gone = await Hardening.wait(timeout: .seconds(2)) { released == nil }
        XCTAssertTrue(gone, "The manager must be released")
        XCTAssertFalse(output.isRunning, "Teardown must stop the engine")
        // A tap left behind would make a second install on the same bus raise.
        for node in [output.mainMixerNode] + stemMixers {
            node.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
            node.removeTap(onBus: 0)
        }
    }

    func testManyManagersCanBeCreatedAndDestroyed() async throws {
        // The macOS 15 CI crash appeared while managers were torn down; repeat it with and without audio.
        let stems = try Hardening.distinctStems(in: directory.appending(path: "stress"), seconds: 1)
        let track = Hardening.track(title: "Stress", original: directory.appending(path: "stress/original.wav"), stems: stems)
        for round in 0..<24 {
            weak var released: AudioEngineManager?
            do {
                let manager = AudioEngineManager()
                released = manager
                if round % 3 == 0 {
                    await manager.loadTrack(track)
                    manager.togglePlayback()
                }
            }
            let gone = await Hardening.wait(timeout: .seconds(2)) { released == nil }
            XCTAssertTrue(gone, "Manager \(round) was not released")
        }
    }
}
