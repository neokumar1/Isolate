import XCTest
import AVFoundation
import SwiftUI
import AppKit
@testable import Isolate

@MainActor
final class UIFixTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func audio(_ name: String, seconds: Double = 0.5) throws -> URL {
        let url = directory.appending(path: name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(44_100 * seconds))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = 0.2 * sin(Float(frame) * 2 * .pi * 440 / 44_100)
            }
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    private func loadedEngine() async throws -> AudioEngineManager {
        let original = try audio("original.wav")
        let urls = try DemucsEngine.stemNames.map { try audio("\($0).wav") }
        let track = TrackModel(id: original.path, title: "UI Fix", originalURL: original,
                               vocalStemURL: urls[0], bassStemURL: urls[2], drumStemURL: urls[1], otherStemURL: urls[3])
        let engine = AudioEngineManager()
        await engine.loadTrack(track)
        XCTAssertTrue(engine.hasLoadedTrack)
        return engine
    }

    /// Ideal (unconstrained) width, which is what `ViewThatFits` compares against.
    private func idealWidth<V: View>(_ view: V) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.width
    }

    private func requireBundledFont() throws {
        try XCTSkipIf(NSFont(name: "DotGothic16-Regular", size: 10) == nil,
                      "Layout widths are only meaningful with the bundled DotGothic16 font")
    }

    /// Posts a double-click straight to an offscreen window; the real pointer never moves.
    /// macOS 26 does not deliver synthetic mouse events to a hosted view (a single click
    /// on the pan bar leaves it untouched there, while macOS 15 and 27 move it). Probe once
    /// so the double-click tests skip, rather than fail, where the harness cannot click.
    private func requireSyntheticClicks() throws {
        let pan = Box<Float>(0.6)
        doubleClick(PanKnobView(pan: pan.binding, channelName: "PROBE"),
                    size: CGSize(width: 200, height: 40), at: CGPoint(x: 40, y: 26), clicks: 1)
        try XCTSkipIf(pan.value == 0.6, "Synthetic mouse events do not reach hosted views on this macOS")
    }

    private func doubleClick<V: View>(_ view: V, size: CGSize, at point: CGPoint, clicks: Int = 2) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let location = host.convert(point, to: nil)
        for clickCount in 1...clicks {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               eventNumber: 0, clickCount: clickCount, pressure: 1)!
                window.sendEvent(event)
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    /// Backs a control's binding in these main-actor tests.
    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
        var binding: Binding<Value> { Binding(get: { self.value }, set: { self.value = $0 }) }
    }

    // MARK: - ui-14: pan readout

    func testPanReadoutRoundsAndKeyboardStepsStayOnGrid() {
        var pan: Float = 1
        var labels: [String] = []
        for _ in 0..<20 {
            pan = PanKnobView.stepped(pan, direction: -1)
            labels.append(PanKnobView.label(for: pan))
        }
        XCTAssertEqual(Array(labels.prefix(5)), ["R 95", "R 90", "R 85", "R 80", "R 75"])
        XCTAssertEqual(labels.last, "CENTER")
        XCTAssertEqual(pan, 0, "Twenty 5% steps from full right must land exactly on center")
        XCTAssertEqual(PanKnobView.label(for: 0.79999995), "R 80")
        XCTAssertEqual(PanKnobView.label(for: -0.3), "L 30")
        // A drag can leave the value off-grid; one key step moves onto the next grid point.
        XCTAssertEqual(PanKnobView.stepped(0.33, direction: 1), 0.35, accuracy: 1e-6)
        XCTAssertEqual(PanKnobView.stepped(0.33, direction: -1), 0.30, accuracy: 1e-6)
        XCTAssertEqual(PanKnobView.stepped(1, direction: 1), 1)
        XCTAssertEqual(PanKnobView.stepped(-1, direction: -1), -1)
    }

    // MARK: - ui-15: EQ detent haptic

    func testEQDetentHapticPlaysOnlyWhenEnteringFlat() {
        XCTAssertEqual(RotaryEQKnobView.detent(0.1, from: 3).gain, 0)
        XCTAssertTrue(RotaryEQKnobView.detent(0.1, from: 3).entersDetent)
        // Pressing or moving within the detent of an already-flat band stays silent.
        XCTAssertFalse(RotaryEQKnobView.detent(0, from: 0).entersDetent)
        XCTAssertFalse(RotaryEQKnobView.detent(-0.2, from: 0).entersDetent)
        XCTAssertEqual(RotaryEQKnobView.detent(2.5, from: 0).gain, 2.5)
        XCTAssertFalse(RotaryEQKnobView.detent(2.5, from: 0).entersDetent)
    }

    // MARK: - ui-13 and audio-engine-7: transport without a track, clearing loops

    func testSeekAndLoopActionsDoNothingWithoutALoadedTrack() {
        let engine = AudioEngineManager()
        XCTAssertFalse(engine.hasLoadedTrack)
        TransportActions.scrub(engine, to: 0.7)
        XCTAssertEqual(engine.playbackProgress, 0, "Scrubbing an empty player must not leave a phantom position")
        TransportActions.toggleLoop(engine)
        TransportActions.setLoopStart(engine)
        TransportActions.setLoopEnd(engine)
        XCTAssertFalse(engine.isLooping)
        XCTAssertEqual(engine.loopStartProgress, 0)
        XCTAssertEqual(engine.loopEndProgress, 1)
        XCTAssertFalse(TransportActions.hasLoopMarkers(engine))
    }

    func testLoopMarkersCanBeSetAndClearedWithALoadedTrack() async throws {
        let engine = try await loadedEngine()
        TransportActions.scrub(engine, to: 0.25)
        XCTAssertEqual(engine.playbackProgress, 0.25, accuracy: 1e-9)
        TransportActions.setLoopStart(engine)
        engine.playbackProgress = 0.6
        TransportActions.setLoopEnd(engine)
        XCTAssertTrue(engine.isLooping)
        XCTAssertTrue(TransportActions.hasLoopMarkers(engine))
        TransportActions.toggleLoop(engine)
        XCTAssertFalse(engine.isLooping)
        XCTAssertTrue(TransportActions.hasLoopMarkers(engine), "Turning the loop off keeps its markers")
        TransportActions.clearLoop(engine)
        XCTAssertFalse(engine.isLooping)
        XCTAssertEqual(engine.loopStartProgress, 0)
        XCTAssertEqual(engine.loopEndProgress, 1)
        XCTAssertFalse(TransportActions.hasLoopMarkers(engine))
        engine.unloadTrack()
    }

    // MARK: - ui-6: global EQ bypass indicator

    func testGlobalEQBypassIsShownOnEveryChannelStrip() {
        XCTAssertEqual(StemEQChannelStripView.headerLabel(isBypassed: false, isGloballyBypassed: false), "3-BAND EQ")
        XCTAssertEqual(StemEQChannelStripView.headerLabel(isBypassed: true, isGloballyBypassed: false), "EQ: BYP")
        XCTAssertEqual(StemEQChannelStripView.headerLabel(isBypassed: false, isGloballyBypassed: true), "ALL EQ OFF")
        XCTAssertEqual(StemEQChannelStripView.headerLabel(isBypassed: true, isGloballyBypassed: true), "ALL EQ OFF")
    }

    // MARK: - ui-1 and ui-9: header, HUD and transport fit

    func testStudioHUDTabsFitWithoutTruncationAtDefaultAndNarrowWidths() throws {
        try requireBundledFont()
        let engine = AudioEngineManager()
        let padding: CGFloat = 20 // HeaderCenterTelemetryModule's horizontal padding

        // Default 1280x800 window with the library open leaves the player 1009pt.
        let defaultWindow = PlayerHeaderMetrics(width: 1009, isCompactHeight: false, hasSidebarToggle: true, isSidebarClosed: false)
        XCTAssertTrue(defaultWindow.showsHUD)
        XCTAssertGreaterThanOrEqual(defaultWindow.trackInfoWidth, 240)
        let fullLabels = idealWidth(HUDTopBar(showsMetadata: false, isCompactHeight: false).environment(engine))
        XCTAssertLessThanOrEqual(fullLabels + padding, defaultWindow.hudWidth,
                                 "Full mode tab names must fit the HUD at the default window")

        // The narrowest header that still shows the HUD must fit the short tab names.
        for compactHeight in [false, true] {
            let narrowest = PlayerHeaderMetrics(width: PlayerHeaderMetrics.hudVisibleWidth, isCompactHeight: compactHeight,
                                                hasSidebarToggle: true, isSidebarClosed: false)
            let shortLabels = idealWidth(HUDTopBar(showsMetadata: false, usesShortLabels: true,
                                                   isCompactHeight: compactHeight).environment(engine))
            XCTAssertLessThanOrEqual(shortLabels + padding, narrowest.hudWidth)
        }
        XCTAssertFalse(PlayerHeaderMetrics.showsHUD(width: 859))
    }

    func testEqualWidthRowIdealWidthUsesItsWidestColumn() {
        let row = EqualWidthHStack(spacing: 6) {
            Color.clear.frame(width: 40, height: 10)
            Color.clear.frame(width: 100, height: 10)
            Color.clear.frame(width: 10, height: 10)
        }
        // Equal columns of the widest ideal (plus a point of rounding slack), so a
        // ViewThatFits check can't pass a row whose widest column would truncate.
        XCTAssertEqual(idealWidth(row), 101 * 3 + 12, accuracy: 0.5)
    }

    func testTransportKeepsSeekBarUsableAtEveryWindowWidth() throws {
        try requireBundledFont()
        let time = "00:00 / -00:00"
        // 960pt minimum window with the 270pt library and 1pt divider, less 28pt padding.
        let minimumWidth: CGFloat = 960 - 271 - 28
        XCTAssertEqual(TransportBar.Metrics.forWidth(minimumWidth, timeLabel: time), .tight)
        XCTAssertEqual(TransportBar.Metrics.forWidth(1280 - 271 - 28, timeLabel: time), .regular)
        for width in stride(from: minimumWidth, through: 1800, by: 1) {
            let metrics = TransportBar.Metrics.forWidth(width, timeLabel: time)
            XCTAssertGreaterThanOrEqual(width - metrics.fixedWidth(timeLabel: time), 100,
                                        "Seek bar collapsed at transport width \(width)")
        }
    }

    func testTransportLabelsFitTheirButtonsAtEveryDensity() throws {
        try requireBundledFont()
        func width(_ text: String, size: CGFloat) -> CGFloat {
            idealWidth(Text(text).font(.custom("DotGothic16-Regular", size: size)).fontWeight(.bold))
        }
        for metrics in [TransportBar.Metrics.regular, .compact, .tight] {
            let size: CGFloat = metrics.isCompact ? 11.5 : 13
            XCTAssertLessThan(width(metrics.isCompact ? "BYPASS" : "BYPASS: OFF", size: size), metrics.bypassWidth)
            XCTAssertLessThan(width(metrics.isCompact ? "EXPORT" : "EXPORT STEMS", size: size), metrics.exportWidth)
            XCTAssertLessThan(width(metrics.isTight ? "100%" : "RENDERING 100%", size: size), metrics.exportWidth)
            XCTAssertLessThan(width(metrics.isCompact ? "LOOP" : "LOOP: OFF", size: metrics.isCompact ? 10.5 : 11.5), metrics.loopWidth)
            XCTAssertLessThan(width(metrics.isCompact ? "-12 ST" : "-12 ST [OCT]", size: metrics.isCompact ? 9.5 : 10),
                              metrics.pitchReadoutWidth)
            XCTAssertLessThan(width("0.75x", size: metrics.isCompact ? 10 : 11), metrics.speedReadoutWidth)
        }
    }

    private typealias Key = (characters: String, unmodified: String, keyCode: UInt16, flags: NSEvent.ModifierFlags)

    private func pressKeys(_ keys: [Key], in engine: AudioEngineManager) {
        pressKeys(keys, in: PlayerView(isSidebarVisible: .constant(false)).environment(engine), size: CGSize(width: 1009, height: 800))
    }

    /// Posts key presses straight to an offscreen window; the real keyboard is untouched.
    private func pressKeys<V: View>(_ keys: [Key], in view: V, size: CGSize) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        for key in keys {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: key.flags,
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             characters: key.characters, charactersIgnoringModifiers: key.unmodified,
                                             isARepeat: false, keyCode: key.keyCode)!
                window.sendEvent(event)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    func testLoopShortcutsSetAndClearMarkers() async throws {
        let engine = try await loadedEngine()
        pressKeys([("¬", "l", 37, [.option])], in: engine)
        XCTAssertFalse(engine.isLooping, "⌥L must not also toggle the loop")
        engine.playbackProgress = 0.2
        pressKeys([("[", "[", 33, [])], in: engine)
        XCTAssertTrue(engine.isLooping, "[ sets the loop start and turns looping on")
        XCTAssertEqual(engine.loopStartProgress, 0.2, accuracy: 1e-9)
        pressKeys([("¬", "l", 37, [.option])], in: engine)
        XCTAssertFalse(engine.isLooping, "⌥L clears the loop")
        XCTAssertEqual(engine.loopStartProgress, 0)
        XCTAssertEqual(engine.loopEndProgress, 1)
        engine.unloadTrack()
    }

    // MARK: - ui-10: Escape closes the shortcut cheat sheet

    func testEscapeClosesShortcutCheatSheet() {
        let closed = Box(false)
        pressKeys([("\u{1b}", "\u{1b}", 53, [])], in: ShortcutsHUDModal(onClose: { closed.value = true }),
                  size: CGSize(width: 540, height: 600))
        XCTAssertTrue(closed.value, "The card says ESC / CLOSE, so Escape must close it")
    }

    // MARK: - design-a11y-18: Reduce Motion

    func testMarqueeTruncatesInsteadOfScrollingUnderReduceMotion() {
        XCTAssertTrue(MarqueeText.scrolls(overflow: 80, containerWidth: 200, reduceMotion: false))
        XCTAssertFalse(MarqueeText.scrolls(overflow: 80, containerWidth: 200, reduceMotion: true))
        // Small overflows no longer get a scroll-style fade without scrolling.
        XCTAssertFalse(MarqueeText.scrolls(overflow: 5, containerWidth: 200, reduceMotion: false))
    }

    // MARK: - ui-5: double-click resets

    func testDoubleClickResetsPanBarToCenter() throws {
        try requireSyntheticClicks()
        let pan = Box<Float>(0.6)
        doubleClick(PanKnobView(pan: pan.binding, channelName: "VOCALS"),
                    size: CGSize(width: 200, height: 40), at: CGPoint(x: 40, y: 26))
        XCTAssertEqual(pan.value, 0, "Double-clicking the pan bar must center it, not leave it at the click point")
    }

    func testDoubleClickResetsEQKnobToFlat() throws {
        try requireSyntheticClicks()
        let gain = Box<Float>(6)
        doubleClick(RotaryEQKnobView(bandName: "MID", freqLabel: "1.0kHz", gain: gain.binding, channelName: "VOCALS"),
                    size: CGSize(width: 80, height: 90), at: CGPoint(x: 40, y: 45))
        XCTAssertEqual(gain.value, 0, "Double-clicking an EQ knob must reset it to 0 dB")
    }

    func testDoubleClickResetsHUDEqualizerNode() throws {
        try requireSyntheticClicks()
        let engine = AudioEngineManager()
        engine.setStemEQ(0, low: 6, mid: 0, high: 0)
        let size = CGSize(width: 400, height: 120)
        // Canvas starts below the 16pt toolbar and 4pt gap; LOW sits at 100Hz on a log axis.
        let canvasHeight = size.height - 20
        let midY = canvasHeight / 2
        let node = CGPoint(x: size.width * log10(5) / 3, y: 20 + midY - 0.5 * midY * 0.78)
        doubleClick(HUDEqualizerCurveView().environment(engine), size: size, at: node)
        XCTAssertEqual(engine.getStemEQ(0).low, 0, accuracy: 1e-4, "Double-clicking a HUD EQ node must reset its gain")
    }

    // MARK: - design-a11y-3/-5/-6: theme tokens only

    func testPlayerAndSettingsViewsUseThemeColorTokens() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = ["Sources/Player/PlayerView.swift", "Sources/Player/CustomFader.swift", "Sources/App/SettingsView.swift"]
        // System red/yellow/gray fail contrast in NOTHING LIGHT; white/black text ignores the theme.
        let literal = try NSRegularExpression(pattern: #"\.(red|yellow|gray)\b|foregroundColor\(\.(white|black)\)|\? \.(white|black) :|: \.(white|black)\)"#)
        for file in files {
            let url = root.appending(path: file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                throw XCTSkip("Sources are not available at \(url.path)")
            }
            let matches = literal.matches(in: source, range: NSRange(source.startIndex..., in: source))
            let lines = matches.map { match -> String in
                let line = source[..<Range(match.range, in: source)!.lowerBound].filter { $0 == "\n" }.count + 1
                return "\(file):\(line)"
            }
            XCTAssertTrue(lines.isEmpty, "Hard-coded colors: \(lines.joined(separator: ", "))")
        }
    }
}
