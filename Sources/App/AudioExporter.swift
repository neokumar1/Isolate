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

    /// Render on a worker task using a separate graph; live playback is untouched.
    static func render(sources: [Source], to destination: URL, format: Format = .wav,
                       masterEQ: EQ = EQ(), rate: Float = 1, pitch: Float = 0,
                       limitPeak: Bool = false) throws {
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
        if limitPeak {
            let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
            engine.attach(limiter)
            engine.connect(eq, to: limiter, format: audioFormat)
            engine.connect(limiter, to: engine.mainMixerNode, format: audioFormat)
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
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 4096) else {
            throw DemucsError.invalidAudioFormat
        }
        let frameCount = AVAudioFramePosition(ceil(Double(files[0].length) / Double(rate)))
        var stalled = 0
        while engine.manualRenderingSampleTime < frameCount {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(4096, frameCount - engine.manualRenderingSampleTime))
            let before = engine.manualRenderingSampleTime
            switch try engine.renderOffline(count, to: buffer) {
            case .success:
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
        }
    }

    static func archive(sources: [Source], title: String, format: Format, to destination: URL,
                        progress: @Sendable (Double) -> Void) throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        guard sources.count == 4 else { throw DemucsError.invalidAudioFormat }
        var names: [String] = []
        for (index, source) in sources.enumerated() {
            let name = "\(safeFilename(title))_\(DemucsEngine.stemNames[index]).\(format.fileExtension)"
            names.append(name)
            try render(sources: [source], to: directory.appending(path: name), format: format)
            progress(Double(index + 1) / 5)
        }
        let archive = directory.appending(path: "stems.zip")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", archive.path, "--"] + names
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DemucsError.conversionFailed("Could not create the stem archive.") }
        try Task.checkCancellation()
        try publish(archive, to: destination)
        progress(1)
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
