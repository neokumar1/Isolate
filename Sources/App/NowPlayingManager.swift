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
        
        // 1. Play Command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self, let engine = self.engineManager else { return .commandFailed }
            if !engine.isPlaying {
                engine.togglePlayback()
            }
            self.updateNowPlayingPlaybackState()
            return .success
        }
        
        // 2. Pause Command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self, let engine = self.engineManager else { return .commandFailed }
            if engine.isPlaying {
                engine.togglePlayback()
            }
            self.updateNowPlayingPlaybackState()
            return .success
        }
        
        // 3. Toggle Play/Pause Command (Function Row F8 & AirPods click)
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self, let engine = self.engineManager else { return .commandFailed }
            engine.togglePlayback()
            self.updateNowPlayingPlaybackState()
            return .success
        }
        
        // 4. Next Track (F9 & AirPods double-click)
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.playNextTrack()
            return .success
        }
        
        // 5. Previous Track (F7 & AirPods triple-click)
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.playPreviousTrack()
            return .success
        }
        
        // 6. Interactive Scrubbing in Control Center & Lock Screen
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let engine = self.engineManager,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent,
                  let duration = engine.totalTrackDuration, duration > 0 else {
                return .commandFailed
            }
            let targetSeconds = positionEvent.positionTime
            let targetPercentage = max(0.0, min(1.0, targetSeconds / duration))
            engine.seek(toPercentage: targetPercentage)
            self.updateNowPlayingProgress(elapsed: targetSeconds, duration: duration)
            return .success
        }
    }
    
    public func playNextTrack() {
        guard let engine = engineManager,
              let tracks = playlistProvider?(),
              !tracks.isEmpty else { return }
        
        let currentIndex = tracks.firstIndex(where: { $0.id == engine.currentTrackID }) ?? -1
        let nextIndex = (currentIndex + 1) % tracks.count
        let nextTrack = tracks[nextIndex]
        trackSelectHandler?(nextTrack)
    }
    
    public func playPreviousTrack() {
        guard let engine = engineManager,
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
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        
        // High-Res Artwork with Nothing OS Application Icon Fallback
        if let art = artwork {
            let mpArtwork = MPMediaItemArtwork(boundsSize: art.size) { _ in art }
            info[MPMediaItemPropertyArtwork] = mpArtwork
        } else if let appIcon = NSApp.applicationIconImage {
            let mpArtwork = MPMediaItemArtwork(boundsSize: appIcon.size) { _ in appIcon }
            info[MPMediaItemPropertyArtwork] = mpArtwork
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
    
    public func updateNowPlayingPlaybackState() {
        guard let engine = engineManager else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = engine.isPlaying ? 1.0 : 0.0
        if let elapsed = engine.currentPlaybackTimeSeconds {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = engine.isPlaying ? .playing : .paused
    }
    
    public func updateNowPlayingProgress(elapsed: Double, duration: Double) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = (engineManager?.isPlaying == true) ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    public func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
    
    public func cleanTrackTitle(_ raw: String) -> String {
        var clean = raw
        // Strip common audio extensions
        for ext in [".mp3", ".m4a", ".wav", ".flac", ".aac", ".aiff", ".MP3", ".M4A", ".WAV", ".FLAC", ".AAC"] {
            if clean.hasSuffix(ext) {
                clean = String(clean.dropLast(ext.count))
            }
        }
        // Strip leading track numbering e.g. "01 - ", "01. ", "01 "
        let pattern = #"^\d{1,3}\s*[-._]\s*"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(clean.startIndex..<clean.endIndex, in: clean)
            clean = regex.stringByReplacingMatches(in: clean, options: [], range: range, withTemplate: "")
        }
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
