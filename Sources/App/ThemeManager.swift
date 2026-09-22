import SwiftUI
import AppKit

public enum HardwareTheme: String, CaseIterable, Identifiable {
    case system = "system"
    case dark = "dark"
    case light = "light"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .system: return "MATCH SYSTEM"
        case .dark: return "NOTHING DARK"
        case .light: return "NOTHING LIGHT"
        }
    }
}

@MainActor
@Observable
public final class ThemeManager {
    public static let shared = ThemeManager()
    
    public var currentTheme: HardwareTheme = .system {
        didSet {
            AppPreferences.defaults.set(currentTheme.rawValue, forKey: "hardwareTheme")
            updateWindowAppearance()
        }
    }
    
    /// Tracks system dark/light appearance changes
    public var systemIsDark: Bool = true
    
    private init() {
        let saved = AppPreferences.defaults.string(forKey: "hardwareTheme") ?? "system"
        self.currentTheme = HardwareTheme(rawValue: saved) ?? .system
        self.systemIsDark = checkSystemIsDark()
        setupAppearanceObserver()
    }
    
    public func applyTheme(_ theme: HardwareTheme) {
        currentTheme = theme
    }
    
    private func checkSystemIsDark() -> Bool {
        Self.systemAppearanceIsDark(NSApp?.effectiveAppearance)
    }

    /// `ThemeManager.shared` is initialized before an `NSApplication` exists in
    /// some test-host and command-line launch paths. Treat an unavailable
    /// appearance as dark until AppKit has finished creating the application.
    static func systemAppearanceIsDark(_ appearance: NSAppearance?) -> Bool {
        guard let best = appearance?.bestMatch(from: [.aqua, .darkAqua]) else {
            return true
        }
        return best == .darkAqua
    }
    
    private func setupAppearanceObserver() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.systemIsDark = self.checkSystemIsDark()
                self.updateWindowAppearance()
            }
        }
    }
    
    public var isDark: Bool {
        switch currentTheme {
        case .dark: return true
        case .light: return false
        case .system: return systemIsDark
        }
    }
    
    public var preferredColorScheme: ColorScheme? {
        switch currentTheme {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
    
    public func updateWindowAppearance() {
        systemIsDark = checkSystemIsDark()
        let appearance: NSAppearance? = switch currentTheme {
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
        for window in NSApp?.windows ?? [] { window.appearance = appearance }
    }

    // MARK: - Semantic Nothing Hardware Design Tokens
    
    // Backgrounds
    public var background: Color {
        isDark ? Color.black : Color(red: 0.93, green: 0.93, blue: 0.94)
    }
    
    public var surface: Color {
        isDark ? Color(red: 0.05, green: 0.05, blue: 0.06) : Color.white
    }
    
    public var surfaceSecondary: Color {
        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
    }
    
    public var surfaceHover: Color {
        isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }
    
    // Text
    public var textPrimary: Color {
        isDark ? Color.white : Color(red: 0.08, green: 0.08, blue: 0.09)
    }
    
    public var textSecondary: Color {
        isDark ? Color.gray : Color(red: 0.46, green: 0.46, blue: 0.49)
    }
    
    public var textMuted: Color {
        isDark ? Color.gray.opacity(0.5) : Color.black.opacity(0.35)
    }
    
    // Borders & Hairlines
    public var hairline: Color {
        isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
    }
    
    public var border: Color {
        isDark ? Color.white.opacity(0.20) : Color.black.opacity(0.20)
    }
    
    public var cardBorder: Color {
        isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.14)
    }
    
    // Overlays & Modals
    public var modalBackdrop: Color {
        isDark ? Color.black.opacity(0.85) : Color.black.opacity(0.40)
    }
    
    public var modalBackground: Color {
        isDark ? Color(red: 0.05, green: 0.05, blue: 0.06) : Color(white: 0.98)
    }
    
    // Hardware elements
    public var accentRed: Color {
        Color.red
    }
    
    public var knobFace: Color {
        isDark ? Color(white: 0.08) : Color(white: 0.93)
    }
    
    public var knobArcTrack: Color {
        isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
    }
    
    public var faderTrack: Color {
        isDark ? Color(white: 0.08) : Color(white: 0.86)
    }
    
    public var faderThumb: Color {
        isDark ? Color(white: 0.96) : Color(white: 0.14)
    }
    
    public var faderThumbStroke: Color {
        isDark ? Color.white.opacity(0.40) : Color.black.opacity(0.35)
    }
    
    public var faderThumbKnurling: Color {
        isDark ? Color(white: 0.70) : Color(white: 0.50)
    }
    
    public var spectrumBarDefault: Color {
        isDark ? Color.white.opacity(0.85) : Color(white: 0.18)
    }
}
