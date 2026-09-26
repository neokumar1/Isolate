import SwiftUI
import AppKit

// MARK: - Persistent App Settings Model
@MainActor
@Observable
public final class AppSettings {
    public static let shared = AppSettings()
    
    public var defaultExportFormat: String {
        didSet {
            AppPreferences.defaults.set(defaultExportFormat, forKey: "defaultExportFormat")
        }
    }
    
    public var hardwareTheme: String {
        didSet {
            AppPreferences.defaults.set(hardwareTheme, forKey: "hardwareTheme")
            ThemeManager.shared.applyTheme(HardwareTheme(rawValue: hardwareTheme) ?? .system)
            Haptics.playClick()
        }
    }
    
    public var isMenuBarMiniPlayerEnabled: Bool {
        didSet {
            AppPreferences.defaults.set(!isMenuBarMiniPlayerEnabled, forKey: "isMenuBarDisabled")
            let enabled = isMenuBarMiniPlayerEnabled
            Task { @MainActor in
                MenuBarManager.shared.setEnabled(enabled)
            }
            if isMenuBarMiniPlayerEnabled {
                Haptics.playClick()
            }
        }
    }
    
    public var isHapticsEnabled: Bool {
        didSet {
            AppPreferences.defaults.set(!isHapticsEnabled, forKey: "isHapticsDisabled")
            if isHapticsEnabled {
                Haptics.playClick()
            }
        }
    }
    
    public var isAutoPlayOnSelect: Bool {
        didSet {
            AppPreferences.defaults.set(!isAutoPlayOnSelect, forKey: "isAutoPlayDisabled")
        }
    }
    
    public var waveformSensitivity: Double {
        didSet {
            AppPreferences.defaults.set(waveformSensitivity, forKey: "waveformSensitivity")
        }
    }
    
    private init() {
        self.defaultExportFormat = AudioExporter.Format(rawValue: AppPreferences.defaults.string(forKey: "defaultExportFormat") ?? "WAV")?.rawValue ?? "WAV"
        self.hardwareTheme = AppPreferences.defaults.string(forKey: "hardwareTheme") ?? "system"
        self.isMenuBarMiniPlayerEnabled = !AppPreferences.defaults.bool(forKey: "isMenuBarDisabled")
        self.isHapticsEnabled = !AppPreferences.defaults.bool(forKey: "isHapticsDisabled")
        self.isAutoPlayOnSelect = !AppPreferences.defaults.bool(forKey: "isAutoPlayDisabled")
        let savedSensitivity = AppPreferences.defaults.double(forKey: "waveformSensitivity")
        self.waveformSensitivity = savedSensitivity > 0 ? savedSensitivity : 1.0
    }
    
    public func reloadFromStorage() {
        self.defaultExportFormat = AudioExporter.Format(rawValue: AppPreferences.defaults.string(forKey: "defaultExportFormat") ?? "WAV")?.rawValue ?? "WAV"
        self.hardwareTheme = AppPreferences.defaults.string(forKey: "hardwareTheme") ?? "system"
        self.isMenuBarMiniPlayerEnabled = !AppPreferences.defaults.bool(forKey: "isMenuBarDisabled")
        self.isHapticsEnabled = !AppPreferences.defaults.bool(forKey: "isHapticsDisabled")
        self.isAutoPlayOnSelect = !AppPreferences.defaults.bool(forKey: "isAutoPlayDisabled")
        let savedSensitivity = AppPreferences.defaults.double(forKey: "waveformSensitivity")
        self.waveformSensitivity = savedSensitivity > 0 ? savedSensitivity : 1.0
    }
    
    public func resetToDefaults() {
        defaultExportFormat = "WAV"
        hardwareTheme = "system"
        isMenuBarMiniPlayerEnabled = true
        isHapticsEnabled = true
        isAutoPlayOnSelect = true
        waveformSensitivity = 1.0
        Task { @MainActor in
            MenuBarManager.shared.setEnabled(true)
        }
        ThemeManager.shared.applyTheme(.system)
        Haptics.playClick()
    }
}

