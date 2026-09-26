import XCTest
import AVFoundation
import AppKit
@testable import Isolate

/// Shared waits and fixtures for the hardening tests. Namespaced so helpers added by
/// other test files cannot collide with these names.
@MainActor
enum Hardening {
    // MARK: - Waiting

    /// Polls `condition` until it holds or `timeout` passes. Use it instead of a fixed
    /// sleep whenever a test waits for asynchronous work to finish.
    @discardableResult
    static func wait(timeout: Duration = .seconds(5), interval: Duration = .milliseconds(10),
                     until condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: interval)
        }
        return true
    }

    /// For checks that late metadata changed nothing: repeats the engine's metadata read of
    /// `url` (tags, then the format probe) so a request started earlier has had as long as it
    /// needs, then lets its main-actor update run.
    static func settleMetadata(for url: URL) async {
        let asset = AVURLAsset(url: url)
        _ = try? await asset.load(.commonMetadata)
        _ = try? await asset.load(.metadata)
        _ = await Task.detached { AudioEngineManager.probeFormat(url) }.value
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// Waits for an import started through ImportCoordinator; a hang fails instead of stalling CI.
    static func finish(_ importer: ImportCoordinator, timeout: Duration = .seconds(10),
                       file: StaticString = #filePath, line: UInt = #line) async {
        let finished = await wait(timeout: timeout, interval: .milliseconds(20)) { !importer.isImporting }
        XCTAssertTrue(finished, "The import did not finish within \(timeout)", file: file, line: line)
    }

    // MARK: - Realtime audio

    struct PlaybackDidNotStart: Error {}

    /// Starts playback if autoplay did not. Skips only when this Mac has no output device
    /// the engine can start; any other reason playback stays off fails the test.
    static func requirePlayback(_ engine: AudioEngineManager,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        if !engine.isPlaying { engine.togglePlayback() }
        guard !engine.isPlaying else { return }
        if let message = engine.errorMessage, message.hasPrefix("Could not start audio output") {
            throw XCTSkip("No audio output device can start: \(message)")
        }
        XCTFail("Playback did not start: \(engine.errorMessage ?? "no error was shown")", file: file, line: line)
        throw PlaybackDidNotStart()
    }

    /// Hosted tests share one preferences domain. Turns autoplay off so loading a track
    /// does not play through the speakers, and returns the block that restores it.
    static func disableAutoPlay() -> @MainActor @Sendable () -> Void {
        let key = "isAutoPlayDisabled"
        let previous = AppPreferences.defaults.object(forKey: key) as? Bool
        AppPreferences.defaults.set(true, forKey: key)
        return {
            if let previous { AppPreferences.defaults.set(previous, forKey: key) }
            else { AppPreferences.defaults.removeObject(forKey: key) }
        }
    }

    // MARK: - Model

    struct ModelRequired: Error, CustomStringConvertible {
        let description: String
    }

    /// Separates with the installed model. Only a missing model skips, and not when
    /// ISOLATE_REQUIRE_MODEL=1. A model that is installed but cannot be loaded throws
    /// DemucsError.modelLoadFailed, which fails the test.
    static func splitRequiringModel(_ url: URL,
                                    progress: @escaping @Sendable (SplitProgressInfo) -> Void = { _ in }) async throws -> [URL] {
        do {
            return try await DemucsEngine.shared.splitAudio(url: url, progressCallback: progress)
        } catch DemucsError.modelNotFound(let message) {
            if ProcessInfo.processInfo.environment["ISOLATE_REQUIRE_MODEL"] == "1" {
                throw ModelRequired(description: "ISOLATE_REQUIRE_MODEL=1 but no model is installed: \(message)")
            }
            throw XCTSkip("Install the model to run inference: \(message)")
        }
    }

    /// Removes a separation result from the test-only cache root.
    static func removeCache(_ stems: [URL]) {
        if let directory = stems.first?.deletingLastPathComponent(), StemCache.owns(directory) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Audio fixtures

    /// One tone per stem in model order (vocals, drums, bass, other), so a swapped
    /// label is audible in the data rather than hidden by identical fixtures.
    nonisolated static let stemFrequencies: [Double] = [440, 660, 110, 880]

    static func write(_ url: URL, frames: Int, sample: (Int) -> Float) throws {
        let buffer = AVAudioPCMBuffer(pcmFormat: StreamingAudio.format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<frames {
            let value = sample(frame)
            buffer.floatChannelData![0][frame] = value
            buffer.floatChannelData![1][frame] = value
        }
        let file = try AVAudioFile(forWriting: url, settings: StreamingAudio.settings)
        try file.write(from: buffer)
    }

    static func tone(_ url: URL, frequency: Double, amplitude: Float = 0.2, seconds: Double = 0.5) throws {
        try write(url, frames: Int(44_100 * seconds)) { frame in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / 44_100))
        }
    }

    /// Writes original.wav and the four stems into `folder`, each stem its own tone.
    @discardableResult
    static func distinctStems(in folder: URL, seconds: Double = 0.5,
                              amplitudes: [Float] = [0.2, 0.2, 0.2, 0.2]) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try tone(folder.appending(path: "original.wav"), frequency: 330, seconds: seconds)
        return try DemucsEngine.stemNames.indices.map { index in
            let url = folder.appending(path: "\(DemucsEngine.stemNames[index]).wav")
            try tone(url, frequency: stemFrequencies[index], amplitude: amplitudes[index], seconds: seconds)
            return url
        }
    }

    /// Publishes distinct-tone stems for `source` into the test cache so imports need no model.
    static func cacheStems(for source: URL, seconds: Double = 0.5) throws -> URL {
        let cache = StemCache.root.appending(path: try StemCache.key(for: source))
        try distinctStems(in: cache, seconds: seconds)
        return cache
    }

    static func track(title: String, original: URL, stems: [URL]) -> TrackModel {
        TrackModel(id: original.path, title: title, originalURL: original,
                   vocalStemURL: stems[0], bassStemURL: stems[2], drumStemURL: stems[1], otherStemURL: stems[3])
    }

    static func samples(_ url: URL, channel: Int = 0) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
    }

    /// Signal power at `frequency` (Goertzel), normalised so a full-scale sine reads about 0.25.
    static func power(of samples: [Float], at frequency: Double) -> Double {
        let coefficient = 2 * cos(2 * Double.pi * frequency / 44_100)
        var previous = 0.0, beforePrevious = 0.0
        for sample in samples {
            let current = Double(sample) + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
        return power / Double(max(1, samples.count * samples.count))
    }

    /// The candidate tone with the most energy in the file's left channel.
    static func dominantFrequency(of url: URL, among candidates: [Double] = stemFrequencies) throws -> Double {
        let samples = try samples(url)
        return candidates.max { power(of: samples, at: $0) < power(of: samples, at: $1) }!
    }

    static func peak<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    // MARK: - Tagged source

    struct Tags {
        var title = "Tag Title"
        var artist = "Tag Artist"
        var album = "Tag Album"
        var bpm = "128"
        var key = "F#m"
        var artwork = true
    }

    /// A float WAV carrying an ID3v2.4 chunk, which AVFoundation reads as it does an MP3's tags.
    static func taggedSource(_ url: URL, tags: Tags = Tags(), seconds: Double = 0.5) throws {
        try tone(url, frequency: 330, seconds: seconds)
        func synchsafe(_ value: Int) -> [UInt8] {
            [21, 14, 7, 0].map { UInt8(value >> $0 & 0x7F) }
        }
        func frame(_ id: String, _ payload: [UInt8]) -> [UInt8] {
            Array(id.utf8) + synchsafe(payload.count) + [0, 0] + payload
        }
        func text(_ id: String, _ value: String) -> [UInt8] { frame(id, [3] + Array(value.utf8)) } // 3: UTF-8
        var frames = text("TIT2", tags.title) + text("TPE1", tags.artist) + text("TALB", tags.album)
            + text("TBPM", tags.bpm) + text("TKEY", tags.key)
        if tags.artwork {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let png = bitmap.representation(using: .png, properties: [:])!
            // Encoding, MIME type, picture type 3 (front cover), empty description.
            frames += frame("APIC", [3] + Array("image/png".utf8) + [0, 3, 0] + [UInt8](png))
        }
        let tag = Array("ID3".utf8) + [4, 0, 0] + synchsafe(frames.count) + frames
        var data = try Data(contentsOf: url)
        data.append(contentsOf: Array("id3 ".utf8))
        withUnsafeBytes(of: UInt32(tag.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: tag)
        if tag.count % 2 == 1 { data.append(0) }
        withUnsafeBytes(of: UInt32(data.count - 8).littleEndian) { data.replaceSubrange(4..<8, with: $0) }
        try data.write(to: url)
    }
}
