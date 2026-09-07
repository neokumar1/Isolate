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
                shortcutsOverlay
            }
        }
    }
    
    private func headerView(isCompactHeight: Bool) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let isCompact = width < 860
            let isMedium = width >= 860 && width < 1260
            let isWide = width >= 1260
            let artSize: CGFloat = isCompactHeight ? 76 : 100
            
            HStack(spacing: isCompactHeight ? 12 : 16) {
                if let isSidebarVisible = isSidebarVisible {
                    sidebarToggleButton(isSidebarVisible: isSidebarVisible)
                        .padding(.leading, isSidebarVisible.wrappedValue ? 0 : 80)
                }
                
                AlbumArtView(image: engineManager.albumArt, size: artSize)
                
                trackInfoView(isCompact: isCompact, isCompactHeight: isCompactHeight)
                    .frame(minWidth: 150, maxWidth: isCompact ? .infinity : 280, alignment: .leading)
                
                if !isCompact {
                    Spacer(minLength: 12)
                    
                    HeaderCenterTelemetryModule(
                        isMedium: isMedium,
                        isWide: isWide,
                        isCompactHeight: isCompactHeight
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, isCompactHeight ? 16 : 24)
            .padding(.top, isCompactHeight ? 40 : 50)
            .padding(.bottom, 2)
        }
        .frame(height: isCompactHeight ? 122 : 152)
    }
    
    private func sidebarToggleButton(isSidebarVisible: Binding<Bool>) -> some View {
        Button(action: {
            Haptics.playClick()
            withAnimation(nil) { // 0ms Instant Nothing Hardware Snap
                isSidebarVisible.wrappedValue.toggle()
            }
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSidebarVisible.wrappedValue ? Color.red : theme.textSecondary, lineWidth: 1)
                    .frame(width: 18, height: 14)
                
                HStack(spacing: 2) {
                    Rectangle()
                        .fill(isSidebarVisible.wrappedValue ? Color.red : theme.textSecondary)
                        .frame(width: 4, height: 10)
                    Spacer()
                }
                .frame(width: 14, height: 10)
            }
            .frame(width: 28, height: 28)
            .background(theme.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private func trackInfoView(isCompact: Bool, isCompactHeight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: isCompactHeight ? 3 : 5) {
            MarqueeText(text: engineManager.currentTrackName, font: .custom("DotGothic16-Regular", size: isCompact ? 20 : (isCompactHeight ? 20 : 24)))
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            if !engineManager.trackArtist.isEmpty && engineManager.trackArtist != "Isolate" {
                Text("\(engineManager.trackArtist.uppercased()) • \(engineManager.trackAlbum.uppercased())")
                    .font(.custom("DotGothic16-Regular", size: 10.0))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
            }
            
            HStack(spacing: 10) {
                Text(engineManager.isBypassed ? "SOURCE: ORIGINAL MASTER" : "SOURCE: 4-STEM ISOLATION")
                    .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 10 : 11))
                    .foregroundColor(engineManager.isBypassed ? .yellow : theme.textSecondary)
                
                HStack(spacing: 5) {
                    Circle()
                        .fill(engineManager.isPlaying ? Color.red : Color.gray)
                        .frame(width: 5, height: 5)
                    
                    Text(engineManager.isPlaying ? "ACTIVE" : "STANDBY")
                        .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 9.5 : 10.5))
                        .foregroundColor(engineManager.isPlaying ? .red : theme.textSecondary)
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
                eqMagnitudes: engine.vocalEQMagnitudes,
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
                eqMagnitudes: engine.drumEQMagnitudes,
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
                eqMagnitudes: engine.bassEQMagnitudes,
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
                eqMagnitudes: engine.otherEQMagnitudes,
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
    
    private var shortcutsOverlay: some View {
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
            Button("") { engineManager.toggleLoop() }.keyboardShortcut("l", modifiers: []).hidden()
            Button("") { engineManager.toggleGlobalEQBypass() }.keyboardShortcut("e", modifiers: [.command]).hidden()
            
            // HUD Visualizer Mode Switching (⌘1 - ⌘5)
            Button("") {
                Haptics.playClick()
                engineManager.setHUDMode(0)
            }.keyboardShortcut("1", modifiers: [.command]).hidden()
            
            Button("") {
                Haptics.playClick()
                engineManager.setHUDMode(1)
            }.keyboardShortcut("2", modifiers: [.command]).hidden()
            
            Button("") {
                Haptics.playClick()
                engineManager.setHUDMode(2)
            }.keyboardShortcut("3", modifiers: [.command]).hidden()
            
            Button("") {
                Haptics.playClick()
                engineManager.setHUDMode(3)
            }.keyboardShortcut("4", modifiers: [.command]).hidden()
            
            Button("") {
                Haptics.playClick()
                engineManager.setHUDMode(4)
            }.keyboardShortcut("5", modifiers: [.command]).hidden()
            
            // On-The-Fly Loop Setters ([ and ])
            Button("") {
                Haptics.playClick()
                engineManager.loopStartProgress = engineManager.playbackProgress
                if engineManager.loopEndProgress <= engineManager.loopStartProgress {
                    engineManager.loopEndProgress = min(1.0, engineManager.loopStartProgress + 0.25)
                }
                engineManager.isLooping = true
            }.keyboardShortcut("[", modifiers: []).hidden()
            
            Button("") {
                Haptics.playClick()
                engineManager.loopEndProgress = max(engineManager.loopStartProgress + 0.05, engineManager.playbackProgress)
                engineManager.isLooping = true
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
    let eqMagnitudes: [Float]
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
            return Color.red
        } else if isAnySoloed {
            return Color.clear
        } else if isMuted {
            return Color.gray.opacity(0.2)
        } else {
            return Color.red.opacity(0.85)
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
        if isAnySoloed {
            return !isSoloed
        } else if isAnyMuted {
            return isMuted || volume <= 0.001
        } else {
            return false
        }
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
            StemDynamicWaveformView(
                title: title,
                magnitudes: eqMagnitudes,
                effectiveVolume: effectiveVolume,
                isPlaying: isPlaying
            )
            .frame(height: isCompactHeight ? 22 : 30)
            
            // Bipolar Stereo Panning Control
            PanKnobView(pan: $pan, isCompactHeight: isCompactHeight)
            
            // 3-Band Rotary EQ Section (Modular strip with hairlines)
            StemEQChannelStripView(
                low: $lowGain,
                mid: $midGain,
                high: $highGain,
                isBypassed: $isEQBypassed,
                isCompactHeight: isCompactHeight,
                onReset: onResetEQ
            )
            
            // Precision Readout Box (% and dB)
            HStack(spacing: 8) {
                Text("\(Int(volume * 100))%")
                    .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 12 : 13.5))
                    .fontWeight(.bold)
                    .foregroundColor(theme.textPrimary)
                
                Text(dbString)
                    .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 9.0 : 10.0))
                    .foregroundColor(abs(volume - 1.0) < 0.01 ? .red : theme.textSecondary)
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
            CustomFader(value: $volume, label: title)
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
        .opacity(isDimmed ? 0.35 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isDimmed)
    }
    
    private var muteButton: some View {
        let bg: Color = isMuted ? .red : (isMutedHovered ? theme.surfaceHover : .clear)
        let strokeColor: Color = isMuted ? .red : (isMutedHovered ? Color.red.opacity(0.7) : theme.cardBorder)
        let fg: Color = isMuted ? .black : theme.textPrimary
        
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
                .background(bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(strokeColor, lineWidth: 1)
                )
                .foregroundColor(fg)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isMutedHovered = $0 }
        .help("Mute channel (\(channelIndex == 0 ? "V" : channelIndex == 1 ? "D" : channelIndex == 2 ? "B" : "O"))")
    }
    
    private var soloButton: some View {
        let bg: Color = isSoloed ? .red : (isSoloedHovered ? theme.surfaceHover : .clear)
        let strokeColor: Color = isSoloed ? .red : (isSoloedHovered ? Color.red.opacity(0.7) : theme.cardBorder)
        let fg: Color = isSoloed ? .black : theme.textPrimary
        
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
                .background(bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(strokeColor, lineWidth: 1)
                )
                .foregroundColor(fg)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isSoloedHovered = $0 }
        .help("Solo channel (\(channelIndex + 1))")
    }
}

