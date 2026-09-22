import Foundation
import CoreML
@preconcurrency import AVFoundation
import Accelerate
import AudioToolbox

public enum DemucsError: LocalizedError, Sendable {
    case modelNotFound(String)
    case compilationFailed(String)
    case assetReaderFailed(String)
    case conversionFailed(String)
    case invalidAudioFormat
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let msg): return "CoreML Model Not Found: \(msg)"
        case .compilationFailed(let msg): return "Model Compilation Failed: \(msg)"
        case .assetReaderFailed(let msg): return "Audio Reading Failed: \(msg)"
        case .conversionFailed(let msg): return "Audio Conversion Failed: \(msg)"
        case .invalidAudioFormat: return "Invalid Audio Format"
        case .cancelled: return "Operation Cancelled"
        }
    }
}

public struct SplitProgressInfo: Sendable {
    public let fraction: Double
    public let currentChunk: Int
    public let totalChunks: Int
    public let elapsedSeconds: Double
    public let estimatedRemainingSeconds: Double
    public let statusMessage: String
    public let secondsPerChunk: Double
    public let realtimeMultiplier: Double
    
    public init(
        fraction: Double,
        currentChunk: Int,
        totalChunks: Int,
        elapsedSeconds: Double,
        estimatedRemainingSeconds: Double,
        statusMessage: String,
        secondsPerChunk: Double = 0,
        realtimeMultiplier: Double = 0
    ) {
        self.fraction = fraction
        self.currentChunk = currentChunk
        self.totalChunks = totalChunks
        self.elapsedSeconds = elapsedSeconds
        self.estimatedRemainingSeconds = estimatedRemainingSeconds
        self.statusMessage = statusMessage
        self.secondsPerChunk = secondsPerChunk
        self.realtimeMultiplier = realtimeMultiplier
    }
}

