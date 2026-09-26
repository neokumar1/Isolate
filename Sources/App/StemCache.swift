import AVFoundation
import CryptoKit

/// Only complete, validated generations are published into the persistent cache.
enum StemCache {
    static let root: URL = {
        if AppPreferences.isTesting {
            return FileManager.default.temporaryDirectory.appending(path: "IsolateTestCache-\(UUID().uuidString)")
        }
        return URL.applicationSupportDirectory.appending(path: "Isolate/Stems", directoryHint: .isDirectory)
    }()

    static func key(for source: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var hash = SHA256()
        // Increment when the separation algorithm or model contract changes.
        hash.update(data: Data("Isolate-streaming-v4".utf8))
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validFiles(in directory: URL) -> [URL]? {
        let stems = DemucsEngine.stemNames.map { directory.appending(path: "\($0).wav") }
        let urls = stems + [directory.appending(path: "original.wav")]
        var length: AVAudioFramePosition?
        for url in urls {
            guard let file = try? AVAudioFile(forReading: url), file.length > 0,
                  file.processingFormat.channelCount == 2,
                  file.processingFormat.sampleRate == DemucsEngine.sampleRate else { return nil }
            if let length, file.length != length { return nil }
            length = file.length
        }
        return stems
    }

    static func owns(_ directory: URL) -> Bool {
        let parent = directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return parent == root.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Removes staging and backup folders left behind when the app quit or crashed
    /// mid-separation. Call only while no separation is running: at launch, or from
    /// DemucsEngine once it holds the single separation slot. A backup exists only
    /// while an invalid cache is being replaced, so it never holds usable stems.
    static func removeAbandonedStaging() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".partial-") || entry.lastPathComponent.hasPrefix(".backup-") {
            try? fm.removeItem(at: entry)
        }
    }

    /// Float32 stereo WAVs for the decoded original and four stems, plus headroom.
    static func requiredBytes(forFrames frames: Int) -> Int64 {
        Int64(frames) * Int64(MemoryLayout<Float>.size * 2) * 5 + (64 << 20)
    }

    /// Fails before decoding and inference when the cache volume cannot hold the result.
    static func ensureSpace(forFrames frames: Int?) throws {
        guard let frames else { return }
        var volume = root
        volume.removeAllCachedResourceValues()
        let available = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        try ensureSpace(needed: requiredBytes(forFrames: frames), available: available)
    }

    static func ensureSpace(needed: Int64, available: Int64?) throws {
        guard let available, available < needed else { return }
        throw DemucsError.insufficientDiskSpace(needed: needed, available: available)
    }

    static func publish(_ staging: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard validFiles(in: staging) != nil else {
            throw DemucsError.conversionFailed("The separated audio is incomplete.")
        }
        if fm.fileExists(atPath: destination.path) {
            let backup = destination.deletingLastPathComponent().appending(path: ".backup-\(UUID().uuidString)")
            try fm.moveItem(at: destination, to: backup)
            do {
                try fm.moveItem(at: staging, to: destination)
            } catch {
                try? fm.moveItem(at: backup, to: destination)
                throw error
            }
            try? fm.removeItem(at: backup)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }
}