// MARK: - Nothing Bipolar Stereo Pan Control
struct PanKnobView: View {
    @Binding var pan: Float // -1.0 to +1.0
    var isCompactHeight: Bool = false
    @State private var theme = ThemeManager.shared
    @State private var isHovered = false
    @State private var isDragging = false
    
    private var panLabel: String {
        if abs(pan) < 0.04 {
            return "CENTER"
        } else if pan < 0 {
            return "L \(Int(abs(pan) * 100))"
        } else {
            return "R \(Int(pan * 100))"
        }
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
                    .foregroundColor(isCenter ? theme.textPrimary : .red)
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
                            .fill(Color.red)
                            .frame(width: max(1, fillWidth), height: isCompactHeight ? 2.5 : 3)
                            .position(x: fillOriginX, y: height / 2.0)
                    }
                    
                    // Thumb Needle / Pip
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isCenter ? theme.faderThumb : Color.red)
                        .frame(width: 3.5, height: isCompactHeight ? 10 : 12)
                        .shadow(color: (isHovered || isDragging) ? Color.red.opacity(0.6) : Color.clear, radius: 3)
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
                .onTapGesture(count: 2) {
                    Haptics.playAlignment()
                    withAnimation(.easeOut(duration: 0.12)) {
                        pan = 0.0
                    }
                }
            }
            .frame(height: isCompactHeight ? 13 : 16)
            .onHover { isHovered = $0 }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, isCompactHeight ? 1 : 2)
    }
}

// MARK: - Rotary 3-Band EQ Knob (-12dB to +12dB)
struct RotaryEQKnobView: View {
    let bandName: String
    let freqLabel: String
    @Binding var gain: Float // -12.0 ... +12.0
    var isBypassed: Bool = false
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
        return gain > 0 ? Color.red : theme.textSecondary
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
                                Color.red,
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
                                isHovered ? Color.red.opacity(0.85) : theme.cardBorder,
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
                        var next = max(-12.0, min(12.0, start + delta))
                        
                        if abs(next) < 0.25 {
                            if abs(gain) >= 0.25 {
                                Haptics.playAlignment()
                            }
                            next = 0.0
                        }
                        gain = next
                    }
                    .onEnded { _ in
                        dragStartGain = nil
                    }
            )
            .onTapGesture(count: 2) {
                Haptics.playAlignment()
                withAnimation(.easeOut(duration: 0.12)) {
                    gain = 0.0
                }
            }
            
            Text(gainString)
                .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 7.5 : 8.5))
                .foregroundColor(accentColor)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Stem 3-Band EQ Channel Strip Component
struct StemEQChannelStripView: View {
    @Binding var low: Float
    @Binding var mid: Float
    @Binding var high: Float
    @Binding var isBypassed: Bool
    var isCompactHeight: Bool = false
    var onReset: (() -> Void)? = nil
    @State private var theme = ThemeManager.shared
    
