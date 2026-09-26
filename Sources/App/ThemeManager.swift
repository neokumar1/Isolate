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

    /// Mirrors System Settings > Accessibility > Display > Increase contrast.
    public var increaseContrast: Bool = false

    private init() {
        let saved = AppPreferences.defaults.string(forKey: "hardwareTheme") ?? "system"
        self.currentTheme = HardwareTheme(rawValue: saved) ?? .system
        self.systemIsDark = checkSystemIsDark()
        self.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
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
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
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
        // The status item must follow the menu bar, not the app theme, or its
        // template glyph disappears against a menu bar of the opposite appearance.
        for window in NSApp?.windows ?? [] where !window.className.hasPrefix("NSStatusBar") {
            window.appearance = appearance
        }
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
    
    // Text. Readable text uses textPrimary, textSecondary, or textMuted, each at
    // least 4.5:1 against the backgrounds and channel-strip fills in its mode.
    public var textPrimary: Color {
        isDark ? Color.white : Color(red: 0.08, green: 0.08, blue: 0.09)
    }

    public var textSecondary: Color {
        if increaseContrast { return textPrimary }
        return isDark ? Color(white: 0.66) : Color(red: 0.30, green: 0.30, blue: 0.32)
    }

    public var textMuted: Color {
        if increaseContrast { return textSecondary }
        return isDark ? Color(red: 0.52, green: 0.52, blue: 0.54) : Color(red: 0.39, green: 0.39, blue: 0.41)
    }

    /// Disabled controls and purely decorative marks only; never information.
    public var textDisabled: Color {
        isDark ? Color.gray.opacity(0.5) : Color.black.opacity(0.35)
    }

    /// Caution states such as original-master comparison and loop markers.
    public var warning: Color {
        isDark ? Color(red: 0.83, green: 0.66, blue: 0.26) : Color(red: 0.49, green: 0.34, blue: 0.0)
    }

    // Borders & Hairlines
    public var hairline: Color {
        let opacity = increaseContrast ? 0.45 : 0.12
        return isDark ? Color.white.opacity(opacity) : Color.black.opacity(opacity)
    }

    public var border: Color {
        let opacity = increaseContrast ? 0.55 : 0.20
        return isDark ? Color.white.opacity(opacity) : Color.black.opacity(opacity)
    }

    public var cardBorder: Color {
        if increaseContrast { return border }
        return isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.14)
    }
    
    // Overlays & Modals
    public var modalBackdrop: Color {
        isDark ? Color.black.opacity(0.85) : Color.black.opacity(0.40)
    }
    
    public var modalBackground: Color {
        isDark ? Color(red: 0.05, green: 0.05, blue: 0.06) : Color(white: 0.98)
    }
    
    // Hardware elements
    /// The single interrupt/active accent. Meets 4.5:1 as text on this mode's
    /// backgrounds; use `onAccent` for anything drawn on top of a red fill.
    public var accentRed: Color {
        isDark ? Color(red: 1.0, green: 0.26, blue: 0.27) : Color(red: 0.78, green: 0.08, blue: 0.11)
    }

    /// Foreground for text and glyphs on an `accentRed` fill.
    public var onAccent: Color {
        isDark ? Color.black : Color.white
    }

    public var knobFace: Color {
        isDark ? Color(white: 0.08) : Color(white: 0.93)
    }

    public var knobArcTrack: Color {
        let opacity = increaseContrast ? 0.45 : 0.12
        return isDark ? Color.white.opacity(opacity) : Color.black.opacity(opacity)
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
