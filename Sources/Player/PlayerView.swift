import SwiftUI

struct GridBackground: View {
    @State private var theme = ThemeManager.shared
    
    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            GeometryReader { geometry in
                Path { path in
                    let step: CGFloat = 20
                    for x in stride(from: 0, to: geometry.size.width, by: step) {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    }
                    for y in stride(from: 0, to: geometry.size.height, by: step) {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }
                }
                .stroke(theme.hairline.opacity(0.4), lineWidth: 1)
            }
        }
        .ignoresSafeArea()
    }
}

public struct PlayerView: View {
    @Environment(AudioEngineManager.self) private var engineManager
    @State private var theme = ThemeManager.shared
    var isSidebarVisible: Binding<Bool>?

    @State private var isShowingShortcutCard = false
    
    public init(isSidebarVisible: Binding<Bool>? = nil) {
        self.isSidebarVisible = isSidebarVisible
    }

    public var body: some View {
        GeometryReader { windowGeo in
            let isCompactHeight = windowGeo.size.height < 680
            let showsHUD = PlayerHeaderMetrics.showsHUD(width: windowGeo.size.width)
            
            ZStack {
                VStack(spacing: 0) {
                    VStack(spacing: isCompactHeight ? 4 : 8) {
                        headerView(isCompactHeight: isCompactHeight)
                        stemMixerView(isCompactHeight: isCompactHeight)
                    }
                    .frame(maxHeight: .infinity)
                    .background(GridBackground())
                    
                    // Fixed Bottom Transport & Mixer Controls (Never Pushed Off-Screen)
                    TransportBar()
                        .layoutPriority(10)
                }
                .frame(width: windowGeo.size.width, height: windowGeo.size.height)
                
                // HUD Shortcut Cheat Sheet Modal
                if isShowingShortcutCard {
                    theme.modalBackdrop
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) {
                                isShowingShortcutCard = false
                            }
                        }
                    
                    ShortcutsHUDModal(onClose: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isShowingShortcutCard = false
                        }
                    })
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isShowingShortcutCard)
            .background {
                shortcutsOverlay(showsHUD: showsHUD)
            }
        }
    }
    
    private func headerView(isCompactHeight: Bool) -> some View {
        GeometryReader { geo in
            let metrics = PlayerHeaderMetrics(
                width: geo.size.width,
                isCompactHeight: isCompactHeight,
                hasSidebarToggle: isSidebarVisible != nil,
                isSidebarClosed: isSidebarVisible?.wrappedValue == false
            )
            let trackInfoWidth: CGFloat? = metrics.showsHUD ? metrics.trackInfoWidth : nil
            
            HStack(spacing: metrics.spacing) {
                if let isSidebarVisible = isSidebarVisible {
                    sidebarToggleButton(isSidebarVisible: isSidebarVisible)
                }
                
                AlbumArtView(image: engineManager.albumArt, size: metrics.artSize)
                
                trackInfoView(isCompact: !metrics.showsHUD, isCompactHeight: isCompactHeight)
                    .frame(minWidth: trackInfoWidth ?? 180, maxWidth: trackInfoWidth ?? .infinity, alignment: .leading)
                
                if metrics.showsHUD {
                    HeaderCenterTelemetryModule(isCompactHeight: isCompactHeight)
                        .frame(maxWidth: .infinity)
                        .padding(.leading, PlayerHeaderMetrics.hudGap)
                }
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.top, isCompactHeight ? 40 : 50)
            .padding(.bottom, 2)
        }
        .frame(height: isCompactHeight ? 122 : 152)
    }
    
    private func sidebarToggleButton(isSidebarVisible: Binding<Bool>) -> some View {
        Button(action: {
            Haptics.playClick()
            withAnimation(.easeOut(duration: 0.12)) {
                isSidebarVisible.wrappedValue.toggle()
            }
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSidebarVisible.wrappedValue ? theme.textPrimary : theme.textSecondary, lineWidth: 1)
                    .frame(width: 18, height: 14)
                
                HStack(spacing: 2) {
                    Rectangle()
                        .fill(isSidebarVisible.wrappedValue ? theme.textPrimary : theme.textSecondary)
                        .frame(width: 4, height: 10)
                    Spacer()
                }
                .frame(width: 14, height: 10)
            }
            .frame(width: 28, height: 28)
            .background(theme.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(theme.hairline, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSidebarVisible.wrappedValue ? "Hide library" : "Show library")
        .help(isSidebarVisible.wrappedValue ? "Hide Library Sidebar (⌘B)" : "Show Library Sidebar (⌘B)")
    }
    
    private func trackInfoView(isCompact: Bool, isCompactHeight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: isCompactHeight ? 3 : 5) {
            MarqueeText(
                text: engineManager.currentTrackName,
                fontSize: isCompact ? 20 : (isCompactHeight ? 20 : 24),
                color: theme.textPrimary,
                height: isCompactHeight ? 26 : 30
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            
            if !engineManager.trackArtist.isEmpty && engineManager.trackArtist != "Isolate" {
                let artistAlbum = "\(engineManager.trackArtist.uppercased()) • \(engineManager.trackAlbum.uppercased())"
                MarqueeText(
                    text: artistAlbum,
                    fontSize: isCompactHeight ? 9.5 : 10.5,
                    color: theme.textSecondary,
                    height: isCompactHeight ? 14 : 16
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("ISOLATE AUDIO CORE • 4-STEM NEURAL DSP")
                    .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 9.5 : 10.5))
                    .foregroundColor(theme.textMuted)
                    .lineLimit(1)
            }
            
            HStack(spacing: 8) {
                Text(engineManager.isBypassed ? "SOURCE: ORIGINAL MASTER" : "SOURCE: 4-STEM ISOLATION")
                    .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 9.5 : 10.5))
                    .foregroundColor(engineManager.isBypassed ? theme.warning : theme.textSecondary)
                
                Text("•")
                    .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 9.0 : 10.0))
                    .foregroundColor(theme.textDisabled)
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(engineManager.isPlaying ? theme.accentRed : theme.textDisabled)
                        .frame(width: 4.5, height: 4.5)
                        .shadow(color: engineManager.isPlaying ? theme.accentRed.opacity(0.6) : Color.clear, radius: 2)
                    
                    Text(engineManager.isPlaying ? "ACTIVE" : "STANDBY")
                        .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 9.0 : 10.0))
                        .foregroundColor(engineManager.isPlaying ? theme.textPrimary : theme.textSecondary)
                }
            }
        }
    }
    
    private func stemMixerView(isCompactHeight: Bool) -> some View {
        @Bindable var engine = engineManager
        let anySolo = engine.vocalSolo || engine.drumSolo || engine.bassSolo || engine.otherSolo
        let anyMuted = engine.vocalMuted || engine.drumMuted || engine.bassMuted || engine.otherMuted
        
        return HStack(spacing: isCompactHeight ? 10 : 16) {
            StemChannelView(
                channelIndex: 0,
                title: "VOCALS",
                volume: $engine.vocalVolume,
                pan: $engine.vocalPan,
                isMuted: $engine.vocalMuted,
                isSoloed: $engine.vocalSolo,
                lowGain: $engine.vocalEQLow,
                midGain: $engine.vocalEQMid,
                highGain: $engine.vocalEQHigh,
                isEQBypassed: $engine.vocalEQBypassed,
                isAnySoloed: anySolo,
                isAnyMuted: anyMuted,
                isPlaying: engine.isPlaying,
                isCompactHeight: isCompactHeight,
                onToggleMute: { toggleMute(0) },
                onToggleSolo: { toggleSolo(0) },
                onResetEQ: { engine.resetStemEQ(0) }
            )
            StemChannelView(
                channelIndex: 1,
                title: "DRUMS",
                volume: $engine.drumVolume,
                pan: $engine.drumPan,
                isMuted: $engine.drumMuted,
                isSoloed: $engine.drumSolo,
                lowGain: $engine.drumEQLow,
                midGain: $engine.drumEQMid,
                highGain: $engine.drumEQHigh,
                isEQBypassed: $engine.drumEQBypassed,
                isAnySoloed: anySolo,
                isAnyMuted: anyMuted,
                isPlaying: engine.isPlaying,
                isCompactHeight: isCompactHeight,
                onToggleMute: { toggleMute(1) },
                onToggleSolo: { toggleSolo(1) },
                onResetEQ: { engine.resetStemEQ(1) }
            )
            StemChannelView(
                channelIndex: 2,
                title: "BASS",
                volume: $engine.bassVolume,
                pan: $engine.bassPan,
                isMuted: $engine.bassMuted,
                isSoloed: $engine.bassSolo,
                lowGain: $engine.bassEQLow,
                midGain: $engine.bassEQMid,
                highGain: $engine.bassEQHigh,
                isEQBypassed: $engine.bassEQBypassed,
                isAnySoloed: anySolo,
                isAnyMuted: anyMuted,
                isPlaying: engine.isPlaying,
                isCompactHeight: isCompactHeight,
                onToggleMute: { toggleMute(2) },
                onToggleSolo: { toggleSolo(2) },
                onResetEQ: { engine.resetStemEQ(2) }
            )
            StemChannelView(
                channelIndex: 3,
                title: "OTHER",
                volume: $engine.otherVolume,
                pan: $engine.otherPan,
                isMuted: $engine.otherMuted,
                isSoloed: $engine.otherSolo,
                lowGain: $engine.otherEQLow,
                midGain: $engine.otherEQMid,
                highGain: $engine.otherEQHigh,
                isEQBypassed: $engine.otherEQBypassed,
                isAnySoloed: anySolo,
                isAnyMuted: anyMuted,
                isPlaying: engine.isPlaying,
                isCompactHeight: isCompactHeight,
                onToggleMute: { toggleMute(3) },
                onToggleSolo: { toggleSolo(3) },
                onResetEQ: { engine.resetStemEQ(3) }
            )
        }
        .padding(.horizontal, isCompactHeight ? 16 : 24)
        .frame(maxHeight: .infinity)
    }
    
    private func shortcutsOverlay(showsHUD: Bool) -> some View {
        Group {
            // Dedicated Numeric Solos (Keys 1 - 4)
            Button("") { toggleSolo(0) }.keyboardShortcut("1", modifiers: []).hidden()
            Button("") { toggleSolo(1) }.keyboardShortcut("2", modifiers: []).hidden()
            Button("") { toggleSolo(2) }.keyboardShortcut("3", modifiers: []).hidden()
            Button("") { toggleSolo(3) }.keyboardShortcut("4", modifiers: []).hidden()
            
            // Letter Mute Toggles (V, D, B, O)
            Button("") { toggleMute(0) }.keyboardShortcut("v", modifiers: []).hidden()
            Button("") { toggleMute(1) }.keyboardShortcut("d", modifiers: []).hidden()
            Button("") { toggleMute(2) }.keyboardShortcut("b", modifiers: []).hidden()
            Button("") { toggleMute(3) }.keyboardShortcut("o", modifiers: []).hidden()
            
            // Stem Macro & Loop Shortcuts
            Button("") { engineManager.applyResetMix() }.keyboardShortcut("r", modifiers: []).hidden()
            Button("") { engineManager.applyAcapella() }.keyboardShortcut("a", modifiers: []).hidden()
            Button("") { engineManager.applyInstrumental() }.keyboardShortcut("i", modifiers: []).hidden()
            Button("") { TransportActions.toggleLoop(engineManager) }.keyboardShortcut("l", modifiers: []).hidden()
            Button("") { TransportActions.clearLoop(engineManager) }.keyboardShortcut("l", modifiers: [.option]).hidden()
            Button("") { engineManager.toggleGlobalEQBypass() }.keyboardShortcut("e", modifiers: [.command]).hidden()
            
            // HUD Visualizer Mode Switching (⌘1 - ⌘5)
            ForEach(0..<5, id: \.self) { mode in
                Button("") {
                    Haptics.playClick()
                    engineManager.setHUDMode(mode)
                    // The HUD only fits beside the library in wide windows; make the
                    // requested mode visible instead of switching it off-screen.
                    if !showsHUD, let isSidebarVisible, isSidebarVisible.wrappedValue {
                        withAnimation(.easeOut(duration: 0.12)) {
                            isSidebarVisible.wrappedValue = false
                        }
                    }
                }.keyboardShortcut(KeyEquivalent(Character("\(mode + 1)")), modifiers: [.command]).hidden()
            }
            
            // On-The-Fly Loop Setters ([ and ])
            Button("") {
                TransportActions.setLoopStart(engineManager)
            }.keyboardShortcut("[", modifiers: []).hidden()

            Button("") {
                TransportActions.setLoopEnd(engineManager)
            }.keyboardShortcut("]", modifiers: []).hidden()

            // HUD Cheat Sheet Toggle (? / /)
            Button("") {
                Haptics.playClick()
                withAnimation(.easeOut(duration: 0.15)) {
                    isShowingShortcutCard.toggle()
                }
            }.keyboardShortcut("/", modifiers: []).hidden()
            
            Button("") {
                Haptics.playClick()
                withAnimation(.easeOut(duration: 0.15)) {
                    isShowingShortcutCard.toggle()
                }
            }.keyboardShortcut("?", modifiers: []).hidden()
        }
    }
    
    private func toggleMute(_ index: Int) {
        Haptics.playClick()
        engineManager.toggleMute(index)
    }
    
    private func toggleSolo(_ index: Int) {
        Haptics.playClick()
        engineManager.soloStem(index)
    }
}

struct StemChannelView: View {
    @Environment(AudioEngineManager.self) private var engineManager
    var channelIndex: Int = 0
    let title: String
    @Binding var volume: Double
    @Binding var pan: Float
    @Binding var isMuted: Bool
    @Binding var isSoloed: Bool
    @Binding var lowGain: Float
    @Binding var midGain: Float
    @Binding var highGain: Float
    @Binding var isEQBypassed: Bool
    let isAnySoloed: Bool
    let isAnyMuted: Bool
    let isPlaying: Bool
    var isCompactHeight: Bool = false
    var onToggleMute: (() -> Void)? = nil
    var onToggleSolo: (() -> Void)? = nil
    var onResetEQ: (() -> Void)? = nil
    
    @State private var theme = ThemeManager.shared
    @State private var isMutedHovered = false
    @State private var isSoloedHovered = false
    
    private var channelTag: String {
        String(format: "CH %02d", channelIndex + 1)
    }
    
    private var shortcutHint: String {
        switch channelIndex {
        case 0: return "[V / 1]"
        case 1: return "[D / 2]"
        case 2: return "[B / 3]"
        case 3: return "[O / 4]"
        default: return ""
        }
    }
    
    private var topAccentColor: Color {
        if isSoloed {
            return theme.accentRed
        } else if isAnySoloed || isMuted {
            return Color.clear
        } else {
            return theme.hairline
        }
    }
    
