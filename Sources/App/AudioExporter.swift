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
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DemucsError.conversionFailed("Could not create the stem archive.") }
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
        // Copy alongside the destination first, including when exporting to another volume.
        let staging = destination.deletingLastPathComponent().appending(path: ".isolate-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
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
