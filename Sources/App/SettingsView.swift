import SwiftUI
import AppKit

// MARK: - Persistent App Settings Model
@Observable
public final class AppSettings {
    public static let shared = AppSettings()
    
    public var defaultExportFormat: String {
        didSet {
            UserDefaults.standard.set(defaultExportFormat, forKey: "defaultExportFormat")
            UserDefaults.standard.synchronize()
        }
    }
    
    public var hardwareTheme: String {
        didSet {
            UserDefaults.standard.set(hardwareTheme, forKey: "hardwareTheme")
            UserDefaults.standard.synchronize()
            ThemeManager.shared.applyTheme(HardwareTheme(rawValue: hardwareTheme) ?? .system)
            Haptics.playClick()
        }
    }
    
    public var isMenuBarMiniPlayerEnabled: Bool {
        didSet {
            UserDefaults.standard.set(!isMenuBarMiniPlayerEnabled, forKey: "isMenuBarDisabled")
            UserDefaults.standard.synchronize()
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
            UserDefaults.standard.set(!isHapticsEnabled, forKey: "isHapticsDisabled")
            UserDefaults.standard.synchronize()
            if isHapticsEnabled {
                Haptics.playClick()
            }
        }
    }
    
    public var isAutoPlayOnSelect: Bool {
        didSet {
            UserDefaults.standard.set(!isAutoPlayOnSelect, forKey: "isAutoPlayDisabled")
            UserDefaults.standard.synchronize()
        }
    }
    
    public var waveformSensitivity: Double {
        didSet {
            UserDefaults.standard.set(waveformSensitivity, forKey: "waveformSensitivity")
            UserDefaults.standard.synchronize()
        }
    }
    
    private init() {
        self.defaultExportFormat = UserDefaults.standard.string(forKey: "defaultExportFormat") ?? "WAV"
        self.hardwareTheme = UserDefaults.standard.string(forKey: "hardwareTheme") ?? "system"
        self.isMenuBarMiniPlayerEnabled = !UserDefaults.standard.bool(forKey: "isMenuBarDisabled")
        self.isHapticsEnabled = !UserDefaults.standard.bool(forKey: "isHapticsDisabled")
        self.isAutoPlayOnSelect = !UserDefaults.standard.bool(forKey: "isAutoPlayDisabled")
        let savedSensitivity = UserDefaults.standard.double(forKey: "waveformSensitivity")
        self.waveformSensitivity = savedSensitivity > 0 ? savedSensitivity : 1.0
    }
    