    private var isModified: Bool {
        abs(low) >= 0.15 || abs(mid) >= 0.15 || abs(high) >= 0.15
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
                    isBypassed.toggle()
                }) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isBypassed ? theme.textMuted : (isModified ? Color.red : theme.textPrimary))
                            .frame(width: 4, height: 4)
                        Text(isBypassed ? "EQ: BYP" : "3-BAND EQ")
                            .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 8.0 : 8.5))
                            .foregroundColor(isBypassed ? theme.textMuted : theme.textPrimary)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(theme.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(
                                isModified && !isBypassed ? Color.red.opacity(0.5) : theme.hairline,
                                lineWidth: 0.5
                            )
                    )
                }
                .buttonStyle(.plain)
                .help(isBypassed ? "Unbypass EQ (⌘E)" : "Bypass EQ (⌘E)")
                
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
                            .foregroundColor(.red)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                    .buttonStyle(.plain)
                    .help("Reset EQ to Flat 0.0 dB")
                }
            }
            .padding(.horizontal, 4)
            
            // 3 Rotary Knobs Row: LOW (100Hz), MID (1kHz), HIGH (10kHz)
            HStack(spacing: 2) {
                RotaryEQKnobView(bandName: "LOW", freqLabel: "100Hz", gain: $low, isBypassed: isBypassed, isCompactHeight: isCompactHeight)
                RotaryEQKnobView(bandName: "MID", freqLabel: "1.0kHz", gain: $mid, isBypassed: isBypassed, isCompactHeight: isCompactHeight)
                RotaryEQKnobView(bandName: "HIGH", freqLabel: "10kHz", gain: $high, isBypassed: isBypassed, isCompactHeight: isCompactHeight)
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

// MARK: - Dynamic Island Symmetrical Dot-Matrix Stem Waveform View
struct StemDynamicWaveformView: View {
    let title: String
    let magnitudes: [Float]
    let effectiveVolume: Double
    let isPlaying: Bool
    @State private var theme = ThemeManager.shared
    
    // Per-stem 7 calibrated acoustic frequency gains
    private var bandGains: [Float] {
        switch title {
        case "VOCALS":
            return [18.0, 24.0, 32.0, 42.0, 54.0, 68.0, 90.0]
        case "DRUMS":
            return [14.0, 18.0, 22.0, 30.0, 42.0, 58.0, 75.0]
        case "BASS":
            return [12.0, 14.0, 16.0, 20.0, 28.0, 38.0, 50.0]
        case "OTHER":
            return [18.0, 22.0, 28.0, 36.0, 48.0, 64.0, 82.0]
        default:
            return [20.0, 24.0, 30.0, 38.0, 48.0, 62.0, 80.0]
        }
    }
    
    private var barAmplitudes: [CGFloat] {
        guard isPlaying, effectiveVolume > 0.001, !magnitudes.isEmpty else {
            return Array(repeating: 0.0, count: 7)
        }
        
        let gains = bandGains
        let sensitivity = Float(AppSettings.shared.waveformSensitivity)
        var bars: [CGFloat] = []
        
        for i in 0..<7 {
            let rawMag = i < magnitudes.count ? magnitudes[i] : 0.0
            let gain = i < gains.count ? gains[i] : 25.0
            let scaled = rawMag * gain * Float(effectiveVolume) * sensitivity
            
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
                                return distance == spread && distance > 1 ? Color.red : theme.textPrimary
                            } else if isRestingCenter {
                                return effectiveVolume <= 0.001 ? theme.knobArcTrack : Color.red.opacity(0.35)
                            } else {
                                return theme.knobArcTrack // Faint unlit physical LED dot
                            }
                        }()
                        
                        RoundedRectangle(cornerRadius: 0.6)
                            .fill(dotColor)
                            .frame(width: 5.0, height: 2.5)
                    }
                }
                .animation(.spring(response: 0.08, dampingFraction: 0.7, blendDuration: 0.01), value: amp)
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
        guard let tiffData = image.tiffRepresentation,
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
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
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
                
                // 100% Perceptual Brightness Compensation:
                // Compensates for non-emissive aperture gaps between circular dots
                // so total luminous flux matches the original continuous-tone image 1:1
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

// MARK: - Album Art View with Full-Color Nothing Dot-Matrix LED Screen
struct AlbumArtView: View {
    let image: NSImage?
    var size: CGFloat = 100
    @Environment(AudioEngineManager.self) private var engineManager
    @State private var theme = ThemeManager.shared
    @State private var dotMatrix: [[DotMatrixCell]]? = nil
    @State private var isHovered = false
    
    var body: some View {
        ZStack {
            theme.surface
            
            if let _ = image {
                ZStack {
                    // 1. Real-Time 50x50 Full-Color RGB Dot-Matrix LED Canvas (100% Brightness Matched)
                    if let matrix = dotMatrix {
                        Canvas { context, sz in
                            let gridSize = 50
                            let cellWidth = sz.width / CGFloat(gridSize)
                            let cellHeight = sz.height / CGFloat(gridSize)
                            let audioEnergy = engineManager.isPlaying ? Double(engineManager.masterWaveformAmplitudes.reduce(0, +) / Float(max(1, engineManager.masterWaveformAmplitudes.count))) : 0.0
                            let pulse = 1.0 + (audioEnergy * 0.08)
                            let maxDotRadius = cellWidth * 0.46 // Micro-aperture 0.2px boundary
                            
                            for y in 0..<gridSize {
                                for x in 0..<gridSize {
                                    let cell = matrix[y][x]
                                    let lum = cell.luminance
                                    
                                    // Scale dot radius smoothly for full luminous coverage
                                    let normalizedScale = CGFloat(0.55 + 0.45 * sqrt(lum))
                                    let baseRadius = maxDotRadius * normalizedScale * CGFloat(pulse)
                                    let clampedRadius = min(maxDotRadius, max(0.40, baseRadius))
                                    
                                    let centerX = CGFloat(x) * cellWidth + (cellWidth * 0.5)
                                    let centerY = CGFloat(y) * cellHeight + (cellHeight * 0.5)
                                    let dotRect = CGRect(
                                        x: centerX - clampedRadius,
                                        y: centerY - clampedRadius,
                                        width: clampedRadius * 2,
                                        height: clampedRadius * 2
                                    )
                                    
                                    let dotColor = Color(
                                        red: Double(cell.r),
                                        green: Double(cell.g),
                                        blue: Double(cell.b)
                                    )
                                    context.fill(Path(ellipseIn: dotRect), with: .color(dotColor))
                                }
                            }
                        }
                        .frame(width: size, height: size)
                    }
                    
                    // 2. Subtle Micro-Bloom Glow on Hover
                    if isHovered, let matrix = dotMatrix {
                        Canvas { context, sz in
                            let gridSize = 50
                            let cellWidth = sz.width / CGFloat(gridSize)
                            let cellHeight = sz.height / CGFloat(gridSize)
                            for y in 0..<gridSize {
                                for x in 0..<gridSize {
                                    let cell = matrix[y][x]
                                    guard cell.luminance > 0.10 else { continue }
                                    let centerX = CGFloat(x) * cellWidth + (cellWidth * 0.5)
                                    let centerY = CGFloat(y) * cellHeight + (cellHeight * 0.5)
                                    let bloomRect = CGRect(x: centerX - cellWidth * 0.55, y: centerY - cellHeight * 0.55, width: cellWidth * 1.1, height: cellHeight * 1.1)
                                    let dotColor = Color(red: Double(cell.r), green: Double(cell.g), blue: Double(cell.b)).opacity(0.35)
                                    context.fill(Path(ellipseIn: bloomRect), with: .color(dotColor))
                                }
                            }
                        }
                        .frame(width: size, height: size)
                        .blur(radius: 1.2)
                        .blendMode(.plusLighter)
                        .transition(.opacity)
                    }
                }
            } else {
                // Standby diagnostic crosslines
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
                    .stroke(Color.red.opacity(0.5), lineWidth: 1)
                    
                    Text("NO ARTWORK")
                        .font(.custom("DotGothic16-Regular", size: size < 85 ? 8.5 : 10))
                        .foregroundColor(.red.opacity(0.85))
                        .padding(3)
                        .background(theme.surface)
                }
            }
            
            // Outer Hardware Border
            Rectangle()
                .stroke(theme.cardBorder, lineWidth: 1)
            
            // Red Corner Accents (Nothing Hardware Style)
            CornerBrackets()
        }
        .frame(width: size, height: size)
        .clipped()
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                isHovered = hovering
            }
        }
        .onChange(of: image) { _, newImage in
            updateMatrix(for: newImage)
        }
        .onAppear {
            updateMatrix(for: image)
        }
    }
    
    private func updateMatrix(for img: NSImage?) {
        guard let img = img else {
            dotMatrix = nil
            return
        }
        Task.detached(priority: .userInitiated) {
            let matrix = DotMatrixImageProcessor.generateColorDotMatrix(from: img, gridSize: 50)
            await MainActor.run {
                self.dotMatrix = matrix
            }
        }
    }
}