    private var effectiveVolume: Double {
        if isAnySoloed {
            return isSoloed ? volume : 0.0
        } else {
            return isMuted ? 0.0 : volume
        }
    }
    
    private var dbString: String {
        if volume <= 0.001 { return "-∞ dB" }
        let db = 20.0 * log10(volume)
        if abs(db) < 0.2 { return "0.0 dB" }
        return String(format: "%.1f dB", db)
    }
    
    private var isDimmed: Bool {
        effectiveVolume <= 0.001
    }
    
    var body: some View {
        VStack(spacing: isCompactHeight ? 4 : 8) {
            // Top Accent Status Bar
            Rectangle()
                .fill(topAccentColor)
                .frame(height: 2)
                .animation(.easeInOut(duration: 0.15), value: isSoloed)
                .animation(.easeInOut(duration: 0.15), value: isMuted)
            
            // Channel Header (Index & Shortcut tag + Stem Title)
            VStack(spacing: 2) {
                HStack {
                    Text(channelTag)
                        .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 9 : 10))
                        .foregroundColor(theme.textSecondary)
                    
                    Spacer()
                    
                    Text(shortcutHint)
                        .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 8.5 : 9))
                        .foregroundColor(theme.textMuted)
                }
                .padding(.horizontal, 6)
                
                Text(title)
                    .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 15 : 17))
                    .fontWeight(.bold)
                    .foregroundColor(theme.textPrimary)
                    .tracking(1.0)
            }
            .padding(.top, isCompactHeight ? 1 : 2)
            
            // Dynamic Island Symmetrical Dot-Matrix Waveform per stem
            StemMeterWaveformView(
                meter: engineManager.stemMeters[channelIndex],
                title: title,
                effectiveVolume: effectiveVolume,
                isPlaying: isPlaying
            )
            .frame(height: isCompactHeight ? 22 : 30)
            
            // Bipolar Stereo Panning Control
            PanKnobView(pan: $pan, channelName: title, isCompactHeight: isCompactHeight)
            
            // 3-Band Rotary EQ Section (Modular strip with hairlines)
            StemEQChannelStripView(
                low: $lowGain,
                mid: $midGain,
                high: $highGain,
                isBypassed: $isEQBypassed,
                isGloballyBypassed: engineManager.isGlobalEQBypassed,
                channelName: title,
                isCompactHeight: isCompactHeight,
                onReset: onResetEQ,
                onRestoreGlobalEQ: { engineManager.toggleGlobalEQBypass() }
            )
            
            // Precision Readout Box (% and dB)
            HStack(spacing: 8) {
                Text("\(Int(volume * 100))%")
                    .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 12 : 13.5))
                    .fontWeight(.bold)
                    .foregroundColor(theme.textPrimary)
                
                Text(dbString)
                    .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 9.0 : 10.0))
                    .foregroundColor(theme.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, isCompactHeight ? 2 : 3)
            .background(theme.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(theme.hairline, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                Haptics.playClick()
                withAnimation(.easeOut(duration: 0.12)) {
                    volume = 1.0
                }
            }
            .help("Double-click to reset to 0.0 dB (100%)")
            .padding(.top, isCompactHeight ? 0 : 2)
            
            // Hardware Fader with Decibel Scale & Machined Thumb
            MeteredFader(meter: engineManager.stemMeters[channelIndex], value: $volume, label: title)
                .frame(minHeight: isCompactHeight ? 75 : 120, maxHeight: .infinity)
            
            // Mute & Solo Hardware Switches
            HStack(spacing: isCompactHeight ? 8 : 12) {
                muteButton
                soloButton
            }
            .padding(.bottom, isCompactHeight ? 2 : 6)
        }
        .padding(.horizontal, isCompactHeight ? 6 : 8)
        .padding(.vertical, isCompactHeight ? 4 : 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surfaceSecondary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        // Keep controls readable while a channel is silent so it remains easy to
        // unmute it or move the solo to another stem.
        .overlay(alignment: .top) {
            if isDimmed {
                Rectangle().fill(theme.textDisabled).frame(height: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isDimmed)
    }
    
    private var muteButton: some View {
        let bg: Color = isMuted ? theme.accentRed : (isMutedHovered ? theme.surfaceHover : .clear)
        let strokeColor: Color = isMuted ? theme.accentRed : (isMutedHovered ? theme.textSecondary : theme.cardBorder)
        let fg: Color = isMuted ? theme.onAccent : theme.textPrimary
        
        return Button(action: {
            if let onToggleMute = onToggleMute {
                onToggleMute()
            } else {
                Haptics.playClick()
                isMuted.toggle()
                if isMuted { isSoloed = false }
            }
        }) {
            Text("M")
                .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 12 : 13))
                .fontWeight(.bold)
                .frame(width: isCompactHeight ? 40 : 44, height: isCompactHeight ? 28 : 32)
                .background(bg, in: RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(strokeColor, lineWidth: 1)
                )
                .foregroundColor(fg)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isMutedHovered = $0 }
        .accessibilityLabel("Mute \(title)")
        .accessibilityValue(isMuted ? "On" : "Off")
        .help("Mute channel (\(channelIndex == 0 ? "V" : channelIndex == 1 ? "D" : channelIndex == 2 ? "B" : "O"))")
    }
    
    private var soloButton: some View {
        let bg: Color = isSoloed ? theme.accentRed : (isSoloedHovered ? theme.surfaceHover : .clear)
        let strokeColor: Color = isSoloed ? theme.accentRed : (isSoloedHovered ? theme.textSecondary : theme.cardBorder)
        let fg: Color = isSoloed ? theme.onAccent : theme.textPrimary
        
        return Button(action: {
            if let onToggleSolo = onToggleSolo {
                onToggleSolo()
            } else {
                Haptics.playClick()
                isSoloed.toggle()
                if isSoloed { isMuted = false }
            }
        }) {
            Text("S")
                .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 12 : 13))
                .fontWeight(.bold)
                .frame(width: isCompactHeight ? 40 : 44, height: isCompactHeight ? 28 : 32)
                .background(bg, in: RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(strokeColor, lineWidth: 1)
                )
                .foregroundColor(fg)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isSoloedHovered = $0 }
        .accessibilityLabel("Solo \(title)")
        .accessibilityValue(isSoloed ? "On" : "Off")
        .help("Solo channel (\(channelIndex + 1))")
    }
}

// MARK: - Nothing Bipolar Stereo Pan Control
struct PanKnobView: View {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var pan: Float // -1.0 to +1.0
    var channelName: String = ""
    var isCompactHeight: Bool = false
    @State private var theme = ThemeManager.shared
    @State private var isHovered = false
    @State private var isDragging = false
    
    private var panLabel: String {
        Self.label(for: pan)
    }
    
    static func label(for pan: Float) -> String {
        // Round, not truncate: Float steps of 0.05 land just below the grid.
        let percent = Int((abs(pan) * 100).rounded())
        if abs(pan) < 0.04 {
            return "CENTER"
        }
        return pan < 0 ? "L \(percent)" : "R \(percent)"
    }
    
    /// Moves one 5% keyboard step, snapping onto the 5% grid so repeated steps
    /// neither drift nor overshoot after a drag left the value off-grid.
    static func stepped(_ pan: Float, direction: Float) -> Float {
        let grid = pan * 20
        let base = direction > 0 ? (grid + 1e-3).rounded(.down) : (grid - 1e-3).rounded(.up)
        return max(-1, min(1, (base + direction) / 20))
    }
    
    private var isCenter: Bool {
        abs(pan) < 0.04
    }
    
    var body: some View {
        VStack(spacing: isCompactHeight ? 1 : 3) {
            // Header: PAN label + Value Readout
            HStack {
                Text("PAN")
                    .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 8.0 : 8.5))
                    .foregroundColor(theme.textSecondary)
                Spacer()
                Text(panLabel)
                    .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 8.0 : 8.5))
                    .fontWeight(.bold)
                    .foregroundColor(isCenter ? theme.textPrimary : theme.accentRed)
            }
            .padding(.horizontal, 4)
            
            // Interactive Bipolar Stereo Bar
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                let centerX = width / 2.0
                let normalizedPan = CGFloat(pan) // -1.0 to +1.0
                let thumbX = centerX + (normalizedPan * (centerX - 6))
                
                ZStack(alignment: .leading) {
                    // Track Groove
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.faderTrack)
                        .frame(width: width, height: isCompactHeight ? 5 : 6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(theme.hairline, lineWidth: 0.5)
                        )
                        .position(x: centerX, y: height / 2.0)
                    
                    // Center Zero Detent Pip
                    Rectangle()
                        .fill(theme.textSecondary)
                        .frame(width: 1.5, height: isCompactHeight ? 8 : 10)
                        .position(x: centerX, y: height / 2.0)
                    
                    // Active Bipolar Fill from Center to Thumb
                    if !isCenter {
                        let fillWidth = abs(thumbX - centerX)
                        let fillOriginX = min(thumbX, centerX) + (fillWidth / 2.0)
                        
                        Rectangle()
                            .fill(theme.accentRed)
                            .frame(width: max(1, fillWidth), height: isCompactHeight ? 2.5 : 3)
                            .position(x: fillOriginX, y: height / 2.0)
                    }
                    
                    // Thumb Needle / Pip
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isCenter ? theme.faderThumb : theme.accentRed)
                        .frame(width: 3.5, height: isCompactHeight ? 10 : 12)
                        .shadow(color: (isHovered || isDragging) ? theme.accentRed.opacity(0.6) : Color.clear, radius: 3)
                        .position(x: thumbX, y: height / 2.0)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            isDragging = true
                            let touchX = drag.location.x
                            let ratio = (touchX - centerX) / (centerX - 6)
                            var newPan = Float(min(1.0, max(-1.0, ratio)))
                            if abs(newPan) < 0.06 {
                                if abs(pan) >= 0.06 { Haptics.playAlignment() }
                                newPan = 0.0
                            }
                            pan = newPan
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
                // A zero-distance drag claims every click, so the double-click
                // reset has to run alongside it rather than compete with it.
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    Haptics.playAlignment()
                    withAnimation(.easeOut(duration: 0.12)) {
                        pan = 0.0
                    }
                })
            }
            .frame(height: isCompactHeight ? 13 : 16)
            .onHover { isHovered = $0 }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, isCompactHeight ? 1 : 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(channelName.isEmpty ? "Pan" : "\(channelName) pan")
        .accessibilityValue(panLabel)
        .accessibilityAdjustableAction { pan = Self.stepped(pan, direction: $0 == .increment ? 1 : -1) }
        .focusable(isEnabled)
        .onKeyPress(.leftArrow) { pan = Self.stepped(pan, direction: -1); return .handled }
        .onKeyPress(.rightArrow) { pan = Self.stepped(pan, direction: 1); return .handled }
        .contextMenu { Button("Center Pan") { pan = 0 } }
    }
}

// MARK: - Rotary 3-Band EQ Knob (-12dB to +12dB)
struct RotaryEQKnobView: View {
    @Environment(\.isEnabled) private var isEnabled
    let bandName: String
    let freqLabel: String
    @Binding var gain: Float // -12.0 ... +12.0
    var isBypassed: Bool = false
    var channelName: String = ""
    var isCompactHeight: Bool = false
    
    @State private var theme = ThemeManager.shared
    @State private var isHovered = false
    @State private var dragStartGain: Float? = nil
    
    private var normalizedAngle: Double {
        let clamped = Double(max(-12.0, min(12.0, gain)))
        return (clamped / 12.0) * 135.0
    }
    
    private var gainString: String {
        if isBypassed { return "BYP" }
        if abs(gain) < 0.15 { return "0.0 dB" }
        return String(format: "%+.1f dB", gain)
    }
    
    private var accentColor: Color {
        if isBypassed { return theme.textMuted }
        if abs(gain) < 0.15 { return theme.textPrimary }
        return gain > 0 ? theme.accentRed : theme.textSecondary
    }
    
    /// Snaps gains within 0.25 dB to flat. The haptic plays only when a drag
    /// enters that detent, not on every drag event inside it.
    static func detent(_ target: Float, from current: Float) -> (gain: Float, entersDetent: Bool) {
        guard abs(target) < 0.25 else { return (target, false) }
        return (0, abs(current) >= 0.25)
    }
    
    var body: some View {
        let knobFrame: CGFloat = isCompactHeight ? 28 : 36
        let trackDiameter: CGFloat = isCompactHeight ? 24 : 32
        let capDiameter: CGFloat = isCompactHeight ? 14 : 18
        let dialOffset: CGFloat = isCompactHeight ? -12 : -16
        let needleLen: CGFloat = isCompactHeight ? 6 : 8
        let needleOffset: CGFloat = isCompactHeight ? -6.5 : -8
        
        return VStack(spacing: isCompactHeight ? 1.5 : 3) {
            Text(bandName)
                .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 8.5 : 9.5))
                .fontWeight(.bold)
                .foregroundColor(theme.textPrimary)
            
