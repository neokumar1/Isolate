import XCTest
import Accelerate
import AVFoundation
import os
@testable import Isolate

@MainActor
final class IsolateTests: XCTestCase {
    
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

    func testShortLivedFFTAnalyzersShareSafeSetupOwnership() {
        autoreleasepool {
            let analyzers = (0..<5).map { _ in FFTAnalyzer(fftSize: 1024) }
            var samples = [Float](repeating: 0.5, count: 1024)
            for analyzer in analyzers {
                XCTAssertEqual(analyzer.computeFFT(buffer: &samples).count, 512)
            }
        }
    }
    
    func testEndToEndStemSplittingWithSyntheticAudio() async throws {
        let sampleRate: Double = 44100.0
        let duration: Double = 11.25
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
        defer { try? FileManager.default.removeItem(at: tempDir) }
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
        
        let progressUpdates = OSAllocatedUnfairLock(initialState: [Double]())
        let stemURLs: [URL]
        do {
            stemURLs = try await DemucsEngine.shared.splitAudio(url: tempAudioURL) { info in
                progressUpdates.withLock { $0.append(info.fraction) }
            }
        } catch DemucsError.modelNotFound(let msg) {
            try? FileManager.default.removeItem(at: tempDir)
            if ProcessInfo.processInfo.environment["ISOLATE_REQUIRE_MODEL"] == "1" {
                XCTFail(msg)
                return
            }
            throw XCTSkip("Install the model to run inference: \(msg)")
        }
        
        XCTAssertEqual(stemURLs.count, 4, "Must output 4 stems (vocals, drums, bass, other)")
        XCTAssertFalse(progressUpdates.withLock { $0.isEmpty }, "Must send progress updates during splitting")
        
        for stemURL in stemURLs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: stemURL.path), "Stem file must exist on disk at \(stemURL.path)")
            let audioFile = try AVAudioFile(forReading: stemURL)
            XCTAssertEqual(audioFile.processingFormat.sampleRate, sampleRate, "Sample rate must be 44.1kHz")
            XCTAssertEqual(audioFile.processingFormat.channelCount, 2, "Must be stereo audio")
            XCTAssertEqual(audioFile.length, Int64(frameCount), "Stem audio length must match original input length")
            let rendered = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount)!
            try audioFile.read(into: rendered)
            for channel in 0..<2 {
                let samples = UnsafeBufferPointer(start: rendered.floatChannelData![channel], count: Int(frameCount))
                XCTAssertTrue(samples.allSatisfy(\.isFinite), "Model output must be finite across overlap boundaries")
            }
        }
        
        let cached = try await DemucsEngine.shared.splitAudio(url: tempAudioURL) { _ in }
        XCTAssertEqual(cached, stemURLs)
        // This directory belongs to the test-only cache root.
        if let first = stemURLs.first { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
    }
    
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

    func testThemeManagerUsesSafeDefaultBeforeAppKitApplicationExists() {
        XCTAssertTrue(
            ThemeManager.systemAppearanceIsDark(nil),
            "Theme initialization must not require NSApp to exist."
        )
    }

    func testAudioEngineManagerReleasesMeterTapsDuringTeardown() {
        weak var releasedManager: AudioEngineManager?
        autoreleasepool {
            let manager = AudioEngineManager()
            releasedManager = manager
        }
        XCTAssertNil(releasedManager, "Audio engine teardown must release meter tap processors.")
    }
    

    

    
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
    @MainActor
    func testMissingStemsWithoutSourceTriggersCleanUnloadAndErrorToast() async {
        let engine = AudioEngineManager()
        
        let dummyOrig = URL(fileURLWithPath: "/tmp/non_existent_isolate_track_\(UUID().uuidString).mp3")
        let dummyVocal = URL(fileURLWithPath: "/tmp/non_existent_isolate_stems_\(UUID().uuidString)/vocals.wav")
        let dummyDrum = URL(fileURLWithPath: "/tmp/non_existent_isolate_stems_\(UUID().uuidString)/drums.wav")
        let dummyBass = URL(fileURLWithPath: "/tmp/non_existent_isolate_stems_\(UUID().uuidString)/bass.wav")
        let dummyOther = URL(fileURLWithPath: "/tmp/non_existent_isolate_stems_\(UUID().uuidString)/other.wav")
        
        let track = TrackModel(
            id: dummyOrig.path,
            title: "By Design Test",
            originalURL: dummyOrig,
            vocalStemURL: dummyVocal,
            bassStemURL: dummyBass,
            drumStemURL: dummyDrum,
            otherStemURL: dummyOther
        )
        
        await engine.loadTrack(track)
        
        // Audio engine must NOT be left in an active/zombie state
        XCTAssertNil(engine.currentTrackID, "Current track ID must be cleared on missing stem/source failure")
        XCTAssertFalse(engine.isPlaying, "Audio engine must not be playing on load failure")
        XCTAssertNotNil(engine.errorMessage, "Error toast must be triggered on missing stem/source failure")
        XCTAssertTrue(engine.errorMessage?.contains("NOT FOUND") == true, "Error message must indicate missing audio source")
        
        // Clean up error message
        engine.dismissError()
        XCTAssertNil(engine.errorMessage, "Error message must be nil after dismissError")
    }
    
    @MainActor
    func testErrorToastStateAndDismissal() {
        let engine = AudioEngineManager()
        engine.showError("TEST ERROR MESSAGE")
        XCTAssertEqual(engine.errorMessage, "TEST ERROR MESSAGE")
        
        engine.dismissError()
        XCTAssertNil(engine.errorMessage)
    }
    
    @MainActor
    func testAudioGraphIntegrityAndPlaybackSafety() async throws {
        let engine = AudioEngineManager()
        
        // 1. Toggling playback when no track is loaded must be safe and not throw or change isPlaying
        XCTAssertFalse(engine.isPlaying)
        engine.togglePlayback()
        XCTAssertFalse(engine.isPlaying, "Toggling playback without loaded audio must not start playing")
        
        // 2. Synthesize test stems on disk
        let sampleRate: Double = 44100.0
        let frameCount = AVAudioFrameCount(sampleRate * 0.5) // 500ms
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        for ch in 0..<2 {
            let p = buffer.floatChannelData![ch]
            for i in 0..<Int(frameCount) {
                p[i] = 0.2 * sinf(2.0 * .pi * 440.0 * (Float(i) / Float(sampleRate)))
            }
        }
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let origURL = tempDir.appendingPathComponent("original.wav")
        let vocalURL = tempDir.appendingPathComponent("vocals.wav")
        let drumURL = tempDir.appendingPathComponent("drums.wav")
        let bassURL = tempDir.appendingPathComponent("bass.wav")
        let otherURL = tempDir.appendingPathComponent("other.wav")
        
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        for url in [origURL, vocalURL, drumURL, bassURL, otherURL] {
            let writer = try AVAudioFile(forWriting: url, settings: settings)
            try writer.write(from: buffer)
        }
        
        let track = TrackModel(
            id: origURL.path,
            title: "Safety Test Song",
            originalURL: origURL,
            vocalStemURL: vocalURL,
            bassStemURL: bassURL,
            drumStemURL: drumURL,
            otherStemURL: otherURL
        )
        
        // 3. Load track: Must connect graph and schedule players safely
        await engine.loadTrack(track)
        XCTAssertEqual(engine.currentTrackID, track.id)
        XCTAssertEqual(engine.currentTrackName, "SAFETY TEST SONG")
        
        // 4. Test togglePlayback (pause / play cycle)
        if !engine.isPlaying {
            engine.togglePlayback()
        }
        XCTAssertTrue(engine.isPlaying, "Audio engine must transition to playing without throwing 'disconnected state' error")
        
        // 5. Pause
        engine.togglePlayback()
        XCTAssertFalse(engine.isPlaying, "Audio engine must cleanly pause")
        
        // 6. Resume
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying, "Audio engine must cleanly resume without error")
        
        // 7. Unload track
        engine.unloadTrack()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertNil(engine.currentTrackID)
    }
}
