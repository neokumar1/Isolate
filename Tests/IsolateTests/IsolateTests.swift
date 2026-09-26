import XCTest
import Accelerate
import AVFoundation
import CoreML
import os
@testable import Isolate

@MainActor
final class IsolateTests: XCTestCase {

    override func setUpWithError() throws {
        // Tests that need sound start playback themselves.
        addTeardownBlock(Hardening.disableAutoPlay())
    }

    func testOverlapAddThroughAccumulateReconstructsTheInput() throws {
        // An identity "model" returns the normalised input for every source. The engine's
        // window, denormalisation and weighting must then give the input back.
        let chunkSize = DemucsEngine.chunkSize
        let hopSize = DemucsEngine.hopSize
        let mean: Float = 0.05
        let deviation: Float = 0.2
        let signal = (0..<(chunkSize + hopSize)).map { Float(0.3 * sin(Double($0) * 0.0123) + 0.1 * sin(Double($0) * 0.00071)) + mean }
        var window = [Float](repeating: 0, count: chunkSize)
        vDSP_hann_window(&window, vDSP_Length(chunkSize), Int32(vDSP_HANN_DENORM))
        // Contiguous Float32, and Float16 stored time-major so accumulate() must follow the strides.
        let layouts: [(MLMultiArrayDataType, [Int], Float)] = [
            (.float32, [8 * chunkSize, 2 * chunkSize, chunkSize, 1], 1e-5),
            (.float16, [8 * chunkSize, 2, 1, 8], 1e-3)
        ]
        for (dataType, strides, tolerance) in layouts {
            var accumulated: [[[Float]]] = []
            var weights: [[Float]] = []
            for start in [0, hopSize] {
                let elementSize = dataType == .float32 ? 4 : 2
                let storage = UnsafeMutableRawPointer.allocate(byteCount: 8 * chunkSize * elementSize, alignment: 16)
                for stem in 0..<4 {
                    for channel in 0..<2 {
                        // A per-target offset shows whether each result lands in its own stem and channel.
                        let offset = Float(stem * 2 + channel) * 0.01
                        for i in 0..<chunkSize {
                            let value = (signal[start + i] - mean) / deviation + offset
                            let index = stem * strides[1] + channel * strides[2] + i * strides[3]
                            if dataType == .float32 { storage.storeBytes(of: value, toByteOffset: index * 4, as: Float.self) }
                            else { storage.storeBytes(of: Float16(value), toByteOffset: index * 2, as: Float16.self) }
                        }
                    }
                }
                let output = try MLMultiArray(dataPointer: storage, shape: [1, 4, 2, NSNumber(value: chunkSize)],
                                              dataType: dataType, strides: strides.map { NSNumber(value: $0) }) { $0.deallocate() }
                var accumulators = (0..<8).map { _ in [Float](repeating: 0, count: chunkSize) }
                var chunkWeights = [Float](repeating: 0, count: chunkSize)
                try DemucsEngine.accumulate(output, into: &accumulators, weights: &chunkWeights, window: window,
                                            mean: mean, standardDeviation: deviation)
                accumulated.append(accumulators)
                weights.append(chunkWeights)
            }
            // The second half of the first chunk overlaps the first half of the second.
            for target in 0..<8 {
                let offset = Float(target) * 0.01 * deviation
                var worst: Float = 0
                for i in stride(from: 0, to: hopSize, by: 7) {
                    let weight = weights[0][hopSize + i] + weights[1][i]
                    let rebuilt = (accumulated[0][target][hopSize + i] + accumulated[1][target][i]) / max(1e-5, weight)
                    worst = max(worst, abs(rebuilt - (signal[hopSize + i] + offset)))
                }
                XCTAssertLessThan(worst, tolerance, "\(dataType == .float32 ? "Float32" : "Float16") target \(target)")
            }
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

    func testShortLivedFFTAnalyzersReleaseSetupOwnership() {
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
        
        let progressUpdates = OSAllocatedUnfairLock(initialState: [SplitProgressInfo]())
        // Skips only when no model is installed; a model that fails to load fails the test.
        let stemURLs = try await Hardening.splitRequiringModel(tempAudioURL) { info in
            progressUpdates.withLock { $0.append(info) }
        }

        XCTAssertEqual(stemURLs.count, 4, "Must output 4 stems (vocals, drums, bass, other)")
        // The 0% cache check is always reported; per-chunk progress must follow and finish.
        let updates = progressUpdates.withLock { $0 }
        let chunked = updates.filter { $0.totalChunks > 0 }
        XCTAssertEqual(chunked.first?.totalChunks, 4, "11.25 s spans four 5 s hops")
        XCTAssertEqual(chunked.map(\.currentChunk), Array(1...4), "Every chunk must report its progress")
        XCTAssertEqual(updates.map(\.fraction), updates.map(\.fraction).sorted(), "Progress must never move backwards")
        XCTAssertEqual(updates.last?.fraction, 1)

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
        
        // 1 kHz sits at the mid band's centre, so the mid gain applies in full.
        for i in 0..<Int(frameCount) {
            let t = Float(i) / Float(sampleRate)
            let val = 0.4 * sinf(2.0 * .pi * 1000.0 * t)
            pL[i] = val
            pR[i] = val
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
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
            mid: -6.0,
            high: 4.5
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path), "Rendered audio file must exist on disk")
        let renderedFile = try AVAudioFile(forReading: destURL)
        XCTAssertEqual(renderedFile.processingFormat.sampleRate, sampleRate, "Sample rate must match")
        XCTAssertEqual(renderedFile.length, AVAudioFramePosition(frameCount), "Rendered file must keep every frame")
        // Past the filters' settling time, the tone must be 6 dB quieter (shelves add little at 1 kHz).
        let rendered = try Hardening.samples(destURL)
        let gain = 20 * log10(Double(Hardening.peak(rendered.dropFirst(Int(frameCount) / 2)) / 0.4))
        XCTAssertEqual(gain, -6, accuracy: 1, "The stem EQ must be rendered into the file, not just stored")
    }
    

    
    func testHardwareThemeSwitchingAndTokenConsistency() {
        let themeManager = ThemeManager.shared
        // The shared theme outlives this test; later layout tests must see the one they started with.
        let originalTheme = themeManager.currentTheme
        defer { themeManager.applyTheme(originalTheme) }

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

    func testAudioEngineManagerReleasesMeterTapsDuringTeardown() throws {
        weak var releasedManager: AudioEngineManager?
        var output: AVAudioEngine?
        var stemMixers: [AVAudioNode] = []
        autoreleasepool {
            let manager = AudioEngineManager()
            releasedManager = manager
            output = manager.timePitchNode.engine
            stemMixers = [manager.vocalEQ, manager.drumEQ, manager.bassEQ, manager.otherEQ].compactMap {
                output?.outputConnectionPoints(for: $0, outputBus: 0).first?.node
            }
        }
        XCTAssertNil(releasedManager, "Audio engine teardown must release meter tap processors.")
        let engine = try XCTUnwrap(output)
        XCTAssertEqual(stemMixers.count, 4)
        // The taps capture the manager weakly, so release alone proves nothing. Installing on a
        // bus that still has a tap raises, so these succeed only if deinit removed every tap.
        for node in [engine.mainMixerNode] + stemMixers {
            node.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
            node.removeTap(onBus: 0)
        }
        XCTAssertFalse(engine.isRunning)
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
        
        // The limiter must sit between master EQ and the output, not merely exist.
        guard let graph = engine.timePitchNode.engine else { return XCTFail("The time/pitch node must be attached") }
        func next(_ node: AVAudioNode) -> AVAudioNode? { graph.outputConnectionPoints(for: node, outputBus: 0).first?.node }
        XCTAssertTrue(next(engine.timePitchNode) === engine.masterEQ)
        XCTAssertTrue(next(engine.masterEQ) === engine.masterLimiter, "Master EQ must feed the peak limiter")
        XCTAssertTrue(next(engine.masterLimiter) === graph.mainMixerNode, "The limiter must feed the output")
        XCTAssertFalse(engine.masterLimiter.bypass)
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
        
        // 4. Test togglePlayback (pause / play cycle); skips only without an output device
        try Hardening.requirePlayback(engine)
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
