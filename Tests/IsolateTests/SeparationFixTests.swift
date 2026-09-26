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
}
