import Foundation

enum FaderScale {
    static let maximumGain = pow(10.0, 6.0 / 20.0)

    static func gain(at position: Double) -> Double {
        guard position.isFinite, position > 0 else { return 0 }
        return pow(10, (min(1, position) * 66 - 60) / 20)
    }

    static func position(for gain: Double) -> Double {
        guard gain.isFinite, gain > 0 else { return 0 }
        return min(1, max(0, (20 * log10(gain) + 60) / 66))
    }
}