// MARK: - Settings & Shortcuts Modal Card
struct SettingsModalCard: View {
    let onDismiss: () -> Void
    
    @State private var selectedTab: Int = 0 // 0 = Settings, 1 = Shortcuts
    @Bindable private var settings = AppSettings.shared
    @Bindable private var theme = ThemeManager.shared
    @State private var isCloseHovered = false
    @State private var isResetHovered = false
    
    var body: some View {
        VStack(spacing: 16) {
            // Header: Title & Tab Switcher
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(theme.textPrimary)
                    Text("SYSTEM PREFERENCES")
                        .font(.custom("DotGothic16-Regular", size: 18))
                        .fontWeight(.bold)
                        .foregroundColor(theme.textPrimary)
                }
                
                Spacer()
                
                // Tab Switcher [ SETTINGS | SHORTCUTS ]
                HStack(spacing: 4) {
                    Button(action: {
                        Haptics.playClick()
                        selectedTab = 0
                    }) {
                        Text("SETTINGS")
                            .font(.custom("DotGothic16-Regular", size: 12))
                            .fontWeight(.bold)
                            .foregroundColor(selectedTab == 0 ? theme.background : theme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(selectedTab == 0 ? theme.textPrimary : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedTab == 0 ? .isSelected : [])
                    
                    Button(action: {
                        Haptics.playClick()
                        selectedTab = 1
                    }) {
                        Text("SHORTCUTS")
                            .font(.custom("DotGothic16-Regular", size: 12))
                            .fontWeight(.bold)
                            .foregroundColor(selectedTab == 1 ? theme.background : theme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(selectedTab == 1 ? theme.textPrimary : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedTab == 1 ? .isSelected : [])
                }
                .padding(3)
                .background(theme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            
            Divider()
                .background(theme.hairline)
            
            // Content Area based on Tab — Pinned to exact height of 345pt for rock-solid consistency.
            // The shortcut list is taller than that, so it scrolls instead of clipping.
            Group {
                if selectedTab == 0 {
                    settingsTabContent
                } else {
                    ScrollView(.vertical) {
                        shortcutsTabContent
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 16)
                    }
                    // Fade the bottom edge so the list reads as scrollable.
                    .mask(
                        VStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 16)
                        }
                    )
                }
            }
            .frame(height: 345, alignment: .top)
            
            Divider()
                .background(theme.hairline)
            
            // Footer: Reset & Close Buttons — Pinned height of 32pt
            HStack {
                if selectedTab == 0 {
                    Button(action: {
                        settings.resetToDefaults()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11))
                            Text("RESET DEFAULTS")
                                .font(.custom("DotGothic16-Regular", size: 12))
                        }
                        .foregroundColor(isResetHovered ? theme.textPrimary : theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isResetHovered ? theme.surfaceHover : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(isResetHovered ? theme.border : theme.hairline, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering && !isResetHovered { Haptics.playClick() }
                        isResetHovered = hovering
                    }
                } else {
                    Spacer().frame(width: 1)
                }
                
                Spacer()
                
                Button(action: {
                    Haptics.playClick()
                    onDismiss()
                }) {
                    Text("CLOSE")
                        .font(.custom("DotGothic16-Regular", size: 13))
                        .fontWeight(.bold)
                        .foregroundColor(theme.background)
                        .frame(width: 100, height: 32)
                        .background(isCloseHovered ? theme.textPrimary.opacity(0.85) : theme.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .onHover { hovering in
                    if hovering && !isCloseHovered { Haptics.playClick() }
                    isCloseHovered = hovering
                }
            }
            .frame(height: 32)
        }
        .onExitCommand(perform: onDismiss)
        .padding(24)
        .frame(width: 540, height: 510) // Constant width and height for complete visual consistency
        .background(theme.modalBackground)
        .compositingGroup()
        .border(theme.cardBorder, width: 1)
        .overlay(CornerBrackets())
        .shadow(color: theme.isDark ? Color.black : Color.black.opacity(0.25), radius: 24, x: 0, y: 8)
    }
    
    // MARK: - Settings Tab Content
    private var settingsTabContent: some View {
        VStack(spacing: 14) {
            // Setting 1: Hardware Finish (Match System, Nothing Dark, Nothing Light)
            settingRow(
                title: "HARDWARE FINISH",
                subtitle: "Industrial design theme aesthetic"
            ) {
                HStack(spacing: 5) {
                    themeButton("system", label: "MATCH SYSTEM")
                    themeButton("dark", label: "NOTHING DARK")
                    themeButton("light", label: "NOTHING LIGHT")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Theme")
            }
            
            // Setting 2: Default Export Format
            settingRow(
                title: "EXPORT BUNDLE FORMAT",
                subtitle: "Preferred audio container for isolated stem archives"
            ) {
                HStack(spacing: 5) {
                    exportFormatButton("WAV", label: "WAV 24B")
                    exportFormatButton("FLAC", label: "FLAC")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Export format")
            }
            
            // Setting 3: Menu Bar Mini Player
            settingRow(
                title: "MENU BAR MINI CONTROLLER",
                subtitle: "Discreet macOS status bar item with quick stem controls"
            ) {
                toggleSwitch("Menu bar controller", isOn: Binding(
                    get: { settings.isMenuBarMiniPlayerEnabled },
                    set: { newVal in
                        settings.isMenuBarMiniPlayerEnabled = newVal
                        MenuBarManager.shared.setEnabled(newVal)
                    }
                ))
            }
            
            // Setting 4: Haptic Feedback
            settingRow(
                title: "TACTILE HAPTICS",
                subtitle: "Physical haptic feedback on clicks, faders, and buttons"
            ) {
                toggleSwitch("Haptic feedback", isOn: $settings.isHapticsEnabled)
            }
            
            // Setting 5: Auto-Play on Select
            settingRow(
                title: "AUTO-PLAY ON SELECT",
                subtitle: "Automatically start playback when clicking a track in Library"
            ) {
                toggleSwitch("Auto-play on select", isOn: $settings.isAutoPlayOnSelect)
            }
            
            // Setting 6: Waveform Sensitivity
            settingRow(
                title: "WAVEFORM SENSITIVITY",
                subtitle: "Dynamic height multiplier for master & stem waveforms"
            ) {
                HStack(spacing: 6) {
                    sensitivityButton(0.7, label: "0.7x")
                    sensitivityButton(1.0, label: "1.0x STD")
                    sensitivityButton(1.5, label: "1.5x")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Waveform sensitivity")
            }
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Shortcuts Tab Content
    private var shortcutsTabContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            shortcutRow(keys: ["Space"], description: "Play / Pause playback")
            shortcutRow(keys: ["1", "2", "3", "4"], description: "Solo Vocals, Drums, Bass, Other (Exclusive)")
            shortcutRow(keys: ["V", "D", "B", "O"], description: "Toggle Mute for individual channels")
            shortcutRow(keys: ["A"], description: "Engage Acapella Preset (Solo Vocals)")
            shortcutRow(keys: ["I"], description: "Engage Instrumental Preset (Mute Vocals)")
            shortcutRow(keys: ["R"], description: "Reset 4-Stem Mix to 100% Unity Gain")
            shortcutRow(keys: ["L"], description: "Toggle A-B Region Loop")
            shortcutRow(keys: ["[", "]"], description: "Set A-B Loop Start / End at the playhead")
            shortcutRow(keys: ["⌥", "L"], description: "Clear A-B Loop Markers")
            shortcutRow(keys: ["⌘", "1-5"], description: "Switch HUD: FFT, Macros, Balance, Telemetry, EQ")
            shortcutRow(keys: ["⌘", "E"], description: "Bypass All EQ (Stems + Master)")
            shortcutRow(keys: ["⌘", "⌥", "B"], description: "Compare Original and Stem Mix")
            shortcutRow(keys: ["⌘", "⇧", "E"], description: "Export 4-Stem Audio Archive")
            shortcutRow(keys: ["⌘", "⇧", "M"], description: "Export Current Mix as WAV")
            shortcutRow(keys: ["⌘", "O"], description: "Import / Batch Import audio tracks")
            shortcutRow(keys: ["⌘", "B"], description: "Toggle Library Sidebar")
            shortcutRow(keys: ["⌘", ","], description: "Open Settings")
            shortcutRow(keys: ["⌘", "0"], description: "Show the Isolate Window")
            shortcutRow(keys: ["?"], description: "Toggle the Shortcut Cheat Sheet")
            shortcutRow(keys: ["Esc"], description: "Close the open panel")
            shortcutRow(keys: ["←", "→", "↑", "↓"], description: "Adjust the focused fader, knob, pan or seek bar")
            shortcutRow(keys: ["Double-Click"], description: "Reset fader, pan, EQ, pitch or speed")
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - UI Helpers
    private func settingRow<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.custom("DotGothic16-Regular", size: 13))
                    .foregroundColor(theme.textPrimary)
                Text(subtitle)
                    .font(.custom("DotGothic16-Regular", size: 10))
                    .foregroundColor(theme.textSecondary)
            }
            
            Spacer()
            
            content()
        }
    }
    
    private func exportFormatButton(_ format: String, label: String) -> some View {
        let isSelected = settings.defaultExportFormat == format
        return Button(action: {
            Haptics.playClick()
            settings.defaultExportFormat = format
        }) {
            Text(label)
                .font(.custom("DotGothic16-Regular", size: 10.5))
                .fontWeight(.bold)
                .foregroundColor(isSelected ? theme.background : theme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(isSelected ? theme.textPrimary : theme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isSelected ? theme.textPrimary : theme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
    
    private func themeButton(_ themeName: String, label: String) -> some View {
        let isSelected = settings.hardwareTheme == themeName
        return Button(action: {
            Haptics.playClick()
            settings.hardwareTheme = themeName
            ThemeManager.shared.currentTheme = HardwareTheme(rawValue: themeName) ?? .system
        }) {
            Text(label)
                .font(.custom("DotGothic16-Regular", size: 10))
                .fontWeight(.bold)
                .foregroundColor(isSelected ? theme.background : theme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(isSelected ? theme.textPrimary : theme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isSelected ? theme.textPrimary : theme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
    
    private func sensitivityButton(_ value: Double, label: String) -> some View {
        let isSelected = abs(settings.waveformSensitivity - value) < 0.05
        return Button(action: {
            Haptics.playClick()
            settings.waveformSensitivity = value
        }) {
            Text(label)
                .font(.custom("DotGothic16-Regular", size: 10))
                .fontWeight(.bold)
                .foregroundColor(isSelected ? theme.background : theme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(isSelected ? theme.textPrimary : theme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isSelected ? theme.textPrimary : theme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
    
    private func toggleSwitch(_ label: String, isOn: Binding<Bool>) -> some View {
        Button(action: {
            Haptics.playClick()
            isOn.wrappedValue.toggle()
        }) {
            HStack(spacing: 0) {
                Text("ON")
                    .font(.custom("DotGothic16-Regular", size: 10))
                    .fontWeight(.bold)
                    .foregroundColor(isOn.wrappedValue ? theme.onAccent : theme.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isOn.wrappedValue ? theme.accentRed : Color.clear)
                
                Text("OFF")
                    .font(.custom("DotGothic16-Regular", size: 10))
                    .fontWeight(.bold)
                    .foregroundColor(!isOn.wrappedValue ? theme.textPrimary : theme.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(!isOn.wrappedValue ? theme.surfaceSecondary : Color.clear)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(theme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }
    
    private func shortcutRow(keys: [String], description: String) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    if key == "+" {
                        Text("+")
                            .font(.custom("DotGothic16-Regular", size: 11))
                            .foregroundColor(theme.textSecondary)
                    } else {
                        Text(key)
                            .font(.custom("DotGothic16-Regular", size: 11))
                            .fontWeight(.bold)
                            .foregroundColor(theme.textPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(theme.surfaceSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(theme.border, lineWidth: 1)
                            )
                    }
                }
            }
            .frame(width: 140, alignment: .leading)
            
            Text(description)
                .font(.custom("DotGothic16-Regular", size: 12))
                .foregroundColor(theme.textPrimary)
            
            Spacer()
        }
    }
}