            Text(freqLabel)
                .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 6.5 : 7.5))
                .foregroundColor(theme.textSecondary)
            
            ZStack {
                // Outer Dial Track (-135 to +135 deg)
                Circle()
                    .trim(from: 0.125, to: 0.875)
                    .stroke(
                        theme.knobArcTrack,
                        style: StrokeStyle(lineWidth: isCompactHeight ? 2.0 : 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(90))
                    .frame(width: trackDiameter, height: trackDiameter)
                
                // Zero Detent Pip at 12 o'clock
                Rectangle()
                    .fill(theme.textSecondary)
                    .frame(width: 1.5, height: isCompactHeight ? 2.5 : 3.5)
                    .offset(y: dialOffset)
                
                // Quarter-turn Tick marks at -6dB and +6dB
                Rectangle()
                    .fill(theme.hairline)
                    .frame(width: 1, height: isCompactHeight ? 2.0 : 2.5)
                    .offset(y: dialOffset)
                    .rotationEffect(.degrees(-67.5))
                
                Rectangle()
                    .fill(theme.hairline)
                    .frame(width: 1, height: isCompactHeight ? 2.0 : 2.5)
                    .offset(y: dialOffset)
                    .rotationEffect(.degrees(67.5))
                
                // Active Gain Arc
                if !isBypassed && abs(gain) >= 0.15 {
                    if gain > 0 {
                        Circle()
                            .trim(from: 0.5, to: 0.5 + (Double(gain) / 24.0) * 0.75)
                            .stroke(
                                theme.accentRed,
                                style: StrokeStyle(lineWidth: isCompactHeight ? 2.0 : 2.5, lineCap: .round)
                            )
                            .rotationEffect(.degrees(90))
                            .frame(width: trackDiameter, height: trackDiameter)
                    } else {
                        Circle()
                            .trim(from: 0.5 - (Double(abs(gain)) / 24.0) * 0.75, to: 0.5)
                            .stroke(
                                theme.spectrumBarDefault.opacity(0.65),
                                style: StrokeStyle(lineWidth: isCompactHeight ? 2.0 : 2.5, lineCap: .round)
                            )
                            .rotationEffect(.degrees(90))
                            .frame(width: trackDiameter, height: trackDiameter)
                    }
                }
                
                // Machined Knob Cap
                Circle()
                    .fill(theme.knobFace)
                    .frame(width: capDiameter, height: capDiameter)
                    .overlay(
                        Circle()
                            .stroke(
                                isHovered ? theme.accentRed.opacity(0.85) : theme.cardBorder,
                                lineWidth: 1
                            )
                    )
                
                // Pointer Needle
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 1.5, height: needleLen)
                    .offset(y: needleOffset)
                    .rotationEffect(.degrees(normalizedAngle))
            }
            .frame(width: knobFrame, height: knobFrame)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        if dragStartGain == nil {
                            dragStartGain = gain
                        }
                        let start = dragStartGain ?? gain
                        let sensitivity: Float = NSEvent.modifierFlags.contains(.option) ? 0.05 : 0.20
                        let delta = Float(-val.translation.height) * sensitivity
                        let next = Self.detent(max(-12.0, min(12.0, start + delta)), from: gain)
                        if next.entersDetent {
                            Haptics.playAlignment()
                        }
                        gain = next.gain
                    }
                    .onEnded { _ in
                        dragStartGain = nil
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                Haptics.playAlignment()
                withAnimation(.easeOut(duration: 0.12)) {
                    gain = 0.0
                }
            })
            
            Text(gainString)
                .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 7.5 : 8.5))
                .foregroundColor(accentColor)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(channelName) \(bandName) EQ".trimmingCharacters(in: .whitespaces))
        .accessibilityValue(gainString)
        .accessibilityAdjustableAction { gain = max(-12, min(12, gain + ($0 == .increment ? 0.5 : -0.5))) }
        .focusable(isEnabled)
        .onKeyPress(.upArrow) { gain = min(12, gain + 0.5); return .handled }
        .onKeyPress(.downArrow) { gain = max(-12, gain - 0.5); return .handled }
        .contextMenu { Button("Reset EQ Gain") { gain = 0 } }
    }
}

// MARK: - Stem 3-Band EQ Channel Strip Component
struct StemEQChannelStripView: View {
    @Binding var low: Float
    @Binding var mid: Float
    @Binding var high: Float
    @Binding var isBypassed: Bool
    var isGloballyBypassed: Bool = false
    var channelName: String = ""
    var isCompactHeight: Bool = false
    var onReset: (() -> Void)? = nil
    var onRestoreGlobalEQ: (() -> Void)? = nil
    @State private var theme = ThemeManager.shared
    
    private var isModified: Bool {
        abs(low) >= 0.15 || abs(mid) >= 0.15 || abs(high) >= 0.15
    }
    
    /// True when no EQ reaches this channel's audio, either from its own
    /// bypass or from ⌘E bypassing every EQ.
    private var isEffectivelyBypassed: Bool {
        isBypassed || isGloballyBypassed
    }
    
    static func headerLabel(isBypassed: Bool, isGloballyBypassed: Bool) -> String {
        if isGloballyBypassed { return "ALL EQ OFF" }
        return isBypassed ? "EQ: BYP" : "3-BAND EQ"
    }
    
    var body: some View {
        VStack(spacing: isCompactHeight ? 3 : 5) {
            // Hairline Boundary Top
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 1)
                .padding(.horizontal, 4)
            
            // Header Bar
            HStack {
                Button(action: {
                    Haptics.playClick()
                    if isGloballyBypassed, let onRestoreGlobalEQ {
                        onRestoreGlobalEQ()
                    } else {
                        isBypassed.toggle()
                    }
                }) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isEffectivelyBypassed ? theme.textDisabled : (isModified ? theme.accentRed : theme.textPrimary))
                            .frame(width: 4, height: 4)
                        Text(Self.headerLabel(isBypassed: isBypassed, isGloballyBypassed: isGloballyBypassed))
                            .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 8.0 : 8.5))
                            .foregroundColor(isGloballyBypassed ? theme.warning : (isBypassed ? theme.textMuted : theme.textPrimary))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(theme.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(
                                isGloballyBypassed ? theme.warning : (isModified && !isBypassed ? theme.accentRed.opacity(0.5) : theme.hairline),
                                lineWidth: 0.5
                            )
                    )
                    .expandedHitArea(vertical: 3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(channelName) EQ bypass")
                .accessibilityValue(isGloballyBypassed ? "On, all EQ bypassed" : (isBypassed ? "On" : "Off"))
                .help(isGloballyBypassed
                      ? "All EQ is bypassed (⌘E). Click to turn EQ back on."
                      : (isBypassed ? "Enable this channel's EQ" : "Bypass this channel's EQ"))
                
                Spacer()
                
                if isModified {
                    Button(action: {
                        Haptics.playAlignment()
                        withAnimation(.easeOut(duration: 0.1)) {
                            low = 0.0
                            mid = 0.0
                            high = 0.0
                            onReset?()
                        }
                    }) {
                        Text("[RESET]")
                            .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 7.5 : 8.0))
                            .foregroundColor(theme.accentRed)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(theme.accentRed.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            .expandedHitArea(vertical: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reset \(channelName) EQ")
                    .help("Reset EQ to Flat 0.0 dB")
                }
            }
            .padding(.horizontal, 4)
            
            // 3 Rotary Knobs Row: LOW (100Hz), MID (1kHz), HIGH (10kHz)
            HStack(spacing: 2) {
                RotaryEQKnobView(bandName: "LOW", freqLabel: "100Hz", gain: $low, isBypassed: isEffectivelyBypassed, channelName: channelName, isCompactHeight: isCompactHeight)
                RotaryEQKnobView(bandName: "MID", freqLabel: "1.0kHz", gain: $mid, isBypassed: isEffectivelyBypassed, channelName: channelName, isCompactHeight: isCompactHeight)
                RotaryEQKnobView(bandName: "HIGH", freqLabel: "10kHz", gain: $high, isBypassed: isEffectivelyBypassed, channelName: channelName, isCompactHeight: isCompactHeight)
            }
            
            // Hairline Boundary Bottom
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 1)
                .padding(.horizontal, 4)
        }
        .padding(.vertical, isCompactHeight ? 1 : 2)
    }
}

// MARK: - Meter Leaf Views
// Only these read a stem's meter, so a tap reading re-renders the waveform or clip LED
// that shows it instead of the channel strip around it.

struct StemMeterWaveformView: View {
    let meter: StemMeter
    let title: String
    let effectiveVolume: Double
    let isPlaying: Bool

    var body: some View {
        StemDynamicWaveformView(
            title: title,
            magnitudes: meter.spectrum,
            effectiveVolume: effectiveVolume,
            isPlaying: isPlaying
        )
    }
}

/// Reads only the clip state, so peak readings below full scale leave the fader alone.
struct MeteredFader: View {
    let meter: StemMeter
    @Binding var value: Double
    let label: String

    var body: some View {
        CustomFader(value: $value, label: label, isClipping: meter.isClipping)
    }
}

// MARK: - Dynamic Island Symmetrical Dot-Matrix Stem Waveform View
struct StemDynamicWaveformView: View {
    let title: String
    let magnitudes: [Float]
    let effectiveVolume: Double
    let isPlaying: Bool
    @State private var theme = ThemeManager.shared
    
    // Per-stem 7 calibrated acoustic frequency gains
    private var barAmplitudes: [CGFloat] {
        guard isPlaying, effectiveVolume > 0.001, !magnitudes.isEmpty else {
            return Array(repeating: 0.0, count: 7)
        }
        
        let sensitivity = Float(AppSettings.shared.waveformSensitivity)
        var bars: [CGFloat] = []
        
        for i in 0..<7 {
            let rawMag = i < magnitudes.count ? magnitudes[i] : 0.0
            let scaled = rawMag * sensitivity
            
            if scaled < 0.015 {
                bars.append(0.0)
            } else {
                let power = pow(Double(min(1.0, scaled)), 0.78)
                bars.append(CGFloat(min(1.0, max(0.0, power))))
            }
        }
        
        return bars
    }
    
    var body: some View {
        let bars = barAmplitudes
        let blockCount = 7 // 7 vertical dots tall (center index 3, spread = 0 to 3)
        let centerIndex = 3
        let isActive = isPlaying && effectiveVolume > 0.001
        
        HStack(spacing: 5.0) {
            ForEach(0..<7, id: \.self) { barIndex in
                let amp = bars[barIndex]
                let hasSignal = isActive && amp > 0.012
                let spread = hasSignal ? min(3, Int(ceil(amp * 3.0))) : 0
                
                VStack(spacing: 2.0) {
                    ForEach(0..<blockCount, id: \.self) { blockIndex in
                        let distance = abs(centerIndex - blockIndex)
                        let isLit = hasSignal && (distance <= spread)
                        let isRestingCenter = !hasSignal && (blockIndex == centerIndex)
                        
                        let dotColor: Color = {
                            if isLit {
                                return distance == spread && distance > 1 ? theme.accentRed : theme.textPrimary
                            } else if isRestingCenter {
                                return effectiveVolume <= 0.001 ? theme.knobArcTrack : theme.textDisabled
                            } else {
                                return theme.knobArcTrack // Faint unlit physical LED dot
                            }
                        }()
                        
                        RoundedRectangle(cornerRadius: 0.6)
                            .fill(dotColor)
                            .frame(width: 5.0, height: 2.5)
                    }
                }
                .animation(.easeOut(duration: 0.08), value: amp)
            }
        }
        .frame(height: 30)
    }
}

// MARK: - Nothing 50x50 Real-Time RGB Color Dot-Matrix Processor
public struct DotMatrixCell: Sendable {
    public let r: Float
    public let g: Float
    public let b: Float
    public let luminance: Float
}

public final class DotMatrixImageProcessor {
    public static func generateColorDotMatrix(from image: NSImage, gridSize: Int = 50) -> [[DotMatrixCell]]? {
        guard (1...256).contains(gridSize), let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else { return nil }
        
        let width = gridSize
        let height = gridSize
        var rawData = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        context.interpolationQuality = .high
        
        // Aspect-fill: scale to fill gridSize x gridSize without distorting aspect ratio
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let scale = max(CGFloat(width) / max(1, imgW), CGFloat(height) / max(1, imgH))
        let drawW = imgW * scale
        let drawH = imgH * scale
        let drawX = (CGFloat(width) - drawW) * 0.5
        let drawY = (CGFloat(height) - drawH) * 0.5
        context.draw(cgImage, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
        
        var matrix = [[DotMatrixCell]](
            repeating: [DotMatrixCell](repeating: DotMatrixCell(r: 0, g: 0, b: 0, luminance: 0), count: width),
            count: height
        )
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let rRaw = Float(rawData[offset]) / 255.0
                let gRaw = Float(rawData[offset + 1]) / 255.0
                let bRaw = Float(rawData[offset + 2]) / 255.0
                
                // Lift artwork brightness slightly to compensate for gaps between dots.
                let gain: Float = 1.25
                let rComp = min(1.0, powf(rRaw, 0.94) * gain)
                let gComp = min(1.0, powf(gRaw, 0.94) * gain)
                let bComp = min(1.0, powf(bRaw, 0.94) * gain)
                let lum = 0.2126 * rComp + 0.7152 * gComp + 0.0722 * bComp
                
                matrix[y][x] = DotMatrixCell(r: rComp, g: gComp, b: bComp, luminance: lum)
            }
        }
        return matrix
    }
}

// MARK: - Album Art View with Authentic Nothing Hardware Dot-Matrix LED Screen
struct AlbumArtView: View {
    let image: NSImage?
    var size: CGFloat = 100
    @Environment(AudioEngineManager.self) private var engineManager
    @State private var theme = ThemeManager.shared
    /// Dot colours, built once per artwork rather than on every redraw.
    @State private var dotColors: [[Color]]? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showHighRes = false
    
    // Constant hardware OLED display panel substrate (deep black #0A0A0A)
    // Ensures consistent LED dot contrast and eliminates distortion in both Light Mode and Dark Mode
    private let panelSubstrate = Color(red: 0.04, green: 0.04, blue: 0.04)
    
    var body: some View {
        ZStack {
            // Hardware OLED display substrate
            panelSubstrate
            
            if let _ = image {
                if showHighRes, let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipped()
                } else if let colors = dotColors {
                    // The dots swell slightly with the music. The engine rounds the level, so
                    // changes of a small fraction of a pixel do not redraw all 2,500 dots.
                    let audioEnergy = engineManager.isPlaying ? Double(engineManager.masterMeter.artworkEnergy) : 0.0
                    let pulse = engineManager.isPlaying && !reduceMotion ? 1.0 + (audioEnergy * 0.05) : 1.0

                    // Real-Time 50x50 Full-Color RGB Dot-Matrix LED Screen
                    Canvas { context, sz in
                        let gridSize = 50
                        let cellWidth = sz.width / CGFloat(gridSize)
                        let cellHeight = sz.height / CGFloat(gridSize)

                        // Uniform, crisp circular LED dot radius across all luminance levels (fill ratio 0.90)
                        let baseDotRadius = (cellWidth * 0.5) * 0.90
                        let dotRadius = min(cellWidth * 0.48, baseDotRadius * CGFloat(pulse))
                        
                        for y in 0..<gridSize {
                            for x in 0..<gridSize {
                                let centerX = CGFloat(x) * cellWidth + (cellWidth * 0.5)
                                let centerY = CGFloat(y) * cellHeight + (cellHeight * 0.5)
                                
                                let dotRect = CGRect(
                                    x: centerX - dotRadius,
                                    y: centerY - dotRadius,
                                    width: dotRadius * 2,
                                    height: dotRadius * 2
                                )
                                context.fill(Path(ellipseIn: dotRect), with: .color(colors[y][x]))
                            }
                        }
                    }
                    .frame(width: size, height: size)
                } else if let img = image {
                    // Smooth transitional placeholder while dot matrix loads
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipped()
                }
            } else {
                // Standby diagnostic crosslines when no artwork exists
                ZStack {
                    theme.surface
                    Rectangle()
                        .stroke(theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 0))
                        path.addLine(to: CGPoint(x: size, y: size))
                        path.move(to: CGPoint(x: size, y: 0))
                        path.addLine(to: CGPoint(x: 0, y: size))
                    }
                    .stroke(theme.border, lineWidth: 1)
                    
                    Text("NO ARTWORK")
                        .font(.custom("DotGothic16-Regular", size: size < 85 ? 8.5 : 10))
                        .foregroundColor(theme.textSecondary)
                        .padding(3)
                        .background(theme.surface)
                }
            }
            
            // Outer Hardware Border (Theme-aware)
            Rectangle()
                .stroke(theme.cardBorder, lineWidth: 1)
            
            // Corner Accents (Nothing Hardware Style)
            CornerBrackets()
        }
        .frame(width: size, height: size)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleArtwork)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(image == nil ? "No artwork" : "Album artwork")
        .accessibilityValue(image == nil ? "" : (showHighRes ? "Full resolution" : "Dot matrix"))
        .accessibilityAddTraits(image == nil ? [] : .isButton)
        .accessibilityAction { toggleArtwork() }
        // Keyboard focus only with system keyboard navigation, so Space still plays.
        .focusable(image != nil, interactions: .activate)
        .onKeyPress(.space) {
            toggleArtwork()
            return .handled
        }
        .onChange(of: image) { _, newImage in
            updateMatrix(for: newImage)
        }
        .onAppear {
            updateMatrix(for: image)
        }
    }
    
    private func toggleArtwork() {
        guard image != nil else { return }
        Haptics.playClick()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            showHighRes.toggle()
        }
    }
    
    private func updateMatrix(for img: NSImage?) {
        guard let img = img,
              let matrix = DotMatrixImageProcessor.generateColorDotMatrix(from: img, gridSize: 50) else {
            dotColors = nil
            return
        }
        dotColors = matrix.map { row in
            row.map { cell in Color(red: Double(cell.r), green: Double(cell.g), blue: Double(cell.b)) }
        }
    }
}


