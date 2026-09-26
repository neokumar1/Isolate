@preconcurrency import AVFoundation
import Observation
import SwiftUI
import SwiftData
import Accelerate
import AppKit
import UniformTypeIdentifiers

public struct TrackData: Sendable {
    public let id: String
    public let title: String
    public let originalURL: URL
    public let vocalStemURL: URL
    public let bassStemURL: URL
    public let drumStemURL: URL
    public let otherStemURL: URL
}

public enum ExportState: Equatable, Sendable {
    case idle
    case exporting(stage: String, percent: Double)
    case completed
}

public struct EQPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let targetStemName: String // "VOCALS", "DRUMS", "BASS", "OTHER", "MASTER", "ALL"
    public let lowGain: Float
    public let midGain: Float
    public let highGain: Float
    
    public init(id: String, name: String, targetStemName: String, lowGain: Float, midGain: Float, highGain: Float) {
        self.id = id
        self.name = name
        self.targetStemName = targetStemName
        self.lowGain = lowGain
        self.midGain = midGain
        self.highGain = highGain
    }
}

@MainActor
@Observable
public final class AudioEngineManager {
    // MARK: - Audio Engine Nodes
    private let engine = AVAudioEngine()
    
    private let vocalPlayer = AVAudioPlayerNode()
    private let drumPlayer = AVAudioPlayerNode()
    private let bassPlayer = AVAudioPlayerNode()
    private let otherPlayer = AVAudioPlayerNode()
    private let originalPlayer = AVAudioPlayerNode()
    
    internal let vocalEQ = AVAudioUnitEQ(numberOfBands: 3)
    internal let drumEQ = AVAudioUnitEQ(numberOfBands: 3)
    internal let bassEQ = AVAudioUnitEQ(numberOfBands: 3)
    internal let otherEQ = AVAudioUnitEQ(numberOfBands: 3)
    internal let masterEQ = AVAudioUnitEQ(numberOfBands: 3)
    
    private let vocalMixer = AVAudioMixerNode()
    private let drumMixer = AVAudioMixerNode()
    private let bassMixer = AVAudioMixerNode()
    private let otherMixer = AVAudioMixerNode()
    private let stemsSumMixer = AVAudioMixerNode()
    private let comparisonMixer = AVAudioMixerNode()
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    public var importRequested = false
    public var hasLoadedTrack: Bool { fileVocals != nil }
    public var canBypass: Bool { audioFile != nil }
    internal let timePitchNode = AVAudioUnitTimePitch()
    internal let masterLimiter: AVAudioUnitEffect = {
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return AVAudioUnitEffect(audioComponentDescription: desc)
    }()
    
    // MARK: - Playback State
    public var isPlaying = false {
        didSet {
            MenuBarManager.shared.updatePlaybackState(isPlaying: isPlaying)
        }
    }
    public var currentTrackID: String? = nil
    public var currentTrackName: String = "NO TRACK LOADED"
    public var trackTitle: String = ""
    public var trackArtist: String = "Isolate"
    public var trackAlbum: String = "4-Stem Neural Audio"
    public var trackSampleRate: String = "44.1 kHz"
    public var trackBitDepth: String = "24-BIT PCM"
    public var trackAudioFormat: String = "WAV"
    public var trackBPM: String = "BPM UNKNOWN"
    public var trackMusicalKey: String = "KEY UNKNOWN"
    
    // Dynamic real-time transposed musical key based on pitchShiftSemitones
    public var effectiveMusicalKey: String {
        let st = Int(pitchShiftSemitones.rounded())
        if st == 0 || trackMusicalKey.isEmpty {
            return trackMusicalKey
        }
        
        let chromaticScaleSharp = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let chromaticScaleFlat = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
        
        let key = trackMusicalKey.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "♭", with: "b")
        guard let first = key.first, "ABCDEFG".contains(first.uppercased()) else { return trackMusicalKey }
        let rootLength = key.count > 1 && ["#", "b", "B"].contains(String(key.dropFirst().first!)) ? 2 : 1
        let root = String(key.prefix(rootLength))
        let suffix = String(key.dropFirst(rootLength))
        let mode = suffix.trimmingCharacters(in: .whitespaces)
        guard ["", "m", "min", "minor", "maj", "major"].contains(mode.lowercased()) else { return trackMusicalKey }
        
        var currentIndex = chromaticScaleSharp.firstIndex(of: root.uppercased())
        if currentIndex == nil {
            currentIndex = chromaticScaleFlat.firstIndex(where: { $0.uppercased() == root.uppercased() })
        }
        
        guard let idx = currentIndex else { return trackMusicalKey }
        var newIdx = (idx + st) % 12
        if newIdx < 0 { newIdx += 12 }
        
