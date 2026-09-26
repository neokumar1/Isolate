import Accelerate
import AVFoundation

enum AudioExporter {
    enum Format: String, CaseIterable, Sendable {
        case wav = "WAV"
        case flac = "FLAC"

        var fileExtension: String { rawValue.lowercased() }
        var settings: [String: Any] {
            [AVFormatIDKey: self == .wav ? kAudioFormatLinearPCM : kAudioFormatFLAC,
             AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 2,
             (self == .wav ? AVLinearPCMBitDepthKey : AVEncoderBitDepthHintKey): 24]
        }
    }

    struct EQ: Sendable {
        var low: Float = 0
        var mid: Float = 0
        var high: Float = 0
    }

    struct Source: Sendable {
        let url: URL
        var gain: Float = 1
        var pan: Float = 0
        var eq = EQ()
    }

    static func safeFilename(_ title: String) -> String {
        // Names are shared in ZIPs, so also exclude characters Windows cannot extract.
        let invalid = CharacterSet(charactersIn: "/:\\?*\"<>|").union(.controlCharacters)
        // A leading dot hides the file on macOS; Windows drops trailing dots and spaces.
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        let name = title.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: edges)
        guard !name.isEmpty else { return "Isolate" }
        // Leave room for stem names and extensions on 255-byte file systems.
        // Truncate at Character boundaries so Unicode titles remain valid.
        var result = ""
        var byteCount = 0
        for character in name.prefix(120) {
            let size = String(character).utf8.count
            guard byteCount + size <= 200 else { break }
            result.append(character)
            byteCount += size
        }
        result = result.trimmingCharacters(in: edges)
        return result.isEmpty ? "Isolate" : result
    }

    /// Stems in fixed-point formats peak at no more than -0.1 dBFS.
    static let stemPeakCeiling = Float(pow(10, -0.1 / 20))

    /// Render on a worker task using a separate graph; live playback is untouched.
    /// `progress` receives the rendered fraction on the rendering thread, at most once per whole percent.
    static func render(sources: [Source], to destination: URL, format: Format = .wav,
                       masterEQ: EQ = EQ(), rate: Float = 1, pitch: Float = 0,
                       limitPeak: Bool = false, progress: (@Sendable (Double) -> Void)? = nil) throws {
        _ = try renderMeasured(sources: sources, to: destination, settings: format.settings, masterEQ: masterEQ,
                               rate: rate, pitch: pitch, limitPeak: limitPeak) { progress?($0) }
    }

    /// Returns the largest sample magnitude written, measured before any fixed-point conversion.
    private static func renderMeasured(sources: [Source], to destination: URL, settings: [String: Any],
                                       masterEQ: EQ, rate: Float, pitch: Float, limitPeak: Bool,
                                       progress: (Double) -> Void) throws -> Float {
        guard !sources.isEmpty, rate.isFinite, rate > 0 else { throw DemucsError.invalidAudioFormat }
        let engine = AVAudioEngine()
        let audioFormat = StreamingAudio.format
        var players: [AVAudioPlayerNode] = []
        var files: [AVAudioFile] = []
        let sum = AVAudioMixerNode()
        engine.attach(sum)
        for source in sources {
            let file = try AVAudioFile(forReading: source.url)
            guard file.length > 0, file.processingFormat.channelCount == 2,
                  file.processingFormat.sampleRate == 44_100 else { throw DemucsError.invalidAudioFormat }
            if let first = files.first, first.length != file.length { throw DemucsError.invalidAudioFormat }
            files.append(file)
            let player = AVAudioPlayerNode()
            let eq = makeEQ(source.eq)
            let mixer = AVAudioMixerNode()
            engine.attach(player)
            engine.attach(eq)
            engine.attach(mixer)
            engine.connect(player, to: eq, format: audioFormat)
            engine.connect(eq, to: mixer, format: audioFormat)
            engine.connect(mixer, to: sum, format: audioFormat)
            mixer.outputVolume = source.gain
            mixer.pan = source.pan
            players.append(player)
        }
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = rate
        timePitch.pitch = pitch * 100
        timePitch.overlap = 32
        timePitch.bypass = rate == 1 && pitch == 0
        let eq = makeEQ(masterEQ)
        engine.attach(timePitch)
        engine.attach(eq)
        engine.connect(sum, to: timePitch, format: audioFormat)
        engine.connect(timePitch, to: eq, format: audioFormat)
        var latency: AVAudioFramePosition = 0
        if limitPeak {
            let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
            engine.attach(limiter)
            engine.connect(eq, to: limiter, format: audioFormat)
            engine.connect(limiter, to: engine.mainMixerNode, format: audioFormat)
            // Drop the limiter's look-ahead so the mix stays aligned with the source and keeps its ending.
            let frames = limiter.latency * audioFormat.sampleRate
            latency = frames.isFinite ? AVAudioFramePosition(min(max(frames, 0), 4096).rounded()) : 0
        } else {
            engine.connect(eq, to: engine.mainMixerNode, format: audioFormat)
        }
        try engine.enableManualRenderingMode(.offline, format: audioFormat, maximumFrameCount: 4096)
        defer {
            players.forEach { $0.stop() }
            engine.stop()
            engine.disableManualRenderingMode()
        }
        for (player, file) in zip(players, files) { player.scheduleFile(file, at: nil) }
        try engine.start()
        for player in players { player.play(at: AVAudioTime(sampleTime: 0, atRate: 44_100)) }
        let output = try AVAudioFile(forWriting: destination, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 4096) else {
            throw DemucsError.invalidAudioFormat
        }
        // Time/pitch spreads the final frames past the stretched length and reports no latency,
        // so render a fixed tail to keep the ending.
        let tail: AVAudioFramePosition = timePitch.bypass ? 0 : 4096
        let frameCount = AVAudioFramePosition(ceil(Double(files[0].length) / Double(rate))) + tail + latency
        var stalled = 0
        var peak: Float = 0
        var reported: AVAudioFramePosition = 0
        while engine.manualRenderingSampleTime < frameCount {
            try Task.checkCancellation()
            let before = engine.manualRenderingSampleTime
            // Blocks never straddle the discarded look-ahead.
            let end = before < latency ? latency : frameCount
            let count = AVAudioFrameCount(min(4096, end - before))
            switch try engine.renderOffline(count, to: buffer) {
            case .success:
                guard before >= latency else { break }
                peak = max(peak, Self.peak(of: buffer))
                try output.write(from: buffer)
            case .cannotDoInCurrentContext, .insufficientDataFromInputNode:
                break
            case .error:
                throw DemucsError.conversionFailed("Offline audio rendering failed.")
            @unknown default:
                throw DemucsError.conversionFailed("Unknown offline rendering status.")
            }
            stalled = before == engine.manualRenderingSampleTime ? stalled + 1 : 0
            guard stalled < 100 else { throw DemucsError.conversionFailed("Offline rendering stopped making progress.") }
            let percent = engine.manualRenderingSampleTime * 100 / frameCount
            if percent > reported {
                reported = percent
                progress(Double(engine.manualRenderingSampleTime) / Double(frameCount))
            }
        }
        return peak
    }

    /// Returns the gain applied to all four stems to stay below `stemPeakCeiling`, or 1 when none was needed.
    @discardableResult
    static func archive(sources: [Source], title: String, format: Format, to destination: URL,
                        progress: @Sendable (Double) -> Void) throws -> Float {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        guard sources.count == 4 else { throw DemucsError.invalidAudioFormat }
        // Separated stems and EQ boosts can exceed full scale, which 24-bit WAV and FLAC would clip.
        // Render in Float32 first, then lower all four by one gain so their balance and sum are kept.
        var rendered: [URL] = []
        var peak: Float = 0
        // Rendering fills 0-40% and encoding 40-80%; the archive step reports 80%.
        for (index, source) in sources.enumerated() {
            let url = directory.appending(path: "render-\(index).wav")
            peak = max(peak, try renderMeasured(sources: [source], to: url, settings: StreamingAudio.settings,
                                                masterEQ: EQ(), rate: 1, pitch: 0, limitPeak: false) {
                progress((Double(index) + $0) / 10)
            })
            rendered.append(url)
        }
        let gain = peak > stemPeakCeiling ? stemPeakCeiling / peak : 1
        var names: [String] = []
        for (index, url) in rendered.enumerated() {
            let name = "\(safeFilename(title))_\(DemucsEngine.stemNames[index]).\(format.fileExtension)"
            names.append(name)
            try encode(url, to: directory.appending(path: name), format: format, gain: gain) {
                progress(0.4 + (Double(index) + $0) / 10)
            }
            try? fm.removeItem(at: url)
        }
        let archive = directory.appending(path: "stems.zip")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        // Store entries: PCM and FLAC barely deflate, and compressing them was the slowest export step.
        process.arguments = ["-q", "-0", archive.path, "--"] + names
        try process.run()
        // Poll so a cancelled export also stops zip.
        while process.isRunning {
            if Task.isCancelled { process.terminate() }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw DemucsError.conversionFailed("Could not create the stem archive.") }
        // Best effort: an unflagged name still extracts correctly on macOS.
        try? markUTF8Names(in: archive)
        try Task.checkCancellation()
        try publish(archive, to: destination)
        progress(1)
        return gain
    }

    /// Converts rendered Float32 audio to the export format, scaling every sample by `gain`.
    private static func encode(_ source: URL, to destination: URL, format: Format, gain: Float,
                               progress: (Double) -> Void) throws {
        let input = try AVAudioFile(forReading: source)
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65_536) else {
            throw DemucsError.invalidAudioFormat
        }
        var scale = gain
        var reported: AVAudioFramePosition = 0
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                throw DemucsError.invalidAudioFormat
            }
            if gain != 1 {
                for channel in 0..<Int(buffer.format.channelCount) {
                    vDSP_vsmul(channels[channel], 1, &scale, channels[channel], 1, vDSP_Length(buffer.frameLength))
                }
            }
            try output.write(from: buffer)
            let percent = input.framePosition * 100 / input.length
            if percent > reported {
                reported = percent
                progress(Double(input.framePosition) / Double(input.length))
            }
        }
    }

    /// /usr/bin/zip stores UTF-8 names without general purpose bit 11, so Windows and other readers
    /// decode non-ASCII names as CP437. Set the bit in the central and local header of each such entry.
    static func markUTF8Names(in archive: URL) throws {
        let invalid = DemucsError.conversionFailed("Could not read the stem archive.")
        let handle = try FileHandle(forUpdating: archive)
        defer { try? handle.close() }
        func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
            try handle.seek(toOffset: offset)
            guard count > 0, let data = try handle.read(upToCount: count), data.count == count else { throw invalid }
            return [UInt8](data)
        }
        func setFlag(at offset: UInt64, _ flags: UInt16) throws {
            let value = flags | 0x0800
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data([UInt8(value & 0xFF), UInt8(value >> 8)]))
        }
        // The end record is 22 bytes plus a comment of up to 65,535 bytes.
        let size = try handle.seekToEnd()
        let tailStart = size - min(size, 65_557)
        let tail = try read(tailStart, Int(size - tailStart))
        guard let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            tail.uint32(at: $0) == 0x0605_4B50 && $0 + 22 + Int(tail.uint16(at: $0 + 20)) == tail.count
        }) else { throw invalid }
        var directorySize = UInt64(tail.uint32(at: end + 12))
        var directoryOffset = UInt64(tail.uint32(at: end + 16))
        if end >= 20, tail.uint32(at: end - 20) == 0x0706_4B50 {
            let record = try read(tail.uint64(at: end - 12), 56)
            guard record.uint32(at: 0) == 0x0606_4B50 else { throw invalid }
            directorySize = record.uint64(at: 40)
            directoryOffset = record.uint64(at: 48)
        }
        guard directorySize < 1 << 24 else { throw invalid }
        let directory = try read(directoryOffset, Int(directorySize))
        var position = 0
        while position + 46 <= directory.count {
            guard directory.uint32(at: position) == 0x0201_4B50 else { throw invalid }
            let nameEnd = position + 46 + Int(directory.uint16(at: position + 28))
            let extraEnd = nameEnd + Int(directory.uint16(at: position + 30))
            let next = extraEnd + Int(directory.uint16(at: position + 32))
            guard next <= directory.count else { throw invalid }
            let name = directory[(position + 46)..<nameEnd]
            if name.contains(where: { $0 >= 0x80 }), String(bytes: name, encoding: .utf8) != nil {
                var local = UInt64(directory.uint32(at: position + 42))
                if local == 0xFFFF_FFFF {
                    // The Zip64 extra field lists only the saturated sizes before the offset.
                    var field = nameEnd
                    var offset: UInt64?
                    while field + 4 <= extraEnd {
                        let length = Int(directory.uint16(at: field + 2))
                        if directory.uint16(at: field) == 0x0001 {
                            var value = field + 4
                            if directory.uint32(at: position + 24) == 0xFFFF_FFFF { value += 8 }
                            if directory.uint32(at: position + 20) == 0xFFFF_FFFF { value += 8 }
                            if value + 8 <= min(field + 4 + length, extraEnd) { offset = directory.uint64(at: value) }
                        }
                        field += 4 + length
                    }
                    guard let offset else { throw invalid }
                    local = offset
                }
                let header = try read(local, 8)
                guard header.uint32(at: 0) == 0x0403_4B50 else { throw invalid }
                try setFlag(at: local + 6, header.uint16(at: 6))
                try setFlag(at: directoryOffset + UInt64(position) + 8, directory.uint16(at: position + 8))
            }
            position = next
        }
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            var channelPeak: Float = 0
            vDSP_maxmgv(channels[channel], 1, &channelPeak, vDSP_Length(buffer.frameLength))
            peak = max(peak, channelPeak)
        }
        return peak
    }

    static func publish(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        // Copy onto the destination volume first, including when exporting to another volume. The system's
        // replacement directory keeps a copy interrupted by quitting out of the user's folder; volumes that
        // cannot provide one fall back to a hidden file beside the destination.
        let replacement = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                      appropriateFor: folder, create: true)
        let staging = replacement?.appending(path: destination.lastPathComponent)
            ?? folder.appending(path: ".isolate-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: replacement ?? staging) }
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }

    private static func makeEQ(_ gains: EQ) -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        for (index, gain) in [gains.low, gains.mid, gains.high].enumerated() {
            let band = eq.bands[index]
            band.filterType = [.lowShelf, .parametric, .highShelf][index]
            band.frequency = [100, 1000, 10_000][index]
            band.bandwidth = 1.2
            band.gain = gain
            band.bypass = false
        }
        eq.bypass = gains.low == 0 && gains.mid == 0 && gains.high == 0
        return eq
    }
}

/// Little-endian reads for ZIP records. Callers check bounds first.
private extension Array where Element == UInt8 {
    func uint16(at offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func uint32(at offset: Int) -> UInt32 { UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16 }
    func uint64(at offset: Int) -> UInt64 { UInt64(uint32(at: offset)) | UInt64(uint32(at: offset + 4)) << 32 }
}
