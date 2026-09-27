import AppKit
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
public final class MenuBarManager: NSObject, NSMenuDelegate {
    public static let shared = MenuBarManager()
    
    private(set) var statusItem: NSStatusItem?
    private weak var engineManager: AudioEngineManager?
    /// Opens or fronts the main window through SwiftUI, which can recreate it
    /// after it was closed; set by the app scene.
    var openMainWindow: (() -> Void)?
    private var playlistProvider: (() -> [TrackModel])?
    private var trackSelectHandler: ((TrackModel) -> Void)?
    
    private var isConfigured = false
    private var animationTimer: Timer?
    private var animationFrame = 0
    
    public override init() {
        super.init()
    }
    
    public func configure(
        engineManager: AudioEngineManager,
        playlistProvider: @escaping () -> [TrackModel],
        trackSelectHandler: @escaping (TrackModel) -> Void
    ) {
        self.engineManager = engineManager
        self.playlistProvider = playlistProvider
        self.trackSelectHandler = trackSelectHandler
        
        if !isConfigured {
            isConfigured = true
            if !AppPreferences.defaults.bool(forKey: "isMenuBarDisabled") { setupStatusItem() }
        }
    }
    
    public func setEnabled(_ enabled: Bool) {
        if enabled {
            if statusItem == nil {
                setupStatusItem()
            }
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }
    
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = createMenuBarIcon(frame: 0, isPlaying: engineManager?.isPlaying ?? false)
            button.imagePosition = .imageOnly
            button.toolTip = "Isolate - 4-Stem Neural Audio"
            // The icon is image-only, so VoiceOver needs an explicit name.
            button.setAccessibilityLabel("Isolate")
        }
        
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.statusItem = item
        updatePlaybackState(isPlaying: engineManager?.isPlaying ?? false)
    }
    
    public func updatePlaybackState(isPlaying: Bool) {
        animationTimer?.invalidate()
        animationTimer = nil
        
        guard statusItem != nil else { return }
        statusItem?.button?.setAccessibilityValue(isPlaying ? "Playing" : "Paused")
        if isPlaying && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.14, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.animationFrame = (self.animationFrame + 1) % 6
                    if let button = self.statusItem?.button {
                        button.image = self.createMenuBarIcon(frame: self.animationFrame, isPlaying: true)
                    }
                }
            }
        } else {
            animationFrame = 0
            if let button = statusItem?.button {
                button.image = createMenuBarIcon(frame: 0, isPlaying: isPlaying)
            }
        }
    }
    
    private func createMenuBarIcon(frame: Int, isPlaying: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            guard NSGraphicsContext.current != nil else { return false }
            
            let color = isPlaying ? NSColor.systemRed : NSColor.labelColor
            color.setFill()
            
            let barW: CGFloat = 2.5
            let frames: [[CGFloat]] = [
                [6.0, 10.0, 6.0],
                [10.0, 15.0, 8.0],
                [14.0, 8.0, 13.0],
                [8.0, 14.0, 15.0],
                [15.0, 10.0, 7.0],
                [11.0, 15.0, 12.0]
            ]
            let heights: [CGFloat] = isPlaying ? frames[frame % frames.count] : [6.0, 10.0, 6.0]
            let xs: [CGFloat] = [3.0, 7.5, 12.0]
            let yCenter: CGFloat = 9.0
            
            for i in 0..<3 {
                let h = heights[i]
                let r = CGRect(x: xs[i], y: yCenter - h / 2.0, width: barW, height: h)
                let path = NSBezierPath(roundedRect: r, xRadius: 1.0, yRadius: 1.0)
                path.fill()
            }
            
            return true
        }
        img.isTemplate = !isPlaying
        return img
    }
    
    /// A single track needs no count; the subtitle already names it.
    static func batchCompletionTitle(count: Int) -> String {
        count == 1 ? "Stems Ready" : "Stems Ready (\(count) Tracks)"
    }

    public func sendBatchCompletionNotification(count: Int, lastTitle: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else { return }
                let content = UNMutableNotificationContent()
                content.title = Self.batchCompletionTitle(count: count)
                content.subtitle = lastTitle
                content.body = "Four-stem separation complete. Ready to play and mix."
                content.sound = .default
                
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                try await center.add(request)
            } catch {
                // Notification permission denied or ignored
            }
        }
    }
    
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let engine = engineManager else { return }
        
        // 1. Current Track Header
        let trackItem = NSMenuItem(
            title: engine.currentTrackName.isEmpty ? "ISOLATE STEM PLAYER" : engine.currentTrackName,
            action: #selector(bringWindowToFront),
            keyEquivalent: ""
        )
        trackItem.target = self
        menu.addItem(trackItem)
        
        if !engine.trackArtist.isEmpty && engine.trackArtist != "Isolate" {
            let artistItem = NSMenuItem(
                title: "\(engine.trackArtist) • \(engine.effectiveBPM) • \(engine.effectiveMusicalKey)",
                action: nil,
                keyEquivalent: ""
            )
            artistItem.isEnabled = false
            menu.addItem(artistItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // 2. Play / Pause & Navigation
        let playTitle = engine.isPlaying ? "Pause" : "Play"
        let playItem = NSMenuItem(title: playTitle, action: #selector(togglePlayPause), keyEquivalent: " ")
        playItem.isEnabled = engine.hasLoadedTrack && !engine.isSplitting
        playItem.target = self
        menu.addItem(playItem)
        
        let nextItem = NSMenuItem(title: "Next Track", action: #selector(nextTrack), keyEquivalent: "]")
        nextItem.keyEquivalentModifierMask = [.command]
        nextItem.target = self
        menu.addItem(nextItem)
        
        let prevItem = NSMenuItem(title: "Previous Track", action: #selector(previousTrack), keyEquivalent: "[")
        prevItem.keyEquivalentModifierMask = [.command]
        prevItem.target = self
        menu.addItem(prevItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. Stem Quick Actions
        let anySolo = engine.vocalSolo || engine.drumSolo || engine.bassSolo || engine.otherSolo
        let acapellaItem = NSMenuItem(title: "Acapella (Solo Vocals)", action: #selector(applyAcapella), keyEquivalent: "")
        acapellaItem.target = self
        acapellaItem.state = (engine.vocalSolo && !engine.vocalMuted && !engine.drumSolo && !engine.bassSolo && !engine.otherSolo) ? .on : .off
        menu.addItem(acapellaItem)
        
        let instrumentalItem = NSMenuItem(title: "Instrumental (Mute Vocals)", action: #selector(applyInstrumental), keyEquivalent: "")
        instrumentalItem.target = self
        instrumentalItem.state = (engine.vocalMuted && !engine.drumMuted && !engine.bassMuted && !engine.otherMuted && !anySolo) ? .on : .off
        menu.addItem(instrumentalItem)
        
        let drumlessItem = NSMenuItem(title: "Drumless Backing", action: #selector(applyDrumless), keyEquivalent: "")
        drumlessItem.target = self
        drumlessItem.state = (engine.drumMuted && !engine.vocalMuted && !engine.bassMuted && !engine.otherMuted && !anySolo) ? .on : .off
        menu.addItem(drumlessItem)
        
        let resetItem = NSMenuItem(title: "Reset 4-Stem Mix", action: #selector(applyResetMix), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 4. App Window & Quit
        let openItem = NSMenuItem(title: "Open Isolate", action: #selector(bringWindowToFront), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = [.command]
        openItem.target = self
        menu.addItem(openItem)
        
        let quitItem = NSMenuItem(title: "Quit Isolate", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    @objc private func togglePlayPause() {
        engineManager?.togglePlayback()
    }
    
    @objc private func nextTrack() {
        NowPlayingManager.shared.playNextTrack()
    }
    
    @objc private func previousTrack() {
        NowPlayingManager.shared.playPreviousTrack()
    }
    
    @objc private func applyAcapella() {
        engineManager?.applyAcapella()
    }
    
    @objc private func applyInstrumental() {
        engineManager?.applyInstrumental()
    }
    
    @objc private func applyDrumless() {
        engineManager?.applyDrumless()
    }
    
    @objc private func applyResetMix() {
        engineManager?.applyResetMix()
    }
    
    @objc private func bringWindowToFront() {
        NSApp.activate()
        if let openMainWindow {
            openMainWindow()
        } else if let window = Self.mainWindowCandidate(in: NSApp.windows) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The status item's own borderless window is also in `NSApp.windows` (and
    /// is first when the main window is closed), so only a titled window counts.
    static func mainWindowCandidate(in windows: [NSWindow]) -> NSWindow? {
        windows.first { !($0 is NSPanel) && $0.styleMask.contains(.titled) }
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