        let newRoot = chromaticScaleSharp[newIdx]
        return newRoot + suffix
    }
    
    // Dynamic real-time scaled BPM based on playbackRate
    public var effectiveBPM: String {
        guard let baseVal = Double(trackBPM.replacingOccurrences(of: " BPM", with: "").trimmingCharacters(in: .whitespacesAndNewlines)), baseVal > 0 else {
            return trackBPM
        }
        let scaled = baseVal * playbackRate
        return String(format: "%.1f BPM", scaled)
    }
    
    public var detailedTimecode: String = "00:00.000 / -00:00.000"
    public var albumArt: NSImage?
    public var playbackProgress: Double = 0.0
    public var seekFrameOffset: AVAudioFramePosition = 0
    public var currentTimeString: String = "00:00 / -00:00"
    public var isBypassed: Bool = false { didSet { applyVolumes() } }
    
    // MARK: - Master Pitch & Tempo Controls
    private var storedPitchShiftSemitones: Double = 0
    public var pitchShiftSemitones: Double {
        get { storedPitchShiftSemitones }
        set {
            storedPitchShiftSemitones = newValue.isFinite ? min(12, max(-12, newValue)) : 0
            timePitchNode.pitch = Float(storedPitchShiftSemitones * 100.0) // 100 cents per semitone
            updateTimePitchBypass()
        }
    }
    private var storedPlaybackRate: Double = 1
    public var playbackRate: Double {
        get { storedPlaybackRate }
        set {
            storedPlaybackRate = newValue.isFinite ? min(2, max(0.5, newValue)) : 1
            timePitchNode.rate = Float(storedPlaybackRate)
            updateTimePitchBypass()
            NowPlayingManager.shared.updateNowPlayingPlaybackState()
        }
    }
    
    private func updateTimePitchBypass() {
        let isDefault = abs(pitchShiftSemitones) < 0.001 && abs(playbackRate - 1.0) < 0.001
        timePitchNode.bypass = isDefault
    }
    
    // MARK: - A-B Loop Controls
    public var isLooping: Bool = false
    public var loopStartProgress: Double = 0.0
    public var loopEndProgress: Double = 1.0
    
    public func toggleLoop() {
        Haptics.playClick()
        isLooping.toggle()
    }
    
    /// Shortest A–B region in seconds, so short phrases can be looped on long tracks.
    nonisolated static let minimumLoopSeconds = 0.5

    nonisolated static func minimumLoopProgress(duration: Double?) -> Double {
        guard let duration, duration > 0 else { return 0.02 }
        return min(0.5, minimumLoopSeconds / duration)
    }

    public func setLoopStart(_ progress: Double) {
        guard progress.isFinite else { return }
        let gap = Self.minimumLoopProgress(duration: totalTrackDuration)
        // A start at or past the current end begins a new region instead of clamping backwards.
        if progress >= loopEndProgress { loopEndProgress = 1.0 }
        loopStartProgress = max(0.0, min(progress, loopEndProgress - gap))
        isLooping = true
        Haptics.playClick()
    }
    
    public func setLoopEnd(_ progress: Double) {
        guard progress.isFinite else { return }
        let gap = Self.minimumLoopProgress(duration: totalTrackDuration)
        if progress <= loopStartProgress { loopStartProgress = 0.0 }
        loopEndProgress = min(1.0, max(progress, loopStartProgress + gap))
        isLooping = true
        Haptics.playClick()
    }
    
    public func resetLoop() {
        isLooping = false
        loopStartProgress = 0.0
        loopEndProgress = 1.0
        Haptics.playClick()
    }
    
    // MARK: - HUD Visualizer Mode State (0: 32-BAND FFT, 1: STEM MACROS, 2: STEM BALANCE, 3: TELEMETRY, 4: EQUALIZER)
    public var activeHUDModeIndex: Int = 0
    
    @MainActor
    public func setHUDMode(_ index: Int) {
        guard index >= 0 && index < 5 else { return }
        activeHUDModeIndex = index
    }
    
    private var lastSyncedNowPlayingSec: Int = -1
    
    public var totalTrackDuration: Double? {
        guard let fVocals = fileVocals else { return nil }
        let duration = Double(fVocals.length) / fVocals.processingFormat.sampleRate
        return duration > 0 ? duration : nil
    }
    
    public var currentPlaybackTimeSeconds: Double? {
        guard fileVocals != nil,
              let lastTime = vocalPlayer.lastRenderTime,
              let playerTime = vocalPlayer.playerTime(forNodeTime: lastTime) else {
            return (playbackProgress > 0 && totalTrackDuration != nil) ? (playbackProgress * totalTrackDuration!) : 0.0
        }
        let elapsedFrames = Double(playerTime.sampleTime) + Double(seekFrameOffset)
        return max(0, elapsedFrames / playerTime.sampleRate)
    }
    
    // MARK: - Toast Error State
    public var errorMessage: String? = nil
    
    private var playbackSessionID = UUID()
    
    // MARK: - Stem Volumes, Mute, Solo (Default 1.0 = Unity Gain / 0 dB)
    public var vocalVolume: Double = 1.0 { didSet { applyVolumes() } }
    public var drumVolume: Double = 1.0 { didSet { applyVolumes() } }
    public var bassVolume: Double = 1.0 { didSet { applyVolumes() } }
    public var otherVolume: Double = 1.0 { didSet { applyVolumes() } }
    
    // MARK: - Stem Stereo Panning (-1.0 Left to +1.0 Right)
    public var vocalPan: Float = 0.0 { didSet { vocalMixer.pan = vocalPan } }
    public var drumPan: Float = 0.0 { didSet { drumMixer.pan = drumPan } }
    public var bassPan: Float = 0.0 { didSet { bassMixer.pan = bassPan } }
    public var otherPan: Float = 0.0 { didSet { otherMixer.pan = otherPan } }
    
    public var vocalMuted = false { didSet { applyVolumes() } }
    public var drumMuted = false { didSet { applyVolumes() } }
    public var bassMuted = false { didSet { applyVolumes() } }
    public var otherMuted = false { didSet { applyVolumes() } }
    
    public var vocalSolo = false { didSet { applyVolumes() } }
    public var drumSolo = false { didSet { applyVolumes() } }
    public var bassSolo = false { didSet { applyVolumes() } }
    public var otherSolo = false { didSet { applyVolumes() } }
    
    // MARK: - 3-Band Semi-Parametric Equalizer State (Gains in dB: -12.0 to +12.0)
    public var vocalEQLow: Float = 0.0 { didSet { updateEQNode(vocalEQ, low: vocalEQLow, mid: vocalEQMid, high: vocalEQHigh) } }
    public var vocalEQMid: Float = 0.0 { didSet { updateEQNode(vocalEQ, low: vocalEQLow, mid: vocalEQMid, high: vocalEQHigh) } }
    public var vocalEQHigh: Float = 0.0 { didSet { updateEQNode(vocalEQ, low: vocalEQLow, mid: vocalEQMid, high: vocalEQHigh) } }
    public var vocalEQBypassed: Bool = false { didSet { updateEQBypass(vocalEQ, isBypassed: vocalEQBypassed || isGlobalEQBypassed) } }
    
    public var drumEQLow: Float = 0.0 { didSet { updateEQNode(drumEQ, low: drumEQLow, mid: drumEQMid, high: drumEQHigh) } }
    public var drumEQMid: Float = 0.0 { didSet { updateEQNode(drumEQ, low: drumEQLow, mid: drumEQMid, high: drumEQHigh) } }
    public var drumEQHigh: Float = 0.0 { didSet { updateEQNode(drumEQ, low: drumEQLow, mid: drumEQMid, high: drumEQHigh) } }
    public var drumEQBypassed: Bool = false { didSet { updateEQBypass(drumEQ, isBypassed: drumEQBypassed || isGlobalEQBypassed) } }
    
    public var bassEQLow: Float = 0.0 { didSet { updateEQNode(bassEQ, low: bassEQLow, mid: bassEQMid, high: bassEQHigh) } }
    public var bassEQMid: Float = 0.0 { didSet { updateEQNode(bassEQ, low: bassEQLow, mid: bassEQMid, high: bassEQHigh) } }
    public var bassEQHigh: Float = 0.0 { didSet { updateEQNode(bassEQ, low: bassEQLow, mid: bassEQMid, high: bassEQHigh) } }
    public var bassEQBypassed: Bool = false { didSet { updateEQBypass(bassEQ, isBypassed: bassEQBypassed || isGlobalEQBypassed) } }
    
    public var otherEQLow: Float = 0.0 { didSet { updateEQNode(otherEQ, low: otherEQLow, mid: otherEQMid, high: otherEQHigh) } }
    public var otherEQMid: Float = 0.0 { didSet { updateEQNode(otherEQ, low: otherEQLow, mid: otherEQMid, high: otherEQHigh) } }
    public var otherEQHigh: Float = 0.0 { didSet { updateEQNode(otherEQ, low: otherEQLow, mid: otherEQMid, high: otherEQHigh) } }
    public var otherEQBypassed: Bool = false { didSet { updateEQBypass(otherEQ, isBypassed: otherEQBypassed || isGlobalEQBypassed) } }
    
    public var masterEQLow: Float = 0.0 { didSet { updateEQNode(masterEQ, low: masterEQLow, mid: masterEQMid, high: masterEQHigh) } }
    public var masterEQMid: Float = 0.0 { didSet { updateEQNode(masterEQ, low: masterEQLow, mid: masterEQMid, high: masterEQHigh) } }
    public var masterEQHigh: Float = 0.0 { didSet { updateEQNode(masterEQ, low: masterEQLow, mid: masterEQMid, high: masterEQHigh) } }
    public var masterEQBypassed: Bool = false { didSet { updateEQBypass(masterEQ, isBypassed: masterEQBypassed || isGlobalEQBypassed) } }
    
    public var isGlobalEQBypassed: Bool = false {
        didSet {
            refreshEQBypass(vocalEQ)
            refreshEQBypass(drumEQ)
            refreshEQBypass(bassEQ)
            refreshEQBypass(otherEQ)
            refreshEQBypass(masterEQ)
        }
    }
    
    public var shouldBakeEQOnExport: Bool = true
    
    private func updateEQNode(_ eq: AVAudioUnitEQ, low: Float, mid: Float, high: Float) {
        guard eq.bands.count >= 3 else { return }
        eq.bands[0].gain = low
        eq.bands[1].gain = mid
        eq.bands[2].gain = high
        refreshEQBypass(eq)
    }
    
    private func updateEQBypass(_ eq: AVAudioUnitEQ, isBypassed: Bool) {
        refreshEQBypass(eq)
    }
    
    private func refreshEQBypass(_ eq: AVAudioUnitEQ) {
        let isUserBypassed: Bool
        let isFlat: Bool
        
        if eq === vocalEQ {
            isUserBypassed = vocalEQBypassed
            isFlat = abs(vocalEQLow) < 0.01 && abs(vocalEQMid) < 0.01 && abs(vocalEQHigh) < 0.01
        } else if eq === drumEQ {
            isUserBypassed = drumEQBypassed
            isFlat = abs(drumEQLow) < 0.01 && abs(drumEQMid) < 0.01 && abs(drumEQHigh) < 0.01
        } else if eq === bassEQ {
            isUserBypassed = bassEQBypassed
            isFlat = abs(bassEQLow) < 0.01 && abs(bassEQMid) < 0.01 && abs(bassEQHigh) < 0.01
        } else if eq === otherEQ {
            isUserBypassed = otherEQBypassed
            isFlat = abs(otherEQLow) < 0.01 && abs(otherEQMid) < 0.01 && abs(otherEQHigh) < 0.01
        } else if eq === masterEQ {
            isUserBypassed = masterEQBypassed
            isFlat = abs(masterEQLow) < 0.01 && abs(masterEQMid) < 0.01 && abs(masterEQHigh) < 0.01
        } else {
            isUserBypassed = false
            isFlat = true
        }
        
        eq.bypass = isUserBypassed || isGlobalEQBypassed || isFlat
    }
    
    public func setStemEQ(_ index: Int, low: Float, mid: Float, high: Float) {
        switch index {
        case 0:
            vocalEQLow = max(-12.0, min(12.0, low))
            vocalEQMid = max(-12.0, min(12.0, mid))
            vocalEQHigh = max(-12.0, min(12.0, high))
        case 1:
            drumEQLow = max(-12.0, min(12.0, low))
            drumEQMid = max(-12.0, min(12.0, mid))
            drumEQHigh = max(-12.0, min(12.0, high))
        case 2:
            bassEQLow = max(-12.0, min(12.0, low))
            bassEQMid = max(-12.0, min(12.0, mid))
            bassEQHigh = max(-12.0, min(12.0, high))
        case 3:
            otherEQLow = max(-12.0, min(12.0, low))
            otherEQMid = max(-12.0, min(12.0, mid))
            otherEQHigh = max(-12.0, min(12.0, high))
        case 4:
            masterEQLow = max(-12.0, min(12.0, low))
            masterEQMid = max(-12.0, min(12.0, mid))
            masterEQHigh = max(-12.0, min(12.0, high))
        default:
            break
        }
    }
    
    public func getStemEQ(_ index: Int) -> (low: Float, mid: Float, high: Float, isBypassed: Bool) {
        switch index {
        case 0: return (vocalEQLow, vocalEQMid, vocalEQHigh, vocalEQBypassed)
        case 1: return (drumEQLow, drumEQMid, drumEQHigh, drumEQBypassed)
        case 2: return (bassEQLow, bassEQMid, bassEQHigh, bassEQBypassed)
        case 3: return (otherEQLow, otherEQMid, otherEQHigh, otherEQBypassed)
        case 4: return (masterEQLow, masterEQMid, masterEQHigh, masterEQBypassed)
        default: return (0, 0, 0, false)
        }
    }
    
    public func resetStemEQ(_ index: Int) {
        Haptics.playClick()
        setStemEQ(index, low: 0.0, mid: 0.0, high: 0.0)
    }
    
    public func resetAllEQ() {
        Haptics.playClick()
        for i in 0...4 {
            setStemEQ(i, low: 0.0, mid: 0.0, high: 0.0)
        }
    }
    
    public func toggleStemEQBypass(_ index: Int) {
        Haptics.playClick()
        switch index {
        case 0: vocalEQBypassed.toggle()
        case 1: drumEQBypassed.toggle()
        case 2: bassEQBypassed.toggle()
        case 3: otherEQBypassed.toggle()
        case 4: masterEQBypassed.toggle()
        default: break
        }
    }
    
    public func toggleGlobalEQBypass() {
        Haptics.playClick()
        isGlobalEQBypassed.toggle()
    }
    
    public static let factoryPresets: [EQPreset] = [
        EQPreset(id: "flat", name: "FLAT / RESET", targetStemName: "ALL", lowGain: 0.0, midGain: 0.0, highGain: 0.0),
        EQPreset(id: "vocal_air", name: "VOCAL AIR & SHEEN", targetStemName: "VOCALS", lowGain: -2.5, midGain: 1.5, highGain: 4.0),
        EQPreset(id: "vocal_demud", name: "DE-MUD VOCALS", targetStemName: "VOCALS", lowGain: -4.0, midGain: -3.0, highGain: 1.0),
        EQPreset(id: "bass_thump", name: "SUB BASS THUMP", targetStemName: "BASS", lowGain: 3.5, midGain: -2.0, highGain: -4.0),
        EQPreset(id: "drum_punch", name: "SNARE & KICK PUNCH", targetStemName: "DRUMS", lowGain: 2.5, midGain: -1.5, highGain: 3.0),
        EQPreset(id: "inst_bright", name: "INSTRUMENTAL BRIGHT", targetStemName: "OTHER", lowGain: -1.5, midGain: 1.0, highGain: 3.5),
        EQPreset(id: "master_warmth", name: "MASTER ANALOG WARMTH", targetStemName: "MASTER", lowGain: 1.5, midGain: -0.5, highGain: 1.0)
    ]
    
    public func applyEQPreset(_ preset: EQPreset, to index: Int) {
        Haptics.playClick()
        setStemEQ(index, low: preset.lowGain, mid: preset.midGain, high: preset.highGain)
    }
    
    // MARK: - Live Visualizers (Waveform & Per-Stem EQ)
    public var masterWaveformAmplitudes: [Float] = Array(repeating: 0.05, count: 30)
    public var originalWaveformAmplitudes: [Float] = Array(repeating: 0.05, count: 30)
    
    public var masterEQMagnitudes: [Float] = Array(repeating: 0, count: 32)
    public var stemPeaks: [Float] = Array(repeating: 0, count: 4)
    public var vocalEQMagnitudes: [Float] = Array(repeating: 0, count: 7)
    public var drumEQMagnitudes: [Float] = Array(repeating: 0, count: 7)
    public var bassEQMagnitudes: [Float] = Array(repeating: 0, count: 7)
    public var otherEQMagnitudes: [Float] = Array(repeating: 0, count: 7)

    // MARK: - Splitting & Progress State
    public var isSplitting = false
    public var isCompilingModel = false
    public var splitProgress = 0.0
    public var currentChunkNumber = 0
    public var totalChunkCount = 0
    public var etaRemainingString = "00:05"
    public var splitStatusMessage: String = "ANALYZING STEMS..."
    public static var systemChipName: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        if size > 0 {
            var machine = [CChar](repeating: 0, count: size)
            sysctlbyname("machdep.cpu.brand_string", &machine, &size, nil, 0)
            let brand = String(cString: machine).trimmingCharacters(in: .whitespacesAndNewlines)
            if !brand.isEmpty {
                return brand.uppercased()
            }
        }
        return "APPLE SILICON"
    }
    
    public var liveSpeedSubtitle: String = "ON-DEVICE CORE ML PROCESSING"
    
    // MARK: - Export State
    public var exportState: ExportState = .idle
    public var isExporting: Bool { exportState != .idle }
    public var exportProgress: Double = 0.0
    
    // MARK: - Audio File Handles
    private var audioFile: AVAudioFile?
    private var fileVocals: AVAudioFile?
    private var fileDrums: AVAudioFile?
    private var fileBass: AVAudioFile?
    private var fileOther: AVAudioFile?
    private let playbackClock = PlaybackClock()
    
    // MARK: - Initialization
    public init() {
        setupAudioGraph()
    }
    
    private func setupAudioGraph() {
        engine.attach(vocalPlayer)
        engine.attach(drumPlayer)
        engine.attach(bassPlayer)
        engine.attach(otherPlayer)
        engine.attach(originalPlayer)
        
        engine.attach(vocalEQ)
        engine.attach(drumEQ)
        engine.attach(bassEQ)
        engine.attach(otherEQ)
        engine.attach(masterEQ)
        
        configureEQNode(vocalEQ)
        configureEQNode(drumEQ)
        configureEQNode(bassEQ)
        configureEQNode(otherEQ)
        configureEQNode(masterEQ)
        
        engine.attach(vocalMixer)
        engine.attach(drumMixer)
        engine.attach(bassMixer)
        engine.attach(otherMixer)
        engine.attach(stemsSumMixer)
        engine.attach(comparisonMixer)
        engine.attach(timePitchNode)
        engine.attach(masterLimiter)
        
        // Bypass time/pitch processing at unity rate and zero pitch.
        timePitchNode.overlap = 32.0 // Time/pitch analysis overlap
        timePitchNode.bypass = true  // Bit-transparent bypass when at root pitch and 1.0x rate
        
        // Connect players through 3-Band EQs into channel mixers
        engine.connect(vocalPlayer, to: vocalEQ, format: StreamingAudio.format)
        engine.connect(vocalEQ, to: vocalMixer, format: StreamingAudio.format)
        
        engine.connect(drumPlayer, to: drumEQ, format: StreamingAudio.format)
        engine.connect(drumEQ, to: drumMixer, format: StreamingAudio.format)
        
        engine.connect(bassPlayer, to: bassEQ, format: StreamingAudio.format)
        engine.connect(bassEQ, to: bassMixer, format: StreamingAudio.format)
        
        engine.connect(otherPlayer, to: otherEQ, format: StreamingAudio.format)
        engine.connect(otherEQ, to: otherMixer, format: StreamingAudio.format)
        
        // Connect channel mixers into the stems sum mixer
        engine.connect(vocalMixer, to: stemsSumMixer, format: StreamingAudio.format)
        engine.connect(drumMixer, to: stemsSumMixer, format: StreamingAudio.format)
        engine.connect(bassMixer, to: stemsSumMixer, format: StreamingAudio.format)
        engine.connect(otherMixer, to: stemsSumMixer, format: StreamingAudio.format)
        
        // Connect stemsSumMixer through timePitchNode to masterEQ to masterLimiter to main mixer
        engine.connect(stemsSumMixer, to: comparisonMixer, format: StreamingAudio.format)
        engine.connect(originalPlayer, to: comparisonMixer, format: StreamingAudio.format)
        engine.connect(comparisonMixer, to: timePitchNode, format: StreamingAudio.format)
        engine.connect(timePitchNode, to: masterEQ, format: StreamingAudio.format)
        engine.connect(masterEQ, to: masterLimiter, format: StreamingAudio.format)
        engine.connect(masterLimiter, to: engine.mainMixerNode, format: StreamingAudio.format)
        
        installMeter(on: engine.mainMixerNode, stem: nil)
        for (index, mixer) in [vocalMixer, drumMixer, bassMixer, otherMixer].enumerated() {
            installMeter(on: mixer, stem: index)
        }
        applyVolumes()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hasLoadedTrack else { return }
                let resume = self.isPlaying
                self.isPlaying = false
                self.playbackClock.timer?.invalidate()
                self.seek(toPercentage: self.playbackProgress)
                if resume { self.playSynced() }
            }
        }
    }

    private func installMeter(on node: AVAudioNode, stem: Int?) {
        let processor = AudioMeterProcessor(bandCount: stem == nil ? 32 : 7)
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let reading = processor.process(buffer) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                if let stem { self.stemPeaks[stem] = reading.peak }
                switch stem {
                case 0: self.vocalEQMagnitudes = reading.spectrum
                case 1: self.drumEQMagnitudes = reading.spectrum
                case 2: self.bassEQMagnitudes = reading.spectrum
                case 3: self.otherEQMagnitudes = reading.spectrum
                default:
                    self.masterEQMagnitudes = reading.spectrum
                    self.masterWaveformAmplitudes = reading.waveform
                }
            }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        activeSplitTask?.cancel()
        metadataTask?.cancel()
        let nodes = [engine.mainMixerNode, vocalMixer, drumMixer, bassMixer, otherMixer]
        let teardown: @MainActor @Sendable () -> Void = { [engine, playbackClock] in
            playbackClock.timer?.invalidate()
            engine.stop()
            for node in nodes { node.removeTap(onBus: 0) }
            engine.reset()
        }
        // Keep graph/timer cleanup on their owning thread without the isolated
        // deinit back-deployment runtime, which crashes on macOS 15 test hosts.
        if Thread.isMainThread {
            MainActor.assumeIsolated { teardown() }
        } else {
            DispatchQueue.main.async(execute: teardown)
        }
    }

    private func configureEQNode(_ eq: AVAudioUnitEQ) {
        guard eq.bands.count >= 3 else { return }
        
        let low = eq.bands[0]
        low.filterType = .lowShelf
        low.frequency = 100.0
        low.gain = 0.0
        low.bypass = false
        
        let mid = eq.bands[1]
        mid.filterType = .parametric
        mid.frequency = 1000.0
        mid.bandwidth = 1.2
        mid.gain = 0.0
        mid.bypass = false
        
        let high = eq.bands[2]
        high.filterType = .highShelf
        high.frequency = 10000.0
        high.gain = 0.0
        high.bypass = false
        
        eq.bypass = true // Bit-transparent bypass until user turns EQ knobs
    }
    
    private func applyVolumes() {
        if isBypassed && canBypass {
            stemsSumMixer.outputVolume = 0.0
            originalPlayer.volume = 1.0
            return
        }
        
        originalPlayer.volume = 0.0
        stemsSumMixer.outputVolume = 1.0
        
        let anySolo = vocalSolo || drumSolo || bassSolo || otherSolo
        
        let applyChannel = { (vol: Double, muted: Bool, soloed: Bool, mixer: AVAudioMixerNode) in
            if anySolo {
                mixer.outputVolume = soloed ? Float(vol) : 0.0
            } else {
                mixer.outputVolume = muted ? 0.0 : Float(vol)
            }
        }
        
        applyChannel(vocalVolume, vocalMuted, vocalSolo, vocalMixer)
        applyChannel(drumVolume, drumMuted, drumSolo, drumMixer)
        applyChannel(bassVolume, bassMuted, bassSolo, bassMixer)
        applyChannel(otherVolume, otherMuted, otherSolo, otherMixer)
        
        if vocalVolume <= 0.001 || vocalMuted || (anySolo && !vocalSolo) { vocalEQMagnitudes = Array(repeating: 0, count: 7) }
        if drumVolume <= 0.001 || drumMuted || (anySolo && !drumSolo) { drumEQMagnitudes = Array(repeating: 0, count: 7) }
        if bassVolume <= 0.001 || bassMuted || (anySolo && !bassSolo) { bassEQMagnitudes = Array(repeating: 0, count: 7) }
        if otherVolume <= 0.001 || otherMuted || (anySolo && !otherSolo) { otherEQMagnitudes = Array(repeating: 0, count: 7) }
    }
    
    // MARK: - Exclusive Radio-Style Stem Soloing & Muting
    public func soloStem(_ index: Int) {
        // 0: Vocals, 1: Drums, 2: Bass, 3: Other
        let isCurrentlySoloed: Bool
        switch index {
        case 0: isCurrentlySoloed = vocalSolo
        case 1: isCurrentlySoloed = drumSolo
        case 2: isCurrentlySoloed = bassSolo
        case 3: isCurrentlySoloed = otherSolo
        default: isCurrentlySoloed = false
        }
        
        if isCurrentlySoloed {
            // Toggling off: Un-solo all stems, return to normal playback
            vocalSolo = false
            drumSolo = false
            bassSolo = false
            otherSolo = false
        } else {
            // Exclusive Solo: Only solo the selected stem, clear all other 3 stems
            vocalSolo = (index == 0)
            drumSolo = (index == 1)
            bassSolo = (index == 2)
            otherSolo = (index == 3)
            
            // Clear mute on the active soloed stem so audio is immediately heard
            if index == 0 { vocalMuted = false }
            if index == 1 { drumMuted = false }
            if index == 2 { bassMuted = false }
            if index == 3 { otherMuted = false }
        }
    }
    
    public func toggleMute(_ index: Int) {
        switch index {
        case 0:
            vocalMuted.toggle()
            if vocalMuted { vocalSolo = false }
        case 1:
            drumMuted.toggle()
            if drumMuted { drumSolo = false }
        case 2:
            bassMuted.toggle()
            if bassMuted { bassSolo = false }
        case 3:
            otherMuted.toggle()
            if otherMuted { otherSolo = false }
        default: break
        }
    }
     // MARK: - Stem Macro Quick Presets (Click to Activate, Click Again to Toggle Off)
    public func applyAcapella() {
        Haptics.playClick()
        if vocalSolo && !vocalMuted && !drumSolo && !bassSolo && !otherSolo {
            applyResetMix()
        } else {
            soloStem(0)
        }
    }
    
    public func applyInstrumental() {
        Haptics.playClick()
        let anySolo = vocalSolo || drumSolo || bassSolo || otherSolo
        let isAlreadyActive = vocalMuted && !drumMuted && !bassMuted && !otherMuted && !anySolo
        
        if isAlreadyActive {
            applyResetMix()
        } else {
            vocalSolo = false
            drumSolo = false
            bassSolo = false
            otherSolo = false
            vocalMuted = true
            drumMuted = false
            bassMuted = false
            otherMuted = false
            vocalVolume = 1.0
            drumVolume = 1.0
            bassVolume = 1.0
            otherVolume = 1.0
        }
    }
    
    public func applyDrumless() {
        Haptics.playClick()
        let anySolo = vocalSolo || drumSolo || bassSolo || otherSolo
        let isAlreadyActive = drumMuted && !vocalMuted && !bassMuted && !otherMuted && !anySolo
        
        if isAlreadyActive {
            applyResetMix()
        } else {
            vocalSolo = false
            drumSolo = false
            bassSolo = false
            otherSolo = false
            drumMuted = true
            vocalMuted = false
            bassMuted = false
            otherMuted = false
            vocalVolume = 1.0
            drumVolume = 1.0
            bassVolume = 1.0
            otherVolume = 1.0
        }
    }
    
    public func applyKaraoke() {
        Haptics.playClick()
        let anySolo = vocalSolo || drumSolo || bassSolo || otherSolo
        let isAlreadyActive = abs(vocalVolume - 0.25) < 0.05 && !vocalMuted && !drumMuted && !bassMuted && !otherMuted && !anySolo
        
        if isAlreadyActive {
            applyResetMix()
        } else {
            vocalSolo = false
            drumSolo = false
            bassSolo = false
            otherSolo = false
            vocalMuted = false
            drumMuted = false
            bassMuted = false
            otherMuted = false
            vocalVolume = 0.25 // -12 dB lead vocal reduction
            drumVolume = 1.0
            bassVolume = 1.0
            otherVolume = 1.0
        }
    }
    
    public func applyDrumAndBass() {
        Haptics.playClick()
        let anySolo = vocalSolo || drumSolo || bassSolo || otherSolo
        let isAlreadyActive = vocalMuted && otherMuted && !drumMuted && !bassMuted && !anySolo
        
        if isAlreadyActive {
            applyResetMix()
        } else {
            vocalSolo = false
            drumSolo = false
            bassSolo = false
            otherSolo = false
            vocalMuted = true
            drumMuted = false
            bassMuted = false
            otherMuted = true
            vocalVolume = 1.0
            drumVolume = 1.0
            bassVolume = 1.0
            otherVolume = 1.0
        }
    }
    
    public func applyResetMix() {
        Haptics.playClick()
        vocalSolo = false
        drumSolo = false
        bassSolo = false
        otherSolo = false
        vocalMuted = false
        drumMuted = false
        bassMuted = false
        otherMuted = false
        vocalVolume = 1.0
        drumVolume = 1.0
        bassVolume = 1.0
        otherVolume = 1.0
        vocalPan = 0.0
        drumPan = 0.0
        bassPan = 0.0
        otherPan = 0.0
    }
    
    private func clearVisualizers() {
        stemPeaks = Array(repeating: 0, count: 4)
        masterWaveformAmplitudes = Array(repeating: 0.05, count: 30)
        originalWaveformAmplitudes = Array(repeating: 0.05, count: 30)
        masterEQMagnitudes = Array(repeating: 0, count: 32)
        vocalEQMagnitudes = Array(repeating: 0, count: 7)
        drumEQMagnitudes = Array(repeating: 0, count: 7)
        bassEQMagnitudes = Array(repeating: 0, count: 7)
        otherEQMagnitudes = Array(repeating: 0, count: 7)
    }

    // MARK: - Loading & Splitting Audio
    
    @MainActor
    public func updateTrackTitle(id: String, newTitle: String) {
        if currentTrackID == id {
            titleOverride = newTitle
            currentTrackName = newTitle.uppercased()
            trackTitle = newTitle
            publishNowPlayingMetadata()
        }
    }
    
    public func loadTrack(_ track: TrackModel) async {
        guard !isSplitting else { return }
        // Reselecting the loaded track keeps its mix, loop, speed and position.
        if track.id == currentTrackID, let loaded = fileVocals?.url,
           loaded.standardizedFileURL == track.vocalStemURL.standardizedFileURL { return }
        lastImportCancelled = false
        let urls = [track.vocalStemURL, track.drumStemURL, track.bassStemURL, track.otherStemURL]
        do {
            try installFiles(urls)
            currentTrackID = track.id
            updateTrackTitle(id: track.id, newTitle: track.title)
            extractMetadata(url: track.originalURL)
            if !AppPreferences.defaults.bool(forKey: "isAutoPlayDisabled") { playSynced() }
        } catch {
            guard FileManager.default.fileExists(atPath: track.originalURL.path) else {
                // A broken entry must not stop a different track that is playing.
                if currentTrackID == track.id { unloadTrack() }
                showError("AUDIO SOURCE NOT FOUND: '\(track.title)'. Reimport the original file to rebuild its stems.")
                return
            }
            if let data = await loadAndSplitAudio(url: track.originalURL) {
                track.vocalStemURL = data.vocalStemURL
                track.drumStemURL = data.drumStemURL
                track.bassStemURL = data.bassStemURL
                track.otherStemURL = data.otherStemURL
                currentTrackID = track.id
                updateTrackTitle(id: track.id, newTitle: track.title)
                do { try track.modelContext?.save() }
                catch { showError("Could not save the recovered track: \(error.localizedDescription)") }
            }
        }
    }

    private func installFiles(_ urls: [URL]) throws {
        guard urls.count == 4 else { throw DemucsError.invalidAudioFormat }
        let files = try urls.map { try AVAudioFile(forReading: $0) }
        guard let first = files.first, first.length > 0,
              files.allSatisfy({ $0.length == first.length && $0.processingFormat.sampleRate == 44_100 && $0.processingFormat.channelCount == 2 }) else {
            throw DemucsError.conversionFailed("The cached stems have inconsistent lengths or formats.")
        }
        unloadTrack()
        fileVocals = files[0]
        fileDrums = files[1]
        fileBass = files[2]
        fileOther = files[3]
        let original = try? AVAudioFile(forReading: urls[0].deletingLastPathComponent().appending(path: "original.wav"))
        if let original, original.length == first.length,
           original.processingFormat.sampleRate == 44_100, original.processingFormat.channelCount == 2 {
            audioFile = original
        }
        seek(toPercentage: 0)
    }

    @MainActor
    public func unloadTrack() {
        playbackSessionID = UUID()
        metadataTask?.cancel()
        metadataRequestID = UUID()
        // 1. Hard stop all audio players & invalidate playback timers
        vocalPlayer.stop()
        drumPlayer.stop()
        bassPlayer.stop()
        otherPlayer.stop()
        originalPlayer.stop()
        // Release the output device and drop the previous track's buffered tail.
        engine.pause()
        timePitchNode.reset()
        isPlaying = false
        playbackClock.timer?.invalidate()
        playbackClock.timer = nil
        
        // 2. Clear all audio file references
        fileVocals = nil
        fileDrums = nil
        fileBass = nil
        fileOther = nil
        audioFile = nil
        
        // 3. Reset all playback state and metadata to default standby
        currentTrackID = nil
        currentTrackName = "NO TRACK LOADED"
        titleOverride = nil
        trackTitle = ""
        trackArtist = "Isolate"
        trackAlbum = "4-Stem Neural Audio"
        albumArt = nil
        trackBPM = "BPM UNKNOWN"
        trackMusicalKey = "KEY UNKNOWN"
        trackSampleRate = "44.1 kHz"
        trackBitDepth = "24-BIT PCM"
        trackAudioFormat = "WAV"
        pitchShiftSemitones = 0.0
        playbackRate = 1.0
        playbackProgress = 0.0
        seekFrameOffset = 0
        currentTimeString = "00:00 / -00:00"
        detailedTimecode = "00:00.000 / -00:00.000"
        isLooping = false
        loopStartProgress = 0.0
        loopEndProgress = 1.0
        isBypassed = false
        
        // 4. Reset stem volumes, pan, mutes, solos to default unity
        applyResetMix()
        
        // 5. Clear all visualizers
        clearVisualizers()
        
        // 6. Clear system Now Playing center
        NowPlayingManager.shared.clear()
    }
    
    // MARK: - Import lifecycle
    @ObservationIgnored private var activeSplitTask: Task<[URL], Error>?
    private var splitRequestID = UUID()
    public private(set) var lastImportCancelled = false

    public func cancelSplitAudio() {
        guard isSplitting else { return }
        lastImportCancelled = true
        splitStatusMessage = "CANCELLING IMPORT..."
        etaRemainingString = "--:--"
        activeSplitTask?.cancel()
        // Keep the operation busy until inference and temporary-file cleanup finish.
    }

    public func loadAndSplitAudio(url: URL) async -> TrackData? {
        guard !isSplitting else { return nil }
        isSplitting = true
        lastImportCancelled = false
        splitProgress = 0
        currentChunkNumber = 0
        totalChunkCount = 0
        etaRemainingString = "ESTIMATING..."
        splitStatusMessage = "CHECKING AUDIO..."
        liveSpeedSubtitle = "ON-DEVICE CORE ML PROCESSING"
        // togglePlayback() ignores requests while splitting, so pause directly.
        if isPlaying { pausePlayback() }
        let requestID = UUID()
        splitRequestID = requestID
        let task = Task { [weak self] in
            try await DemucsEngine.shared.splitAudio(url: url) { [weak self] info in
                Task { @MainActor [weak self] in
                    guard let self, self.isSplitting, self.splitRequestID == requestID,
                          !self.lastImportCancelled else { return }
                    self.splitProgress = info.fraction
                    self.currentChunkNumber = info.currentChunk
                    self.totalChunkCount = info.totalChunks
                    self.splitStatusMessage = info.statusMessage
                    if info.secondsPerChunk > 0 {
                        let seconds = Int(ceil(info.estimatedRemainingSeconds))
                        self.etaRemainingString = String(format: "%02d:%02d", seconds / 60, seconds % 60)
                        self.liveSpeedSubtitle = String(format: "%.2fs / CHUNK • %.1fx REALTIME", info.secondsPerChunk, info.realtimeMultiplier)
                    }
                }
            }
        }
        activeSplitTask = task
        defer {
            activeSplitTask = nil
            isSplitting = false
            splitRequestID = UUID()
        }
        do {
            let stems = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard !lastImportCancelled else { return nil }
            try installFiles(stems)
            currentTrackID = url.path
            let title = url.deletingPathExtension().lastPathComponent
            currentTrackName = title.uppercased()
            trackTitle = title
            extractMetadata(url: url)
            splitProgress = 1
            if !AppPreferences.defaults.bool(forKey: "isAutoPlayDisabled") { playSynced() }
            return TrackData(id: url.path, title: title, originalURL: url,
                             vocalStemURL: stems[0], bassStemURL: stems[2],
                             drumStemURL: stems[1], otherStemURL: stems[3])
        } catch is CancellationError {
            lastImportCancelled = true
            return nil
        } catch {
            if !lastImportCancelled { showError("Import failed: \(error.localizedDescription)") }
            return nil
        }
    }

    public func showError(_ message: String) {
        errorMessage = message
    }

    public func dismissError() {
        errorMessage = nil
    }

    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    @ObservationIgnored private var titleOverride: String?
    private var metadataRequestID = UUID()

    private func extractMetadata(url: URL) {
        metadataTask?.cancel()
        let requestID = UUID()
        metadataRequestID = requestID
        let asset = AVURLAsset(url: url)
        metadataTask = Task { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var foundBPM: String?
            var foundKey: String?
            var foundTitle: String? = nil
            var foundArtist: String? = nil
            var foundAlbum: String? = nil
            var foundArt: NSImage? = nil
            
            do {
                let metadata = try await asset.load(.commonMetadata)
                for item in metadata {
                    if item.commonKey == .commonKeyArtwork {
                        if let data = (try? await item.load(.value)) as? Data {
                            foundArt = NSImage(data: data)
                        }
                    } else if item.commonKey == .commonKeyTitle {
                        if let titleStr = (try? await item.load(.value)) as? String {
                            foundTitle = titleStr
                        }
                    } else if item.commonKey == .commonKeyArtist {
                        if let artistStr = (try? await item.load(.value)) as? String {
                            foundArtist = artistStr
                        }
                    } else if item.commonKey == .commonKeyAlbumName {
                        if let albumStr = (try? await item.load(.value)) as? String {
                            foundAlbum = albumStr
                        }
                    }
                }
                
                // Fallback for ID3 frames in MP3s
                let allMeta = try await asset.load(.metadata)
                for item in allMeta {
                    let identifier = item.identifier?.rawValue.lowercased() ?? ""
                    if identifier.contains("tbpm") || identifier.contains("tmpo"),
                       let value = try? await item.load(.value) {
                        let number = (value as? NSNumber)?.doubleValue ?? Double((value as? String) ?? "")
                        if let number, number.isFinite, number > 0 { foundBPM = String(format: "%.1f BPM", number) }
                    }
                    if identifier.contains("tkey"), let value = try? await item.load(.stringValue), !value.isEmpty {
                        foundKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }

                    if foundArt == nil && (item.commonKey == .commonKeyArtwork || item.identifier?.rawValue.contains("APIC") == true || item.identifier?.rawValue.contains("artwork") == true) {
                        if let data = (try? await item.load(.value)) as? Data {
                            foundArt = NSImage(data: data)
                        }
                    }
                    if foundTitle == nil && (item.commonKey == .commonKeyTitle || item.identifier?.rawValue.contains("TIT2") == true || item.identifier?.rawValue.contains("title") == true) {
                        if let str = (try? await item.load(.value)) as? String {
                            foundTitle = str
                        }
                    }
                    if foundArtist == nil && (item.commonKey == .commonKeyArtist || item.identifier?.rawValue.contains("TPE1") == true || item.identifier?.rawValue.contains("artist") == true) {
                        if let str = (try? await item.load(.value)) as? String {
                            foundArtist = str
                        }
                    }
                    if foundAlbum == nil && (item.commonKey == .commonKeyAlbumName || item.identifier?.rawValue.contains("TALB") == true || item.identifier?.rawValue.contains("album") == true) {
                        if let str = (try? await item.load(.value)) as? String {
                            foundAlbum = str
                        }
                    }
                }
            } catch {
                // Fallbacks used below
            }
            
            let finalArt = foundArt
            let finalTitle = foundTitle ?? url.deletingPathExtension().lastPathComponent
            let finalArtist = foundArtist ?? "Isolate"
            let finalAlbum = foundAlbum ?? "4-Stem Neural Audio"
            let ext = url.pathExtension.uppercased()
            let finalFormat = ext.isEmpty ? "WAV" : ext
            
            let finalBPM = foundBPM ?? "BPM UNKNOWN"
            let finalKey = foundKey ?? "KEY UNKNOWN"

            let (computedSampleRate, computedBitDepth): (String, String) = {
                guard let f = try? AVAudioFile(forReading: url) else {
                    return ("44.1 kHz", "24-BIT PCM")
                }
                let sr = f.fileFormat.sampleRate
                let srStr = String(format: "%.1f kHz", sr / 1000)
                let bd = (f.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int) ?? 0
                return (srStr, bd > 0 ? "\(bd)-BIT" : "COMPRESSED")
            }()
            let finalSampleRate = computedSampleRate
            let finalBitDepth = computedBitDepth
            
            await MainActor.run {
                guard !Task.isCancelled, let self, self.metadataRequestID == requestID else { return }
                self.albumArt = finalArt
                self.trackTitle = self.titleOverride ?? finalTitle
                self.trackArtist = finalArtist
                self.trackAlbum = finalAlbum
                self.trackAudioFormat = finalFormat
                self.trackBPM = finalBPM
                self.trackMusicalKey = finalKey
                self.trackSampleRate = finalSampleRate
                self.trackBitDepth = finalBitDepth
                
                self.publishNowPlayingMetadata()
            }
        }
    }

    private func publishNowPlayingMetadata() {
        NowPlayingManager.shared.updateNowPlayingInfo(
            title: trackTitle, artist: trackArtist, album: trackAlbum, artwork: albumArt,
            duration: totalTrackDuration ?? 0, elapsed: currentPlaybackTimeSeconds ?? 0,
            isPlaying: isPlaying
        )
    }
    
    // MARK: - Export
    public nonisolated static func renderStemToFile(sourceURL: URL, destURL: URL, low: Float, mid: Float, high: Float) throws {
        try AudioExporter.render(sources: [.init(url: sourceURL, eq: .init(low: low, mid: mid, high: high))], to: destURL)
    }

    private func exportSources(includeMix: Bool) -> [AudioExporter.Source] {
        let anySolo = vocalSolo || drumSolo || bassSolo || otherSolo
        let volumes = [vocalVolume, drumVolume, bassVolume, otherVolume]
        let muted = [vocalMuted, drumMuted, bassMuted, otherMuted]
        let soloed = [vocalSolo, drumSolo, bassSolo, otherSolo]
        let pans = [vocalPan, drumPan, bassPan, otherPan]
        return [fileVocals, fileDrums, fileBass, fileOther].enumerated().compactMap { index, file in
            guard let file else { return nil }
            let gains = getStemEQ(index)
            let useEQ = !isGlobalEQBypassed && !gains.isBypassed && (includeMix || shouldBakeEQOnExport)
            let audible = anySolo ? soloed[index] : !muted[index]
            return AudioExporter.Source(url: file.url,
                gain: includeMix ? (audible ? Float(volumes[index]) : 0) : 1,
                pan: includeMix ? pans[index] : 0,
                eq: useEQ ? .init(low: gains.low, mid: gains.mid, high: gains.high) : .init())
        }
    }

    public func exportStems() {
        guard hasLoadedTrack, !isExporting, !isSplitting else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(AudioExporter.safeFilename(currentTrackName))_Stems.zip"
        panel.allowedContentTypes = [.zip]
        panel.message = "Four individual stems in \(AppSettings.shared.defaultExportFormat). Channel levels, pan, speed and pitch are excluded."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let sources = exportSources(includeMix: false)
        let title = currentTrackName
        let format = AudioExporter.Format(rawValue: AppSettings.shared.defaultExportFormat) ?? .wav
        beginExport { [self] in
            try AudioExporter.archive(sources: sources, title: title, format: format, to: destination) { progress in
                Task { @MainActor [self] in
                    guard case .exporting = self.exportState else { return }
                    self.exportProgress = progress
                    self.exportState = .exporting(stage: progress < 0.8 ? "RENDERING" : "ARCHIVING", percent: progress)
                }
            }
            return destination
        }
    }

    public func exportMix() {
        guard hasLoadedTrack, !isExporting, !isSplitting else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(AudioExporter.safeFilename(currentTrackName))_Mix.wav"
        panel.allowedContentTypes = [.wav]
        panel.message = "Export the full track with current levels, pan, EQ, speed and pitch as 24-bit WAV."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let sources = isBypassed && audioFile != nil ? [AudioExporter.Source(url: audioFile!.url)] : exportSources(includeMix: true)
        let gains = getStemEQ(4)
        let masterEQ = isGlobalEQBypassed || gains.isBypassed ? AudioExporter.EQ() : .init(low: gains.low, mid: gains.mid, high: gains.high)
        let rate = Float(playbackRate)
        let pitch = Float(pitchShiftSemitones)
        beginExport {
            let temporary = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try AudioExporter.render(sources: sources, to: temporary, masterEQ: masterEQ, rate: rate, pitch: pitch, limitPeak: true)
            try AudioExporter.publish(temporary, to: destination)
            return destination
        }
    }

    private func beginExport(_ operation: @escaping @Sendable () throws -> URL) {
        exportState = .exporting(stage: "RENDERING", percent: 0)
        exportProgress = 0
        Task {
            do {
                let destination = try await Task.detached(priority: .userInitiated, operation: operation).value
                exportState = .completed
                exportProgress = 1
                NSWorkspace.shared.activateFileViewerSelecting([destination])
                try? await Task.sleep(for: .seconds(2))
            } catch {
                showError("Export failed: \(error.localizedDescription)")
            }
            exportState = .idle
            exportProgress = 0
        }
    }

    // MARK: - Synchronized Playback Graph Scheduling
    
    private func onPlaybackEnded() {
        if isPlaying && isLooping {
            seek(toPercentage: loopStartProgress, flushTail: false)
        } else {
            // Also reached when a pause lands while this completion is queued: the players
            // have nothing left, so the next Play must restart instead of resuming them.
            stopPlayers()
            playbackProgress = 1
            updateTimeString(for: 1)
            NowPlayingManager.shared.updateNowPlayingPlaybackState()
            releaseOutputAfterTail()
        }
    }

    /// Lets the limiter and time/pitch tails play out, then idles the output device
    /// so the Mac can sleep. playSynced() restarts the engine.
    private func releaseOutputAfterTail() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !self.isPlaying else { return }
            self.engine.pause()
        }
    }

    private func stopPlayers() {
        // Invalidate callbacks before stop() invokes outstanding completions.
        playbackSessionID = UUID()
        vocalPlayer.stop()
        drumPlayer.stop()
        bassPlayer.stop()
        otherPlayer.stop()
        originalPlayer.stop()
        isPlaying = false
        playbackClock.timer?.invalidate()
        playbackClock.timer = nil
        clearVisualizers()
    }

    @MainActor
    private func playSynced() {
        guard fileVocals != nil else { return }
        // Players left running by pausePlayback() resume together with the engine.
        let resumesPausedPlayers = vocalPlayer.isPlaying
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                showError("Could not start audio output: \(error.localizedDescription)")
                return
            }
        }
        if !resumesPausedPlayers { startPlayersTogether() }
        
        self.isPlaying = true
        self.startPlaybackTimer()
        NowPlayingManager.shared.updateNowPlayingPlaybackState()
    }

    /// play(at:) waits for about one output IO cycle per player, and a player whose start
    /// time has already passed begins on a later cycle than the others. Lead by the whole
    /// call sequence plus the render-ahead margin; if the calls still overran it, reschedule
    /// from the same frame and retry with a longer lead.
    private func startPlayersTogether() {
        var players = [vocalPlayer, drumPlayer, bassPlayer, otherPlayer]
        if audioFile != nil { players.append(originalPlayer) }
        let cycle = outputCycleDuration()
        let margin = 4 * cycle + engine.outputNode.presentationLatency + 0.005
        var lead = Double(players.count + 1) * cycle + margin
        for attempt in 1...3 {
            let startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead)
            let startTime = AVAudioTime(hostTime: startHostTime)
            for player in players { player.play(at: startTime) }
            let startedTogether = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: margin) <= startHostTime
            guard !startedTogether, attempt < 3 else { return }
            stopPlayers()
            timePitchNode.reset()
            schedulePlayers(from: seekFrameOffset)
            lead *= 2
        }
    }

    /// One output IO cycle, never taken as shorter than 512 frames.
    private func outputCycleDuration() -> TimeInterval {
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if let unit = engine.outputNode.audioUnit {
            AudioUnitGetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, &size)
        }
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        return Double(max(frames, 512)) / (rate > 0 ? rate : 44_100)
    }

    /// Pausing the engine rather than each player freezes all five on the same render cycle,
    /// keeps buffered tails for a seamless resume, and releases the output device so the Mac
    /// can idle-sleep. playSynced() restarts the engine to resume.
    private func pausePlayback() {
        engine.pause()
        playbackClock.timer?.invalidate()
        isPlaying = false
        clearVisualizers()
        NowPlayingManager.shared.updateNowPlayingPlaybackState()
    }

    /// Engine state for tests; false while paused or stopped.
    var isOutputRunning: Bool { engine.isRunning }
    
    @MainActor
    public func togglePlayback() {
        guard fileVocals != nil, !isSplitting else { return }
        if isPlaying {
            pausePlayback()
        } else {
            if playbackProgress >= 1 { seek(toPercentage: isLooping ? loopStartProgress : 0) }
            playSynced()
        }
    }
    
    // High-precision 60Hz Playback Timer (16.6ms) for Instantaneous Time & Progress Sync (Active in Common RunLoop Modes)
    private func startPlaybackTimer() {
        playbackClock.timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
            guard let self = self, self.isPlaying,
                  let fVocals = self.fileVocals,
                  let lastTime = self.vocalPlayer.lastRenderTime,
                  let playerTime = self.vocalPlayer.playerTime(forNodeTime: lastTime) else { return }
            
            let elapsedFrames = Double(playerTime.sampleTime) + Double(self.seekFrameOffset)
            let elapsed = max(0, elapsedFrames / playerTime.sampleRate)
            let duration = Double(fVocals.length) / fVocals.processingFormat.sampleRate
            guard duration > 0 else { return }
            
            let progress = max(0, min(1, elapsed / duration))
            
                if self.isLooping && progress >= self.loopEndProgress {
                    self.seek(toPercentage: self.loopStartProgress, flushTail: false)
                    return
                }
                
                self.playbackProgress = progress
                
                self.updateTimeDisplay(elapsed: elapsed, duration: duration)
                
                let elapsedSecs = Int(min(duration, elapsed))
                if elapsedSecs != self.lastSyncedNowPlayingSec {
                    self.lastSyncedNowPlayingSec = elapsedSecs
                    NowPlayingManager.shared.updateNowPlayingProgress(elapsed: elapsed, duration: duration)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        playbackClock.timer = t
    }
    
    @MainActor
    public func updateTimeString(for progress: Double) {
        guard let fVocals = fileVocals else { return }
        let duration = Double(fVocals.length) / fVocals.processingFormat.sampleRate
        guard duration > 0, progress.isFinite else { return }
        updateTimeDisplay(elapsed: duration * max(0, min(1, progress)), duration: duration)
    }

    private func updateTimeDisplay(elapsed: Double, duration: Double) {
        let times = Self.playbackTimecodes(elapsed: elapsed, duration: duration)
        currentTimeString = times.compact
        detailedTimecode = times.detailed
    }

    nonisolated static func playbackTimecodes(elapsed: Double, duration: Double) -> (compact: String, detailed: String) {
        let current = min(duration, max(0, elapsed))
        let remaining = max(0, duration - current)
        let elapsedMS = Int((current * 1000).rounded())
        let remainingMS = Int((remaining * 1000).rounded())
        let compact = String(format: "%02d:%02d / -%02d:%02d",
            Int(current) / 60, Int(current) % 60, Int(ceil(remaining)) / 60, Int(ceil(remaining)) % 60)
        let detailed = String(format: "%02d:%02d.%03d / -%02d:%02d.%03d",
            elapsedMS / 60_000, elapsedMS / 1000 % 60, elapsedMS % 1000,
            remainingMS / 60_000, remainingMS / 1000 % 60, remainingMS % 1000)
        return (compact, detailed)
    }
    
    public func seek(toPercentage percentage: Double) {
        seek(toPercentage: percentage, flushTail: true)
    }

    /// Loop wraps keep the time/pitch tail so the end of the region stays audible; other
    /// seeks flush it so audio from the old position is not heard after the jump.
    private func seek(toPercentage percentage: Double, flushTail: Bool) {
        guard percentage.isFinite, let vocals = fileVocals,
              fileDrums != nil, fileBass != nil, fileOther != nil else { return }
        let progress = max(0, min(1, percentage))
        // Reaching the end while looping wraps to the loop start, like a natural end.
        if progress >= 1 && isPlaying && isLooping {
            seek(toPercentage: loopStartProgress, flushTail: flushTail)
            return
        }
        let wasPlaying = isPlaying
        stopPlayers()
        if flushTail { timePitchNode.reset() }
        let totalFrames = vocals.length
        let target = min(totalFrames, max(0, AVAudioFramePosition(Double(totalFrames) * progress)))
        seekFrameOffset = target
        playbackProgress = progress
        updateTimeString(for: progress)
        let duration = totalTrackDuration ?? 0
        NowPlayingManager.shared.updateNowPlayingProgress(elapsed: duration * progress, duration: duration)
        guard target < totalFrames else {
            engine.pause()
            NowPlayingManager.shared.updateNowPlayingPlaybackState()
            return
        }
        schedulePlayers(from: target)
        if wasPlaying { playSynced() }
    }

    private func schedulePlayers(from target: AVAudioFramePosition) {
        guard let vocals = fileVocals, let drums = fileDrums, let bass = fileBass,
              let other = fileOther, target < vocals.length else { return }
        let count = AVAudioFrameCount(min(Int64(UInt32.max), vocals.length - target))
        let session = playbackSessionID
        vocalPlayer.scheduleSegment(vocals, startingFrame: target, frameCount: count, at: nil,
                                    completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackSessionID == session else { return }
                self.onPlaybackEnded()
            }
        }
        drumPlayer.scheduleSegment(drums, startingFrame: target, frameCount: count, at: nil)
        bassPlayer.scheduleSegment(bass, startingFrame: target, frameCount: count, at: nil)
        otherPlayer.scheduleSegment(other, startingFrame: target, frameCount: count, at: nil)
        if let audioFile {
            originalPlayer.scheduleSegment(audioFile, startingFrame: target, frameCount: count, at: nil)
        }
    }
}
