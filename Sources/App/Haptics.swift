import AppKit

@MainActor
struct Haptics {
    static func playClick() {
        guard AppSettings.shared.isHapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
    
    static func playAlignment() {
        guard AppSettings.shared.isHapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
