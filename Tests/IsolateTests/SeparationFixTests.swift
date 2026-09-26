import XCTest
import AVFoundation
import AudioToolbox
import Accelerate
import CoreML
import SwiftData
import os
@testable import Isolate

@MainActor
final class SeparationFixTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func tone(_ frame: Int, amplitude: Float = 0.5) -> Float {
        amplitude * sin(Float(frame) * 2 * .pi * 440 / 44_100)
    }

    /// Stereo float WAV; `amplitude` makes the bytes, and so the cache key, unique.
    private func stereo(_ name: String, frames: Int = 8_820, amplitude: Float = 0.3) throws -> URL {
        let url = directory.appending(path: name)
        let buffer = AVAudioPCMBuffer(pcmFormat: StreamingAudio.format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<frames {
            buffer.floatChannelData![0][frame] = tone(frame, amplitude: amplitude)
            buffer.floatChannelData![1][frame] = tone(frame, amplitude: amplitude) * 0.5
        }
        let file = try AVAudioFile(forWriting: url, settings: StreamingAudio.settings)
        try file.write(from: buffer)
        return url
    }

    /// One second of audio with signal in a single channel.
    private func surroundBuffer(tag: AudioChannelLayoutTag, active: Int, sampleRate: Double = 44_100) -> AVAudioPCMBuffer {
        let layout = AVAudioChannelLayout(layoutTag: tag)!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(sampleRate) { buffer.floatChannelData![channel][frame] = channel == active ? tone(frame) : 0 }
        }
        return buffer
    }

    /// Multichannel WAV or FLAC with a declared layout and signal in one channel only.
    private func surround(_ name: String, tag: AudioChannelLayoutTag, active: Int,
                          sampleRate: Double = 44_100, settings extra: [String: Any] = [:]) throws -> URL {
        let url = directory.appending(path: name)
        let buffer = surroundBuffer(tag: tag, active: active, sampleRate: sampleRate)
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings.merging(extra) { $1 },
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    /// 5.1 ALAC in the codec's native channel order, as afconvert, Music and ffmpeg write it.
    private func surroundALAC(_ name: String, active: Int) throws -> URL {
        let url = directory.appending(path: name)
        let buffer = surroundBuffer(tag: kAudioChannelLayoutTag_MPEG_5_1_A, active: active)
        let layout = buffer.format.channelLayout!
        var alac = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatAppleLossless,
                                               mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData, mBytesPerPacket: 0,
                                               mFramesPerPacket: 4096, mBytesPerFrame: 0, mChannelsPerFrame: 6,
                                               mBitsPerChannel: 0, mReserved: 0)
        var reference: ExtAudioFileRef?
        XCTAssertEqual(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &alac, layout.layout,
                                                 AudioFileFlags.eraseFile.rawValue, &reference), noErr)
        let file = try XCTUnwrap(reference)
        defer { ExtAudioFileDispose(file) }
        XCTAssertEqual(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                               UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                               buffer.format.streamDescription), noErr)
        // The encoder reorders to ALAC's native order only when told the input layout.
        XCTAssertEqual(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientChannelLayout,
                                               UInt32(MemoryLayout<AudioChannelLayout>.size), layout.layout), noErr)
        XCTAssertEqual(ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList), noErr)
        return url
    }

    /// Float WAV without a channel mask, as many tools write multichannel audio.
    private func plainWAV(_ name: String, channels: Int, active: Int) throws -> URL {
        let url = directory.appending(path: name)
        let frames = 44_100
        var data = Data()
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = frames * channels * 4
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(UInt16(channels)); u32(44_100)
        u32(UInt32(44_100 * channels * 4)); u16(UInt16(channels * 4)); u16(32)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
        for frame in 0..<frames {
            for channel in 0..<channels {
                u32((channel == active ? tone(frame) : 0).bitPattern)
            }
        }
        try data.write(to: url)
        return url
    }

    private func rms(_ url: URL) throws -> (left: Float, right: Float, frames: Int) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        var sums: [Float] = [0, 0]
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) {
                sums[channel] += buffer.floatChannelData![channel][frame] * buffer.floatChannelData![channel][frame]
            }
        }
        let count = Float(max(1, buffer.frameLength))
        return (sqrt(sums[0] / count), sqrt(sums[1] / count), Int(buffer.frameLength))
    }

    /// Publishes the stems for `source` into the test cache so imports need no model.
    private func cache(for source: URL) throws -> URL {
        let cache = StemCache.root.appending(path: try StemCache.key(for: source))
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for name in DemucsEngine.stemNames + ["original"] {
            try FileManager.default.copyItem(at: source, to: cache.appending(path: "\(name).wav"))
        }
        return cache
    }

    private func split(_ url: URL, progress: @escaping @Sendable (SplitProgressInfo) -> Void = { _ in }) async throws -> [URL]? {
        do {
            return try await DemucsEngine.shared.splitAudio(url: url, progressCallback: progress)
        } catch DemucsError.modelNotFound(let message) {
            if ProcessInfo.processInfo.environment["ISOLATE_REQUIRE_MODEL"] == "1" { XCTFail(message); return nil }
            throw XCTSkip("Install the model to run inference: \(message)")
        }
    }

    private func removeCache(_ stems: [URL]?) {
        if let directory = stems?.first?.deletingLastPathComponent(), StemCache.owns(directory) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Accumulation (performance-2)

    /// The accumulation loop before hoisting, kept verbatim as the reference.
    private static func referenceAccumulate(_ output: MLMultiArray, into accumulators: inout [[Float]],
                                            weights: inout [Float], window: [Float], mean: Float,
                                            standardDeviation: Float) {
        let chunkSize = DemucsEngine.chunkSize
        let strides = output.strides.map(\.intValue)
        for stem in 0..<4 {
            for channel in 0..<2 {
                let offset = stem * strides[1] + channel * strides[2]
                let target = stem * 2 + channel
                for i in 0..<chunkSize {
                    let index = offset + i * strides[3]
                    let sample: Float
                    if output.dataType == .float32 {
                        sample = output.dataPointer.assumingMemoryBound(to: Float.self)[index]
                    } else {
                        sample = Float(output.dataPointer.assumingMemoryBound(to: Float16.self)[index])
                    }
                    accumulators[target][i] += (sample * standardDeviation + mean) * window[i]
                }
            }
        }
        for i in 0..<chunkSize { weights[i] += window[i] }
    }

    func testAccumulationIsBitIdenticalToTheReferenceLoop() throws {
        let chunkSize = DemucsEngine.chunkSize
        // The bundled model pads its innermost stride; keep that layout here.
        let strides = [3_528_192, 882_048, 441_024, 1]
        var window = [Float](repeating: 0, count: chunkSize)
        vDSP_hann_window(&window, vDSP_Length(chunkSize), Int32(vDSP_HANN_DENORM))
        var random = SystemRandomNumberGenerator()
        for dataType in [MLMultiArrayDataType.float32, .float16] {
            let elementSize = dataType == .float32 ? 4 : 2
            let storage = UnsafeMutableRawPointer.allocate(byteCount: strides[0] * elementSize, alignment: 16)
            for index in 0..<strides[0] {
                let value = Float.random(in: -1.5...1.5, using: &random)
                if dataType == .float32 { storage.storeBytes(of: value, toByteOffset: index * 4, as: Float.self) }
                else { storage.storeBytes(of: Float16(value), toByteOffset: index * 2, as: Float16.self) }
            }
            let output = try MLMultiArray(dataPointer: storage, shape: [1, 4, 2, NSNumber(value: chunkSize)],
                                          dataType: dataType, strides: strides.map { NSNumber(value: $0) }) { $0.deallocate() }
            let seed = (0..<8).map { _ in (0..<chunkSize).map { _ in Float.random(in: -0.5...0.5, using: &random) } }
            var expected = seed, actual = seed
            var expectedWeights = window, actualWeights = window
            Self.referenceAccumulate(output, into: &expected, weights: &expectedWeights, window: window,
                                     mean: 0.013, standardDeviation: 0.27)
            try DemucsEngine.accumulate(output, into: &actual, weights: &actualWeights, window: window,
                                        mean: 0.013, standardDeviation: 0.27)
            for channel in 0..<8 {
                XCTAssertTrue(expected[channel].map(\.bitPattern) == actual[channel].map(\.bitPattern),
                              "\(dataType == .float32 ? "Float32" : "Float16") channel \(channel) differs")
            }
            XCTAssertTrue(expectedWeights.map(\.bitPattern) == actualWeights.map(\.bitPattern))
        }
    }

    // MARK: - Multichannel downmix (separation-1)

    func testCentreOnlySurroundDecodesToBothSides() throws {
        for source in [
            try surround("centre.wav", tag: kAudioChannelLayoutTag_MPEG_5_1_A, active: 2),
            try plainWAV("centre-plain.wav", channels: 6, active: 2),
            try surroundALAC("centre.caf", active: 2),
            try surround("centre.flac", tag: kAudioChannelLayoutTag_MPEG_5_1_A, active: 2, sampleRate: 48_000,
                         settings: [AVFormatIDKey: kAudioFormatFLAC, AVEncoderBitDepthHintKey: 16])
        ] {
            let decoded = directory.appending(path: "decoded-\(source.lastPathComponent).wav")
            let stats = try StreamingAudio.decode(source, to: decoded)
            let level = try rms(decoded)
            XCTAssertEqual(stats.frames, 44_100, accuracy: 2, source.lastPathComponent)
            XCTAssertGreaterThan(level.left, 0.05, "Centre content must reach the left channel: \(source.lastPathComponent)")
            XCTAssertEqual(level.left, level.right, accuracy: level.left * 0.01, source.lastPathComponent)
        }
    }

    func testSurroundChannelsKeepTheirSide() throws {
        let leftSurround = try surround("ls.wav", tag: kAudioChannelLayoutTag_MPEG_5_1_A, active: 4)
        _ = try StreamingAudio.decode(leftSurround, to: directory.appending(path: "ls-decoded.wav"))
        var level = try rms(directory.appending(path: "ls-decoded.wav"))
        XCTAssertGreaterThan(level.left, 0.05)
        XCTAssertLessThan(level.right, 0.001)
        let rearRight = try plainWAV("quad.wav", channels: 4, active: 3)
        _ = try StreamingAudio.decode(rearRight, to: directory.appending(path: "quad-decoded.wav"))
        level = try rms(directory.appending(path: "quad-decoded.wav"))
        XCTAssertGreaterThan(level.right, 0.05)
        XCTAssertLessThan(level.left, 0.001)
    }

    // MARK: - Truncated sources (separation-5)

    func testTruncatedFLACFailsInsteadOfImportingPartOfTheSong() throws {
        let frames = 44_100 * 6
        let flac = directory.appending(path: "song.flac")
        do {
            let buffer = AVAudioPCMBuffer(pcmFormat: StreamingAudio.format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = buffer.frameCapacity
            var generator = SystemRandomNumberGenerator()
            for frame in 0..<frames {
                let noise = Float.random(in: -0.1...0.1, using: &generator)
                buffer.floatChannelData![0][frame] = tone(frame, amplitude: 0.3) + noise
                buffer.floatChannelData![1][frame] = tone(frame, amplitude: 0.2) - noise
            }
            let file = try AVAudioFile(forWriting: flac, settings: [
                AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                AVEncoderBitDepthHintKey: 16
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        XCTAssertEqual(StreamingAudio.declaredFrames(of: flac), frames)
        XCTAssertEqual(try StreamingAudio.decode(flac, to: directory.appending(path: "whole.wav")).frames, frames)

        let bytes = try Data(contentsOf: flac)
        let truncated = directory.appending(path: "truncated.flac")
        try bytes.prefix(bytes.count / 2).write(to: truncated)
        XCTAssertThrowsError(try StreamingAudio.decode(truncated, to: directory.appending(path: "part.wav"))) { error in
            guard case DemucsError.unreadableSource(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("damaged or incomplete"), message)
            XCTAssertTrue(message.contains("of 0:06"), message)
        }
    }

    func testResampledSourcesAreNotMistakenForTruncatedOnes() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let frames = 48_000 * 3
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<frames { buffer.floatChannelData![0][frame] = tone(frame); buffer.floatChannelData![1][frame] = tone(frame) }
        let url = directory.appending(path: "48k.flac")
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        XCTAssertEqual(StreamingAudio.declaredFrames(of: url), 44_100 * 3)
        XCTAssertEqual(try StreamingAudio.decode(url, to: directory.appending(path: "out.wav")).frames, 44_100 * 3, accuracy: 2)
    }

    // MARK: - Readable decode errors (separation-2)

    func testDecodeFailuresUsePlainLanguage() throws {
        let fake = directory.appending(path: "notes.mp3")
        try Data(repeating: 0x41, count: 4096).write(to: fake)
        XCTAssertThrowsError(try StreamingAudio.decode(fake, to: directory.appending(path: "out.wav"))) { error in
            guard case DemucsError.unreadableSource(let message) = error else { return XCTFail("\(error)") }
            let longestNumber = message.split(whereSeparator: { !$0.isNumber }).map(\.count).max() ?? 0
            XCTAssertLessThan(longestNumber, 7, "Raw OSStatus numbers must not be shown: \(message)")
        }
        XCTAssertTrue(StreamingAudio.describe(kAudioFileInvalidFileError).contains("'dta?'"))
        XCTAssertTrue(StreamingAudio.describe(kAudioCodecBadDataError).hasPrefix("The file appears to be damaged"))
        XCTAssertEqual(StreamingAudio.describe(-50), "The file could not be decoded. It may be damaged or unsupported (Core Audio -50).")
    }

    // MARK: - Model errors (separation-8)

    func testUnusableModelIsNotReportedAsMissing() async throws {
        let broken = directory.appending(path: "HTDemucs.mlmodelc")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not a model".utf8).write(to: broken.appending(path: "model.mil"))
        let cache = directory.appending(path: "compiled.mlmodelc")
        do {
            _ = try await DemucsEngine.loadModel(compiled: [broken, broken], packages: [], compiledCache: cache)
            XCTFail("A damaged model must not load")
        } catch DemucsError.modelLoadFailed(let message) {
            XCTAssertTrue(message.contains("HTDemucs.mlmodelc could not be used"), message)
            XCTAssertTrue(message.contains("MODEL.md"), message)
        }
        do {
            _ = try await DemucsEngine.loadModel(compiled: [], packages: [], compiledCache: cache)
            XCTFail("No candidates means no model")
        } catch DemucsError.modelNotFound {
        }
    }

    // MARK: - Model lifetime (concurrency-5, concurrency-8)

    func testCancellingDuringModelLoadReturnsPromptlyAndLaterImportsSucceed() async throws {
        let engine = DemucsEngine.shared
        await engine.releaseIdleModel()
        let source = try stereo("load-cancel.wav", amplitude: Float.random(in: 0.25...0.35))
        let loading = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            try await self.split(source) { info in
                if info.statusMessage == "LOADING SEPARATION MODEL..." { loading.withLock { $0 = true } }
            }
        }
        let deadline = Date.now.addingTimeInterval(10)
        while !loading.withLock({ $0 }), Date.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(loading.withLock { $0 })
        let cancelled = Date.now
        task.cancel()
        do {
            let stems = try await task.value
            removeCache(stems)
            XCTFail("The import must stop when cancelled")
        } catch is CancellationError {
            XCTAssertLessThan(Date.now.timeIntervalSince(cancelled), 1.5, "Cancel must not wait for the model to load")
        }
        // The abandoned load is shared with the next import instead of being restarted.
        let stems = try await split(source)
        defer { removeCache(stems) }
        XCTAssertEqual(stems?.count, 4)
    }

    func testIdleModelIsReleasedAndReloadedOnDemand() async throws {
        let engine = DemucsEngine.shared
        await engine.setIdleModelLifetime(.milliseconds(300))
        defer { Task { await engine.setIdleModelLifetime(.seconds(60)) } }
        let first = try await split(try stereo("idle-1.wav", amplitude: Float.random(in: 0.25...0.35)))
        defer { removeCache(first) }
        guard first != nil else { return }
        let loadedAfterSplit = await engine.isModelLoaded
        XCTAssertTrue(loadedAfterSplit)
        try await Task.sleep(for: .seconds(1))
        let loadedWhenIdle = await engine.isModelLoaded
        XCTAssertFalse(loadedWhenIdle, "An idle model must be released")
        await engine.setIdleModelLifetime(.seconds(60))
        let second = try await split(try stereo("idle-2.wav", amplitude: Float.random(in: 0.25...0.35)))
        defer { removeCache(second) }
        XCTAssertEqual(second?.count, 4)
        let loadedAgain = await engine.isModelLoaded
        XCTAssertTrue(loadedAgain)
    }

    // MARK: - Abandoned staging (separation-3)

    func testAbandonedStagingSweepKeepsPublishedCaches() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: StemCache.root, withIntermediateDirectories: true)
        let partial = StemCache.root.appending(path: ".partial-\(UUID().uuidString)")
        let backup = StemCache.root.appending(path: ".backup-\(UUID().uuidString)")
        let published = StemCache.root.appending(path: "published-\(UUID().uuidString)")
        for folder in [partial, backup, published] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("audio".utf8).write(to: folder.appending(path: "original.wav"))
        }
        defer { try? fm.removeItem(at: published) }
        StemCache.removeAbandonedStaging()
        XCTAssertFalse(fm.fileExists(atPath: partial.path))
        XCTAssertFalse(fm.fileExists(atPath: backup.path))
        XCTAssertTrue(fm.fileExists(atPath: published.appending(path: "original.wav").path))
    }

    func testSeparationStartSweepsAbandonedStaging() async throws {
        let source = try stereo("sweep.wav", amplitude: 0.21)
        let cache = try cache(for: source)
        defer { try? FileManager.default.removeItem(at: cache) }
        let partial = StemCache.root.appending(path: ".partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let stems = try await DemucsEngine.shared.splitAudio(url: source) { _ in }
        XCTAssertEqual(stems.first?.deletingLastPathComponent().standardizedFileURL, cache.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    // MARK: - iCloud Drive (separation-4)

    func testLocalFilesSkipTheICloudDownload() async throws {
        let source = try stereo("local.wav")
        XCTAssertFalse(StreamingAudio.isCloudPlaceholder(source))
        var started = false
        try await StreamingAudio.downloadIfNeeded(source) { started = true }
        XCTAssertFalse(started)
    }

    func testICloudWaitFinishesFailsOfflineAndHonoursCancel() async throws {
        var polls = 0
        try await StreamingAudio.waitForDownload(named: "a.flac", interval: .milliseconds(1), isOffline: { false }) {
            polls += 1
            return polls == 3
        }
        XCTAssertEqual(polls, 3)

        do {
            try await StreamingAudio.waitForDownload(named: "a.flac", interval: .milliseconds(1), isOffline: { true }) { false }
            XCTFail("An offline wait must fail")
        } catch DemucsError.unreadableSource(let message) {
            XCTAssertTrue(message.contains("iCloud Drive") && message.contains("internet"), message)
        }

        do {
            try await StreamingAudio.waitForDownload(named: "a.flac", interval: .milliseconds(1), isOffline: { false }) {
                throw CocoaError(.ubiquitousFileUnavailable)
            }
            XCTFail("A download error must fail the wait")
        } catch DemucsError.unreadableSource(let message) {
            XCTAssertTrue(message.contains("could not be downloaded"), message)
        }

        let waiting = Task {
            try await StreamingAudio.waitForDownload(named: "a.flac", interval: .milliseconds(20), isOffline: { false }) { false }
        }
        try await Task.sleep(for: .milliseconds(50))
        let cancelled = Date.now
        waiting.cancel()
        do {
            try await waiting.value
            XCTFail("Cancelling must end the wait")
        } catch is CancellationError {
            XCTAssertLessThan(Date.now.timeIntervalSince(cancelled), 1)
        }
    }

    // MARK: - Disk space (separation-7)

    func testDiskSpacePreflightExplainsTheShortfall() throws {
        let minute = 44_100 * 60
        // Five Float32 stereo files: the original and four stems.
        XCTAssertEqual(StemCache.requiredBytes(forFrames: minute), Int64(minute) * 8 * 5 + (64 << 20))
        XCTAssertNoThrow(try StemCache.ensureSpace(needed: 1_000, available: nil))
        XCTAssertNoThrow(try StemCache.ensureSpace(needed: 1_000, available: 1_000))
        XCTAssertThrowsError(try StemCache.ensureSpace(needed: 6_000_000_000, available: 4_000_000_000)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.hasPrefix("Not enough disk space"), message)
            XCTAssertTrue(message.contains("6 GB") && message.contains("4 GB"), message)
        }
        XCTAssertNoThrow(try StemCache.ensureSpace(forFrames: nil))
        XCTAssertNoThrow(try StemCache.ensureSpace(forFrames: 44_100))
    }
}
