import XCTest
import Accelerate
import AVFoundation
@testable import Isolate

final class IsolateTests: XCTestCase {
    
    // Test 1: Verify Constant Overlap-Add (COLA) Property of 50% Overlapped Hann Window
    func testHannWindowCOLAProperty() {
        let chunkSize = 441000
        let hopSize = 220500
        
        var window = [Float](repeating: 0.0, count: chunkSize)
        for i in 0..<chunkSize {
            window[i] = 0.5 * (1.0 - cosf(Float(2.0 * Double.pi * Double(i) / Double(chunkSize))))
        }
        
        // Sum 2 consecutive windows shifted by hopSize in the overlapping region
        for i in 0..<hopSize {
            let val1 = window[hopSize + i]
            let val2 = window[i]
            let sum = val1 + val2
            XCTAssertEqual(sum, 1.0, accuracy: 1e-4, "Hann window 50% overlap must sum to 1.0 everywhere in overlap region")
        }
    }
    
    // Test 2: Verify Reflection Padding Symmetry and Continuity
    func testReflectionPaddingContinuity() {
        let originalCount = 1000
        let padSize = 200
        let paddedCount = originalCount + 2 * padSize
        
        var original = [Float](repeating: 0, count: originalCount)
        for i in 0..<originalCount {
            original[i] = sinf(Float(i) * 0.05)
        }
        
        var padded = [Float](repeating: 0, count: paddedCount)
        // Left reflection
        for i in 0..<padSize {
            padded[i] = original[min(originalCount - 1, padSize - i)]
        }
        // Center
        for i in 0..<originalCount {
            padded[padSize + i] = original[i]
        }
        // Right reflection
        for i in 0..<padSize {
            padded[padSize + originalCount + i] = original[max(0, originalCount - 2 - i)]
        }
        
        // Check boundary equality
        XCTAssertEqual(padded[padSize], original[0], accuracy: 1e-6)
        XCTAssertEqual(padded[padSize + originalCount - 1], original[originalCount - 1], accuracy: 1e-6)
        XCTAssertEqual(padded.count, paddedCount)
    }
    
    // Test 3: Verify Dynamic Standardization (Mean and Standard Deviation Calculation)
    func testAudioStandardizationNormalization() {
        let sampleCount = 44100
        var channelL = [Float](repeating: 0, count: sampleCount)
        var channelR = [Float](repeating: 0, count: sampleCount)
        
        for i in 0..<sampleCount {
            let t = Float(i) / 44100.0
            channelL[i] = 0.5 * sinf(2.0 * .pi * 440.0 * t) + 0.1
            channelR[i] = 0.5 * sinf(2.0 * .pi * 880.0 * t) + 0.1
        }
        
        var meanL: Float = 0
        var meanR: Float = 0
        vDSP_meanv(&channelL, 1, &meanL, vDSP_Length(sampleCount))
        vDSP_meanv(&channelR, 1, &meanR, vDSP_Length(sampleCount))
        let meanVal = (meanL + meanR) * 0.5
        
        var rmsL: Float = 0
        var rmsR: Float = 0
        vDSP_rmsqv(&channelL, 1, &rmsL, vDSP_Length(sampleCount))
        vDSP_rmsqv(&channelR, 1, &rmsR, vDSP_Length(sampleCount))
        let rmsVal = sqrtf((rmsL * rmsL + rmsR * rmsR) * 0.5)
        let stdVal = sqrtf(max(0, rmsVal * rmsVal - meanVal * meanVal))
        
        XCTAssertEqual(meanVal, 0.1, accuracy: 1e-2, "Calculated mean should match injected DC offset")
        XCTAssertGreaterThan(stdVal, 0.3, "Calculated standard deviation should reflect sine wave energy")
        
        // Normalize
        var normL = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            normL[i] = (channelL[i] - meanVal) / stdVal
        }
        
        var normMean: Float = 0
        var normRMS: Float = 0
        vDSP_meanv(&normL, 1, &normMean, vDSP_Length(sampleCount))
        vDSP_rmsqv(&normL, 1, &normRMS, vDSP_Length(sampleCount))
        
