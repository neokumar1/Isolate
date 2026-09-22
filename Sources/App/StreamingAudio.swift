import AVFoundation
import AudioToolbox

/// Disk-backed audio preparation keeps memory independent of track duration.
enum StreamingAudio {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 44_100, channels: 2, interleaved: false)!
    static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 44_100.0,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]

    struct Statistics {
        let frames: Int
        let mean: Float
        let standardDeviation: Float
    }

    static func decode(_ source: URL, to destination: URL) throws -> Statistics {
        var reference: ExtAudioFileRef?
        try check(ExtAudioFileOpenURL(source as CFURL, &reference))
        guard let reference else { throw DemucsError.invalidAudioFormat }
        defer { ExtAudioFileDispose(reference) }
        var description = format.streamDescription.pointee
        try check(ExtAudioFileSetProperty(reference, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &description))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384),
              let channels = buffer.floatChannelData else { throw DemucsError.invalidAudioFormat }
        let writer = try AVAudioFile(forWriting: destination, settings: settings)
        var count = 0
        var sum = 0.0
        var sumSquares = 0.0
        while true {
            try Task.checkCancellation()
            buffer.frameLength = buffer.frameCapacity
            var frames = buffer.frameCapacity
            try check(ExtAudioFileRead(reference, &frames, buffer.mutableAudioBufferList))
            guard frames > 0 else { break }
            buffer.frameLength = frames
            for i in 0..<Int(frames) {
                guard channels[0][i].isFinite, channels[1][i].isFinite else {
                    throw DemucsError.conversionFailed("The source contains non-finite audio samples.")
                }
                // Demucs normalizes against the mono reference signal.
                let mono = (Double(channels[0][i]) + Double(channels[1][i])) * 0.5
                sum += mono
                sumSquares += mono * mono
            }
            count += Int(frames)
            try writer.write(from: buffer)
        }
        guard count > 0 else { throw DemucsError.invalidAudioFormat }
        let mean = sum / Double(count)
        let variance = max(0, sumSquares / Double(count) - mean * mean)
        return Statistics(frames: count, mean: Float(mean), standardDeviation: max(1e-4, Float(sqrt(variance))))
    }

    static func reflectedIndex(_ index: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let period = 2 * (count - 1)
        let remainder = ((index % period) + period) % period
        return remainder < count ? remainder : period - remainder
    }

    static func readWindow(file: AVAudioFile, start: Int, count: Int, into buffer: AVAudioPCMBuffer) throws {
        let length = Int(file.length)
        guard length > 0, count <= buffer.frameCapacity else { throw DemucsError.invalidAudioFormat }
        var lower = length - 1
        var upper = 0
        for i in 0..<count {
            let index = reflectedIndex(start + i, count: length)
            lower = min(lower, index)
            upper = max(upper, index)
        }
        let readCount = AVAudioFrameCount(upper - lower + 1)
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readCount) else {
            throw DemucsError.invalidAudioFormat
        }
        file.framePosition = AVAudioFramePosition(lower)
        try file.read(into: input, frameCount: readCount)
        guard input.frameLength == readCount else { throw DemucsError.invalidAudioFormat }
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<2 {
            let source = input.floatChannelData![channel]
            let target = buffer.floatChannelData![channel]
            for i in 0..<count {
                target[i] = source[reflectedIndex(start + i, count: length) - lower]
            }
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw DemucsError.conversionFailed("Audio decoding failed (\(status)). The file may be damaged or unsupported.")
        }
    }
}
