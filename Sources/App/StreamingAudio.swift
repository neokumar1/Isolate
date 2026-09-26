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
        let info = try sourceInfo(reference)
        // A stereo client format keeps only the first two channels of wider
        // sources, so decode every channel and downmix by speaker position.
        var clientFormat = format
        var downmix: AVAudioConverter?
        if info.format.mChannelsPerFrame > 2 {
            let layout = try channelLayout(of: reference, channels: info.format.mChannelsPerFrame)
            clientFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                         interleaved: false, channelLayout: layout)
            guard let converter = AVAudioConverter(from: clientFormat, to: format) else {
                throw DemucsError.invalidAudioFormat
            }
            converter.downmix = true
            downmix = converter
        }
        var description = clientFormat.streamDescription.pointee
        try check(ExtAudioFileSetProperty(reference, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &description))
        if let layout = clientFormat.channelLayout, downmix != nil {
            // Codecs such as ALAC decode in their native order unless the client layout is explicit.
            let size = MemoryLayout<AudioChannelLayout>.size
                + max(0, Int(layout.layout.pointee.mNumberChannelDescriptions) - 1) * MemoryLayout<AudioChannelDescription>.size
            try check(ExtAudioFileSetProperty(reference, kExtAudioFileProperty_ClientChannelLayout,
                                             UInt32(size), layout.layout))
        }
        guard let decoded = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: 16_384),
              let buffer = downmix == nil ? decoded : AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384),
              let channels = buffer.floatChannelData else { throw DemucsError.invalidAudioFormat }
        let writer = try AVAudioFile(forWriting: destination, settings: settings)
        var count = 0
        var sum = 0.0
        var sumSquares = 0.0
        var stereoSumSquares = 0.0
        while true {
            try Task.checkCancellation()
            decoded.frameLength = decoded.frameCapacity
            var frames = decoded.frameCapacity
            try check(ExtAudioFileRead(reference, &frames, decoded.mutableAudioBufferList))
            guard frames > 0 else { break }
            decoded.frameLength = frames
            try downmix?.convert(to: buffer, from: decoded)
            for i in 0..<Int(buffer.frameLength) {
                guard channels[0][i].isFinite, channels[1][i].isFinite else {
                    throw DemucsError.conversionFailed("The source contains non-finite audio samples.")
                }
                // Demucs normalizes against the mono reference signal.
                let mono = (Double(channels[0][i]) + Double(channels[1][i])) * 0.5
                sum += mono
                sumSquares += mono * mono
                stereoSumSquares += (Double(channels[0][i]) * Double(channels[0][i])
                    + Double(channels[1][i]) * Double(channels[1][i])) * 0.5
            }
            count += Int(buffer.frameLength)
            try writer.write(from: buffer)
        }
        guard count > 0 else { throw DemucsError.unreadableSource("The file contains no audio that could be decoded.") }
        // Some decoders end cleanly at a damaged region instead of failing. Lossless
        // formats declare an exact length, so a large shortfall means lost audio.
        let exactLength = [kAudioFormatLinearPCM, kAudioFormatFLAC, kAudioFormatAppleLossless].contains(info.format.mFormatID)
        if exactLength, info.frames > 0, info.frames - count > max(info.frames / 100, 44_100) {
            throw DemucsError.unreadableSource("The file appears damaged or incomplete: only \(clock(count)) of \(clock(info.frames)) could be decoded.")
        }
        let mean = sum / Double(count)
        let variance = max(0, sumSquares / Double(count) - mean * mean)
        // Opposite-phase stereo can have a silent mono reference while both
        // channels remain loud. Do not amplify it by 10,000x before inference.
        let stereoVariance = max(0, stereoSumSquares / Double(count) - mean * mean)
        let normalizationVariance = variance < 1e-8 ? stereoVariance : variance
        return Statistics(frames: count, mean: Float(mean), standardDeviation: max(1e-4, Float(sqrt(normalizationVariance))))
    }

    /// Declared length at 44.1 kHz, or nil when the file does not state one.
    static func declaredFrames(of source: URL) -> Int? {
        var reference: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(source as CFURL, &reference) == noErr, let reference else { return nil }
        defer { ExtAudioFileDispose(reference) }
        guard let frames = try? sourceInfo(reference).frames, frames > 0 else { return nil }
        return frames
    }

    private static func sourceInfo(_ reference: ExtAudioFileRef) throws -> (format: AudioStreamBasicDescription, frames: Int) {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(ExtAudioFileGetProperty(reference, kExtAudioFileProperty_FileDataFormat, &size, &format))
        var length: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        // Streams written without a total length report zero.
        if ExtAudioFileGetProperty(reference, kExtAudioFileProperty_FileLengthFrames, &size, &length) != noErr { length = 0 }
        guard format.mSampleRate > 0, length > 0 else { return (format, 0) }
        return (format, Int((Double(length) * 44_100 / format.mSampleRate).rounded()))
    }

    /// The file's speaker layout, or the WAV/FLAC default order when it declares none.
    private static func channelLayout(of reference: ExtAudioFileRef, channels: UInt32) throws -> AVAudioChannelLayout {
        var size: UInt32 = 0
        if ExtAudioFileGetPropertyInfo(reference, kExtAudioFileProperty_FileChannelLayout, &size, nil) == noErr, size > 0 {
            let byteCount = max(Int(size), MemoryLayout<AudioChannelLayout>.size)
            let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { raw.deallocate() }
            raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
            let pointer = raw.assumingMemoryBound(to: AudioChannelLayout.self)
            if ExtAudioFileGetProperty(reference, kExtAudioFileProperty_FileChannelLayout, &size, raw) == noErr {
                let layout = AVAudioChannelLayout(layout: pointer)
                let tag = layout.layoutTag
                let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
                let descriptions = UnsafeBufferPointer(
                    start: (raw + offset).assumingMemoryBound(to: AudioChannelDescription.self),
                    count: min(Int(pointer.pointee.mNumberChannelDescriptions),
                               (byteCount - offset) / MemoryLayout<AudioChannelDescription>.stride))
                // Discrete or unlabelled channels have no speaker position to downmix from.
                let positioned = tag != kAudioChannelLayoutTag_UseChannelDescriptions
                    || descriptions.allSatisfy { (1..<100).contains($0.mChannelLabel) }
                if layout.channelCount == channels, positioned,
                   tag & 0xFFFF_0000 != kAudioChannelLayoutTag_DiscreteInOrder,
                   tag & 0xFFFF_0000 != kAudioChannelLayoutTag_Unknown {
                    return layout
                }
            }
        }
        let defaults: [UInt32: AudioChannelLayoutTag] = [
            3: kAudioChannelLayoutTag_WAVE_3_0, 4: kAudioChannelLayoutTag_WAVE_4_0_A,
            5: kAudioChannelLayoutTag_WAVE_5_0_A, 6: kAudioChannelLayoutTag_WAVE_5_1_A,
            7: kAudioChannelLayoutTag_WAVE_6_1, 8: kAudioChannelLayoutTag_WAVE_7_1
        ]
        guard let tag = defaults[channels], let layout = AVAudioChannelLayout(layoutTag: tag) else {
            throw DemucsError.unreadableSource("Audio with \(channels) channels is not supported. Import a stereo or surround mix.")
        }
        return layout
    }

    static func reflectedIndex(_ index: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let period = 2 * (count - 1)
        let remainder = ((index % period) + period) % period
        return remainder < count ? remainder : period - remainder
    }

    static func readWindow(file: AVAudioFile, start: Int, count: Int, into buffer: AVAudioPCMBuffer) throws {
        let length = Int(file.length)
        guard length > 0, count > 0, count <= buffer.frameCapacity else { throw DemucsError.invalidAudioFormat }
        // Most windows are entirely inside the track. Read them directly into
        // the reusable model buffer; only edge windows need reflection.
        if start >= 0, start <= length - count {
            file.framePosition = AVAudioFramePosition(start)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
            guard buffer.frameLength == AVAudioFrameCount(count) else { throw DemucsError.invalidAudioFormat }
            return
        }
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

    // MARK: - Errors

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw DemucsError.unreadableSource(describe(status)) }
    }

    /// Plain-language reasons for common Core Audio failures, keeping the code for diagnosis.
    static func describe(_ status: OSStatus) -> String {
        let reason: String
        switch status {
        case kAudioFileUnsupportedFileTypeError, kAudioFileUnsupportedDataFormatError:
            reason = "This audio format is not supported"
        case kAudioFileInvalidFileError:
            reason = "The file is damaged, or its contents do not match its extension"
        case kAudioFileInvalidChunkError, kAudioFileInvalidPacketOffsetError,
             kAudioFileInvalidPacketDependencyError, kAudioCodecBadDataError:
            reason = "The file appears to be damaged"
        case kAudioFilePermissionsError:
            reason = "Isolate does not have permission to read the file"
        case kAudioFileFileNotFoundError:
            reason = "The file could not be found"
        default:
            reason = "The file could not be decoded. It may be damaged or unsupported"
        }
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { Array($0) }
        let code = bytes.allSatisfy({ (0x20...0x7E).contains($0) })
            ? "'\(String(decoding: bytes, as: UTF8.self))'" : "\(status)"
        return "\(reason) (Core Audio \(code))."
    }

    static func clock(_ frames: Int) -> String {
        let seconds = frames / 44_100
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

