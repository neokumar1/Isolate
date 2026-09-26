import Foundation
import CoreML
@preconcurrency import AVFoundation
import Accelerate
import AudioToolbox
import os

public enum DemucsError: LocalizedError, Sendable {
    case modelNotFound(String)
    case modelLoadFailed(String)
    case compilationFailed(String)
    case assetReaderFailed(String)
    case conversionFailed(String)
    /// A source file that cannot be read; the message is already user-facing.
    case unreadableSource(String)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case invalidAudioFormat
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let msg): return "CoreML Model Not Found: \(msg)"
        case .modelLoadFailed(let msg): return "Model Could Not Be Loaded: \(msg)"
        case .compilationFailed(let msg): return "Model Compilation Failed: \(msg)"
        case .assetReaderFailed(let msg): return "Audio Reading Failed: \(msg)"
        case .conversionFailed(let msg): return "Audio Conversion Failed: \(msg)"
        case .unreadableSource(let msg): return msg
        case .insufficientDiskSpace(let needed, let available):
            let size = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return "Not enough disk space: separating this track needs about \(size(needed)) free, and \(size(available)) is available."
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
    /// One shared load, so a cancelled import never starts a second compile.
    private var modelLoad: Task<MLModel, Error>?
    private var modelRelease: Task<Void, Never>?
    /// Core ML holds a large working set while the model stays loaded. Reloading
    /// from its compiled cache is quick next to a separation, so an idle model is
    /// released; a batch keeps it because each file starts before this elapses.
    private var idleModelLifetime: Duration = .seconds(60)
    
    // Demucs HTDemucs operates on 10.0s chunks @ 44.1kHz (441,000 samples)
    public static let sampleRate: Double = 44100.0
    public static let chunkSize: Int = 441000       // 10.0 seconds
    public static let hopSize: Int = 220500         // 5.0 seconds (50% overlap)
    
    // Stem ordering from the HTDemucs CoreML model
    public static let stemNames: [String] = ["vocals", "drums", "bass", "other"]
    
    private init() {}
    
    // MARK: - Model loading

    /// Returns the model, sharing one in-flight load. Cancelling an import ends its
    /// wait at once; the load finishes in the background for the next import.
    private func loadedModel() async throws -> MLModel {
        if let model { return model }
        let load: Task<MLModel, Error>
        if let modelLoad {
            load = modelLoad
        } else {
            load = Task.detached(priority: .userInitiated) { try await Self.loadModel() }
            modelLoad = load
            Task { await finishModelLoad(load) }
        }
        let loaded = try await Self.value(of: load)
        model = loaded
        return loaded
    }

    private func finishModelLoad(_ load: Task<MLModel, Error>) async {
        let result = await load.result
        guard modelLoad == load else { return }
        modelLoad = nil
        guard case .success(let loaded) = result else { return }
        model = loaded
        // A load abandoned by a cancelled import must not stay resident.
        if !isSeparating { scheduleModelRelease() }
    }

    private func scheduleModelRelease() {
        modelRelease?.cancel()
        let lifetime = idleModelLifetime
        modelRelease = Task {
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            releaseIdleModel()
        }
    }

    /// Drops the loaded model unless a separation is using it.
    func releaseIdleModel() {
        guard !isSeparating else { return }
        model = nil
    }

    var isModelLoaded: Bool { model != nil }

    /// Tests shorten the lifetime to observe a release.
    func setIdleModelLifetime(_ lifetime: Duration) {
        idleModelLifetime = lifetime
    }

    /// Awaits a task's result while letting the caller's cancellation end the wait.
    private static func value<T: Sendable>(of task: Task<T, Error>) async throws -> T {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<T, Error>?>(initialState: nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.withLock { $0 = continuation }
                if Task.isCancelled {
                    pending.withLock { $0.take() }?.resume(throwing: CancellationError())
                    return
                }
                Task {
                    let result = await task.result
                    pending.withLock { $0.take() }?.resume(with: result)
                }
            }
        } onCancel: {
            pending.withLock { $0.take() }?.resume(throwing: CancellationError())
        }
    }

    private static func loadModel() async throws -> MLModel {
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
        return try await loadModel(compiled: candidateModelURLs, packages: candidatePackages,
                                   compiledCache: appSupportCompiledURL)
    }

    static func loadModel(compiled: [URL], packages: [URL], compiledCache appSupportCompiledURL: URL) async throws -> MLModel {
        let fileManager = FileManager.default
        // Only the first failure is reported: it belongs to the preferred location.
        var failure: String?
        
        // Try loading candidate pre-compiled models
        for url in unique(compiled) {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let loaded = try MLModel(contentsOf: url, configuration: config)
                try Self.validateModel(loaded)
                return loaded
            } catch {
                print("Failed to load CoreML model from \(url.path): \(error)")
                failure = failure ?? loadFailure(url, error)
            }
        }
        
        for pkgURL in unique(packages) {
            do {
                // The shared load task prevents a second compile while this one awaits.
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
                return try MLModel(contentsOf: appSupportCompiledURL, configuration: config)
            } catch {
                print("Failed to compile mlpackage from \(pkgURL.path): \(error)")
                failure = failure ?? loadFailure(pkgURL, error)
            }
        }
        
        // A model that is present but unusable needs a different fix than a missing one.
        if let failure {
            throw DemucsError.modelLoadFailed("\(failure) Replace it with the validated model described in MODEL.md.")
        }
        throw DemucsError.modelNotFound("Install the complete Isolate release, or follow MODEL.md to place HTDemucs.mlmodelc in ~/Library/Application Support/Isolate.")
    }

    /// Bundle lookups by name and by resource path can return the same model.
    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func loadFailure(_ url: URL, _ error: Error) -> String {
        let reason = if case DemucsError.modelLoadFailed(let message) = error { message } else { error.localizedDescription }
        return "\((url.path as NSString).abbreviatingWithTildeInPath) could not be used. \(reason)"
    }
    
    // MARK: - Streaming separation

    private var isSeparating = false

    /// Launch-time cache cleanup that cannot race a separation this process starts.
    public func removeAbandonedStaging() {
        guard !isSeparating else { return }
        StemCache.removeAbandonedStaging()
    }

    /// Uses a rolling ten-second overlap accumulator and writes completed hops to disk.
    public func splitAudio(
        url: URL,
        progressCallback: @escaping @Sendable (SplitProgressInfo) -> Void
    ) async throws -> [URL] {
        guard !isSeparating else {
            throw DemucsError.conversionFailed("Another separation is still running.")
        }
        isSeparating = true
        modelRelease?.cancel()
        defer {
            isSeparating = false
            scheduleModelRelease()
        }
        // Holding the only separation slot means no other staging folder is live.
        StemCache.removeAbandonedStaging()
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
        try await StreamingAudio.downloadIfNeeded(url) { report(0, "DOWNLOADING FROM ICLOUD...") }
        report(0, "CHECKING AUDIO CACHE...")
        let key = try StemCache.key(for: url)
        let destination = StemCache.root.appending(path: key, directoryHint: .isDirectory)
        if let cached = StemCache.validFiles(in: destination) {
            report(1, "LOADED FROM CACHE")
            return cached
        }
        let fm = FileManager.default
        try fm.createDirectory(at: StemCache.root, withIntermediateDirectories: true)
        try StemCache.ensureSpace(forFrames: StreamingAudio.declaredFrames(of: url))
        report(0.01, "LOADING SEPARATION MODEL...")
        let model = try await loadedModel()
        try Task.checkCancellation()
        try Self.validateModel(model)
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
            throw DemucsError.modelLoadFailed("The model must accept audio [1, 2, 441000] and return sources [1, 4, 2, 441000].")
        }
    }

    static func accumulate(_ output: MLMultiArray, into accumulators: inout [[Float]],
                           weights: inout [Float], window: [Float], mean: Float,
                           standardDeviation: Float) throws {
        guard output.shape.map(\.intValue) == [1, 4, 2, chunkSize],
              output.dataType == .float16 || output.dataType == .float32 else {
            throw DemucsError.conversionFailed("The model returned an unsupported audio tensor.")
        }
        let strides = output.strides.map(\.intValue)
        let step = strides[3]
        let isFloat32 = output.dataType == .float32
        // Resolve the tensor type and storage once; per-sample Objective-C
        // property reads dominated this loop. Arithmetic order is unchanged.
        output.withUnsafeBytes { raw in
            window.withUnsafeBufferPointer { window in
                for stem in 0..<4 {
                    for channel in 0..<2 {
                        let offset = stem * strides[1] + channel * strides[2]
                        accumulators[stem * 2 + channel].withUnsafeMutableBufferPointer { target in
                            if isFloat32 {
                                let samples = raw.baseAddress!.assumingMemoryBound(to: Float.self)
                                for i in 0..<chunkSize {
                                    target[i] += (samples[offset + i * step] * standardDeviation + mean) * window[i]
                                }
                            } else {
                                let samples = raw.baseAddress!.assumingMemoryBound(to: Float16.self)
                                for i in 0..<chunkSize {
                                    target[i] += (Float(samples[offset + i * step]) * standardDeviation + mean) * window[i]
                                }
                            }
                        }
                    }
                }
            }
        }
        for i in 0..<chunkSize { weights[i] += window[i] }
    }

}