struct CornerBrackets: View {
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
            .stroke(Color.red, lineWidth: 2)
        }
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
                            .fill(isLit ? Color.red : theme.knobArcTrack)
                            .frame(width: 4.5, height: 2.5)
                    }
                }
                .animation(.spring(response: 0.08, dampingFraction: 0.7, blendDuration: 0.01), value: amp)
            }
        }
        .frame(height: 36)
    }
}


// MARK: - Discrete LED Dot-Matrix Progress Bar with A-B Looping
struct DotMatrixProgressBar: View {
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
                            ? (inLoop ? Color.red : Color(red: 1.0, green: 0.35, blue: 0.35))
                            : (inLoop ? Color.red.opacity(0.35) : theme.knobArcTrack)
                        
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
                            .foregroundColor(.yellow)
                            .offset(x: max(0, geo.size.width * loopStart - 6), y: -14)
                        Spacer()
                    }
                    HStack {
                        Text("[B]")
                            .font(.custom("DotGothic16-Regular", size: 9))
                            .foregroundColor(.yellow)
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
                        let percent = max(0, min(1, value.location.x / geo.size.width))
                        onSeek(percent)
                    }
                    .onEnded { value in
                        let percent = max(0, min(1, value.location.x / geo.size.width))
                        onSeek(percent)
                        onSeekingChanged(false)
                    }
            )
        }
        .frame(height: 36)
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
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let isCompact = w < 800
            let isMini = w < 620
            
            HStack(spacing: isCompact ? 8 : 12) {
                timeLabel(isCompact: isCompact)
                
                progressBar
                    .frame(minWidth: 50)
                
                // A-B Loop Quick Toggle
                loopButton(isCompact: isCompact)
                
                if !isMini {
                    pitchControl(isCompact: isCompact)
                    speedControl(isCompact: isCompact)
                }
                
                playButton
                bypassButton(isCompact: isCompact)
                exportButton(isCompact: isCompact)
            }
            .frame(width: w, height: 48)
        }
        .frame(height: 48)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.surface)
        .border(theme.hairline, width: 1)
    }
    
    private func timeLabel(isCompact: Bool) -> some View {
        Text(engineManager.currentTimeString)
            .font(.custom("DotGothic16-Regular", size: isCompact ? 13 : 15))
            .foregroundColor(.red)
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
                engineManager.playbackProgress = percent
                engineManager.updateTimeString(for: percent)
            },
            onSeekingChanged: { isSeeking in
                if isSeeking {
                    if !wasPlayingBeforeDrag && engineManager.isPlaying {
                        wasPlayingBeforeDrag = true
                        engineManager.togglePlayback()
                    }
                } else {
                    engineManager.seek(toPercentage: engineManager.playbackProgress)
                    if wasPlayingBeforeDrag {
                        engineManager.togglePlayback()
                    }
                    wasPlayingBeforeDrag = false
                }
            }
        )
    }
    
    private func loopButton(isCompact: Bool) -> some View {
        Button(action: {
            engineManager.toggleLoop()
        }) {
            Text(engineManager.isLooping ? (isCompact ? "LOOP" : "LOOP: ON") : (isCompact ? "LOOP" : "LOOP: OFF"))
                .font(.custom("DotGothic16-Regular", size: isCompact ? 10.5 : 11.5))
                .fontWeight(.bold)
                .frame(width: isCompact ? 64 : 80, height: 32)
                .background(engineManager.isLooping ? Color.red : (isLoopHovered ? theme.surfaceHover : Color.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(engineManager.isLooping ? Color.red : (isLoopHovered ? theme.textPrimary : theme.border), lineWidth: 1)
                )
                .foregroundColor(engineManager.isLooping ? .black : (isLoopHovered ? theme.textPrimary : theme.textSecondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isLoopHovered = $0 }
    }
    
    private func pitchControl(isCompact: Bool) -> some View {
        HStack(spacing: 2) {
            Button(action: {
                Haptics.playClick()
                engineManager.pitchShiftSemitones = max(-12.0, engineManager.pitchShiftSemitones - 1.0)
            }) {
                Text("-")
                    .font(.custom("DotGothic16-Regular", size: 12))
                    .foregroundColor(theme.textSecondary)
                    .frame(width: 14, height: 28)
            }
            .buttonStyle(.plain)
            
            let st = Int(engineManager.pitchShiftSemitones)
            let absSt = abs(st)
            let intervals = [
                0: "ROOT", 1: "m2", 2: "M2", 3: "m3", 4: "M3", 5: "4th", 6: "TRI",
                7: "5th", 8: "m6", 9: "M6", 10: "m7", 11: "M7", 12: "OCT"
            ]
            let intervalName = intervals[absSt] ?? "\(absSt)ST"
            let sign = st > 0 ? "+" : ""
            let displayText = isCompact ? (st == 0 ? "0 ST" : "\(sign)\(st) ST") : (st == 0 ? "0 ST [ROOT]" : "\(sign)\(st) ST [\(intervalName)]")
            
            Text(displayText)
                .font(.custom("DotGothic16-Regular", size: isCompact ? 9.5 : 10))
                .fontWeight(.bold)
                .foregroundColor(st == 0 ? theme.textMuted : .red)
                .frame(width: isCompact ? 54 : 78)
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
                    .frame(width: 14, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 3)
        .frame(height: 32)
        .background(isPitchHovered ? theme.surfaceHover : theme.surfaceSecondary)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(engineManager.pitchShiftSemitones != 0 ? Color.red.opacity(0.6) : theme.hairline, lineWidth: 1)
        )
        .onHover { isPitchHovered = $0 }
    }
    
    private func speedControl(isCompact: Bool) -> some View {
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
                    .frame(width: 12, height: 28)
            }
            .buttonStyle(.plain)
            
            Text(String(format: "%.2fx", engineManager.playbackRate))
                .font(.custom("DotGothic16-Regular", size: isCompact ? 10 : 11))
                .fontWeight(.bold)
                .foregroundColor(engineManager.playbackRate == 1.0 ? theme.textMuted : .red)
                .frame(width: isCompact ? 38 : 44)
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
                    .frame(width: 12, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 3)
        .frame(height: 32)
        .background(isSpeedHovered ? theme.surfaceHover : theme.surfaceSecondary)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(engineManager.playbackRate != 1.0 ? Color.red.opacity(0.6) : theme.hairline, lineWidth: 1)
        )
        .onHover { isSpeedHovered = $0 }
    }
    
    private var playButton: some View {
        Button(action: {
            Haptics.playClick()
            engineManager.togglePlayback()
        }) {
            Image(systemName: engineManager.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 18))
                .foregroundColor(.black)
                .frame(width: 38, height: 38)
                .background(Color.red)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .keyboardShortcut(.space, modifiers: [])
    }
    
    private func bypassButton(isCompact: Bool) -> some View {
        Button(action: {
            Haptics.playClick()
            engineManager.isBypassed.toggle()
        }) {
            Text(engineManager.isBypassed ? (isCompact ? "BYPASS" : "BYPASS: ON") : (isCompact ? "BYPASS" : "BYPASS: OFF"))
                .font(.custom("DotGothic16-Regular", size: isCompact ? 11.5 : 13))
                .fontWeight(.bold)
                .frame(width: isCompact ? 90 : 110, height: 34)
                .background(
                    engineManager.isBypassed
                        ? Color.red
                        : (isBypassHovered ? theme.surfaceHover : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            engineManager.isBypassed
                                ? Color.red
                                : (isBypassHovered ? theme.textPrimary : Color.red.opacity(0.8)),
                            lineWidth: 1
                        )
                )
                .foregroundColor(engineManager.isBypassed ? .black : .red)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isBypassHovered = hovering
        }
    }
    
    private func exportButton(isCompact: Bool) -> some View {
        Button(action: {
            Haptics.playClick()
            engineManager.exportStems()
        }) {
            ZStack {
                switch engineManager.exportState {
                case .idle:
                    Text(isCompact ? "EXPORT" : "EXPORT STEMS")
                        .fontWeight(.bold)
                        .foregroundColor(.red)
                case .exporting(let stage, let percent):
                    Text("\(stage) \(Int(percent * 100))%")
                        .fontWeight(.bold)
                        .foregroundColor(.yellow)
                case .completed:
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                        Text(isCompact ? "DONE" : "COMPLETED")
                    }
                    .fontWeight(.bold)
                    .foregroundColor(theme.isDark ? .black : .white)
                }
            }
            .font(.custom("DotGothic16-Regular", size: isCompact ? 11.5 : 13))
            .frame(width: isCompact ? 110 : 140, height: 34)
            .background(
                engineManager.exportState == .completed
                    ? Color.red
                    : (engineManager.isExporting
                        ? Color.red.opacity(0.25)
                        : (isExportHovered ? theme.surfaceHover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        engineManager.exportState == .completed
                            ? theme.textPrimary
                            : (isExportHovered ? theme.textPrimary : Color.red),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .disabled(engineManager.isExporting || engineManager.exportState == .completed)
        .buttonStyle(.plain)
        .onHover { hovering in
            isExportHovered = hovering
        }
    }
}

struct MarqueeText: View {
    let text: String
    let font: Font
    
    @State private var offset: CGFloat = 0
    @State private var animationTask: Task<Void, Never>? = nil
    
    var body: some View {
        GeometryReader { geo in
            let containerWidth = geo.size.width
            let textWidth = measureTextWidth(text)
            
            Text(text)
                .font(font)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: offset)
                .frame(width: containerWidth, alignment: .leading)
                .clipped()
                .onAppear {
                    updateAnimation(containerWidth: containerWidth, textWidth: textWidth)
                }
                .onChange(of: text) { _, _ in
                    updateAnimation(containerWidth: containerWidth, textWidth: textWidth)
                }
                .onChange(of: containerWidth) { _, newWidth in
                    updateAnimation(containerWidth: newWidth, textWidth: textWidth)
                }
        }
        .frame(height: 32)
    }
    
    private func measureTextWidth(_ string: String) -> CGFloat {
        let font = NSFont(name: "DotGothic16-Regular", size: 26) ?? NSFont.monospacedSystemFont(ofSize: 26, weight: .regular)
        let attr: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((string as NSString).size(withAttributes: attr).width)
    }
    
    private func updateAnimation(containerWidth: CGFloat, textWidth: CGFloat) {
        animationTask?.cancel()
        animationTask = nil
        offset = 0
        
        let diff = textWidth - containerWidth
        guard diff > 8, containerWidth > 50 else {
            offset = 0
            return
        }
        
        animationTask = Task { @MainActor in
            let speed: CGFloat = 28.0 // px per second
            let totalTime = Double(diff / speed)
            let steps = max(1, Int(diff / 8))
            let timePerStep = totalTime / Double(steps)
            
            while !Task.isCancelled {
                // Settle at start
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                
                // Ping to end
                for step in 1...steps {
                    offset = -CGFloat(step) * (diff / CGFloat(steps))
                    try? await Task.sleep(nanoseconds: UInt64(timePerStep * 1_000_000_000))
                    guard !Task.isCancelled else { break }
                }
                offset = -diff
                
                // Settle at end
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                
                // Pong back to start
                for step in 1...steps {
                    offset = -diff + CGFloat(step) * (diff / CGFloat(steps))
                    try? await Task.sleep(nanoseconds: UInt64(timePerStep * 1_000_000_000))
                    guard !Task.isCancelled else { break }
                }
                offset = 0
            }
        }
    }
}

// MARK: - Header Center Telemetry & Visualizer Console Module
struct HeaderCenterTelemetryModule: View {
    @Environment(AudioEngineManager.self) private var engineManager
    @State private var theme = ThemeManager.shared
    let isMedium: Bool
    let isWide: Bool
    var isCompactHeight: Bool = false
    
    private let modes = ["32-BAND FFT", "STEM MACROS", "STEM BALANCE", "TELEMETRY", "EQUALIZER"]
    
    var body: some View {
        ZStack {
            theme.surface
            
            // Outer hardware frame
            Rectangle()
                .stroke(theme.border, lineWidth: 1)
            
            // Red corner brackets (Nothing aesthetic)
            CornerBrackets()
            
            VStack(spacing: 0) {
                // Top Telemetry / Mode Switcher Header Bar
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("[")
                            .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 9 : 10))
                            .foregroundColor(theme.textMuted)
                        Text("STUDIO HUD")
                            .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 9 : 10))
                            .foregroundColor(.red)
                        Text("]")
                            .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 9 : 10))
                            .foregroundColor(theme.textMuted)
                    }
                    
                    if isWide || isMedium {
                        HStack(spacing: 8) {
                            Text("• \(engineManager.effectiveBPM)")
                                .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 8.5 : 10))
                                .foregroundColor(theme.textPrimary)
                            Text("• \(engineManager.effectiveMusicalKey)")
                                .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 8.5 : 10))
                                .foregroundColor(.red)
                            Text("• \(engineManager.trackSampleRate)")
                                .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 8.0 : 9.5))
                                .foregroundColor(theme.textMuted)
                        }
                    }
                    
                    Spacer(minLength: 8)
                    
                    // Mode Switcher Tabs
                    HStack(spacing: isCompactHeight ? 2 : 3) {
                        ForEach(0..<modes.count, id: \.self) { idx in
                            Button(action: {
                                Haptics.playClick()
                                engineManager.setHUDMode(idx)
                            }) {
                                Text(modes[idx])
                                    .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 7.5 : 8.5))
                                    .fontWeight(engineManager.activeHUDModeIndex == idx ? .bold : .regular)
                                    .padding(.horizontal, isCompactHeight ? 4 : 6)
                                    .padding(.vertical, isCompactHeight ? 2 : 3)
                                    .background(engineManager.activeHUDModeIndex == idx ? Color.red : theme.surfaceSecondary)
                                    .foregroundColor(engineManager.activeHUDModeIndex == idx ? .black : theme.textPrimary)
                                    .clipShape(RoundedRectangle(cornerRadius: 2))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(engineManager.activeHUDModeIndex == idx ? Color.red : theme.hairline, lineWidth: 1)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    // Neural Engine Activity LED
                    HStack(spacing: 4) {
                        Circle()
                            .fill(engineManager.isPlaying ? Color.red : theme.textMuted.opacity(0.5))
                            .frame(width: 5, height: 5)
                            .shadow(color: engineManager.isPlaying ? Color.red.opacity(0.8) : Color.clear, radius: 3)
                        Text("ANE")
                            .font(.custom("DotGothic16-Regular", size: isCompactHeight ? 8 : 9))
                            .foregroundColor(engineManager.isPlaying ? .red : theme.textMuted)
                    }
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

// MARK: - 32-Band Dot-Matrix FFT Spectrum Visualizer
struct Spectrum32BandView: View {
    @Environment(AudioEngineManager.self) private var engineManager
    
    private var magnitudes: [Float] {
        engineManager.masterEQMagnitudes
    }
    
    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let totalHeight = geo.size.height
            let barCount = 32
            let spacing: CGFloat = 2.0
            let totalSpacing = spacing * CGFloat(barCount - 1)
            let barWidth = max(2.0, (totalWidth - totalSpacing) / CGFloat(barCount))
            
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    let mag = index < magnitudes.count ? CGFloat(magnitudes[index]) : 0.0
                    FFT32BarColumn(magnitude: mag, height: totalHeight, width: barWidth, barIndex: index)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}

struct FFT32BarColumn: View {
    @State private var theme = ThemeManager.shared
    let magnitude: CGFloat
    let height: CGFloat
    let width: CGFloat
    let barIndex: Int
    
    private let blockCount = 14
    private let blockSpacing: CGFloat = 1.5
    
    var body: some View {
        let totalSpacing = blockSpacing * CGFloat(blockCount - 1)
        let blockHeight = max(1.5, (height - totalSpacing) / CGFloat(blockCount))
        let activeBlocksFloat = max(0.0, min(CGFloat(blockCount), magnitude * CGFloat(blockCount)))
        
        VStack(spacing: blockSpacing) {
            ForEach((0..<blockCount).reversed(), id: \.self) { blockIdx in
                let blockBottomLevel = CGFloat(blockIdx)
                let blockTopLevel = CGFloat(blockIdx + 1)
                
                let fillFraction: CGFloat = {
                    if activeBlocksFloat >= blockTopLevel {
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
                        return Color.red
                    } else if isUpperMidBlock {
                        return theme.spectrumBarDefault
                    } else {
                        return theme.spectrumBarDefault.opacity(0.88)
                    }
                }()
                
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(activeColor.opacity(fillFraction > 0 ? max(0.2, fillFraction) : (theme.isDark ? 0.05 : 0.08)))
                    .frame(width: width, height: blockHeight)
            }
        }
        .frame(width: width, height: height, alignment: .bottom)
    }
}

// MARK: - Stem Macro Quick Presets
struct StemMacroPresetsView: View {
    @Environment(AudioEngineManager.self) private var engineManager
    @State private var theme = ThemeManager.shared
    
    private var isAcapellaActive: Bool {
        engineManager.vocalSolo && !engineManager.vocalMuted && !engineManager.drumSolo && !engineManager.bassSolo && !engineManager.otherSolo
    }
    
    private var isInstrumentalActive: Bool {
        engineManager.vocalMuted && !engineManager.drumMuted && !engineManager.bassMuted && !engineManager.otherMuted && !engineManager.vocalSolo
    }
    
    private var isDrumlessActive: Bool {
        engineManager.drumMuted && !engineManager.vocalMuted && !engineManager.bassMuted && !engineManager.otherMuted && !engineManager.drumSolo
    }
    
    private var isKaraokeActive: Bool {
        abs(engineManager.vocalVolume - 0.25) < 0.05 && !engineManager.vocalMuted && !engineManager.drumMuted && !engineManager.bassMuted && !engineManager.otherMuted
    }
    
    private var isDnBActive: Bool {
        engineManager.vocalMuted && engineManager.otherMuted && !engineManager.drumMuted && !engineManager.bassMuted
    }
    
    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                macroButton(title: "ACAPELLA", desc: "SOLO VOCALS", isActive: isAcapellaActive) {
                    engineManager.applyAcapella()
                }
                macroButton(title: "INSTRUMENTAL", desc: "MUTE VOCALS", isActive: isInstrumentalActive) {
                    engineManager.applyInstrumental()
                }
                macroButton(title: "DRUMLESS", desc: "MUTE DRUMS", isActive: isDrumlessActive) {
                    engineManager.applyDrumless()
                }
                macroButton(title: "KARAOKE", desc: "-12dB VOCALS", isActive: isKaraokeActive) {
                    engineManager.applyKaraoke()
                }
                macroButton(title: "D&B", desc: "DRUMS + BASS", isActive: isDnBActive) {
                    engineManager.applyDrumAndBass()
                }
                macroButton(title: "RESET MIX", desc: "UNITY 0dB", isActive: false) {
                    engineManager.applyResetMix()
                }
            }
            .frame(maxWidth: .infinity)
            
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
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
        if isAcapellaActive { return "STATUS: VOCAL ISOLATION • BACKING STEMS MUTED" }
        if isInstrumentalActive { return "STATUS: INSTRUMENTAL • LEAD VOCALS MUTED" }
        if isDrumlessActive { return "STATUS: DRUMLESS PRACTICE • DRUMS MUTED" }
        if isKaraokeActive { return "STATUS: KARAOKE MODE • -12dB LEAD VOCALS" }
        if isDnBActive { return "STATUS: DRUM & BASS • VOCALS & OTHER MUTED" }
        return "STATUS: BALANCED 4-STEM MASTER • 0.0 dB UNITY GAIN"
    }
    
    private func macroButton(title: String, desc: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            action()
        }) {
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    if isActive {
                        Circle()
                            .fill(Color.black)
                            .frame(width: 4, height: 4)
                    }
                    Text(title)
                        .font(.custom("DotGothic16-Regular", size: 9.5))
                        .fontWeight(.bold)
                }
                Text(desc)
                    .font(.custom("DotGothic16-Regular", size: 7.5))
                    .opacity(isActive ? 0.85 : 0.6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(isActive ? Color.red : theme.surfaceSecondary)
            .foregroundColor(isActive ? .black : theme.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isActive ? Color.red : theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                magnitudes: engineManager.vocalEQMagnitudes,
                accentColor: theme.textPrimary
            )
            StemChannelCardView(
                index: 1,
                name: "DRUMS",
                vol: engineManager.drumVolume,
                pan: engineManager.drumPan,
                isMuted: engineManager.drumMuted,
                isSolo: engineManager.drumSolo,
                magnitudes: engineManager.drumEQMagnitudes,
                accentColor: .red
            )
            StemChannelCardView(
                index: 2,
                name: "BASS",
                vol: engineManager.bassVolume,
                pan: engineManager.bassPan,
                isMuted: engineManager.bassMuted,
                isSolo: engineManager.bassSolo,
                magnitudes: engineManager.bassEQMagnitudes,
                accentColor: .red
            )
            StemChannelCardView(
                index: 3,
                name: "OTHER",
                vol: engineManager.otherVolume,
                pan: engineManager.otherPan,
                isMuted: engineManager.otherMuted,
                isSolo: engineManager.otherSolo,
                magnitudes: engineManager.otherEQMagnitudes,
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
    let magnitudes: [Float]
    let accentColor: Color
    
    private var isAudible: Bool {
        let anySolo = engineManager.vocalSolo || engineManager.drumSolo || engineManager.bassSolo || engineManager.otherSolo
        return !isMuted && (!anySolo || isSolo)
    }
    
    private var clampedEnergy: CGFloat {
        guard engineManager.isPlaying && isAudible else { return 0.0 }
        let avg = magnitudes.reduce(0, +) / Float(max(1, magnitudes.count))
        let energy = CGFloat(avg) * 2.8
        return max(0.0, min(1.0, energy))
    }
    
    var body: some View {
        VStack(spacing: 3) {
            headerRow
            vuMeterRow
            actionsRow
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(theme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(isSolo ? Color.red : theme.hairline, lineWidth: 1)
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
                .foregroundColor(isMuted ? .red : (isSolo ? .red : theme.textMuted))
        }
    }
    
    private var vuMeterRow: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<10, id: \.self) { seg in
                let segThreshold = CGFloat(seg + 1) / 10.0
                let isLit = clampedEnergy >= segThreshold
                let isPeak = seg >= 8
                let segColor: Color = isPeak ? Color.red : (accentColor == .red ? Color.red.opacity(0.9) : theme.spectrumBarDefault)
                
                Rectangle()
                    .fill(isLit ? segColor : theme.knobArcTrack)
                    .frame(height: 5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 1))
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
                    .background(isMuted ? Color.red : theme.surfaceHover)
                    .foregroundColor(isMuted ? .black : theme.textSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(isMuted ? Color.red : theme.hairline, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            Button(action: {
                Haptics.playClick()
                engineManager.soloStem(index)
            }) {
                Text("S")
                    .font(.custom("DotGothic16-Regular", size: 8.0))
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(isSolo ? Color.red : theme.surfaceHover)
                    .foregroundColor(isSolo ? .black : theme.textSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(isSolo ? Color.red : theme.hairline, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Studio Telemetry HUD Diagnostics View
struct StudioTelemetryHUDView: View {
    @Environment(AudioEngineManager.self) private var engineManager
    @State private var theme = ThemeManager.shared
    
    var body: some View {
        HStack(spacing: 6) {
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
                title: "NEURAL ENGINE (ANE)",
                line1: "\(AudioEngineManager.systemChipName)",
                line2: engineManager.isPlaying ? "REALTIME ACTIVE • 5.1x" : "STANDBY • READY"
            )
            
            telemetryCard(
                title: "TIMECODE & BYPASS",
                line1: engineManager.detailedTimecode,
                line2: engineManager.isBypassed ? "BYPASS: ON (ORIGINAL)" : "BYPASS: OFF (4-STEMS)"
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    
    private func telemetryCard(title: String, line1: String, line2: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 3.5, height: 3.5)
                Text(title)
                    .font(.custom("DotGothic16-Regular", size: 8.0))
                    .foregroundColor(.red.opacity(0.9))
                Spacer()
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
    @State private var theme = ThemeManager.shared
    
    @State private var selectedStemIndex: Int = 0 // 0: VOCALS, 1: DRUMS, 2: BASS, 3: OTHER, 4: MASTER
    @State private var draggingBand: Int? = nil
    
    private let stemNames = ["VOCALS", "DRUMS", "BASS", "OTHER", "MASTER"]
    
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
    
    var body: some View {
        VStack(spacing: 4) {
            // Top Toolbar: Stem Pills, Preset Quick Actions, Bypass & Reset
            HStack(spacing: 6) {
                // Stem Selectors
                HStack(spacing: 2) {
                    ForEach(0..<stemNames.count, id: \.self) { idx in
                        Button(action: {
                            Haptics.playClick()
                            selectedStemIndex = idx
                        }) {
                            Text(stemNames[idx])
                                .font(.custom("DotGothic16-Regular", size: 7.5))
                                .fontWeight(selectedStemIndex == idx ? .bold : .regular)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(selectedStemIndex == idx ? Color.red : theme.surfaceSecondary)
                                .foregroundColor(selectedStemIndex == idx ? .black : theme.textPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(selectedStemIndex == idx ? Color.red : theme.hairline, lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                Spacer()
                
                // Readout of currently selected stem's gains
                HStack(spacing: 4) {
                    Text("L: \(formatGain(currentLow))")
                        .font(.custom("DotGothic16-Regular", size: 8))
                        .foregroundColor(abs(currentLow) > 0.1 ? .red : theme.textMuted)
                    Text("M: \(formatGain(currentMid))")
                        .font(.custom("DotGothic16-Regular", size: 8))
                        .foregroundColor(abs(currentMid) > 0.1 ? .red : theme.textMuted)
                    Text("H: \(formatGain(currentHigh))")
                        .font(.custom("DotGothic16-Regular", size: 8))
                        .foregroundColor(abs(currentHigh) > 0.1 ? .red : theme.textMuted)
                }
                .padding(.horizontal, 4)
                
                // Presets Dropdown Menu
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
                
                // Bypass Button
                Button(action: {
                    engineManager.toggleStemEQBypass(selectedStemIndex)
                }) {
                    HStack(spacing: 2.5) {
                        Circle()
                            .fill(isCurrentBypassed ? theme.textMuted.opacity(0.5) : Color.red)
                            .frame(width: 4, height: 4)
                        Text(isCurrentBypassed ? "BYP" : "ACTIVE")
                            .font(.custom("DotGothic16-Regular", size: 7.5))
                            .foregroundColor(isCurrentBypassed ? theme.textMuted : theme.textPrimary)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(isCurrentBypassed ? theme.surfaceSecondary : Color.red.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(isCurrentBypassed ? theme.hairline : Color.red.opacity(0.4), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                
                // Reset Button
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
                }
                .buttonStyle(.plain)
                .help("Reset to 0.0 dB")
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
                
                ZStack {
                    // 1. Grid lines & labels
                    gridLines(w: w, h: h, midY: midY, x100: x100, x1k: x1k, x10k: x10k)
                    
                    // 2. Real-time FFT Backdrop
                    fftBackdrop(w: w, h: h)
                    
                    // 3. Mathematical Biquad Curve Path
                    curvePath(w: w, h: h, midY: midY)
                        .fill(
                            LinearGradient(
                                colors: [
                                    isCurrentBypassed ? Color.gray.opacity(0.08) : Color.red.opacity(0.20),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    
                    curvePath(w: w, h: h, midY: midY)
                        .stroke(
                            isCurrentBypassed ? Color.gray.opacity(0.4) : Color.red,
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
            .foregroundColor(theme.textMuted.opacity(0.7))
            .position(x: x100, y: h - 5)
        Text("1kHz")
            .font(.custom("DotGothic16-Regular", size: 6.5))
            .foregroundColor(theme.textMuted.opacity(0.7))
            .position(x: x1k, y: h - 5)
        Text("10kHz")
            .font(.custom("DotGothic16-Regular", size: 6.5))
            .foregroundColor(theme.textMuted.opacity(0.7))
            .position(x: x10k, y: h - 5)
    }
    
    @ViewBuilder
    private func fftBackdrop(w: CGFloat, h: CGFloat) -> some View {
        let mags: [Float] = {
            switch selectedStemIndex {
            case 0: return engineManager.vocalEQMagnitudes
            case 1: return engineManager.drumEQMagnitudes
            case 2: return engineManager.bassEQMagnitudes
            case 3: return engineManager.otherEQMagnitudes
            default: return engineManager.masterEQMagnitudes
            }
        }()
        
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
                        .stroke(isDragging ? theme.textPrimary : (isModified ? Color.red : theme.textSecondary), lineWidth: 1.5)
                )
            
            Circle()
                .fill(isModified ? Color.red : theme.textPrimary)
                .frame(width: 6, height: 6)
            
            Text(isDragging ? String(format: "%+.1fdB", gain) : name)
                .font(.custom("DotGothic16-Regular", size: 6.5))
                .foregroundColor(isModified ? .red : theme.textPrimary)
                .offset(y: y < midY ? 12 : -12)
        }
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .position(x: x, y: y)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { val in
                    draggingBand = bandIndex
                    let deltaY = -Float(val.translation.height) * 0.25
                    let baseGain: Float = {
                        switch bandIndex {
                        case 0: return currentLow
                        case 1: return currentMid
                        case 2: return currentHigh
                        default: return 0.0
                        }
                    }()
                    var target = max(-12.0, min(12.0, baseGain + deltaY))
                    if abs(target) < 0.25 {
                        target = 0.0
                        Haptics.playAlignment()
                    }
                    applyGainToBand(bandIndex, val: target)
                }
                .onEnded { _ in
                    draggingBand = nil
                }
        )
        .onTapGesture(count: 2) {
            Haptics.playAlignment()
            applyGainToBand(bandIndex, val: 0.0)
        }
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
                        .fill(Color.red)
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
                .onHover { isCloseHovered = $0 }
            }
            
            Divider()
                .background(theme.hairline)
            
            VStack(alignment: .leading, spacing: 8) {
                hudRow(keys: ["1", "2", "3", "4"], action: "Exclusive Solo Vocals, Drums, Bass, Other")
                hudRow(keys: ["V", "D", "B", "O"], action: "Toggle Mute for individual channels")
                hudRow(keys: ["⌘1", "⌘2", "⌘3", "⌘4"], action: "Switch HUD: FFT, Macros, Balance, Telemetry")
                hudRow(keys: ["[", "]"], action: "Set A-B Loop Start and End points on the fly")
                hudRow(keys: ["L"], action: "Toggle A-B Region Loop On / Off")
                hudRow(keys: ["A", "I", "R"], action: "Acapella, Instrumental, Reset Unity Mix")
                hudRow(keys: ["Space"], action: "Play / Pause playback")
                hudRow(keys: ["B"], action: "Toggle Bypass (Original vs Separated Stems)")
                hudRow(keys: ["E"], action: "Export 4-Stem Audio Archive")
                hudRow(keys: ["⌘", "O"], action: "Import / Batch Import audio tracks")
                hudRow(keys: ["?"], action: "Toggle this Shortcut Cheat Sheet")
            }
        }
        .padding(22)
        .frame(width: 500)
        .background(theme.modalBackground)
        .border(theme.cardBorder, width: 1)
        .overlay(CornerBrackets())
        .shadow(color: theme.isDark ? Color.black : Color.black.opacity(0.15), radius: 30, x: 0, y: 10)
    }
    
    private func hudRow(keys: [String], action: String) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.custom("DotGothic16-Regular", size: 11))
                        .fontWeight(.bold)
                        .foregroundColor(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.red.opacity(0.4), lineWidth: 1)
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