    public func reloadFromStorage() {
        self.defaultExportFormat = UserDefaults.standard.string(forKey: "defaultExportFormat") ?? "WAV"
        self.hardwareTheme = UserDefaults.standard.string(forKey: "hardwareTheme") ?? "system"
        self.isMenuBarMiniPlayerEnabled = !UserDefaults.standard.bool(forKey: "isMenuBarDisabled")
        self.isHapticsEnabled = !UserDefaults.standard.bool(forKey: "isHapticsDisabled")
        self.isAutoPlayOnSelect = !UserDefaults.standard.bool(forKey: "isAutoPlayDisabled")
        let savedSensitivity = UserDefaults.standard.double(forKey: "waveformSensitivity")
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
                        .foregroundColor(.red)
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
                            .foregroundColor(selectedTab == 0 ? (theme.isDark ? .black : .white) : theme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(selectedTab == 0 ? (theme.isDark ? Color.white : Color.black) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: {
                        Haptics.playClick()
                        selectedTab = 1
                    }) {
                        Text("SHORTCUTS")
                            .font(.custom("DotGothic16-Regular", size: 12))
                            .fontWeight(.bold)
                            .foregroundColor(selectedTab == 1 ? (theme.isDark ? .black : .white) : theme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(selectedTab == 1 ? (theme.isDark ? Color.white : Color.black) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                }
                .padding(3)
                .background(theme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            
            Divider()
                .background(theme.hairline)
            
            // Content Area based on Tab — Pinned to exact height of 345pt for rock-solid consistency
            Group {
                if selectedTab == 0 {
                    settingsTabContent
                } else {
                    shortcutsTabContent
                }
            }
            .frame(height: 345)
            .clipped()
            
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
                        .background(isResetHovered ? theme.surfaceHover : Color.clear)
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
                        .foregroundColor(.white)
                        .frame(width: 100, height: 32)
                        .background(isCloseHovered ? Color.red.opacity(0.85) : Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering && !isCloseHovered { Haptics.playClick() }
                    isCloseHovered = hovering
                }
            }
            .frame(height: 32)
        }
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
            }
            
            // Setting 2: Default Export Format
            settingRow(
                title: "EXPORT BUNDLE FORMAT",
                subtitle: "Preferred audio container for isolated stem archives"
            ) {
                HStack(spacing: 5) {
                    exportFormatButton("WAV", label: "WAV 24B")
                    exportFormatButton("MP3", label: "MP3 320K")
                    exportFormatButton("FLAC", label: "FLAC")
                    exportFormatButton("ALL", label: "ALL ZIP")
                }
            }
            
            // Setting 3: Menu Bar Mini Player
            settingRow(
                title: "MENU BAR MINI CONTROLLER",
                subtitle: "Discreet macOS status bar item with quick stem controls"
            ) {
                toggleSwitch(isOn: Binding(
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
                toggleSwitch(isOn: $settings.isHapticsEnabled)
            }
            
            // Setting 5: Auto-Play on Select
            settingRow(
                title: "AUTO-PLAY ON SELECT",
                subtitle: "Automatically start playback when clicking a track in Library"
            ) {
                toggleSwitch(isOn: $settings.isAutoPlayOnSelect)
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
            }
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Shortcuts Tab Content
    private var shortcutsTabContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            shortcutRow(keys: ["1", "2", "3", "4"], description: "Solo Vocals, Drums, Bass, Other (Exclusive)")
            shortcutRow(keys: ["V", "D", "B", "O"], description: "Toggle Mute for individual channels")
            shortcutRow(keys: ["A"], description: "Engage Acapella Preset (Solo Vocals)")
            shortcutRow(keys: ["I"], description: "Engage Instrumental Preset (Mute Vocals)")
            shortcutRow(keys: ["R"], description: "Reset 4-Stem Mix to 100% Unity Gain")
            shortcutRow(keys: ["L"], description: "Toggle A-B Region Loop")
            shortcutRow(keys: ["Space"], description: "Play / Pause playback")
            shortcutRow(keys: ["B"], description: "Toggle Bypass (Original vs Separated Stems)")
            shortcutRow(keys: ["E"], description: "Export 4-Stem Audio Archive")
            shortcutRow(keys: ["⌘", "O"], description: "Import / Batch Import audio tracks")
            shortcutRow(keys: ["Tab"], description: "Toggle Library Sidebar")
            shortcutRow(keys: ["Double-Click"], description: "Reset fader or pan dial to Center")
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
                .foregroundColor(isSelected ? .white : theme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(isSelected ? Color.red : theme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isSelected ? Color.red : theme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
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
                .foregroundColor(isSelected ? .white : theme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(isSelected ? Color.red : theme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isSelected ? Color.red : theme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
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
                .foregroundColor(isSelected ? .white : theme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(isSelected ? Color.red : theme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isSelected ? Color.red : theme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
    
    private func toggleSwitch(isOn: Binding<Bool>) -> some View {
        Button(action: {
            Haptics.playClick()
            isOn.wrappedValue.toggle()
        }) {
            HStack(spacing: 0) {
                Text("ON")
                    .font(.custom("DotGothic16-Regular", size: 10))
                    .fontWeight(.bold)
                    .foregroundColor(isOn.wrappedValue ? .white : theme.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isOn.wrappedValue ? Color.red : Color.clear)
                
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
                            .foregroundColor(.red)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.red.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.red.opacity(0.4), lineWidth: 1)
                            )
                    }
                }
            }
            .frame(width: 140, alignment: .leading)
            
            Text(description)
                .font(.custom("DotGothic16-Regular", size: 12))
                .foregroundColor(theme.textPrimary.opacity(0.88))
            
            Spacer()
        }
    }
}
