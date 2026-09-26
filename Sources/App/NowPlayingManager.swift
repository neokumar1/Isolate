import Foundation
import MediaPlayer
import AppKit
import AVFoundation

@MainActor
public final class NowPlayingManager: NSObject {
    public static let shared = NowPlayingManager()
    
    private weak var engineManager: AudioEngineManager?
    private var playlistProvider: (() -> [TrackModel])?
    private var trackSelectHandler: ((TrackModel) -> Void)?

    /// The artwork last handed to MediaPlayer, reused while the image is unchanged.
    private var artworkImage: NSImage?
    private var artwork: MPMediaItemArtwork?

    /// What the system was last told. It extrapolates elapsed time from this,
    /// so progress only needs republishing when playback departs from it.
    struct PublishedProgress: Equatable {
        var elapsed: Double
        var duration: Double
        var rate: Double
        var uptime: TimeInterval
    }
    private var publishedProgress: PublishedProgress?
    
    public override init() {
        super.init()
        setupRemoteCommands()
    }
    
    public func configure(
        engineManager: AudioEngineManager,
        playlistProvider: @escaping () -> [TrackModel],
        trackSelectHandler: @escaping (TrackModel) -> Void
    ) {
        self.engineManager = engineManager
        self.playlistProvider = playlistProvider
        self.trackSelectHandler = trackSelectHandler
    }
    
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // MediaPlayer may invoke handlers off the main thread. Queue UI/audio state
        // changes on the main actor and acknowledge that the command was accepted.
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, let engine = self.engineManager, !engine.isPlaying else { return }
                engine.togglePlayback()
            }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, let engine = self.engineManager, engine.isPlaying else { return }
                engine.togglePlayback()
            }
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.engineManager?.togglePlayback() }
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNextTrack() }
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPreviousTrack() }
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime,
                  position.isFinite else { return .commandFailed }
            Task { @MainActor in
                guard let engine = self?.engineManager, !engine.isSplitting,
                      let duration = engine.totalTrackDuration, duration > 0 else { return }
                engine.seek(toPercentage: position / duration)
            }
            return .success
        }
    }

    public func playNextTrack() {
        guard let engine = engineManager, !engine.isSplitting,
              let tracks = playlistProvider?(),
              !tracks.isEmpty else { return }
        
        let currentIndex = tracks.firstIndex(where: { $0.id == engine.currentTrackID }) ?? -1
        let nextIndex = (currentIndex + 1) % tracks.count
        let nextTrack = tracks[nextIndex]
        trackSelectHandler?(nextTrack)
    }
    
    public func playPreviousTrack() {
        guard let engine = engineManager, !engine.isSplitting,
              let tracks = playlistProvider?(),
              !tracks.isEmpty else { return }
        
        // If more than 3 seconds in, restart current track first (standard macOS media behavior)
        if let currentSecs = engine.currentPlaybackTimeSeconds, currentSecs > 3.0 {
            engine.seek(toPercentage: 0.0)
            return
        }
        
        let currentIndex = tracks.firstIndex(where: { $0.id == engine.currentTrackID }) ?? 0
        let prevIndex = (currentIndex - 1 + tracks.count) % tracks.count
        let prevTrack = tracks[prevIndex]
        trackSelectHandler?(prevTrack)
    }
    
    public func updateNowPlayingInfo(
        title: String,
        artist: String? = nil,
        album: String? = nil,
        artwork: NSImage? = nil,
        duration: Double,
        elapsed: Double,
        isPlaying: Bool
    ) {
        var info: [String: Any] = [:]
        
        let cleanTitle = cleanTrackTitle(title)
        info[MPMediaItemPropertyTitle] = cleanTitle
        info[MPMediaItemPropertyArtist] = (artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? artist! : "Isolate"
        info[MPMediaItemPropertyAlbumTitle] = (album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? album! : "4-Stem Neural Audio"
        
        info[MPMediaItemPropertyPlaybackDuration] = max(0.0, duration)
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0.0, elapsed)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? (engineManager?.playbackRate ?? 1) : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        
        // High-Res Artwork with Nothing OS Application Icon Fallback
        if let image = artwork ?? NSApp?.applicationIconImage {
            info[MPMediaItemPropertyArtwork] = mediaArtwork(for: image)
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        recordProgress(info)
    }

    private func mediaArtwork(for image: NSImage) -> MPMediaItemArtwork {
        if let artwork, artworkImage === image { return artwork }
        let made = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        artworkImage = image
        artwork = made
        return made
    }

    private func recordProgress(_ info: [String: Any]) {
        publishedProgress = PublishedProgress(
            elapsed: info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0,
            duration: info[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0,
            rate: info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0,
            uptime: ProcessInfo.processInfo.systemUptime)
    }

    /// True when the system's extrapolated position, duration or rate no longer
    /// matches playback, e.g. after a seek, loop wrap or rate change.
    static func progressNeedsPublish(_ last: PublishedProgress?, elapsed: Double, duration: Double,
                                     rate: Double, uptime: TimeInterval) -> Bool {
        guard let last else { return true }
        guard last.rate == rate, abs(last.duration - duration) < 0.001 else { return true }
        let expected = last.elapsed + (uptime - last.uptime) * last.rate
        return abs(expected - elapsed) > 0.25
    }
    
    public func updateNowPlayingPlaybackState() {
        guard let engine = engineManager else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = engine.isPlaying ? (engineManager?.playbackRate ?? 1) : 0.0
        if let elapsed = engine.currentPlaybackTimeSeconds {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = engine.isPlaying ? .playing : .paused
        recordProgress(info)
    }
    
    public func updateNowPlayingProgress(elapsed: Double, duration: Double) {
        let rate = (engineManager?.isPlaying == true) ? (engineManager?.playbackRate ?? 1) : 0.0
        let uptime = ProcessInfo.processInfo.systemUptime
        guard Self.progressNeedsPublish(publishedProgress, elapsed: elapsed, duration: duration,
                                        rate: rate, uptime: uptime),
              var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        publishedProgress = PublishedProgress(elapsed: elapsed, duration: duration, rate: rate, uptime: uptime)
    }
    
    public func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        publishedProgress = nil
        artworkImage = nil
        artwork = nil
    }
    
    public func cleanTrackTitle(_ raw: String) -> String {
        var clean = raw
        // Strip common audio extensions
        for ext in [".mp3", ".m4a", ".wav", ".flac", ".aac", ".aiff", ".MP3", ".M4A", ".WAV", ".FLAC", ".AAC"] {
            if clean.hasSuffix(ext) {
                clean = String(clean.dropLast(ext.count))
            }
        }
        // Strip only an unmistakable track-number prefix ("01 - ", "01. ",
        // "01_") before a letter, so titles such as "7-Eleven", "22",
        // "1-800-273-8255" or "99 Problems" are published unchanged.
        let pattern = #"^\d{1,3}(?:\s*[-.]\s+|_\s*)(?=\p{L})"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(clean.startIndex..<clean.endIndex, in: clean)
            clean = regex.stringByReplacingMatches(in: clean, options: [], range: range, withTemplate: "")
        }
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