struct CornerBrackets: View {
    @State private var theme = ThemeManager.shared
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let len: CGFloat = 8.0
            
            Path { p in
                // Top-Left
                p.move(to: CGPoint(x: 0, y: len))
                p.addLine(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: len, y: 0))
                
                // Top-Right
                p.move(to: CGPoint(x: w - len, y: 0))
                p.addLine(to: CGPoint(x: w, y: 0))
                p.addLine(to: CGPoint(x: w, y: len))
                
                // Bottom-Left
                p.move(to: CGPoint(x: 0, y: h - len))
                p.addLine(to: CGPoint(x: 0, y: h))
                p.addLine(to: CGPoint(x: len, y: h))
                
                // Bottom-Right
                p.move(to: CGPoint(x: w - len, y: h))
                p.addLine(to: CGPoint(x: w, y: h))
                p.addLine(to: CGPoint(x: w, y: h - len))
            }
            .stroke(theme.textSecondary, lineWidth: 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Dynamic Island Dot-Matrix Waveform View (Apple Symmetric Midline Waveform in Nothing Red)
struct DynamicIslandDotWaveformView: View {
    let magnitudes: [Float]
    let amplitudes: [Float]
    let isPlaying: Bool
    @State private var theme = ThemeManager.shared
    
    // 7 Pure Isolated Perceptual Frequency Bands (Sub-Bass -> Bass -> Low-Mid -> Vocals -> High-Mid -> Treble -> Air)
    private var barAmplitudes: [CGFloat] {
        guard isPlaying else { return Array(repeating: 0.0, count: 7) }
        
        let magCount = magnitudes.count
        
        // Define isolated frequency bin ranges across the 32 FFT bins with tuned gain multipliers
        let bandConfigs: [(bins: [Int], gain: Float)] = [
            ([0, 1], 8.5),             // Left Bar 0: Sub-Bass & Heavy Kick (20 - 120 Hz)
            ([2, 3], 12.5),            // Left Bar 1: Basslines & 808s (120 - 300 Hz)
            ([4, 5, 6], 17.0),         // Mid-Left Bar 2: Low-Mid / Snare / Guitar Body (300 - 700 Hz)
            ([7, 8, 9, 10, 11], 24.0), // Center Bar 3: Lead Vocals & Main Melodies (700 - 1.8 kHz)
            ([12, 13, 14, 15, 16, 17], 32.0), // Mid-Right Bar 4: High-Mid / Vocal Articulation (1.8 - 4.5 kHz)
            ([18, 19, 20, 21, 22, 23, 24], 48.0), // Right Bar 5: Treble & Hi-Hats / Shakers (4.5 - 9.5 kHz)
            ([25, 26, 27, 28, 29, 30, 31], 70.0)  // Far-Right Bar 6: Air & Cymbals Sparkle (9.5 - 20 kHz)
        ]
        
        var bars: [CGFloat] = []
        
        for config in bandConfigs {
            var sum: Float = 0.0
            var validBins = 0
            for bin in config.bins {
                if bin < magCount {
                    sum += magnitudes[bin]
                    validBins += 1
                }
            }
            let avgMag = validBins > 0 ? (sum / Float(validBins)) : 0.0
            let sensitivity = Float(AppSettings.shared.waveformSensitivity)
            let rawEnergy = avgMag * config.gain * sensitivity
            
            // If quiet/empty or stem is lowered/muted, drop strictly to 0.0
            if rawEnergy < 0.025 {
                bars.append(0.0)
            } else {
                // Logarithmic power curve for high contrast
                let power = pow(Double(min(1.0, rawEnergy)), 0.82)
                bars.append(CGFloat(min(1.0, max(0.0, power))))
            }
        }
        
        return bars
    }
    
    var body: some View {
        let bars = barAmplitudes
        let blockCount = 9 // 9 vertical pixel blocks: center is index 4 (d = 0 to 4)
        let centerIndex = 4
        
        HStack(spacing: 4.5) {
            ForEach(0..<7, id: \.self) { barIndex in
                let amp = bars[barIndex]
                let hasSignal = isPlaying && amp > 0.02
                let spread = hasSignal ? min(4, Int(ceil(amp * 4.0))) : 0
                
                VStack(spacing: 1.5) {
                    ForEach(0..<blockCount, id: \.self) { blockIndex in
                        let distance = abs(centerIndex - blockIndex)
                        let isLit = hasSignal && (distance <= spread)
                        
                        RoundedRectangle(cornerRadius: 0.6)
                            .fill(isLit ? theme.accentRed : theme.knobArcTrack)
                            .frame(width: 4.5, height: 2.5)
                    }
                }
                .animation(.easeOut(duration: 0.08), value: amp)
            }
        }
        .frame(height: 36)
    }
}


// MARK: - Discrete LED Dot-Matrix Progress Bar with A-B Looping
struct DotMatrixProgressBar: View {
    @Environment(\.isEnabled) private var isEnabled
    let progress: Double
    let isLooping: Bool
    let loopStart: Double
    let loopEnd: Double
    let onSeek: (Double) -> Void
    let onSeekingChanged: (Bool) -> Void
    @State private var theme = ThemeManager.shared
    
    var body: some View {
        GeometryReader { geo in
            let blockWidth: CGFloat = 5.0
            let blockSpacing: CGFloat = 3.0
            let totalUnitWidth = blockWidth + blockSpacing
            let blockCount = max(1, Int(geo.size.width / totalUnitWidth))
            let activeCount = Int(round(Double(blockCount) * max(0, min(1, progress))))
            
            let loopStartIndex = isLooping ? Int(round(Double(blockCount) * loopStart)) : 0
            let loopEndIndex = isLooping ? Int(round(Double(blockCount) * loopEnd)) : blockCount
            
            ZStack(alignment: .leading) {
                HStack(spacing: blockSpacing) {
                    ForEach(0..<blockCount, id: \.self) { i in
                        let inLoop = isLooping && i >= loopStartIndex && i <= loopEndIndex
                        let isPassed = i < activeCount
                        
                        let fill: Color = isPassed
                            ? (inLoop ? theme.accentRed : theme.textPrimary)
                            : (inLoop ? theme.accentRed.opacity(0.35) : theme.knobArcTrack)
                        
                        Rectangle()
                            .fill(fill)
                            .frame(width: blockWidth, height: inLoop ? 8 : 6)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                
                // Visual A-B Loop Indicator Badges
                if isLooping {
                    HStack {
                        Text("[A]")
                            .font(.custom("DotGothic16-Regular", size: 9))
                            .foregroundColor(theme.warning)
                            .offset(x: max(0, geo.size.width * loopStart - 6), y: -14)
                        Spacer()
                    }
                    HStack {
                        Text("[B]")
                            .font(.custom("DotGothic16-Regular", size: 9))
                            .foregroundColor(theme.warning)
                            .offset(x: min(geo.size.width - 18, geo.size.width * loopEnd - 6), y: -14)
                        Spacer()
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onSeekingChanged(true)
                        let percent = max(0, min(1, value.location.x / max(1, geo.size.width)))
                        onSeek(percent)
                    }
                    .onEnded { value in
                        let percent = max(0, min(1, value.location.x / max(1, geo.size.width)))
                        onSeek(percent)
                        onSeekingChanged(false)
                    }
            )
        }
        .frame(height: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(progress * 100)) percent")
        .accessibilityAdjustableAction { seekBy($0 == .increment ? 0.01 : -0.01) }
        .focusable(isEnabled)
        .onKeyPress(.leftArrow) { seekBy(-0.01); return .handled }
        .onKeyPress(.rightArrow) { seekBy(0.01); return .handled }
    }
    private func seekBy(_ amount: Double) {
        onSeekingChanged(true)
        onSeek(max(0, min(1, progress + amount)))
        onSeekingChanged(false)
    }
}

/// Transport commands shared by the transport controls and keyboard shortcuts.
/// Seeking and A-B loop edits need a loaded track; without one they would leave
/// a playback position or loop region on screen for audio that does not exist.
@MainActor
enum TransportActions {
    static func scrub(_ engine: AudioEngineManager, to percent: Double) {
        guard engine.hasLoadedTrack else { return }
        engine.playbackProgress = percent
        engine.updateTimeString(for: percent)
    }
    
    static func toggleLoop(_ engine: AudioEngineManager) {
        guard engine.hasLoadedTrack else { return }
        engine.toggleLoop()
    }
    
    static func setLoopStart(_ engine: AudioEngineManager) {
        guard engine.hasLoadedTrack else { return }
        engine.setLoopStart(engine.playbackProgress)
    }
    
    static func setLoopEnd(_ engine: AudioEngineManager) {
        guard engine.hasLoadedTrack else { return }
        engine.setLoopEnd(engine.playbackProgress)
    }
    
    static func hasLoopMarkers(_ engine: AudioEngineManager) -> Bool {
        engine.isLooping || engine.loopStartProgress > 0 || engine.loopEndProgress < 1
    }
    
    static func clearLoop(_ engine: AudioEngineManager) {
        guard engine.hasLoadedTrack, hasLoopMarkers(engine) else { return }
        engine.resetLoop()
    }
}

struct TransportBar: View {
    @Environment(AudioEngineManager.self) private var engineManager
    @State private var theme = ThemeManager.shared
    @State private var wasPlayingBeforeDrag = false
    @State private var isBypassHovered = false
    @State private var isExportHovered = false
    @State private var isLoopHovered = false
    @State private var isPitchHovered = false
    @State private var isSpeedHovered = false
    
    /// Control sizes for each transport density. The roomiest density that still
    /// leaves the seek bar `minimumSeekWidth` is used, so the fixed controls
    /// shrink before the seek bar collapses.
    struct Metrics: Equatable {
        let isCompact: Bool
        let isTight: Bool
        let timeFontSize: CGFloat
        let spacing: CGFloat
        let loopWidth: CGFloat
        let pitchReadoutWidth: CGFloat
        let speedReadoutWidth: CGFloat
        let bypassWidth: CGFloat
        let exportWidth: CGFloat
        
        static let stepperWidth: CGFloat = 20
        static let playDiameter: CGFloat = 38
        static let minimumSeekWidth: CGFloat = 120
        
        static let regular = Metrics(isCompact: false, isTight: false, timeFontSize: 15, spacing: 12, loopWidth: 80,
                                     pitchReadoutWidth: 78, speedReadoutWidth: 44, bypassWidth: 110, exportWidth: 140)
        static let compact = Metrics(isCompact: true, isTight: false, timeFontSize: 13, spacing: 8, loopWidth: 64,
                                     pitchReadoutWidth: 54, speedReadoutWidth: 38, bypassWidth: 90, exportWidth: 110)
        static let tight = Metrics(isCompact: true, isTight: true, timeFontSize: 13, spacing: 6, loopWidth: 52,
                                   pitchReadoutWidth: 44, speedReadoutWidth: 36, bypassWidth: 70, exportWidth: 76)
        
        /// Width of everything in the row except the seek bar.
        func fixedWidth(timeLabel: String) -> CGFloat {
            // Each tempo control: two steppers, two 2pt gaps and 3pt padding per side.
            let stepperChrome = Self.stepperWidth * 2 + 4 + 6
            return MarqueeText.measureTextWidth(timeLabel, size: timeFontSize)
                + loopWidth
                + pitchReadoutWidth + stepperChrome
                + speedReadoutWidth + stepperChrome
                + Self.playDiameter + bypassWidth + exportWidth
                + spacing * 7
        }
        
        static func forWidth(_ width: CGFloat, timeLabel: String) -> Metrics {
            [regular, compact].first { width - $0.fixedWidth(timeLabel: timeLabel) >= minimumSeekWidth } ?? tight
        }
    }
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let timeString = engineManager.currentTimeString
            let metrics = Metrics.forWidth(w, timeLabel: timeString)
            // Only below the window's minimum width: keep the seek bar usable.
            let hidesTempoControls = w - metrics.fixedWidth(timeLabel: timeString) < 40
            
            HStack(spacing: metrics.spacing) {
                timeLabel(metrics)
                
                progressBar
                    .frame(minWidth: 50)
                
                // A-B Loop Quick Toggle
                loopButton(metrics)
                
                if !hidesTempoControls {
                    pitchControl(metrics)
                    speedControl(metrics)
                }
                
                playButton
                bypassButton(metrics)
                exportButton(metrics)
            }
            .frame(width: w, height: 48)
        }
        .frame(height: 48)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.surface)
        .border(theme.hairline, width: 1)
    }
    
    private func timeLabel(_ metrics: Metrics) -> some View {
        Text(engineManager.currentTimeString)
            .font(.custom("DotGothic16-Regular", size: metrics.timeFontSize))
            .foregroundColor(theme.textPrimary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
    
    private var progressBar: some View {
        DotMatrixProgressBar(
            progress: engineManager.playbackProgress,
            isLooping: engineManager.isLooping,
            loopStart: engineManager.loopStartProgress,
            loopEnd: engineManager.loopEndProgress,
            onSeek: { percent in
                TransportActions.scrub(engineManager, to: percent)
            },
            onSeekingChanged: { isSeeking in
                guard engineManager.hasLoadedTrack else { return }
                if isSeeking {
                    if !wasPlayingBeforeDrag && engineManager.isPlaying {
                        wasPlayingBeforeDrag = true
                        engineManager.togglePlayback()
                    }
                } else {
                    engineManager.seek(toPercentage: engineManager.playbackProgress)
                    // Releasing at the very end stops, unless looping wraps it to A.
                    if wasPlayingBeforeDrag && (engineManager.playbackProgress < 1 || engineManager.isLooping) {
                        engineManager.togglePlayback()
                    }
                    wasPlayingBeforeDrag = false
                }
            }
        )
        .disabled(!engineManager.hasLoadedTrack)
    }
    
    private func loopButton(_ metrics: Metrics) -> some View {
        let isLooping = engineManager.isLooping
        return Button(action: {
            TransportActions.toggleLoop(engineManager)
        }) {
            Text(isLooping ? (metrics.isCompact ? "LOOP" : "LOOP: ON") : (metrics.isCompact ? "LOOP" : "LOOP: OFF"))
                .font(.custom("DotGothic16-Regular", size: metrics.isCompact ? 10.5 : 11.5))
                .fontWeight(.bold)
                .frame(width: metrics.loopWidth, height: 32)
                .background(isLooping ? theme.accentRed : (isLoopHovered ? theme.surfaceHover : Color.clear),
                            in: RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isLooping ? theme.accentRed : (isLoopHovered ? theme.textPrimary : theme.border), lineWidth: 1)
                )
                .foregroundColor(isLooping ? theme.onAccent : (isLoopHovered ? theme.textPrimary : theme.textSecondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!engineManager.hasLoadedTrack)
        .onHover { isLoopHovered = $0 }
        .accessibilityLabel("Loop")
        .accessibilityValue(isLooping ? "On" : "Off")
        .accessibilityAction(named: "Clear loop markers") { TransportActions.clearLoop(engineManager) }
        .help("Toggle A-B loop (L). Set points with [ and ]; clear them with ⌥L or right-click.")
        .contextMenu {
            Button("Clear Loop Markers") { TransportActions.clearLoop(engineManager) }
                .disabled(!engineManager.hasLoadedTrack || !TransportActions.hasLoopMarkers(engineManager))
        }
    }
    
    private func pitchControl(_ metrics: Metrics) -> some View {
        HStack(spacing: 2) {
            Button(action: {
                Haptics.playClick()
                engineManager.pitchShiftSemitones = max(-12.0, engineManager.pitchShiftSemitones - 1.0)
            }) {
                Text("-")
                    .font(.custom("DotGothic16-Regular", size: 12))
                    .foregroundColor(theme.textSecondary)
                    .frame(width: Metrics.stepperWidth, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Decrease pitch")
            .disabled(engineManager.pitchShiftSemitones <= -12)
            
            let st = Int(engineManager.pitchShiftSemitones)
            let absSt = abs(st)
            let intervals = [
                0: "ROOT", 1: "m2", 2: "M2", 3: "m3", 4: "M3", 5: "4th", 6: "TRI",
                7: "5th", 8: "m6", 9: "M6", 10: "m7", 11: "M7", 12: "OCT"
            ]
            let intervalName = intervals[absSt] ?? "\(absSt)ST"
            let sign = st > 0 ? "+" : ""
            let displayText = metrics.isCompact ? (st == 0 ? "0 ST" : "\(sign)\(st) ST") : (st == 0 ? "0 ST [ROOT]" : "\(sign)\(st) ST [\(intervalName)]")
            
            Text(displayText)
                .font(.custom("DotGothic16-Regular", size: metrics.isCompact ? 9.5 : 10))
                .fontWeight(.bold)
                .foregroundColor(st == 0 ? theme.textMuted : theme.accentRed)
                .lineLimit(1)
                .frame(width: metrics.pitchReadoutWidth)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    Haptics.playClick()
                    engineManager.pitchShiftSemitones = 0.0
                }
            
            Button(action: {
                Haptics.playClick()
                engineManager.pitchShiftSemitones = min(12.0, engineManager.pitchShiftSemitones + 1.0)
            }) {
                Text("+")
                    .font(.custom("DotGothic16-Regular", size: 12))
                    .foregroundColor(theme.textSecondary)
                    .frame(width: Metrics.stepperWidth, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Increase pitch")
            .disabled(engineManager.pitchShiftSemitones >= 12)
        }
        .padding(.horizontal, 3)
        .frame(height: 32)
        .background(isPitchHovered ? theme.surfaceHover : theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(engineManager.pitchShiftSemitones != 0 ? theme.accentRed.opacity(0.6) : theme.hairline, lineWidth: 1)
        )
        .onHover { isPitchHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pitch")
        .accessibilityValue("\(Int(engineManager.pitchShiftSemitones)) semitones")
    }
    
    private func speedControl(_ metrics: Metrics) -> some View {
        HStack(spacing: 2) {
            Button(action: {
                Haptics.playClick()
                let rates: [Double] = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5]
                if let idx = rates.lastIndex(where: { $0 < engineManager.playbackRate }) {
                    engineManager.playbackRate = rates[idx]
                } else {
                    engineManager.playbackRate = 0.5
                }
            }) {
                Text("‹")
                    .font(.custom("DotGothic16-Regular", size: 12))
                    .foregroundColor(theme.textSecondary)
                    .frame(width: Metrics.stepperWidth, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Decrease playback speed")
            .disabled(engineManager.playbackRate <= 0.5)
            
            Text(String(format: "%.2fx", engineManager.playbackRate))
                .font(.custom("DotGothic16-Regular", size: metrics.isCompact ? 10 : 11))
                .fontWeight(.bold)
                .foregroundColor(engineManager.playbackRate == 1.0 ? theme.textMuted : theme.accentRed)
                .lineLimit(1)
                .frame(width: metrics.speedReadoutWidth)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    Haptics.playClick()
                    engineManager.playbackRate = 1.0
                }
            
            Button(action: {
                Haptics.playClick()
                let rates: [Double] = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5]
                if let idx = rates.firstIndex(where: { $0 > engineManager.playbackRate }) {
                    engineManager.playbackRate = rates[idx]
                } else {
                    engineManager.playbackRate = 1.5
                }
            }) {
                Text("›")
                    .font(.custom("DotGothic16-Regular", size: 12))
                    .foregroundColor(theme.textSecondary)
                    .frame(width: Metrics.stepperWidth, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Increase playback speed")
            .disabled(engineManager.playbackRate >= 1.5)
        }
        .padding(.horizontal, 3)
        .frame(height: 32)
        .background(isSpeedHovered ? theme.surfaceHover : theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(engineManager.playbackRate != 1.0 ? theme.accentRed.opacity(0.6) : theme.hairline, lineWidth: 1)
        )
        .onHover { isSpeedHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback speed")
        .accessibilityValue(String(format: "%.2f times", engineManager.playbackRate))
    }
    
    private var playButton: some View {
        Button(action: {
            Haptics.playClick()
            engineManager.togglePlayback()
        }) {
            Image(systemName: engineManager.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 18))
                .foregroundColor(theme.onAccent)
                .frame(width: Metrics.playDiameter, height: Metrics.playDiameter)
                .background(theme.accentRed)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel(engineManager.isPlaying ? "Pause" : "Play")
        .disabled(!engineManager.hasLoadedTrack || engineManager.isSplitting)
    }
    
    private func bypassButton(_ metrics: Metrics) -> some View {
        let isBypassed = engineManager.isBypassed
        return Button(action: {
            Haptics.playClick()
            engineManager.isBypassed.toggle()
        }) {
            Text(isBypassed ? (metrics.isCompact ? "BYPASS" : "BYPASS: ON") : (metrics.isCompact ? "BYPASS" : "BYPASS: OFF"))
                .font(.custom("DotGothic16-Regular", size: metrics.isCompact ? 11.5 : 13))
                .fontWeight(.bold)
                .lineLimit(1)
                .frame(width: metrics.bypassWidth, height: 34)
                // Comparing against the original is a caution state, like the header's SOURCE label.
                .background(isBypassed ? theme.warning : (isBypassHovered ? theme.surfaceHover : Color.clear),
                            in: RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isBypassed ? theme.warning : (isBypassHovered ? theme.textPrimary : theme.border), lineWidth: 1)
                )
                .foregroundColor(isBypassed ? theme.onAccent : theme.textPrimary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!engineManager.canBypass)
        .onHover { hovering in
            isBypassHovered = hovering
        }
        .accessibilityLabel("Compare original")
        .accessibilityInputLabels(["Bypass", "Compare original"])
        .accessibilityValue(isBypassed ? "On, playing original" : "Off, playing stem mix")
        .help(isBypassed ? "Return to the stem mix (⌥⌘B)" : "Compare with the original (⌥⌘B)")
    }
    
    private func exportButton(_ metrics: Metrics) -> some View {
        let state = engineManager.exportState
        let isExporting = engineManager.isExporting
        return Button(action: {
            Haptics.playClick()
            // While exporting, the same control cancels the render.
            if engineManager.isExporting {
                engineManager.cancelExport()
            } else {
                engineManager.exportStems()
            }
        }) {
            ZStack {
                switch state {
                case .idle:
                    Text(metrics.isCompact ? "EXPORT" : "EXPORT STEMS")
                        .fontWeight(.bold)
                        .foregroundColor(theme.textPrimary)
                case .exporting(let stage, let percent):
                    Text(isExportHovered ? "CANCEL" : (metrics.isTight ? "\(Int(percent * 100))%" : "\(stage) \(Int(percent * 100))%"))
                        .fontWeight(.bold)
                        .foregroundColor(theme.textPrimary)
                case .completed:
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                        Text(metrics.isCompact ? "DONE" : "COMPLETED")
                    }
                    .fontWeight(.bold)
                    .foregroundColor(theme.background)
                }
            }
            .font(.custom("DotGothic16-Regular", size: metrics.isCompact ? 11.5 : 13))
            .lineLimit(1)
            .frame(width: metrics.exportWidth, height: 34)
            .background(
                state == .completed
                    ? theme.textPrimary
                    : (isExporting
                        ? theme.accentRed.opacity(0.18)
                        : (isExportHovered ? theme.surfaceHover : Color.clear)),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        state == .completed
                            ? theme.textPrimary
                            : (isExporting ? theme.accentRed : (isExportHovered ? theme.textPrimary : theme.border)),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .disabled(!engineManager.hasLoadedTrack || engineManager.isSplitting)
        .accessibilityLabel(isExporting ? "Cancel export" : "Export stems")
        .help(isExporting ? "Cancel the export in progress" : "Export four stems as a ZIP (⇧⌘E)")
        .contextMenu {
            Button("Export Mix…") { engineManager.exportMix() }
                .disabled(isExporting)
            if isExporting {
                Button("Cancel Export") { engineManager.cancelExport() }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isExportHovered = hovering
        }
    }
}

struct MarqueeText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    var fontSize: CGFloat = 24
    var color: Color = .primary
    var height: CGFloat = 30
    
    @State private var offset: CGFloat = 0
    @State private var animationTask: Task<Void, Never>? = nil
    
    var body: some View {
        GeometryReader { geo in
            let containerWidth = geo.size.width
            let textWidth = Self.measureTextWidth(text, size: fontSize)
            let overflow = textWidth - containerWidth
            let scrolls = Self.scrolls(overflow: overflow, containerWidth: containerWidth, reduceMotion: reduceMotion)
            
            ZStack(alignment: .leading) {
                if scrolls {
                    Text(text)
                        .font(.custom("DotGothic16-Regular", size: fontSize))
                        .foregroundColor(color)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: offset)
                } else {
                    // Without scrolling (Reduce Motion or a tiny overflow), end with an
                    // ellipsis rather than clipping mid-glyph; the tooltip has the rest.
                    Text(text)
                        .font(.custom("DotGothic16-Regular", size: fontSize))
                        .foregroundColor(color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: containerWidth, alignment: .leading)
            .clipped()
            .help(overflow > 0 ? text : "")
            .mask(
                Group {
                    if scrolls {
                        HStack(spacing: 0) {
                            LinearGradient(
                                colors: [.clear, .black],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 4)
                            
                            Rectangle().fill(Color.black)
                            
                            LinearGradient(
                                colors: [.black, .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 8)
                        }
                    } else {
                        Rectangle().fill(Color.black)
                    }
                }
            )
            .onAppear {
                startAnimation(containerWidth: containerWidth, textWidth: textWidth)
            }
            .onChange(of: text) { _, _ in
                startAnimation(containerWidth: containerWidth, textWidth: textWidth)
            }
            .onChange(of: reduceMotion) { _, _ in
                startAnimation(containerWidth: containerWidth, textWidth: textWidth)
            }
            .onChange(of: containerWidth) { _, newWidth in
                startAnimation(containerWidth: newWidth, textWidth: textWidth)
            }
            .onDisappear {
                animationTask?.cancel()
                animationTask = nil
            }
        }
        .frame(height: height)
    }
    
    static func scrolls(overflow: CGFloat, containerWidth: CGFloat, reduceMotion: Bool) -> Bool {
        !reduceMotion && overflow > 6 && containerWidth > 40
    }
    
    static func measureTextWidth(_ string: String, size: CGFloat) -> CGFloat {
        let font = NSFont(name: "DotGothic16-Regular", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let attr: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((string as NSString).size(withAttributes: attr).width)
    }
    
    private func startAnimation(containerWidth: CGFloat, textWidth: CGFloat) {
        animationTask?.cancel()
        animationTask = nil
        
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = 0
        }
        
        let overflow = textWidth - containerWidth
        guard Self.scrolls(overflow: overflow, containerWidth: containerWidth, reduceMotion: reduceMotion) else {
            return
        }
        
        animationTask = Task { @MainActor in
            let speed: CGFloat = 30.0 // readable 30 points per second
            let duration = max(1.5, Double(overflow / speed))
            
            while !Task.isCancelled {
                // Settle at start so user can read initial text
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                guard !Task.isCancelled else { break }
                
                // Smooth GPU easeInOut glide to end
                withAnimation(.easeInOut(duration: duration)) {
                    offset = -overflow
                }
                try? await Task.sleep(nanoseconds: UInt64((duration + 0.1) * 1_000_000_000))
                guard !Task.isCancelled else { break }
                
                // Settle at end
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                
                // Smooth GPU easeInOut glide back to start
                withAnimation(.easeInOut(duration: duration)) {
                    offset = 0
                }
                try? await Task.sleep(nanoseconds: UInt64((duration + 0.1) * 1_000_000_000))
                guard !Task.isCancelled else { break }
            }
        }
    }
}

/// Header geometry, shared with the layout tests so the STUDIO HUD always gets
/// the width its labels are measured against.
struct PlayerHeaderMetrics {
    static let hudVisibleWidth: CGFloat = 860
    static let hudGap: CGFloat = 26
    
    let width: CGFloat
    var isCompactHeight = false
    var hasSidebarToggle = true
    var isSidebarClosed = false
    
    static func showsHUD(width: CGFloat) -> Bool {
        width >= hudVisibleWidth
    }
    
    var showsHUD: Bool { Self.showsHUD(width: width) }
    var isWide: Bool { width >= 1260 }
    var artSize: CGFloat { isCompactHeight ? 76 : 100 }
    var spacing: CGFloat { isCompactHeight ? 10 : 14 }
    var horizontalPadding: CGFloat { isCompactHeight ? 16 : 24 }
    
    /// Everything in the header row except the track info and the HUD.
    private var chrome: CGFloat {
        horizontalPadding * 2 + (hasSidebarToggle ? 28 + spacing : 0) + artSize + spacing * 2 + Self.hudGap
    }
    
    var trackInfoWidth: CGFloat {
        let hudReserve: CGFloat = isWide ? 520 : 460
        let preferred: CGFloat = isWide ? (isSidebarClosed ? 680 : 480) : (isSidebarClosed ? 500 : 360)
        return max(240, min(width - chrome - hudReserve, preferred))
    }
    
    var hudWidth: CGFloat {
        showsHUD ? max(0, width - chrome - trackInfoWidth) : 0
    }
}

/// Equal-width columns whose ideal width is the widest column's ideal times the
/// column count, so `ViewThatFits` rejects a row in which any column would truncate.
struct EqualWidthHStack: Layout {
    var spacing: CGFloat = 6
    
    private func columnWidth(for width: CGFloat, count: Int) -> CGFloat {
        max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
    }
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let widestIdeal = (subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0).rounded(.up) + 1
        let idealWidth = widestIdeal * CGFloat(subviews.count) + spacing * CGFloat(subviews.count - 1)
        let width = proposal.width.map { $0.isFinite ? $0 : idealWidth } ?? idealWidth
        let column = ProposedViewSize(width: columnWidth(for: width, count: subviews.count), height: proposal.height)
        let height = subviews.map { $0.sizeThatFits(column).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = columnWidth(for: bounds.width, count: subviews.count)
        var x = bounds.minX
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

extension View {
    /// Grows a small control's click target vertically without moving the layout.
    func expandedHitArea(vertical amount: CGFloat) -> some View {
        padding(.vertical, amount)
            .contentShape(Rectangle())
            .padding(.vertical, -amount)
    }
}

// MARK: - Header Center Telemetry & Visualizer Console Module
struct HeaderCenterTelemetryModule: View {
    @Environment(AudioEngineManager.self) private var engineManager
    @State private var theme = ThemeManager.shared
    var isCompactHeight: Bool = false
    
    var body: some View {
        ZStack {
            theme.surface
            
            // Outer hardware frame
            Rectangle()
                .stroke(theme.border, lineWidth: 1)
            
            // Corner brackets (Nothing aesthetic)
            CornerBrackets()
            
            VStack(spacing: 0) {
                // Top Telemetry / Mode Switcher Header Bar. Track metadata goes first,
                // then the tabs switch to short names, so no label ever truncates.
                ViewThatFits(in: .horizontal) {
                    HUDTopBar(isCompactHeight: isCompactHeight)
                    HUDTopBar(showsMetadata: false, isCompactHeight: isCompactHeight)
                    HUDTopBar(showsMetadata: false, usesShortLabels: true, isCompactHeight: isCompactHeight)
                    HUDTopBar(showsMetadata: false, usesShortLabels: true, showsTitle: false, isCompactHeight: isCompactHeight)
                }
                .padding(.horizontal, 10)
                .frame(height: isCompactHeight ? 24 : 28)
                
                Divider()
                    .background(theme.hairline)
                
                // Display Body
                ZStack {
                    switch engineManager.activeHUDModeIndex {
                    case 0:
                        Spectrum32BandView()
                            .padding(.horizontal, 10)
                            .padding(.vertical, isCompactHeight ? 3 : 6)
                    case 1:
                        StemMacroPresetsView()
                            .padding(.horizontal, 10)
                            .padding(.vertical, isCompactHeight ? 3 : 6)
                    case 2:
                        StemBalanceHUDView()
                            .padding(.horizontal, 8)
                            .padding(.vertical, isCompactHeight ? 3 : 5)
                    case 3:
                        StudioTelemetryHUDView()
                            .padding(.horizontal, 10)
                            .padding(.vertical, isCompactHeight ? 3 : 5)
                    case 4:
                        HUDEqualizerCurveView()
                            .padding(.horizontal, 8)
                            .padding(.vertical, isCompactHeight ? 2 : 4)
                    default:
                        Spectrum32BandView()
                            .padding(.horizontal, 10)
                            .padding(.vertical, isCompactHeight ? 3 : 6)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: isCompactHeight ? 76 : 100)
    }
}

/// The STUDIO HUD title bar in one of its widths; see `HeaderCenterTelemetryModule`.
struct HUDTopBar: View {
    @Environment(AudioEngineManager.self) private var engineManager
    @State private var theme = ThemeManager.shared
    var showsMetadata = true
    var usesShortLabels = false
    var showsTitle = true
    var isCompactHeight = false
    
    static let modes = ["32-BAND FFT", "STEM MACROS", "STEM BALANCE", "TELEMETRY", "EQUALIZER"]
    static let shortModes = ["FFT", "MACRO", "BAL", "TELE", "EQ"]
    
    var body: some View {
        HStack(spacing: 8) {
            if showsTitle {
                HStack(spacing: 4) {
                    Text("[")
                        .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 9 : 10))
                        .foregroundColor(theme.textDisabled)
                    Text("STUDIO HUD")
                        .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 9 : 10))
                        .foregroundColor(theme.textSecondary)
                    Text("]")
                        .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 9 : 10))
                        .foregroundColor(theme.textDisabled)
                }
                .fixedSize()
            }
            
            if showsMetadata {
                HStack(spacing: 8) {
                    // Unknown tags stay visibly placeholder; they are never estimated.
                    Text("• \(engineManager.effectiveBPM)")
                        .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 8.5 : 10))
                        .foregroundColor(engineManager.effectiveBPM.contains("UNKNOWN") ? theme.textMuted : theme.textPrimary)
                    Text("• \(engineManager.effectiveMusicalKey)")
                        .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 8.5 : 10))
                        .foregroundColor(engineManager.effectiveMusicalKey.contains("UNKNOWN") ? theme.textMuted : theme.textPrimary)
                    Text("• \(engineManager.trackSampleRate)")
                        .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 8.0 : 9.5))
                        .foregroundColor(theme.textMuted)
                }
                .fixedSize()
            }
            
            Spacer(minLength: 8)
            
            // Mode Switcher Tabs
            HStack(spacing: isCompactHeight ? 2 : 3) {
                ForEach(0..<Self.modes.count, id: \.self) { idx in
                    let isActive = engineManager.activeHUDModeIndex == idx
                    Button(action: {
                        Haptics.playClick()
                        engineManager.setHUDMode(idx)
                    }) {
                        Text(usesShortLabels ? Self.shortModes[idx] : Self.modes[idx])
                            .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 7.5 : 8.5))
                            .fontWeight(isActive ? .bold : .regular)
                            .fixedSize()
                            .padding(.horizontal, isCompactHeight ? 4 : 6)
                            .padding(.vertical, isCompactHeight ? 2 : 3)
                            .background(isActive ? theme.textPrimary : theme.surfaceSecondary)
                            .foregroundColor(isActive ? theme.background : theme.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(isActive ? theme.textPrimary : theme.hairline, lineWidth: 1)
                            )
                            .expandedHitArea(vertical: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.modes[idx])
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                    .help("\(Self.modes[idx]) (⌘\(idx + 1))")
                }
            }
            
            // Neural Engine Activity LED
            HStack(spacing: 4) {
                Circle()
                    .fill(engineManager.isPlaying ? theme.accentRed : theme.textDisabled)
                    .frame(width: 5, height: 5)
                    .shadow(color: engineManager.isPlaying ? theme.accentRed.opacity(0.8) : Color.clear, radius: 3)
                Text("DSP")
                    .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 8 : 9))
                    .foregroundColor(engineManager.isPlaying ? theme.textPrimary : theme.textMuted)
            }
            .fixedSize()
        }
    }
}

// MARK: - 32-Band Dot-Matrix FFT Spectrum Visualizer
/// 32 bars of 14 blocks drawn in one Canvas rather than 448 shape views. Block edges are
/// rounded to device pixels in window coordinates, the way SwiftUI placed the former
/// per-block views, so the output matches them.
struct Spectrum32BandView: View {
    @Environment(AudioEngineManager.self) private var engineManager
    @Environment(\.displayScale) private var displayScale
    @State private var theme = ThemeManager.shared

    private static let barCount = 32
    private static let blockCount = 14
    private static let barSpacing: CGFloat = 2.0
    private static let blockSpacing: CGFloat = 1.5

    /// Items plus the gaps between them, added in the order a stack adds them. Summing
    /// differently can flip an edge that lands exactly on a half pixel.
    private static func stackLength(count: Int, item: CGFloat, spacing: CGFloat) -> CGFloat {
        var length: CGFloat = 0
        for index in 0..<count {
            length += item
            if index < count - 1 { length += spacing }
        }
        return length
    }

    var body: some View {
        // Read observable state here rather than in the renderer so each reading redraws.
        let magnitudes = engineManager.masterMeter.spectrum
        let barColor = theme.spectrumBarDefault
        let peakColor = theme.accentRed
        let unlitOpacity = theme.isDark ? 0.05 : 0.08
        let scale = max(1, displayScale)

        GeometryReader { geo in
            let size = geo.size
            let origin = geo.frame(in: .global).origin
            Canvas { context, _ in
                let barCount = Self.barCount
                let blockCount = Self.blockCount
                let barWidth = max(2.0, (size.width - Self.barSpacing * CGFloat(barCount - 1)) / CGFloat(barCount))
                let blockHeight = max(1.5, (size.height - Self.blockSpacing * CGFloat(blockCount - 1)) / CGFloat(blockCount))
                // Bars are centered and blocks bottom-aligned, as in the former HStack and VStacks.
                let rowWidth = Self.stackLength(count: barCount, item: barWidth, spacing: Self.barSpacing)
                let columnHeight = Self.stackLength(count: blockCount, item: blockHeight, spacing: Self.blockSpacing)
                // Positions accumulate in window space as the stacks laid them out, then round
                // to device pixels; the canvas itself sits at its rounded origin.
                func snapped(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
                let canvasX = snapped(origin.x), canvasY = snapped(origin.y)
                let block = RoundedRectangle(cornerRadius: 0.5)

                var x = origin.x + (size.width - rowWidth) / 2
                for index in 0..<barCount {
                    let magnitude = index < magnitudes.count ? CGFloat(magnitudes[index]) : 0.0
                    let activeBlocksFloat = max(0.0, min(CGFloat(blockCount), magnitude * CGFloat(blockCount)))
                    let minX = snapped(x) - canvasX
                    let maxX = snapped(x + barWidth) - canvasX

                    // Top block first, as the VStack listed them.
                    var y = origin.y + (size.height - columnHeight)
                    for blockIdx in (0..<blockCount).reversed() {
                        let blockBottomLevel = CGFloat(blockIdx)
                        let fillFraction: CGFloat = {
                            if activeBlocksFloat >= blockBottomLevel + 1 {
                                return 1.0
                            } else if activeBlocksFloat <= blockBottomLevel {
                                return 0.0
                            } else {
                                return activeBlocksFloat - blockBottomLevel
                            }
                        }()

                        let isTopTwoBlocks = blockIdx >= (blockCount - 2)
                        let isUpperMidBlock = blockIdx >= (blockCount - 5)
                        let activeColor: Color = {
                            if isTopTwoBlocks {
                                // Peak blocks light red only while signal reaches them.
                                return fillFraction > 0 ? peakColor : barColor
                            } else if isUpperMidBlock {
                                return barColor
                            } else {
                                return barColor.opacity(0.88)
                            }
                        }()

                        let minY = snapped(y) - canvasY
                        let maxY = snapped(y + blockHeight) - canvasY
                        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                        context.fill(
                            block.path(in: rect),
                            with: .color(activeColor.opacity(fillFraction > 0 ? max(0.2, fillFraction) : unlitOpacity))
                        )
                        y = y + blockHeight + Self.blockSpacing
                    }
                    x = x + barWidth + Self.barSpacing
                }
            }
        }
    }
}

// MARK: - Stem Macro Quick Presets
struct StemMacroPresetsView: View {
    @Environment(AudioEngineManager.self) private var engineManager
    @State private var theme = ThemeManager.shared

    private var anySolo: Bool {
        engineManager.vocalSolo || engineManager.drumSolo || engineManager.bassSolo || engineManager.otherSolo
    }
    
    private var isAcapellaActive: Bool {
        engineManager.vocalSolo && !engineManager.vocalMuted && !engineManager.drumSolo && !engineManager.bassSolo && !engineManager.otherSolo
    }
    
    private var isInstrumentalActive: Bool {
        engineManager.vocalMuted && !engineManager.drumMuted && !engineManager.bassMuted && !engineManager.otherMuted && !anySolo
    }
    
    private var isDrumlessActive: Bool {
        engineManager.drumMuted && !engineManager.vocalMuted && !engineManager.bassMuted && !engineManager.otherMuted && !anySolo
    }
    
    private var isKaraokeActive: Bool {
        abs(engineManager.vocalVolume - 0.25) < 0.05 && !engineManager.vocalMuted && !engineManager.drumMuted && !engineManager.bassMuted && !engineManager.otherMuted && !anySolo
    }
    
    private var isDnBActive: Bool {
        engineManager.vocalMuted && engineManager.otherMuted && !engineManager.drumMuted && !engineManager.bassMuted && !anySolo
    }
    
    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                macroButton(title: "ACAPELLA", desc: "SOLO VOCALS", isActive: isAcapellaActive) {
                    engineManager.applyAcapella()
                }
                macroButton(title: "INSTRUMENTAL", shortTitle: "INSTR.", desc: "MUTE VOCALS", isActive: isInstrumentalActive) {
                    engineManager.applyInstrumental()
                }
                macroButton(title: "DRUMLESS", desc: "MUTE DRUMS", isActive: isDrumlessActive) {
                    engineManager.applyDrumless()
                }
                macroButton(title: "KARAOKE", desc: "-12dB VOCALS", shortDesc: "-12dB VOX", isActive: isKaraokeActive) {
                    engineManager.applyKaraoke()
                }
                macroButton(title: "D&B", desc: "DRUMS + BASS", shortDesc: "DRUMS+BASS", isActive: isDnBActive) {
                    engineManager.applyDrumAndBass()
                }
                macroButton(title: "RESET MIX", desc: "UNITY 0dB", isActive: false) {
                    engineManager.applyResetMix()
                }
            }
            .frame(maxWidth: .infinity)
            
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.textMuted)
                    .frame(width: 4, height: 4)
                Text(activePresetDescription)
                    .font(.custom("DotGothic16-Regular", size: 9))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    
    private var activePresetDescription: String {
        if engineManager.isBypassed { return "STATUS: ORIGINAL MASTER • STEM MIX BYPASSED" }
        if isAcapellaActive { return "STATUS: VOCAL ISOLATION • BACKING STEMS MUTED" }
        if isInstrumentalActive { return "STATUS: INSTRUMENTAL • LEAD VOCALS MUTED" }
        if isDrumlessActive { return "STATUS: DRUMLESS PRACTICE • DRUMS MUTED" }
        if isKaraokeActive { return "STATUS: KARAOKE MODE • -12dB LEAD VOCALS" }
        if isDnBActive { return "STATUS: DRUM & BASS • VOCALS & OTHER MUTED" }
        let volumes = [engineManager.vocalVolume, engineManager.drumVolume, engineManager.bassVolume, engineManager.otherVolume]
        let anyMuted = engineManager.vocalMuted || engineManager.drumMuted || engineManager.bassMuted || engineManager.otherMuted
        if !anySolo && !anyMuted && volumes.allSatisfy({ abs($0 - 1) < 0.001 }) {
            return "STATUS: ALL STEMS ACTIVE • 0.0 dB UNITY GAIN"
        }
        return "STATUS: CUSTOM STEM MIX"
    }
    
    private func macroButton(title: String, shortTitle: String? = nil, desc: String, shortDesc: String? = nil,
                             isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            action()
        }) {
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    if isActive {
                        Circle()
                            .fill(theme.background)
                            .frame(width: 4, height: 4)
                    }
                    // Narrow HUDs use the short title instead of truncating.
                    ViewThatFits(in: .horizontal) {
                        Text(title).fixedSize()
                        Text(shortTitle ?? title)
                    }
                    .font(.custom("DotGothic16-Regular", size: 9.5))
                    .fontWeight(.bold)
                    .lineLimit(1)
                }
                ViewThatFits(in: .horizontal) {
                    Text(desc).fixedSize()
                    Text(shortDesc ?? desc)
                }
                .font(.custom("DotGothic16-Regular", size: 7.5))
                .foregroundColor(isActive ? theme.background : theme.textSecondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(isActive ? theme.textPrimary : theme.surfaceSecondary)
            .foregroundColor(isActive ? theme.background : theme.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isActive ? theme.textPrimary : theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) preset")
        .accessibilityHint(desc)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Stem Balance HUD View with Live VU Meters & Direct Quick Actions
struct StemBalanceHUDView: View {
    @Environment(AudioEngineManager.self) private var engineManager
    @State private var theme = ThemeManager.shared
    
    var body: some View {
        HStack(spacing: 8) {
            StemChannelCardView(
                index: 0,
                name: "VOCALS",
                vol: engineManager.vocalVolume,
                pan: engineManager.vocalPan,
                isMuted: engineManager.vocalMuted,
                isSolo: engineManager.vocalSolo,
                meter: engineManager.stemMeters[0],
                accentColor: theme.textPrimary
            )
            StemChannelCardView(
                index: 1,
                name: "DRUMS",
                vol: engineManager.drumVolume,
                pan: engineManager.drumPan,
                isMuted: engineManager.drumMuted,
                isSolo: engineManager.drumSolo,
                meter: engineManager.stemMeters[1],
                accentColor: theme.textPrimary
            )
            StemChannelCardView(
                index: 2,
                name: "BASS",
                vol: engineManager.bassVolume,
                pan: engineManager.bassPan,
                isMuted: engineManager.bassMuted,
                isSolo: engineManager.bassSolo,
                meter: engineManager.stemMeters[2],
                accentColor: theme.textPrimary
            )
            StemChannelCardView(
                index: 3,
                name: "OTHER",
                vol: engineManager.otherVolume,
                pan: engineManager.otherPan,
                isMuted: engineManager.otherMuted,
                isSolo: engineManager.otherSolo,
                meter: engineManager.stemMeters[3],
                accentColor: theme.textPrimary
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Stem Channel Card Subview
struct StemChannelCardView: View {
    @Environment(AudioEngineManager.self) private var engineManager
    @State private var theme = ThemeManager.shared
    let index: Int
    let name: String
    let vol: Double
    let pan: Float
    let isMuted: Bool
    let isSolo: Bool
    let meter: StemMeter
    let accentColor: Color
    
    private var isAudible: Bool {
        let anySolo = engineManager.vocalSolo || engineManager.drumSolo || engineManager.bassSolo || engineManager.otherSolo
        return !isMuted && (!anySolo || isSolo)
    }
    
    var body: some View {
        VStack(spacing: 3) {
            headerRow
            StemVUMeterRow(meter: meter, isActive: engineManager.isPlaying && isAudible)
            actionsRow
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(theme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(isSolo ? theme.accentRed : theme.hairline, lineWidth: 1)
        )
    }
    
    private var headerRow: some View {
        HStack {
            Text(name)
                .font(.custom("DotGothic16-Regular", size: 9.0))
                .fontWeight(.bold)
                .foregroundColor(accentColor)
            Spacer()
            Text(isMuted ? "MUTED" : (isSolo ? "SOLO" : "\(Int(vol * 100))%"))
                .font(.custom("DotGothic16-Regular", size: 8.0))
                .foregroundColor(isMuted || isSolo ? theme.accentRed : theme.textMuted)
        }
    }
    
    private var actionsRow: some View {
        HStack(spacing: 4) {
            Button(action: {
                Haptics.playClick()
                engineManager.toggleMute(index)
            }) {
                Text("M")
                    .font(.custom("DotGothic16-Regular", size: 8.0))
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(isMuted ? theme.accentRed : theme.surfaceHover)
                    .foregroundColor(isMuted ? theme.onAccent : theme.textSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(isMuted ? theme.accentRed : theme.hairline, lineWidth: 1)
                    )
                    .expandedHitArea(vertical: 3)
            }
            .buttonStyle(.plain)
            // Distinct from the mixer's "Mute VOCALS" so both stay addressable.
            .accessibilityLabel("Balance mute \(name)")
            .accessibilityValue(isMuted ? "On" : "Off")
            .help("Mute \(name.capitalized)")
            
            Button(action: {
                Haptics.playClick()
                engineManager.soloStem(index)
            }) {
                Text("S")
                    .font(.custom("DotGothic16-Regular", size: 8.0))
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(isSolo ? theme.accentRed : theme.surfaceHover)
                    .foregroundColor(isSolo ? theme.onAccent : theme.textSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(isSolo ? theme.accentRed : theme.hairline, lineWidth: 1)
                    )
                    .expandedHitArea(vertical: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Balance solo \(name)")
            .accessibilityValue(isSolo ? "On" : "Off")
            .help("Solo \(name.capitalized)")
        }
    }
}

/// The balance card's 10-segment VU row. It reads the stem meter itself, so readings
/// re-render this row and not the card's labels and buttons.
struct StemVUMeterRow: View {
    let meter: StemMeter
    let isActive: Bool
    @State private var theme = ThemeManager.shared
    
    private var clampedEnergy: CGFloat {
        guard isActive else { return 0.0 }
        let magnitudes = meter.spectrum
        let avg = magnitudes.reduce(0, +) / Float(max(1, magnitudes.count))
        let energy = CGFloat(avg) * 2.8
        return max(0.0, min(1.0, energy))
    }
    
    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<10, id: \.self) { seg in
                let segThreshold = CGFloat(seg + 1) / 10.0
                let isLit = clampedEnergy >= segThreshold
                let isPeak = seg >= 8
                let segColor: Color = isPeak ? theme.accentRed : theme.spectrumBarDefault
                
                Rectangle()
                    .fill(isLit ? segColor : theme.knobArcTrack)
                    .frame(height: 5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 1))
    }
}

// MARK: - Studio Telemetry HUD Diagnostics View
struct StudioTelemetryHUDView: View {
    @Environment(AudioEngineManager.self) private var engineManager
    @State private var theme = ThemeManager.shared
    
    var body: some View {
        // Narrow HUDs split each reading over two short lines instead of truncating.
        ViewThatFits(in: .horizontal) {
            fullCards
            compactCards
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    
    private var compactCards: some View {
        let timecode = engineManager.detailedTimecode.components(separatedBy: " / ")
        return EqualWidthHStack(spacing: 6) {
            telemetryCard(title: "TEMPO / KEY", line1: engineManager.effectiveBPM, line2: engineManager.effectiveMusicalKey)
            telemetryCard(title: "FORMAT", line1: engineManager.trackBitDepth, line2: engineManager.trackSampleRate)
            telemetryCard(
                title: "PROCESSING",
                line1: AudioEngineManager.systemChipName,
                line2: engineManager.isSplitting ? "SEPARATING" : "MODEL IDLE"
            )
            telemetryCard(title: "TIMECODE", line1: timecode.first ?? "", line2: timecode.dropFirst().first ?? "")
        }
    }
    
    private var fullCards: some View {
        EqualWidthHStack(spacing: 6) {
            telemetryCard(
                title: "HARMONICS / TEMPO",
                line1: "\(engineManager.effectiveBPM) • \(engineManager.effectiveMusicalKey)",
                line2: "PITCH: \(Int(engineManager.pitchShiftSemitones.rounded())) ST [\(engineManager.pitchShiftSemitones == 0 ? "ROOT" : (engineManager.pitchShiftSemitones > 0 ? "+\(Int(engineManager.pitchShiftSemitones))" : "\(Int(engineManager.pitchShiftSemitones))"))]"
            )
            
            telemetryCard(
                title: "AUDIO DSP PIPELINE",
                line1: "\(engineManager.trackBitDepth) • \(engineManager.trackSampleRate)",
                line2: "AVAudioEngine 32-BIT FLOAT"
            )
            
            telemetryCard(
                title: "ON-DEVICE PROCESSING",
                line1: "\(AudioEngineManager.systemChipName)",
                line2: engineManager.isSplitting ? "SEPARATING AUDIO" : "MODEL IDLE"
            )
            
            telemetryCard(
                title: "TIMECODE & BYPASS",
                line1: engineManager.detailedTimecode,
                line2: engineManager.isBypassed ? "BYPASS: ON (ORIGINAL)" : "BYPASS: OFF (4-STEMS)"
            )
        }
    }
    
    private func telemetryCard(title: String, line1: String, line2: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Circle()
                    .fill(theme.textDisabled)
                    .frame(width: 3.5, height: 3.5)
                Text(title)
                    .font(.custom("DotGothic16-Regular", size: 8.0))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(line1)
                .font(.custom("DotGothic16-Regular", size: 9.0))
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
            Text(line2)
                .font(.custom("DotGothic16-Regular", size: 8.0))
                .foregroundColor(theme.textMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(theme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(theme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - HUD Interactive Parametric Equalizer Curve Visualizer
struct HUDEqualizerCurveView: View {
    @Environment(AudioEngineManager.self) private var engineManager
    @Environment(\.isEnabled) private var isEnabled
    @State private var theme = ThemeManager.shared
    
    @State private var selectedStemIndex: Int = 0 // 0: VOCALS, 1: DRUMS, 2: BASS, 3: OTHER, 4: MASTER
    @State private var draggingBand: Int? = nil
    @State private var dragStartGain: Float? = nil
    
    private let stemNames = ["VOCALS", "DRUMS", "BASS", "OTHER", "MASTER"]
    static let shortStemNames = ["VOX", "DRM", "BAS", "OTH", "MST"]
    
    private var currentLow: Float {
        engineManager.getStemEQ(selectedStemIndex).low
    }
    
    private var currentMid: Float {
        engineManager.getStemEQ(selectedStemIndex).mid
    }
    
    private var currentHigh: Float {
        engineManager.getStemEQ(selectedStemIndex).high
    }
    
    private var isCurrentBypassed: Bool {
        engineManager.getStemEQ(selectedStemIndex).isBypassed || engineManager.isGlobalEQBypassed
    }
    
    private var isCurrentFlat: Bool {
        abs(currentLow) < 0.15 && abs(currentMid) < 0.15 && abs(currentHigh) < 0.15
    }
    
    var body: some View {
        VStack(spacing: 4) {
            // Top Toolbar: Stem Pills, Preset Quick Actions, Bypass & Reset
            HStack(spacing: 6) {
                // Narrow HUDs use short stem names, then drop the gain readout. The
                // menu stays outside: AppKit-backed controls measure unreliably here.
                ViewThatFits(in: .horizontal) {
                    stemSelectors(usesShortNames: false, showsReadout: true)
                    stemSelectors(usesShortNames: true, showsReadout: true)
                    stemSelectors(usesShortNames: true, showsReadout: false)
                }
                
                presetsMenu
                
                bypassChip
                    .fixedSize()
                
                resetButton
                    .fixedSize()
            }
            .frame(height: 16)
            
            // Curve Canvas
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let midY = h / 2.0
                
                // Frequencies at log coordinates:
                // 20Hz -> 0, 20kHz -> w
                // x(f) = w * log10(f / 20) / 3.0
                let x100 = w * (log10(100.0 / 20.0) / 3.0)
                let x1k = w * (log10(1000.0 / 20.0) / 3.0)
                let x10k = w * (log10(10000.0 / 20.0) / 3.0)
                
                let yLow = midY - CGFloat(currentLow / 12.0) * (midY * 0.78)
                let yMid = midY - CGFloat(currentMid / 12.0) * (midY * 0.78)
                let yHigh = midY - CGFloat(currentHigh / 12.0) * (midY * 0.78)
                let isCurveActive = !isCurrentBypassed && !isCurrentFlat
                
                ZStack {
                    // 1. Grid lines & labels
                    gridLines(w: w, h: h, midY: midY, x100: x100, x1k: x1k, x10k: x10k)
                    
                    // 2. Real-time FFT Backdrop
                    HUDSpectrumBackdrop(stemIndex: selectedStemIndex, height: h)
                    
                    // 3. Mathematical Biquad Curve Path
                    curvePath(w: w, h: h, midY: midY)
                        .fill(
                            LinearGradient(
                                colors: [
                                    isCurveActive ? theme.accentRed.opacity(0.20) : theme.textDisabled.opacity(0.12),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    
                    curvePath(w: w, h: h, midY: midY)
                        .stroke(
                            isCurrentBypassed ? theme.textDisabled : (isCurveActive ? theme.accentRed : theme.textSecondary),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                        )
                    
                    // 4. Interactive Draggable Filter Nodes
                    filterNode(
                        bandIndex: 0,
                        name: "LOW",
                        freq: "100Hz",
                        x: x100,
                        y: yLow,
                        gain: currentLow,
                        h: h,
                        midY: midY
                    )
                    
                    filterNode(
                        bandIndex: 1,
                        name: "MID",
                        freq: "1kHz",
                        x: x1k,
                        y: yMid,
                        gain: currentMid,
                        h: h,
                        midY: midY
                    )
                    
                    filterNode(
                        bandIndex: 2,
                        name: "HIGH",
                        freq: "10kHz",
                        x: x10k,
                        y: yHigh,
                        gain: currentHigh,
                        h: h,
                        midY: midY
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func stemSelectors(usesShortNames: Bool, showsReadout: Bool) -> some View {
        HStack(spacing: 6) {
            // Stem Selectors
            HStack(spacing: 2) {
                ForEach(0..<stemNames.count, id: \.self) { idx in
                    let isSelected = selectedStemIndex == idx
                    Button(action: {
                        Haptics.playClick()
                        selectedStemIndex = idx
                    }) {
                        Text(usesShortNames ? Self.shortStemNames[idx] : stemNames[idx])
                            .font(.custom("DotGothic16-Regular", size: 7.5))
                            .fontWeight(isSelected ? .bold : .regular)
                            .fixedSize()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(isSelected ? theme.textPrimary : theme.surfaceSecondary)
                            .foregroundColor(isSelected ? theme.background : theme.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(isSelected ? theme.textPrimary : theme.hairline, lineWidth: 0.5)
                            )
                            .expandedHitArea(vertical: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(stemNames[idx]) EQ")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            
            Spacer(minLength: 4)
            
            if showsReadout {
                // Readout of currently selected stem's gains
                HStack(spacing: 4) {
                    gainReadout("L", gain: currentLow)
                    gainReadout("M", gain: currentMid)
                    gainReadout("H", gain: currentHigh)
                }
                .fixedSize()
                .padding(.horizontal, 4)
            }
        }
    }
    
    // Presets Dropdown Menu
    private var presetsMenu: some View {
        Menu {
            ForEach(AudioEngineManager.factoryPresets) { preset in
                Button(preset.name) {
                    engineManager.applyEQPreset(preset, to: selectedStemIndex)
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text("PRESETS")
                    .font(.custom("DotGothic16-Regular", size: 7.5))
                Text("▾")
                    .font(.custom("DotGothic16-Regular", size: 7))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(theme.surfaceSecondary)
            .foregroundColor(theme.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("\(stemNames[selectedStemIndex]) EQ presets")
    }
    
    private var resetButton: some View {
        Button(action: {
            engineManager.resetStemEQ(selectedStemIndex)
        }) {
            Text("RST")
                .font(.custom("DotGothic16-Regular", size: 7.5))
                .foregroundColor(theme.textMuted)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(theme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .expandedHitArea(vertical: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reset \(stemNames[selectedStemIndex]) EQ")
        .help("Reset to 0.0 dB")
    }
    
    /// Sized for the widest value so the toolbar does not change width mid-drag.
    private func gainReadout(_ band: String, gain: Float) -> some View {
        Text("\(band): +12.0dB")
            .font(.custom("DotGothic16-Regular", size: 8))
            .hidden()
            .overlay(alignment: .leading) {
                Text("\(band): \(formatGain(gain))")
                    .font(.custom("DotGothic16-Regular", size: 8))
                    .foregroundColor(abs(gain) > 0.1 ? theme.accentRed : theme.textMuted)
                    .fixedSize()
            }
    }
    
    private var bypassChip: some View {
        let isGloballyBypassed = engineManager.isGlobalEQBypassed
        let label = isGloballyBypassed ? "ALL BYP" : (isCurrentBypassed ? "BYP" : "ACTIVE")
        return Button(action: {
            // While ⌘E bypasses every EQ, this chip is the visible way back.
            if isGloballyBypassed {
                engineManager.toggleGlobalEQBypass()
            } else {
                engineManager.toggleStemEQBypass(selectedStemIndex)
            }
        }) {
            HStack(spacing: 2.5) {
                Circle()
                    .fill(isCurrentBypassed ? theme.textDisabled : theme.textPrimary)
                    .frame(width: 4, height: 4)
                ZStack(alignment: .leading) {
                    Text("ALL BYP").hidden()
                    Text(label)
                        .foregroundColor(isGloballyBypassed ? theme.warning : (isCurrentBypassed ? theme.textMuted : theme.textPrimary))
                }
                .font(.custom("DotGothic16-Regular", size: 7.5))
                .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(theme.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isGloballyBypassed ? theme.warning : theme.hairline, lineWidth: 0.5)
            )
            .expandedHitArea(vertical: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stemNames[selectedStemIndex]) EQ bypass")
        .accessibilityValue(isGloballyBypassed ? "On, all EQ bypassed" : (isCurrentBypassed ? "On" : "Off"))
        .help(isGloballyBypassed ? "All EQ is bypassed (⌘E). Click to turn EQ back on." : "Bypass this EQ")
    }
    
    private func formatGain(_ gain: Float) -> String {
        if abs(gain) < 0.15 { return "0.0dB" }
        return String(format: "%+.1fdB", gain)
    }
    
    @ViewBuilder
    private func gridLines(w: CGFloat, h: CGFloat, midY: CGFloat, x100: CGFloat, x1k: CGFloat, x10k: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: midY))
            p.addLine(to: CGPoint(x: w, y: midY))
            
            p.move(to: CGPoint(x: 0, y: midY - midY * 0.45))
            p.addLine(to: CGPoint(x: w, y: midY - midY * 0.45))
            p.move(to: CGPoint(x: 0, y: midY + midY * 0.45))
            p.addLine(to: CGPoint(x: w, y: midY + midY * 0.45))
            
            p.move(to: CGPoint(x: x100, y: 0))
            p.addLine(to: CGPoint(x: x100, y: h))
            p.move(to: CGPoint(x: x1k, y: 0))
            p.addLine(to: CGPoint(x: x1k, y: h))
            p.move(to: CGPoint(x: x10k, y: 0))
            p.addLine(to: CGPoint(x: x10k, y: h))
        }
        .stroke(theme.hairline, style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
        
        Text("100Hz")
            .font(.custom("DotGothic16-Regular", size: 6.5))
            .foregroundColor(theme.textMuted)
            .position(x: x100, y: h - 5)
        Text("1kHz")
            .font(.custom("DotGothic16-Regular", size: 6.5))
            .foregroundColor(theme.textMuted)
            .position(x: x1k, y: h - 5)
        Text("10kHz")
            .font(.custom("DotGothic16-Regular", size: 6.5))
            .foregroundColor(theme.textMuted)
            .position(x: x10k, y: h - 5)
    }
    
    private func curvePath(w: CGFloat, h: CGFloat, midY: CGFloat) -> Path {
        let low = currentLow
        let mid = currentMid
        let high = currentHigh
        let steps = 60
        
        var points: [CGPoint] = []
        for i in 0...steps {
            let frac = CGFloat(i) / CGFloat(steps)
            let x = frac * w
            let freq = 20.0 * pow(10.0, 3.0 * Double(frac))
            
            // Low Shelf @ 100Hz
            let g0 = Double(low) / (1.0 + pow(freq / 100.0, 2.0))
            // Peaking Parametric @ 1000Hz (Q ~ 1.2)
            let logR = log10(freq / 1000.0)
            let g1 = Double(mid) * exp(-pow(logR / 0.35, 2.0))
            // High Shelf @ 10000Hz
            let fSq = pow(freq / 10000.0, 2.0)
            let g2 = Double(high) * (fSq / (1.0 + fSq))
            
            let totalGain = g0 + g1 + g2
            let y = midY - CGFloat(totalGain / 12.0) * (midY * 0.78)
            points.append(CGPoint(x: x, y: max(2, min(h - 2, y))))
        }
        
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for pt in points.dropFirst() {
            path.addLine(to: pt)
        }
        return path
    }
    
    @ViewBuilder
    private func filterNode(bandIndex: Int, name: String, freq: String, x: CGFloat, y: CGFloat, gain: Float, h: CGFloat, midY: CGFloat) -> some View {
        let isDragging = (draggingBand == bandIndex)
        let isModified = abs(gain) >= 0.15
        
        ZStack {
            Circle()
                .fill(theme.background)
                .frame(width: 14, height: 14)
                .overlay(
                    Circle()
                        .stroke(isDragging ? theme.textPrimary : (isModified ? theme.accentRed : theme.textSecondary), lineWidth: 1.5)
                )
            
            Circle()
                .fill(isModified ? theme.accentRed : theme.textPrimary)
                .frame(width: 6, height: 6)
            
            Text(isDragging ? String(format: "%+.1fdB", gain) : name)
                .font(.custom("DotGothic16-Regular", size: 6.5))
                .foregroundColor(isModified ? theme.accentRed : theme.textPrimary)
                .offset(y: y < midY ? 12 : -12)
        }
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        // Keyboard and VoiceOver access; MASTER gain has no other control.
        // Applied before .position so focus and the element frame stay on the node.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stemNames[selectedStemIndex]) \(name) EQ, \(freq)")
        .accessibilityValue(String(format: "%+.1f decibels", gain))
        .accessibilityAdjustableAction { nudgeBand(bandIndex, by: $0 == .increment ? 0.5 : -0.5) }
        .accessibilityAction(named: "Reset") { applyGainToBand(bandIndex, val: 0) }
        .focusable(isEnabled)
        .onKeyPress(.upArrow) { nudgeBand(bandIndex, by: 0.5); return .handled }
        .onKeyPress(.downArrow) { nudgeBand(bandIndex, by: -0.5); return .handled }
        .position(x: x, y: y)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { val in
                    draggingBand = bandIndex
                    let deltaY = -Float(val.translation.height) * 0.25
                    if dragStartGain == nil { dragStartGain = gain }
                    let baseGain = dragStartGain ?? gain
                    let target = RotaryEQKnobView.detent(max(-12.0, min(12.0, baseGain + deltaY)), from: gain)
                    if target.entersDetent {
                        Haptics.playAlignment()
                    }
                    applyGainToBand(bandIndex, val: target.gain)
                }
                .onEnded { _ in
                    draggingBand = nil
                    dragStartGain = nil
                }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            Haptics.playAlignment()
            applyGainToBand(bandIndex, val: 0.0)
        })
    }
    
    /// Steps a band from its live value, so key repeat never starts from a stale gain.
    private func nudgeBand(_ band: Int, by delta: Float) {
        let eq = engineManager.getStemEQ(selectedStemIndex)
        let current = band == 0 ? eq.low : (band == 1 ? eq.mid : eq.high)
        applyGainToBand(band, val: max(-12, min(12, current + delta)))
    }
    
    private func applyGainToBand(_ band: Int, val: Float) {
        let current = engineManager.getStemEQ(selectedStemIndex)
        switch band {
        case 0:
            engineManager.setStemEQ(selectedStemIndex, low: val, mid: current.mid, high: current.high)
        case 1:
            engineManager.setStemEQ(selectedStemIndex, low: current.low, mid: val, high: current.high)
        case 2:
            engineManager.setStemEQ(selectedStemIndex, low: current.low, mid: current.mid, high: val)
        default:
            break
        }
    }
}

/// Live spectrum behind the HUD EQ curve (index 4 is the master). Reading the meter here
/// re-renders only these bars on each tap reading, not the curve, grid and nodes.
struct HUDSpectrumBackdrop: View {
    @Environment(AudioEngineManager.self) private var engineManager
    @State private var theme = ThemeManager.shared
    let stemIndex: Int
    let height: CGFloat
    
    var body: some View {
        let h = height
        let mags = engineManager.stemMeters.indices.contains(stemIndex)
            ? engineManager.stemMeters[stemIndex].spectrum
            : engineManager.masterMeter.spectrum
        
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<min(24, mags.count), id: \.self) { i in
                let mag = CGFloat(mags[i])
                let barH = max(2.0, min(h, mag * h * 1.5))
                Rectangle()
                    .fill(theme.spectrumBarDefault.opacity(0.10))
                    .frame(height: barH)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .opacity(engineManager.isPlaying ? 1.0 : 0.0)
    }
}

// MARK: - Nothing OS HUD Shortcut Cheat Sheet Modal
struct ShortcutsHUDModal: View {
    let onClose: () -> Void
    @State private var theme = ThemeManager.shared
    @State private var isCloseHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(theme.textPrimary)
                        .frame(width: 8, height: 8)
                    Text("ISOLATE // QUICK SHORTCUTS")
                        .font(.custom("DotGothic16-Regular", size: 16))
                        .fontWeight(.bold)
                        .foregroundColor(theme.textPrimary)
                }
                
                Spacer()
                
                Button(action: {
                    Haptics.playClick()
                    onClose()
                }) {
                    Text("ESC / CLOSE")
                        .font(.custom("DotGothic16-Regular", size: 11))
                        .foregroundColor(isCloseHovered ? theme.textPrimary : theme.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isCloseHovered ? theme.surfaceHover : theme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .onHover { isCloseHovered = $0 }
                .accessibilityLabel("Close shortcuts")
            }
            
            Divider()
                .background(theme.hairline)
            
            // Scrolls only when the window is too short to show every row.
            ViewThatFits(in: .vertical) {
                shortcutRows
                ScrollView(.vertical) {
                    shortcutRows
                }
            }
        }
        .padding(22)
        .frame(width: 500)
        .background(theme.modalBackground)
        .border(theme.cardBorder, width: 1)
        .overlay(CornerBrackets())
        .shadow(color: theme.isDark ? Color.black : Color.black.opacity(0.15), radius: 30, x: 0, y: 10)
        .padding(.vertical, 16)
        .onExitCommand(perform: onClose)
        .accessibilityAddTraits(.isModal)
    }
    
    private var shortcutRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            hudRow(keys: ["⌘", "B"], action: "Toggle Audio Library Sidebar")
            hudRow(keys: ["1", "2", "3", "4"], action: "Exclusive Solo Vocals, Drums, Bass, Other")
            hudRow(keys: ["V", "D", "B", "O"], action: "Toggle Mute for individual channels")
            hudRow(keys: ["⌘1-5"], action: "Switch HUD: FFT, Macros, Balance, Telemetry, EQ")
            hudRow(keys: ["⌘", "E"], action: "Bypass All EQ (Stems + Master) On / Off")
            hudRow(keys: ["[", "]"], action: "Set A-B Loop Start and End points on the fly")
            hudRow(keys: ["L"], action: "Toggle A-B Region Loop On / Off")
            hudRow(keys: ["⌥", "L"], action: "Clear A-B Loop Markers")
            hudRow(keys: ["A", "I", "R"], action: "Acapella, Instrumental, Reset Unity Mix")
            hudRow(keys: ["Space"], action: "Play / Pause playback")
            hudRow(keys: ["⌘", "⌥", "B"], action: "Compare Original and Stem Mix")
            hudRow(keys: ["⌘", "O"], action: "Import / Batch Import audio tracks")
            hudRow(keys: ["⌘", ","], action: "Open Studio Settings Modal")
            hudRow(keys: ["?"], action: "Toggle this Shortcut Cheat Sheet")
        }
    }
    
    private func hudRow(keys: [String], action: String) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.custom("DotGothic16-Regular", size: 11))
                        .fontWeight(.bold)
                        .foregroundColor(theme.textPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(theme.border, lineWidth: 1)
                        )
                }
            }
            .frame(width: 110, alignment: .leading)
            
            Text(action)
                .font(.custom("DotGothic16-Regular", size: 12))
                .foregroundColor(theme.textPrimary)
            
            Spacer()
        }
    }
}