public actor DemucsEngine {
    public static let shared = DemucsEngine()
    
    private var model: MLModel?
    
    // Demucs HTDemucs operates on 10.0s chunks @ 44.1kHz (441,000 samples)
    public static let sampleRate: Double = 44100.0
    public static let chunkSize: Int = 441000       // 10.0 seconds
    public static let hopSize: Int = 220500         // 5.0 seconds (50% overlap)
    
    // Stem ordering from the HTDemucs CoreML model
    public static let stemNames: [String] = ["vocals", "drums", "bass", "other"]
    
    private init() {}
    
    // MARK: - Model loading

    private func loadModelIfNeeded() async throws {
        if model != nil { return }
        
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Isolate")
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let appSupportCompiledURL = appSupport.appendingPathComponent("HTDemucs.mlmodelc")
        
        // 1. Check in Bundle.main (Resources)
        var candidateModelURLs: [URL] = []
        if let bundleCompiledURL = Bundle.main.url(forResource: "HTDemucs", withExtension: "mlmodelc") {
            candidateModelURLs.append(bundleCompiledURL)
        }
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent("HTDemucs.mlmodelc"),
           fileManager.fileExists(atPath: resURL.path) {
            candidateModelURLs.append(resURL)
        }
        
        // 2. Check in Application Support
        if fileManager.fileExists(atPath: appSupportCompiledURL.path) {
            candidateModelURLs.append(appSupportCompiledURL)
        }
        
        // Try loading candidate pre-compiled models
        for url in candidateModelURLs {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let loaded = try MLModel(contentsOf: url, configuration: config)
                try Self.validateModel(loaded)
                self.model = loaded
                
                return
            } catch {
                print("Failed to load CoreML model from \(url.path): \(error)")
            }
        }
        
        // 3. Check for .mlpackage in AppSupport or Bundle to compile on-the-fly
        var candidatePackages: [URL] = []
        if let bundlePkg = Bundle.main.url(forResource: "HTDemucs_CoreML_FP16", withExtension: "mlpackage") {
            candidatePackages.append(bundlePkg)
        }
        if let resPkg = Bundle.main.resourceURL?.appendingPathComponent("HTDemucs_CoreML_FP16.mlpackage"),
           fileManager.fileExists(atPath: resPkg.path) {
            candidatePackages.append(resPkg)
        }
        let appSupportPkg = appSupport.appendingPathComponent("HTDemucs_CoreML_FP16.mlpackage")
        if fileManager.fileExists(atPath: appSupportPkg.path) {
            candidatePackages.append(appSupportPkg)
        }
        
        for pkgURL in candidatePackages {
            do {
                // The separation guard prevents a second load while compilation awaits.
                // Validate before replacing the cached compiled model.
                let temporary = try await MLModel.compileModel(at: pkgURL)
                defer { try? fileManager.removeItem(at: temporary) }
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let loaded = try MLModel(contentsOf: temporary, configuration: config)
                try Self.validateModel(loaded)
                if fileManager.fileExists(atPath: appSupportCompiledURL.path) {
                    _ = try fileManager.replaceItemAt(appSupportCompiledURL, withItemAt: temporary)
                } else {
                    try fileManager.moveItem(at: temporary, to: appSupportCompiledURL)
                }
                self.model = try MLModel(contentsOf: appSupportCompiledURL, configuration: config)
                return
            } catch {
                print("Failed to compile mlpackage from \(pkgURL.path): \(error)")
            }
        }
        
        throw DemucsError.modelNotFound("Install the complete Isolate release, or follow MODEL.md to place HTDemucs.mlmodelc in ~/Library/Application Support/Isolate.")
    }
    
    // MARK: - Streaming separation

    private var isSeparating = false

    /// Uses a rolling ten-second overlap accumulator and writes completed hops to disk.
    public func splitAudio(
        url: URL,
        progressCallback: @escaping @Sendable (SplitProgressInfo) -> Void
    ) async throws -> [URL] {
        guard !isSeparating else {
            throw DemucsError.conversionFailed("Another separation is still running.")
        }
        isSeparating = true
        defer { isSeparating = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let startTime = CACurrentMediaTime()
        func report(_ fraction: Double, _ message: String, chunk: Int = 0, total: Int = 0,
                    secondsPerChunk: Double = 0) {
            progressCallback(SplitProgressInfo(
                fraction: fraction, currentChunk: chunk, totalChunks: total,
                elapsedSeconds: CACurrentMediaTime() - startTime,
                estimatedRemainingSeconds: Double(total - chunk) * secondsPerChunk,
                statusMessage: message, secondsPerChunk: secondsPerChunk,
                realtimeMultiplier: secondsPerChunk > 0 ? 5 / secondsPerChunk : 0
            ))
        }
        try Task.checkCancellation()
        report(0, "CHECKING AUDIO CACHE...")
        let key = try StemCache.key(for: url)
        let destination = StemCache.root.appending(path: key, directoryHint: .isDirectory)
        if let cached = StemCache.validFiles(in: destination) {
            report(1, "LOADED FROM CACHE")
            return cached
        }
        report(0.01, "LOADING SEPARATION MODEL...")
        try await loadModelIfNeeded()
        try Task.checkCancellation()
        guard let model else { throw DemucsError.modelNotFound("Install the HTDemucs Core ML model.") }
        try Self.validateModel(model)
        let fm = FileManager.default
        try fm.createDirectory(at: StemCache.root, withIntermediateDirectories: true)
        let staging = StemCache.root.appending(path: ".partial-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        report(0.02, "DECODING AUDIO...")
        let original = staging.appending(path: "original.wav")
        let stats = try StreamingAudio.decode(url, to: original)
        let inputFile = try AVAudioFile(forReading: original)
        let chunkSize = Self.chunkSize
        let hopSize = Self.hopSize
        let totalChunks = (stats.frames + hopSize - 1) / hopSize + 1
        let inputArray = try MLMultiArray(shape: [1, 2, NSNumber(value: chunkSize)], dataType: .float32)
        let input = inputArray.dataPointer.assumingMemoryBound(to: Float.self)
        guard let windowBuffer = AVAudioPCMBuffer(pcmFormat: StreamingAudio.format, frameCapacity: AVAudioFrameCount(chunkSize)),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: StreamingAudio.format, frameCapacity: AVAudioFrameCount(hopSize)) else {
            throw DemucsError.invalidAudioFormat
        }
        var writers = try Self.stemNames.map {
            try AVAudioFile(forWriting: staging.appending(path: "\($0).wav"), settings: StreamingAudio.settings)
        }
        var window = [Float](repeating: 0, count: chunkSize)
        vDSP_hann_window(&window, vDSP_Length(chunkSize), Int32(vDSP_HANN_DENORM))
        var accumulators = (0..<8).map { _ in [Float](repeating: 0, count: chunkSize) }
        var weights = [Float](repeating: 0, count: chunkSize)
        let inferenceStart = CACurrentMediaTime()
        for chunk in 0..<totalChunks {
            try Task.checkCancellation()
            let sourceStart = chunk * hopSize - hopSize
            try StreamingAudio.readWindow(file: inputFile, start: sourceStart, count: chunkSize, into: windowBuffer)
            for channel in 0..<2 {
                let samples = windowBuffer.floatChannelData![channel]
                for i in 0..<chunkSize {
                    input[channel * chunkSize + i] = (samples[i] - stats.mean) / stats.standardDeviation
                }
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: inputArray)])
            let prediction = try await model.prediction(from: provider)
            try Task.checkCancellation()
            guard let output = prediction.featureValue(for: "sources")?.multiArrayValue else {
                throw DemucsError.conversionFailed("The model did not return separated audio.")
            }
            try Self.accumulate(output, into: &accumulators, weights: &weights, window: window,
                                mean: stats.mean, standardDeviation: stats.standardDeviation)
            let first = max(0, -sourceStart)
            let end = min(hopSize, stats.frames - sourceStart)
            if end > first {
                outputBuffer.frameLength = AVAudioFrameCount(end - first)
                for stem in 0..<4 {
                    for channel in 0..<2 {
                        let samples = outputBuffer.floatChannelData![channel]
                        for i in first..<end {
                            let sample = accumulators[stem * 2 + channel][i] / max(1e-5, weights[i])
                            guard sample.isFinite else {
                                throw DemucsError.conversionFailed("The model produced invalid audio samples.")
                            }
                            samples[i - first] = sample
                        }
                    }
                    try writers[stem].write(from: outputBuffer)
                }
            }
            // Only the overlap is retained for the following chunk.
            for channel in 0..<8 {
                accumulators[channel].withUnsafeMutableBufferPointer { samples in
                    samples.baseAddress!.update(from: samples.baseAddress! + hopSize, count: hopSize)
                    (samples.baseAddress! + hopSize).update(repeating: 0, count: hopSize)
                }
            }
            weights.withUnsafeMutableBufferPointer { samples in
                samples.baseAddress!.update(from: samples.baseAddress! + hopSize, count: hopSize)
                (samples.baseAddress! + hopSize).update(repeating: 0, count: hopSize)
            }
            let secondsPerChunk = (CACurrentMediaTime() - inferenceStart) / Double(chunk + 1)
            report(0.03 + 0.95 * Double(chunk + 1) / Double(totalChunks), "SEPARATING STEMS...",
                   chunk: chunk + 1, total: totalChunks, secondsPerChunk: secondsPerChunk)
        }
        writers.removeAll() // Close files before validating their headers.
        try Task.checkCancellation()
        try StemCache.publish(staging, to: destination)
        report(1, "SEPARATION COMPLETE")
        return Self.stemNames.map { destination.appending(path: "\($0).wav") }
    }

    private static func validateModel(_ model: MLModel) throws {
        guard let input = model.modelDescription.inputDescriptionsByName["audio"]?.multiArrayConstraint,
              input.shape.map(\.intValue) == [1, 2, chunkSize],
              let output = model.modelDescription.outputDescriptionsByName["sources"]?.multiArrayConstraint,
              output.shape.map(\.intValue) == [1, 4, 2, chunkSize] else {
            throw DemucsError.conversionFailed("The model must accept audio [1, 2, 441000] and return sources [1, 4, 2, 441000].")
        }
    }

    private static func accumulate(_ output: MLMultiArray, into accumulators: inout [[Float]],
                                   weights: inout [Float], window: [Float], mean: Float,
                                   standardDeviation: Float) throws {
        guard output.shape.map(\.intValue) == [1, 4, 2, chunkSize],
              output.dataType == .float16 || output.dataType == .float32 else {
            throw DemucsError.conversionFailed("The model returned an unsupported audio tensor.")
        }
        let strides = output.strides.map(\.intValue)
        for stem in 0..<4 {
            for channel in 0..<2 {
                let offset = stem * strides[1] + channel * strides[2]
                let target = stem * 2 + channel
                for i in 0..<chunkSize {
                    let index = offset + i * strides[3]
                    let sample: Float
                    if output.dataType == .float32 {
                        sample = output.dataPointer.assumingMemoryBound(to: Float.self)[index]
                    } else {
                        sample = Float(output.dataPointer.assumingMemoryBound(to: Float16.self)[index])
                    }
                    accumulators[target][i] += (sample * standardDeviation + mean) * window[i]
                }
            }
        }
        for i in 0..<chunkSize { weights[i] += window[i] }
    }

}
