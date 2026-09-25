import Foundation

/// Keeps the non-Sendable run-loop timer on the main actor, including teardown.
@MainActor
final class PlaybackClock {
    var timer: Timer?
}
