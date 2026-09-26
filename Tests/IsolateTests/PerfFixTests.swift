import XCTest
import AVFoundation
import SwiftUI
import AppKit
import Observation
@testable import Isolate

@MainActor
final class PerfFixTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private final class Flag: @unchecked Sendable {
        var value = false
    }

    /// Calls `onChange` once if anything `read` touched is mutated afterwards.
    private func observe(_ read: () -> Void) -> Flag {
        let flag = Flag()
        withObservationTracking(read) { flag.value = true }
        return flag
    }

    private func reading(peak: Float = 0.5, spectrum: [Float], waveform: [Float] = []) -> AudioMeterProcessor.Reading {
        AudioMeterProcessor.Reading(spectrum: spectrum, waveform: waveform, peak: peak)
    }

    private func playingEngine() -> AudioEngineManager {
        let engine = AudioEngineManager()
        engine.isPlaying = true
        return engine
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func render<V: View>(_ view: V, scale: CGFloat) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return pixels(try XCTUnwrap(renderer.cgImage))
    }

    // MARK: - performance-1: per-stem meters

    func testStemReadingNotifiesOnlyThatStemsMeter() {
        let engine = playingEngine()
        let flags = engine.stemMeters.map { meter in observe { _ = meter.spectrum; _ = meter.isClipping } }
        let master = observe { _ = engine.masterMeter.spectrum; _ = engine.masterMeter.artworkEnergy }

        engine.deliverMeterReading(reading(peak: 0.4, spectrum: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7]), stem: 1)

        XCTAssertEqual(flags.map(\.value), [false, true, false, false], "A drum reading must not redraw the other strips")
        XCTAssertFalse(master.value)
        XCTAssertEqual(engine.stemMeters[1].spectrum, [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7])
        XCTAssertEqual(engine.stemMeters[1].peak, 0.4)
        XCTAssertEqual(engine.stemMeters[0].spectrum, Array(repeating: 0, count: 7))
    }

    func testPeaksBelowFullScaleDoNotReachTheFader() {
        let engine = playingEngine()
        let meter = engine.stemMeters[0]
        let spectrum: [Float] = Array(repeating: 0.2, count: 7)
        engine.deliverMeterReading(reading(peak: 0.3, spectrum: spectrum), stem: 0)
        let clip = observe { _ = meter.isClipping }
        engine.deliverMeterReading(reading(peak: 0.9, spectrum: spectrum), stem: 0)
        XCTAssertFalse(clip.value, "The fader reads only the clip state")
        XCTAssertEqual(meter.peak, 0.9)

        engine.deliverMeterReading(reading(peak: 1.2, spectrum: spectrum), stem: 0)
        XCTAssertTrue(clip.value)
        XCTAssertTrue(meter.isClipping)
        engine.deliverMeterReading(reading(peak: 0.99, spectrum: spectrum), stem: 0)
        XCTAssertFalse(meter.isClipping)
    }

    func testMutedStemAndStopClearTheirMeters() {
        let engine = playingEngine()
        let spectrum: [Float] = Array(repeating: 0.5, count: 7)
        for stem in 0..<4 { engine.deliverMeterReading(reading(peak: 1.1, spectrum: spectrum), stem: stem) }
        engine.deliverMeterReading(reading(spectrum: Array(repeating: 0.5, count: 32), waveform: Array(repeating: 1, count: 30)), stem: nil)

        engine.toggleMute(2)
        XCTAssertEqual(engine.stemMeters[2].spectrum, Array(repeating: 0, count: 7))
        XCTAssertEqual(engine.stemMeters[1].spectrum, spectrum)

        engine.isPlaying = false
        engine.deliverMeterReading(reading(peak: 0.7, spectrum: spectrum), stem: 2)
        XCTAssertEqual(engine.stemMeters[2].spectrum, Array(repeating: 0, count: 7), "Readings after a stop are dropped")
        engine.unloadTrack()
        XCTAssertEqual(engine.stemMeters.map(\.peak), [0, 0, 0, 0])
        XCTAssertEqual(engine.stemMeters.map(\.isClipping), [false, false, false, false])
        XCTAssertEqual(engine.masterMeter.spectrum, Array(repeating: 0, count: 32))
        XCTAssertEqual(engine.masterMeter.waveform, Array(repeating: MasterMeter.waveformFloor, count: 30))
    }

    // MARK: - performance-3: hidden player

    func testHiddenPlayerDropsMeterReadingsAndStartsCleanWhenShown() {
        let engine = playingEngine()
        engine.deliverMeterReading(reading(peak: 1.3, spectrum: Array(repeating: 0.6, count: 7)), stem: 0)
        XCTAssertTrue(engine.stemMeters[0].isClipping)

        engine.setUIVisible(false)
        XCTAssertFalse(engine.isUIVisible)
        XCTAssertFalse(engine.stemMeters[0].isClipping, "A stale clip must not light the LED when the window returns")
        let flags = engine.stemMeters.map { meter in observe { _ = meter.spectrum; _ = meter.isClipping } }
        let master = observe { _ = engine.masterMeter.spectrum }
        engine.deliverMeterReading(reading(peak: 1.3, spectrum: Array(repeating: 0.6, count: 7)), stem: 0)
        engine.deliverMeterReading(reading(spectrum: Array(repeating: 0.4, count: 32), waveform: Array(repeating: 0.5, count: 30)), stem: nil)
        XCTAssertEqual(flags.map(\.value), [false, false, false, false])
        XCTAssertFalse(master.value)

        engine.setUIVisible(true)
        engine.deliverMeterReading(reading(peak: 0.2, spectrum: Array(repeating: 0.6, count: 7)), stem: 0)
        XCTAssertEqual(engine.stemMeters[0].spectrum, Array(repeating: 0.6, count: 7))
    }

    func testHiddenPlayerKeepsPositionCurrentWithoutNotifyingViews() {
        let engine = AudioEngineManager()
        engine.publishPlaybackPosition(progress: 0.25, elapsed: 50, duration: 200)
        XCTAssertEqual(engine.currentTimeString, "00:50 / -02:30")

        engine.setUIVisible(false)
        let views = observe {
            _ = engine.playbackProgress
            _ = engine.currentTimeString
            _ = engine.detailedTimecode
        }
        engine.publishPlaybackPosition(progress: 0.4, elapsed: 80, duration: 200)
        XCTAssertFalse(views.value, "Hidden views must not re-render at the timer rate")
        XCTAssertEqual(engine.playbackProgress, 0.4, "Seeks, loop markers and device changes read the live position")

        let shown = observe { _ = engine.playbackProgress }
        engine.setUIVisible(true)
        XCTAssertTrue(shown.value, "Showing the player publishes the current position at once")
        engine.publishPlaybackPosition(progress: 0.5, elapsed: 100, duration: 200)
        XCTAssertEqual(engine.currentTimeString, "01:40 / -01:40")
    }

    func testDirectPositionWritesStillNotifyWhileHidden() {
        let engine = AudioEngineManager()
        engine.setUIVisible(false)
        let views = observe { _ = engine.playbackProgress }
        engine.playbackProgress = 0.6
        XCTAssertTrue(views.value, "Only the timer's writes are held back")
        XCTAssertEqual(engine.playbackProgress, 0.6)
    }

    func testVisibilityReporterMarksAnUnseenWindowHiddenAndResetsOnRemoval() {
        let engine = AudioEngineManager()
        let host = NSHostingView(rootView: PlayerVisibilityReporter(engine: engine).frame(width: 10, height: 10))
        host.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        // Never ordered in, so its occlusion state has no .visible.
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 10, height: 10),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(engine.isUIVisible)

        window.contentView = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(engine.isUIVisible, "Without a window the engine goes back to publishing")
    }

    /// Silent stems, so the loop test makes no sound.
    private func silentTrack(seconds: Double) throws -> TrackModel {
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: StreamingAudio.format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(buffer.format.channelCount) {
            buffer.floatChannelData![channel].update(repeating: 0, count: Int(frames))
        }
        let original = directory.appending(path: "original.wav")
        let urls = [original] + DemucsEngine.stemNames.map { directory.appending(path: "\($0).wav") }
        for url in urls {
            let file = try AVAudioFile(forWriting: url, settings: StreamingAudio.settings)
            try file.write(from: buffer)
        }
        return TrackModel(id: original.path, title: "Loop Probe", originalURL: original,
                          vocalStemURL: urls[1], bassStemURL: urls[3], drumStemURL: urls[2], otherStemURL: urls[4])
    }

    func testLoopKeepsWrappingWhileThePlayerIsHidden() async throws {
        let engine = AudioEngineManager()
        await engine.loadTrack(try silentTrack(seconds: 6))
        guard engine.isPlaying else {
            engine.unloadTrack()
            throw XCTSkip("No audio output device: \(engine.errorMessage ?? "playback did not start")")
        }
        // A 0.9 s region from 0.3 s to 1.2 s.
        engine.seek(toPercentage: 0.05)
        engine.setLoopStart(0.05)
        engine.setLoopEnd(0.2)
        engine.setUIVisible(false)
        try await Task.sleep(for: .milliseconds(2000))
        XCTAssertTrue(engine.isPlaying)
        // Without wrapping, 2 s of playback from 0.3 s would be at 2.3 s (progress 0.38).
        XCTAssertGreaterThan(engine.playbackProgress, 0)
        XCTAssertLessThan(engine.playbackProgress, 0.21, "The timer must keep wrapping A-B loops while hidden")
        engine.setUIVisible(true)
        engine.unloadTrack()
    }

    // MARK: - performance-4: spectrum Canvas

    /// The per-block views the Canvas replaced, kept as the visual reference.
    private struct ReferenceSpectrum: View {
        let magnitudes: [Float]
        @State private var theme = ThemeManager.shared

        var body: some View {
            GeometryReader { geo in
                let barWidth = max(2.0, (geo.size.width - 2.0 * 31) / 32)
                HStack(alignment: .bottom, spacing: 2.0) {
                    ForEach(0..<32, id: \.self) { index in
                        column(magnitude: index < magnitudes.count ? CGFloat(magnitudes[index]) : 0,
                               height: geo.size.height, width: barWidth)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }

        private func column(magnitude: CGFloat, height: CGFloat, width: CGFloat) -> some View {
            let blockHeight = max(1.5, (height - 1.5 * 13) / 14)
            let active = max(0.0, min(14, magnitude * 14))
            return VStack(spacing: 1.5) {
                ForEach((0..<14).reversed(), id: \.self) { blockIdx in
                    let level = CGFloat(blockIdx)
                    let fill: CGFloat = active >= level + 1 ? 1 : (active <= level ? 0 : active - level)
                    let color: Color = blockIdx >= 12 ? (fill > 0 ? theme.accentRed : theme.spectrumBarDefault)
                        : (blockIdx >= 9 ? theme.spectrumBarDefault : theme.spectrumBarDefault.opacity(0.88))
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(color.opacity(fill > 0 ? max(0.2, fill) : (theme.isDark ? 0.05 : 0.08)))
                        .frame(width: width, height: blockHeight)
                }
            }
            .frame(width: width, height: height, alignment: .bottom)
        }
    }

    func testSpectrumCanvasMatchesTheFormerBlockViewsPixelForPixel() throws {
        let engine = playingEngine()
        let magnitudes: [Float] = (0..<32).map { [0, 0.03, 0.5, 0.97, 1, 0.071, 0.33, 0.9999, 0.2, 0.61, 0.07, 0.14][$0 % 12] }
        engine.deliverMeterReading(reading(spectrum: magnitudes, waveform: Array(repeating: 0.5, count: 30)), stem: nil)
        XCTAssertEqual(engine.masterMeter.spectrum, magnitudes)

        // Default-window HUD geometry plus fractional sizes and offsets whose block edges
        // land exactly on half pixels.
        let layouts: [(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)] = [
            (36, 85, 440, 59), (20, 61, 376, 45), (3.5, 0.25, 437.5, 58.5), (7.75, 86.75, 481, 48.5),
            (32, 45.25, 446.5, 51.75), (0.3, 0.37, 456.6, 59)
        ]
        for layout in layouts {
            for scale in [1.0, 2.0] {
                func placed<V: View>(_ view: V) -> some View {
                    view.frame(width: layout.width, height: layout.height)
                        .padding(.leading, layout.x).padding(.top, layout.y)
                        .frame(width: 560, height: 160, alignment: .topLeading)
                }
                let expected = try render(placed(ReferenceSpectrum(magnitudes: magnitudes)), scale: scale)
                let actual = try render(placed(Spectrum32BandView().environment(engine)), scale: scale)
                let differing = stride(from: 0, to: expected.count, by: 4).filter {
                    expected[$0..<$0 + 4] != actual[$0..<$0 + 4]
                }.count
                XCTAssertEqual(differing, 0, "\(layout) at \(scale)x")
            }
        }
    }

    // MARK: - performance-5: album-art pulse

    func testArtworkEnergyRoundsToTwentieths() {
        XCTAssertEqual(MasterMeter.artworkEnergy(for: Array(repeating: 1, count: 30)), 1)
        XCTAssertEqual(MasterMeter.artworkEnergy(for: Array(repeating: 0.62, count: 30)), 0.6, accuracy: 1e-6)
        XCTAssertEqual(MasterMeter.artworkEnergy(for: Array(repeating: 0.63, count: 30)), 0.65, accuracy: 1e-6)
        XCTAssertEqual(MasterMeter.artworkEnergy(for: Array(repeating: MasterMeter.waveformFloor, count: 30)),
                       MasterMeter.waveformFloor, accuracy: 1e-6)

        let engine = playingEngine()
        let spectrum = Array(repeating: Float(0.3), count: 32)
        engine.deliverMeterReading(reading(spectrum: spectrum, waveform: Array(repeating: 0.61, count: 30)), stem: nil)
        let art = observe { _ = engine.masterMeter.artworkEnergy }
        engine.deliverMeterReading(reading(spectrum: spectrum, waveform: Array(repeating: 0.62, count: 30)), stem: nil)
        XCTAssertFalse(art.value, "A change that rounds to the same level must not redraw the artwork")
        XCTAssertEqual(engine.masterMeter.waveform, Array(repeating: 0.62, count: 30))
        engine.deliverMeterReading(reading(spectrum: spectrum, waveform: Array(repeating: 0.9, count: 30)), stem: nil)
        XCTAssertTrue(art.value)
    }

    // MARK: - performance-1: clip LED hold

    private final class ClipModel: ObservableObject {
        @Published var isClipping = false
    }

    private struct ClipHost: View {
        @ObservedObject var model: ClipModel
        @State private var value = 0.5

        var body: some View {
            CustomFader(value: $value, label: "VOCALS", isClipping: model.isClipping)
                .frame(width: 80, height: 200)
        }
    }

    /// True when the clip LED (4.5 pt, centred 3.25 pt below the fader's top edge) is lit red.
    private func ledIsLit(_ host: NSView) -> Bool {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / host.bounds.height
        guard let color = rep.colorAt(x: rep.pixelsWide / 2, y: Int(3.25 * scale))?.usingColorSpace(.sRGB) else { return false }
        return color.redComponent - color.greenComponent > 0.35
    }

    func testClipLEDHoldsAfterThePeakFallsBelowFullScale() {
        let model = ClipModel()
        let host = NSHostingView(rootView: ClipHost(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 80, height: 200)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 80, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        wait(0.3)
        XCTAssertFalse(ledIsLit(host))
        model.isClipping = true
        wait(0.4)
        XCTAssertTrue(ledIsLit(host))
        model.isClipping = false
        wait(0.4)
        XCTAssertTrue(ledIsLit(host), "The LED holds for 1.2 s after the clip ends")
        // A new clip during the hold cancels it; the second release starts a fresh hold.
        wait(0.5)
        model.isClipping = true
        wait(0.1)
        model.isClipping = false
        wait(0.9)
        XCTAssertTrue(ledIsLit(host), "The first hold would have ended 0.7 s ago")
        wait(1.0)
        XCTAssertFalse(ledIsLit(host))
    }
}