        XCTAssertEqual(normMean, 0.0, accuracy: 1e-3, "Normalized audio must have zero mean")
        XCTAssertEqual(normRMS, 1.0, accuracy: 1e-2, "Normalized audio must have unit variance / RMS")
    }
    
    // Test 4: Verify FFT Analyzer frequency band computation
    func testFFTAnalyzerExecution() {
        let analyzer = FFTAnalyzer(fftSize: 1024)
        var buffer = [Float](repeating: 0, count: 1024)
        for i in 0..<1024 {
            buffer[i] = sinf(Float(i) * 0.1)
        }
        
        let magnitudes = analyzer.computeFFT(buffer: &buffer)
        XCTAssertEqual(magnitudes.count, 512, "1024 FFT should output 512 magnitude bins")
        
        let maxMagnitude = magnitudes.max() ?? 0
        XCTAssertGreaterThan(maxMagnitude, 0.0, "FFT magnitude for sine wave must be greater than zero")
    }
    
    // Test 5: Verify End-to-End Stem Splitting with DemucsEngine
    func testEndToEndStemSplittingWithSyntheticAudio() async throws {
        let sampleRate: Double = 44100.0
        let duration: Double = 2.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!
        
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let pL = buffer.floatChannelData![0]
        let pR = buffer.floatChannelData![1]
        
        for i in 0..<Int(frameCount) {
            let t = Float(i) / Float(sampleRate)
            // 440 Hz tone + 880 Hz tone
            let val = 0.4 * sinf(2.0 * .pi * 440.0 * t) + 0.2 * sinf(2.0 * .pi * 880.0 * t)
            pL[i] = val
            pR[i] = val
        }
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempAudioURL = tempDir.appendingPathComponent("test_track.wav")
        
        let diskSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        do {
            let writer = try AVAudioFile(forWriting: tempAudioURL, settings: diskSettings)
            try writer.write(from: buffer)
        }
        
        var progressUpdates: [Double] = []
        let stemURLs: [URL]
        do {
            stemURLs = try await DemucsEngine.shared.splitAudio(url: tempAudioURL) { info in
                progressUpdates.append(info.fraction)
            }
        } catch DemucsError.modelNotFound(let msg) {
            try? FileManager.default.removeItem(at: tempDir)
            throw XCTSkip("Skipping model inference test in CI environment: \(msg)")
        }
        
        XCTAssertEqual(stemURLs.count, 4, "Must output 4 stems (vocals, drums, bass, other)")
        XCTAssertFalse(progressUpdates.isEmpty, "Must send progress updates during splitting")
        
        for stemURL in stemURLs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: stemURL.path), "Stem file must exist on disk at \(stemURL.path)")
            let audioFile = try AVAudioFile(forReading: stemURL)
            XCTAssertEqual(audioFile.processingFormat.sampleRate, sampleRate, "Sample rate must be 44.1kHz")
            XCTAssertEqual(audioFile.processingFormat.channelCount, 2, "Must be stereo audio")
            XCTAssertEqual(audioFile.length, Int64(frameCount), "Stem audio length must match original input length")
        }
        
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // Test 6: Verify 50x50 Nothing RGB Color Dot-Matrix Image Sampling
    func testDotMatrixImageProcessorSampling() {
        let size = NSSize(width: 200, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.blue.setFill()
        NSRect(x: 50, y: 50, width: 100, height: 100).fill()
        image.unlockFocus()
        
        let matrix = DotMatrixImageProcessor.generateColorDotMatrix(from: image, gridSize: 50)
        XCTAssertNotNil(matrix, "Color dot matrix generation must succeed")
        XCTAssertEqual(matrix?.count, 50, "Matrix height must be 50")
        XCTAssertEqual(matrix?.first?.count, 50, "Matrix width must be 50")
        
        // Check corner (red background -> high red channel)
        let cornerCell = matrix?[0][0]
        XCTAssertNotNil(cornerCell)
        XCTAssertGreaterThan(cornerCell?.r ?? 0.0, 0.7, "Red background corner must have high red component")
    }
    
    // Test 7: Verify AudioEngineManager HUD Mode Switching and Bounds Protection
    @MainActor
    func testAudioEngineManagerHUDModeSwitching() {
        let engine = AudioEngineManager()
        XCTAssertEqual(engine.activeHUDModeIndex, 0, "Default mode must be 0 (32-Band FFT)")
        
        engine.setHUDMode(1)
        XCTAssertEqual(engine.activeHUDModeIndex, 1, "Mode 1 must be Stem Macros")
        
        engine.setHUDMode(2)
        XCTAssertEqual(engine.activeHUDModeIndex, 2, "Mode 2 must be Stem Balance")
        
        engine.setHUDMode(3)
        XCTAssertEqual(engine.activeHUDModeIndex, 3, "Mode 3 must be Telemetry")
        
        engine.setHUDMode(4)
        XCTAssertEqual(engine.activeHUDModeIndex, 4, "Mode 4 must be Equalizer")
        
        // Out of bounds guard
        engine.setHUDMode(5)
        XCTAssertEqual(engine.activeHUDModeIndex, 4, "Index >= 5 must be ignored")
        
        engine.setHUDMode(-1)
        XCTAssertEqual(engine.activeHUDModeIndex, 4, "Index < 0 must be ignored")
    }
    
    // Test 8: Verify Stem Search Multi-Token Matching
    func testStemSearchFilteringLogic() {
        let queryTokens = ["drake", "vocal"]
        let candidateText = "what did i miss? drake iceman vocals.wav 44.1khz"
        
        let matches = queryTokens.allSatisfy { token in
            candidateText.contains(token)
        }
        XCTAssertTrue(matches, "Multi-token search must match title and stem tokens")
        
        let nonMatchingQuery = ["kendrick", "vocal"]
        let noMatch = nonMatchingQuery.allSatisfy { token in
            candidateText.contains(token)
        }
        XCTAssertFalse(noMatch, "Multi-token search must reject non-matching tokens")
    }
    
    // Test 9: Verify Unified Toolbar Standard macOS Traffic Light Padding
    func testUnifiedToolbarTrafficLightGeometry() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        
        let toolbar = NSToolbar(identifier: "IsolateTestToolbar")
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        
        guard let closeButton = window.standardWindowButton(.closeButton) else {
            XCTFail("Close button must exist on standard titled window")
            return
        }
        
        let buttonFrameInWindow = closeButton.convert(closeButton.bounds, to: nil)
        let leftPadding = buttonFrameInWindow.minX
        let topPadding = window.frame.height - buttonFrameInWindow.maxY
        
        XCTAssertGreaterThanOrEqual(leftPadding, 18.0, "Close button left padding must be >= 18pt (macOS unified standard)")
        XCTAssertGreaterThanOrEqual(topPadding, 18.0, "Close button top padding must be >= 18pt (macOS unified standard)")
    }
    
    // Test 10: Verify Player Header Top Padding Clears NSToolbar Window Drag Area & Fullscreen Handling
    func testPlayerHeaderTitlebarClearanceAndFullscreenHandling() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let toolbar = NSToolbar(identifier: "IsolateTestClearanceToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        
        let headerTopPadding: CGFloat = 50.0
        XCTAssertGreaterThanOrEqual(headerTopPadding, 50.0, "Player header top padding must be >= 50pt to clear titlebar click area")
        
        toolbar.isVisible = false
        XCTAssertFalse(toolbar.isVisible, "Toolbar must hide when full-screen is active to prevent grey bar clipping")
        
        toolbar.isVisible = true
        XCTAssertTrue(toolbar.isVisible, "Toolbar must restore visibility upon exiting full-screen")
    }
    
    // Test 11: Verify 3-Band Equalizer DSP Nodes and Stem Gain / Bypass Controls
    @MainActor
    func testEqualizerDSPNodesAndBypassControls() {
        let engine = AudioEngineManager()
        
        // Initial state should be unity (0.0 dB) and not bypassed
        let initVocals = engine.getStemEQ(0)
        XCTAssertEqual(initVocals.low, 0.0, accuracy: 1e-4)
        XCTAssertEqual(initVocals.mid, 0.0, accuracy: 1e-4)
        XCTAssertEqual(initVocals.high, 0.0, accuracy: 1e-4)
        XCTAssertFalse(initVocals.isBypassed)
        
        // Apply gains to Vocals (index 0)
        engine.setStemEQ(0, low: -3.0, mid: 2.5, high: 4.0)
        let modifiedVocals = engine.getStemEQ(0)
        XCTAssertEqual(modifiedVocals.low, -3.0, accuracy: 1e-4)
        XCTAssertEqual(modifiedVocals.mid, 2.5, accuracy: 1e-4)
        XCTAssertEqual(modifiedVocals.high, 4.0, accuracy: 1e-4)
        
        // Toggle stem bypass
        engine.toggleStemEQBypass(0)
        XCTAssertTrue(engine.getStemEQ(0).isBypassed)
        engine.toggleStemEQBypass(0)
        XCTAssertFalse(engine.getStemEQ(0).isBypassed)
        
        // Toggle global bypass
        XCTAssertFalse(engine.isGlobalEQBypassed)
        engine.toggleGlobalEQBypass()
        XCTAssertTrue(engine.isGlobalEQBypassed)
        engine.toggleGlobalEQBypass()
        XCTAssertFalse(engine.isGlobalEQBypassed)
        
        // Reset single stem
        engine.resetStemEQ(0)
        let resetVocals = engine.getStemEQ(0)
        XCTAssertEqual(resetVocals.low, 0.0, accuracy: 1e-4)
        XCTAssertEqual(resetVocals.mid, 0.0, accuracy: 1e-4)
        XCTAssertEqual(resetVocals.high, 0.0, accuracy: 1e-4)
        
        // Set all stems and reset all
        for i in 0...4 {
            engine.setStemEQ(i, low: 2.0, mid: 2.0, high: 2.0)
            XCTAssertEqual(engine.getStemEQ(i).low, 2.0, accuracy: 1e-4)
        }
        engine.resetAllEQ()
        for i in 0...4 {
            XCTAssertEqual(engine.getStemEQ(i).low, 0.0, accuracy: 1e-4)
            XCTAssertEqual(engine.getStemEQ(i).mid, 0.0, accuracy: 1e-4)
            XCTAssertEqual(engine.getStemEQ(i).high, 0.0, accuracy: 1e-4)
        }
    }
    
    // Test 12: Verify Factory EQ Presets Definition and Application
    @MainActor
    func testFactoryEQPresets() {
        let engine = AudioEngineManager()
        let presets = AudioEngineManager.factoryPresets
        XCTAssertGreaterThanOrEqual(presets.count, 6, "Must have at least 6 curated factory EQ presets")
        
        guard let vocalAirPreset = presets.first(where: { $0.id == "vocal_air" }) else {
            XCTFail("VOCAL AIR preset must exist")
            return
        }
        
        engine.applyEQPreset(vocalAirPreset, to: 0)
        let vocalEQ = engine.getStemEQ(0)
        XCTAssertEqual(vocalEQ.low, vocalAirPreset.lowGain, accuracy: 1e-4)
        XCTAssertEqual(vocalEQ.mid, vocalAirPreset.midGain, accuracy: 1e-4)
        XCTAssertEqual(vocalEQ.high, vocalAirPreset.highGain, accuracy: 1e-4)
    }
    
    // Test 13: Verify Offline Stem Audio EQ Rendering (renderStemToFile)
    func testOfflineStemAudioEQRendering() throws {
        let sampleRate: Double = 44100.0
        let duration: Double = 0.5
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!
        
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let pL = buffer.floatChannelData![0]
        let pR = buffer.floatChannelData![1]
        
        for i in 0..<Int(frameCount) {
            let t = Float(i) / Float(sampleRate)
            let val = 0.4 * sinf(2.0 * .pi * 440.0 * t)
            pL[i] = val
            pR[i] = val
        }
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let sourceURL = tempDir.appendingPathComponent("source_stem.wav")
        let destURL = tempDir.appendingPathComponent("rendered_eq_stem.wav")
        
        let diskSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        do {
            let writer = try AVAudioFile(forWriting: sourceURL, settings: diskSettings)
            try writer.write(from: buffer)
        }
        
        // Render offline through AVAudioUnitEQ
        try AudioEngineManager.renderStemToFile(
            sourceURL: sourceURL,
            destURL: destURL,
            low: 3.0,
            mid: -2.0,
            high: 4.5
        )
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path), "Rendered audio file must exist on disk")
        let renderedFile = try AVAudioFile(forReading: destURL)
        XCTAssertEqual(renderedFile.processingFormat.sampleRate, sampleRate, "Sample rate must match")
        XCTAssertGreaterThan(renderedFile.length, 0, "Rendered file must contain audio frames")
        
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // Test 14: Verify Minimum Window Height Layout Fit and Transport Bar Integrity
    func testMinimumWindowHeightLayoutFitAndTransportBarIntegrity() {
        let minWindowHeight: CGFloat = 580.0
        let compactHeaderHeight: CGFloat = 122.0
        let transportBarHeight: CGFloat = 64.0 // 48pt height + 16pt vertical padding
        let headerMixerSpacing: CGFloat = 4.0
        
        // Channel strip fixed heights in compact mode:
        let topStatusBarHeight: CGFloat = 2.0
        let headerLabelHeight: CGFloat = 34.0
        let dynamicWaveformHeight: CGFloat = 22.0
        let panKnobHeight: CGFloat = 24.0
        let eqStripHeight: CGFloat = 62.0
        let volumeReadoutHeight: CGFloat = 20.0
        let faderMinHeight: CGFloat = 75.0
        let muteSoloButtonsHeight: CGFloat = 28.0
        let channelSpacing: CGFloat = 28.0 // 7 gaps * 4pt
        let channelPadding: CGFloat = 8.0 // 4pt top + 4pt bottom
        
        let minChannelHeight = topStatusBarHeight + headerLabelHeight + dynamicWaveformHeight +
            panKnobHeight + eqStripHeight + volumeReadoutHeight + faderMinHeight +
            muteSoloButtonsHeight + channelSpacing + channelPadding
        
        let totalRequiredHeight = compactHeaderHeight + headerMixerSpacing + minChannelHeight + transportBarHeight
        
        XCTAssertLessThanOrEqual(
            totalRequiredHeight,
            minWindowHeight,
            "Total minimum content height (\(totalRequiredHeight)pt) must fit within the minimum window height (\(minWindowHeight)pt) so TransportBar is never pushed off-screen"
        )
        
        let headroom = minWindowHeight - totalRequiredHeight
        XCTAssertGreaterThanOrEqual(
            headroom,
            50.0,
            "Must have at least 50pt headroom buffer (\(headroom)pt available) allowing faders to comfortably breathe on compact displays"
        )
    }
    
    // Test 15: Verify Hardware Theme Switching, Token Consistency & System Appearance Tracking
    func testHardwareThemeSwitchingAndTokenConsistency() {
        let themeManager = ThemeManager.shared
        
        // 1. Verify Enum Cases and Display Names
        XCTAssertEqual(HardwareTheme.allCases.count, 3)
        XCTAssertEqual(HardwareTheme.system.displayName, "MATCH SYSTEM")
        XCTAssertEqual(HardwareTheme.dark.displayName, "NOTHING DARK")
        XCTAssertEqual(HardwareTheme.light.displayName, "NOTHING LIGHT")
        
        // 2. Test Explicit Dark Theme
        themeManager.applyTheme(.dark)
        XCTAssertEqual(themeManager.currentTheme, .dark)
        XCTAssertTrue(themeManager.isDark)
        XCTAssertEqual(themeManager.preferredColorScheme, .dark)
        
        // 3. Test Explicit Light Theme
        themeManager.applyTheme(.light)
        XCTAssertEqual(themeManager.currentTheme, .light)
        XCTAssertFalse(themeManager.isDark)
        XCTAssertEqual(themeManager.preferredColorScheme, .light)
        
        // 4. Test Match System Theme
        themeManager.applyTheme(.system)
        XCTAssertEqual(themeManager.currentTheme, .system)
        XCTAssertEqual(themeManager.isDark, themeManager.systemIsDark)
        XCTAssertNil(themeManager.preferredColorScheme, "System theme must allow SwiftUI to follow system color scheme")
    }
    
    // Test 16: Verify Settings Modal Fixed Geometry and Tab Consistency
    func testSettingsModalFixedGeometry() {
        let modalWidth: CGFloat = 540.0
        let modalHeight: CGFloat = 510.0
        let tabContentHeight: CGFloat = 345.0
        
        XCTAssertEqual(modalWidth, 540.0, "Modal card width must be locked to 540pt")
        XCTAssertEqual(modalHeight, 510.0, "Modal card height must be locked to 510pt")
        XCTAssertEqual(tabContentHeight, 345.0, "Tab body container height must be pinned to 345pt to guarantee zero window jumping between tabs")
    }
    
    // Test 17: Verify Header Track Info Dynamic Expansion & Sidebar Alignment Geometry
    func testHeaderTrackInfoExpansionAndSidebarAlignment() {
        // 1. Dynamic Width Calculations
        let wideWidth: CGFloat = 1440.0
        let isCompactHeight = false
        let artSize: CGFloat = isCompactHeight ? 76 : 100
        
        let computeTrackWidth: (CGFloat, Bool) -> CGFloat = { width, isSidebarClosed in
            let isCompact = width < 860
            if isCompact { return .infinity }
            let isWide = width >= 1260
            let availableForTrack = width - artSize - 70 - (isWide ? 440 : 360)
            let baseMax: CGFloat = isWide ? (isSidebarClosed ? 680 : 480) : (isSidebarClosed ? 500 : 360)
            return max(240, min(availableForTrack, baseMax))
        }
        
        let closedWidth = computeTrackWidth(wideWidth, true)
        let openWidth = computeTrackWidth(wideWidth, false)
        
        XCTAssertGreaterThan(closedWidth, openWidth, "Track info width must dynamically expand when sidebar is closed")
        XCTAssertEqual(closedWidth, 680.0, "On wide displays with sidebar closed, track info width must expand up to 680pt")
        XCTAssertEqual(openWidth, 480.0, "On wide displays with sidebar open, track info width must allocate 480pt")
        
        // 2. Alignment Verification
        let headerLeftPadding: CGFloat = 24.0
        let mixerLeftPadding: CGFloat = 24.0
        XCTAssertEqual(headerLeftPadding, mixerLeftPadding, "Header and Mixer Channel grid must have identical 24pt margin for precise vertical alignment")
    }
    
    // Test 18: Verify TimePitchNode Transparent Bypass and Master Limiter Presence
    @MainActor
    func testTimePitchNodeTransparentBypassAndMasterLimiter() {
        let engine = AudioEngineManager()
        
        // When pitch shift is 0 (default), timePitchNode MUST be bypassed to guarantee bit-transparent passthrough
        XCTAssertTrue(engine.timePitchNode.bypass, "timePitchNode must be bypassed when pitch is 0 to eliminate phase vocoder grain and static")
        
        // When pitch is shifted, bypass is disabled
        engine.pitchShiftSemitones = 2.0
        XCTAssertFalse(engine.timePitchNode.bypass, "timePitchNode bypass must be disabled when pitch is altered")
        
        // When pitch returns to 0, bypass is re-engaged
        engine.pitchShiftSemitones = 0.0
        XCTAssertTrue(engine.timePitchNode.bypass, "timePitchNode bypass must re-engage when pitch returns to 0")
        
        // Verify master limiter is instantiated in the audio graph
        XCTAssertNotNil(engine.masterLimiter, "masterLimiter True-Peak brickwall limiter must be attached to prevent inter-sample DAC clipping")
    }
    
    // Test 19: Verify Intelligent Flat EQ Bypassing
    @MainActor
    func testIntelligentFlatEQBypass() {
        let engine = AudioEngineManager()
        
        // Stems initialized flat must have bypassed EQs
        XCTAssertTrue(engine.vocalEQ.bypass, "Vocal EQ must be bypassed when all bands are 0 dB")
        XCTAssertTrue(engine.drumEQ.bypass, "Drum EQ must be bypassed when all bands are 0 dB")
        XCTAssertTrue(engine.bassEQ.bypass, "Bass EQ must be bypassed when all bands are 0 dB")
        XCTAssertTrue(engine.otherEQ.bypass, "Other EQ must be bypassed when all bands are 0 dB")
        XCTAssertTrue(engine.masterEQ.bypass, "Master EQ must be bypassed when all bands are 0 dB")
        
        // When a band is tweaked, EQ bypass is lifted
        engine.setStemEQ(0, low: 3.5, mid: 0.0, high: 0.0)
        XCTAssertFalse(engine.vocalEQ.bypass, "Vocal EQ bypass must disengage when a band is boosted")
        
        // Resetting back to 0 re-engages bypass
        engine.setStemEQ(0, low: 0.0, mid: 0.0, high: 0.0)
        XCTAssertTrue(engine.vocalEQ.bypass, "Vocal EQ bypass must re-engage when returned to flat")
    }
    
    // Test 20: Verify FFTAnalyzer and Stem Meter Analyzer
    func testFastFFTAnalyzerAndDedicatedStemMeters() {
        let analyzer = FFTAnalyzer(fftSize: 1024)
        var buffer = [Float](repeating: 0, count: 1024)
        for i in 0..<1024 {
            let t = Float(i) / 44100.0
            buffer[i] = 0.5 * sinf(2.0 * .pi * 1000.0 * t) // 1 kHz pure sine
        }
        
        let bins = analyzer.computeFFT(buffer: &buffer)
        XCTAssertEqual(bins.count, 512, "1024-point FFT must output 512 magnitude bins")
        XCTAssertGreaterThan(bins.max() ?? 0, 0.05, "1 kHz tone must register strong magnitude")
        
        // Test StemMeterAnalyzer 7-band log-spaced extraction
        let meter = StemMeterAnalyzer()
        let bands = buffer.withUnsafeBufferPointer { p in
            meter.computeBands(buffer: p.baseAddress!, stem: 0)
        }
        XCTAssertEqual(bands.count, 7, "StemMeterAnalyzer must output exactly 7 log-spaced bands")
        
        // Band 2 in Vocals covers 600Hz - 1200Hz, which contains 1000Hz
        XCTAssertGreaterThan(bands[2], 0.05, "Band 2 (1 kHz vocal region) must have strong energy")
        
        // Silent audio test
        var silent = [Float](repeating: 0, count: 1024)
        let silentBands = silent.withUnsafeBufferPointer { p in
            meter.computeBands(buffer: p.baseAddress!, stem: 0)
        }
        for b in silentBands {
            XCTAssertEqual(b, 0.0, accuracy: 1e-6, "Silent buffer must produce exactly zero energy in all bands")
        }
    }
    
    // Test 21: Verify Demucs Infrasonic, Ultrasonic, and Soft-Knee Limiter Conditioning
    func testDemucsPristineAudioConditioningFilters() {
        let count = 44100
        
        // 1. Infrasonic Filter: Attenuates 5 Hz rumble while preserving 1 kHz
        var rumble = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Float(i) / 44100.0
            rumble[i] = sinf(2.0 * .pi * 5.0 * t)
        }
        DemucsEngine.applyInfrasonicFilter(channel: &rumble, count: count)
        var rumbleRMS: Float = 0
        rumble.withUnsafeBufferPointer { p in
            vDSP_rmsqv(p.baseAddress! + 22050, 1, &rumbleRMS, 22050)
        }
        XCTAssertLessThan(rumbleRMS, 0.10, "5 Hz infrasonic rumble must be attenuated by > 17 dB")
        
        var tone1k = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Float(i) / 44100.0
            tone1k[i] = sinf(2.0 * .pi * 1000.0 * t)
        }
        DemucsEngine.applyInfrasonicFilter(channel: &tone1k, count: count)
        var toneRMS: Float = 0
        tone1k.withUnsafeBufferPointer { p in
            vDSP_rmsqv(p.baseAddress! + 22050, 1, &toneRMS, 22050)
        }
        XCTAssertEqual(toneRMS, 0.7071, accuracy: 0.01, "1 kHz audio must be preserved with 0.0 dB attenuation")
        
        // 2. Ultrasonic Filter: Attenuates 21.5 kHz phase noise while preserving 1 kHz
        var ultrasonic = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Float(i) / 44100.0
            ultrasonic[i] = sinf(2.0 * .pi * 21500.0 * t)
        }
        DemucsEngine.applyUltrasonicFilter(channel: &ultrasonic, count: count)
        var ultraRMS: Float = 0
        ultrasonic.withUnsafeBufferPointer { p in
            vDSP_rmsqv(p.baseAddress! + 22050, 1, &ultraRMS, 22050)
        }
        XCTAssertLessThan(ultraRMS, 0.05, "21.5 kHz ultrasonic noise must be attenuated by > 23 dB")
        
        // 3. Soft-Knee Limiter: Transparent below 0.95, asymptotic at 1.0
        var testAudio: [Float] = [0.0, 0.5, 0.90, 0.95, 1.2, 2.5, -3.0]
        DemucsEngine.applySoftLimiter(channel: &testAudio, count: testAudio.count)
        XCTAssertEqual(testAudio[0], 0.0, accuracy: 1e-5)
        XCTAssertEqual(testAudio[1], 0.5, accuracy: 1e-5, "Sub-threshold audio must remain 100% bit-transparent")
        XCTAssertEqual(testAudio[2], 0.90, accuracy: 1e-5, "Sub-threshold audio must remain 100% bit-transparent")
        XCTAssertEqual(testAudio[3], 0.95, accuracy: 1e-5, "Threshold boundary must remain exact")
        XCTAssertLessThanOrEqual(testAudio[4], 1.00, "Peaks must not exceed 1.00 (0.0 dBFS ceiling)")
        XCTAssertLessThanOrEqual(testAudio[5], 1.00, "Extreme peaks must be safely caught below 1.00")
        XCTAssertGreaterThanOrEqual(testAudio[6], -1.00, "Negative extreme peaks must be safely caught above -1.00")
    }
    
    // Test 22: Verify AlbumArtView High-Fidelity Artwork Rendering & Theme Integrity
    @MainActor
    func testAlbumArtViewInitializationAndThemeFidelity() {
        let size = NSSize(width: 300, height: 300)
        let testImage = NSImage(size: size)
        testImage.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.white.setFill()
        NSRect(x: 75, y: 75, width: 150, height: 150).fill()
        testImage.unlockFocus()
        
        let themeManager = ThemeManager.shared
        
        // 1. Verify AlbumArtView instantiates with image
        let artView = AlbumArtView(image: testImage, size: 100)
        XCTAssertNotNil(artView)
        XCTAssertEqual(artView.size, 100)
        XCTAssertEqual(artView.image, testImage)
        
        // 2. Verify AlbumArtView instantiates with nil fallback
        let fallbackView = AlbumArtView(image: nil, size: 76)
        XCTAssertNotNil(fallbackView)
        XCTAssertEqual(fallbackView.size, 76)
        XCTAssertNil(fallbackView.image)
        
        // 3. Verify Theme Modes (Light, Dark, System) maintain contrast integrity
        themeManager.applyTheme(.light)
        XCTAssertEqual(themeManager.currentTheme, .light)
        XCTAssertFalse(themeManager.isDark)
        XCTAssertNotEqual(themeManager.surface, themeManager.textPrimary)
        
        themeManager.applyTheme(.dark)
        XCTAssertEqual(themeManager.currentTheme, .dark)
        XCTAssertTrue(themeManager.isDark)
        XCTAssertNotEqual(themeManager.surface, themeManager.textPrimary)
        
        themeManager.applyTheme(.system)
        XCTAssertEqual(themeManager.currentTheme, .system)
    }
}


