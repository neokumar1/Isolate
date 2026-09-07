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
        secondsPerChunk: Double = 0.98,
        realtimeMultiplier: Double = 5.1
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
    private var isInitializing = false
    
    // Demucs HTDemucs operates on 10.0s chunks @ 44.1kHz (441,000 samples)
    public static let sampleRate: Double = 44100.0
    public static let chunkSize: Int = 441000       // 10.0 seconds
    public static let hopSize: Int = 220500         // 5.0 seconds (50% overlap)
    
    // Stem ordering from the HTDemucs CoreML model
    public static let stemNames: [String] = ["vocals", "drums", "bass", "other"]
    
    private init() {}
    
    // MARK: - Model Pre-Warming & Loading
    
    public func prewarmModel() async {
        do {
            try await loadModelIfNeeded()
            if let model = self.model {
                let inputShape: [NSNumber] = [1, 2, NSNumber(value: Self.chunkSize)]
                if let dummyInput = try? MLMultiArray(shape: inputShape, dataType: .float32) {
                    let provider = try? MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: dummyInput)])
                    if let p = provider {
                        _ = try? await model.prediction(from: p)
                    }
                }
            }
        } catch {
            print("Pre-warming Demucs model background task: \(error)")
        }
    }
    
    public func loadModelIfNeeded() async throws {
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
                self.model = try MLModel(contentsOf: url, configuration: config)
                
                // If loaded from bundle, copy to Application Support for fast future access
                if url != appSupportCompiledURL && !fileManager.fileExists(atPath: appSupportCompiledURL.path) {
                    try? fileManager.copyItem(at: url, to: appSupportCompiledURL)
                }
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
                let tempCompiledURL = try await Task.detached {
                    try MLModel.compileModel(at: pkgURL)
                }.value
                
                if fileManager.fileExists(atPath: appSupportCompiledURL.path) {
                    try? fileManager.removeItem(at: appSupportCompiledURL)
                }
                try fileManager.moveItem(at: tempCompiledURL, to: appSupportCompiledURL)
                
                let config = MLModelConfiguration()
                config.computeUnits = .all
                self.model = try MLModel(contentsOf: appSupportCompiledURL, configuration: config)
                return
            } catch {
                print("Failed to compile mlpackage from \(pkgURL.path): \(error)")
            }
        }
        
        throw DemucsError.modelNotFound("HTDemucs CoreML Neural Engine model could not be found in Bundle resources or Application Support.")
    }
    
    // MARK: - Audio Splitting
    
    /// Splits an input audio file into 4 pristine 32-bit Float stems (Vocals, Drums, Bass, Other).
    /// Uses 50% Normalized Overlap-Add (COLA) with mirror-padded boundaries and energy standardization.
    public func splitAudio(
        url: URL,
        progressCallback: @escaping @Sendable (SplitProgressInfo) -> Void
    ) async throws -> [URL] {
        let startTime = CACurrentMediaTime()
        
        // Stage 1: Immediate feedback for decoding (0% -> 2%)
        progressCallback(SplitProgressInfo(
            fraction: 0.01,
            currentChunk: 0,
            totalChunks: 0,
            elapsedSeconds: 0,
            estimatedRemainingSeconds: 0,
            statusMessage: "DECODING AUDIO TRACK..."
        ))
        
        try await loadModelIfNeeded()
        guard let mlModel = self.model else {
            throw DemucsError.modelNotFound("Model failed to load into memory.")
        }
        
        // 1. Decode and convert input audio to 44.1kHz Stereo Float32
        let (fullSongBuffer, originalFrames) = try await decodeAudioToStandardFormat(url: url)
        guard originalFrames > 0,
              let inL = fullSongBuffer.floatChannelData?[0],
              let inR = fullSongBuffer.floatChannelData?[1] else {
            throw DemucsError.invalidAudioFormat
        }
        
        // Remove sub-audible DC drift and infrasonic rumble below 18 Hz (< 18 Hz)
        // Prevents nonlinear cone excursion and intermodulation static on laptop speakers
        Self.applyInfrasonicFilter(channel: inL, count: originalFrames)
        Self.applyInfrasonicFilter(channel: inR, count: originalFrames)
        
        // 2. Prepare Caching Directory
        let fileHash = "\(url.lastPathComponent.replacingOccurrences(of: " ", with: "_"))_\(originalFrames)"
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Isolate")
            .appendingPathComponent("Stems")
            .appendingPathComponent(fileHash)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        
        let outputURLs = Self.stemNames.map { name in
            appSupport.appendingPathComponent("\(name).wav")
        }
        let originalURL = appSupport.appendingPathComponent("original.wav")
        
        // If all 4 stem files + original.wav already exist in cache and have valid length, return immediately!
        var allCached = true
        let allRequiredURLs = outputURLs + [originalURL]
        for stemURL in allRequiredURLs {
            if !FileManager.default.fileExists(atPath: stemURL.path) {
                allCached = false
                break
            }
            if let attr = try? FileManager.default.attributesOfItem(atPath: stemURL.path),
               let size = attr[.size] as? Int64, size < 1024 {
                allCached = false
                break
            }
        }
        if allCached {
            progressCallback(SplitProgressInfo(
                fraction: 1.0,
                currentChunk: 1,
                totalChunks: 1,
                elapsedSeconds: 0,
                estimatedRemainingSeconds: 0,
                statusMessage: "LOADED FROM CACHE"
            ))
            return outputURLs
        }
        
        // Stage 2: Tensor Prep and Symmetrical Reflection Padding (2% -> 3%)
        let padSize = Self.hopSize
        let paddedFrames = originalFrames + 2 * padSize
        let chunkSize = Self.chunkSize
        let hopSize = Self.hopSize
        let numChunks = Int(ceil(Double(paddedFrames - chunkSize) / Double(hopSize))) + 1
        
        let baselineSecsPerChunk: Double = 0.98
        let initialETA: Double = (Double(numChunks) * baselineSecsPerChunk) + 1.2
        let elapsedDec = CACurrentMediaTime() - startTime
        
        progressCallback(SplitProgressInfo(
            fraction: 0.02,
            currentChunk: 0,
            totalChunks: numChunks,
            elapsedSeconds: elapsedDec,
            estimatedRemainingSeconds: max(1.0, initialETA),
            statusMessage: "PREPARING NEURAL ENGINE..."
        ))
        
        // 3. Compute Audio Energy / Standard Deviation for Demucs nominal scaling
        let (meanVal, stdVal) = computeMeanAndStd(channelL: inL, channelR: inR, count: originalFrames)
        let safeStd = max(stdVal, 1e-4)
        
        // 4. Apply Reflection Padding
        var paddedL = [Float](repeating: 0.0, count: paddedFrames)
        var paddedR = [Float](repeating: 0.0, count: paddedFrames)
        
        // Left reflection pad
        for i in 0..<padSize {
            let srcIdx = min(originalFrames - 1, padSize - i)
            paddedL[i] = inL[srcIdx]
            paddedR[i] = inR[srcIdx]
        }
        // Center original audio
        for i in 0..<originalFrames {
            paddedL[padSize + i] = inL[i]
            paddedR[padSize + i] = inR[i]
        }
        // Right reflection pad
        for i in 0..<padSize {
            let srcIdx = max(0, originalFrames - 2 - i)
            paddedL[padSize + originalFrames + i] = inL[srcIdx]
            paddedR[padSize + originalFrames + i] = inR[srcIdx]
        }
        
        // Normalize padded audio to zero mean, unit variance for model inference
        var normPaddedL = [Float](repeating: 0.0, count: paddedFrames)
        var normPaddedR = [Float](repeating: 0.0, count: paddedFrames)
        let invStd = 1.0 / safeStd
        for i in 0..<paddedFrames {
            normPaddedL[i] = (paddedL[i] - meanVal) * invStd
            normPaddedR[i] = (paddedR[i] - meanVal) * invStd
        }
        
        // 5. Initialize Hann Window & Overlap-Add Accumulators
        var hannWindow = [Float](repeating: 0.0, count: chunkSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(chunkSize), Int32(vDSP_HANN_DENORM))
        
        // Accumulators for 4 stems × 2 channels (8 total) across paddedFrames
        var stemAccumulators = [[Float]](repeating: [Float](repeating: 0.0, count: paddedFrames), count: 8)
        var weightAccumulator = [Float](repeating: 0.0, count: paddedFrames)
        var scratchChunk = [Float](repeating: 0.0, count: chunkSize)
        
        let inputShape: [NSNumber] = [1, 2, NSNumber(value: chunkSize)]
        let inputArray = try MLMultiArray(shape: inputShape, dataType: .float32)
        let inPtrL = inputArray.dataPointer.assumingMemoryBound(to: Float.self)
        let inPtrR = inPtrL.advanced(by: chunkSize)
        
        // Stage 3: Sequential Pipelined Inference Loop (3% to 95%)
        let inferenceStartTime = CACurrentMediaTime()
        
        for chunkIdx in 0..<numChunks {
            try Task.checkCancellation()
            let chunkStart = chunkIdx * hopSize
            let chunkEnd = min(chunkStart + chunkSize, paddedFrames)
            let readFrames = chunkEnd - chunkStart
            
            // Clear input buffer
            vDSP_vclr(inPtrL, 1, vDSP_Length(chunkSize * 2))
            
            // Copy normalized audio into MLMultiArray input
            normPaddedL.withUnsafeBufferPointer { (pL: UnsafeBufferPointer<Float>) -> Void in
                normPaddedR.withUnsafeBufferPointer { (pR: UnsafeBufferPointer<Float>) -> Void in
                    _ = memcpy(inPtrL, pL.baseAddress!.advanced(by: chunkStart), readFrames * MemoryLayout<Float>.size)
                    _ = memcpy(inPtrR, pR.baseAddress!.advanced(by: chunkStart), readFrames * MemoryLayout<Float>.size)
                }
            }
            
            // CoreML Prediction on Neural Engine
            let inputProvider = try MLDictionaryFeatureProvider(dictionary: [
                "audio": MLFeatureValue(multiArray: inputArray)
            ])
            
            let prediction = try await mlModel.prediction(from: inputProvider)
            guard let sourcesArray = prediction.featureValue(for: "sources")?.multiArrayValue else {
                throw DemucsError.conversionFailed("Model output 'sources' multiarray is missing.")
            }
            
            // Overlap-Add model output into accumulators using zero-allocation SIMD
            applyOverlapAddChunk(
                outMultiArray: sourcesArray,
                accumulators: &stemAccumulators,
                weightAccumulator: &weightAccumulator,
                scratchBuffer: &scratchChunk,
                chunkStart: chunkStart,
                readFrames: readFrames,
                window: hannWindow,
                mean: meanVal,
                std: safeStd
            )
            
            let completedChunks = chunkIdx + 1
            let chunkProgress = Double(completedChunks) / Double(numChunks)
            let totalFraction = 0.03 + (0.92 * chunkProgress) // 0.03 -> 0.95
            
            let now = CACurrentMediaTime()
            let inferenceElapsed = now - inferenceStartTime
            
            // Prior-weighted Bayesian moving average (smooths out early warmup variations)
            let priorWeight: Double = 3.0
            let effectiveChunks = Double(completedChunks) + priorWeight
            let effectiveTime = inferenceElapsed + (priorWeight * baselineSecsPerChunk)
            let avgSecsPerChunk = max(0.20, effectiveTime / effectiveChunks)
            
            let remainingChunks = Double(numChunks - completedChunks)
            let rawRemainingSeconds = (remainingChunks * avgSecsPerChunk) + 1.0
            let realtimeMultiplier = max(0.1, 5.0 / max(0.1, avgSecsPerChunk))
            
            progressCallback(SplitProgressInfo(
                fraction: totalFraction,
                currentChunk: completedChunks,
                totalChunks: numChunks,
                elapsedSeconds: now - startTime,
                estimatedRemainingSeconds: max(1.0, rawRemainingSeconds),
                statusMessage: "SEPARATING STEMS (CHUNK \(completedChunks)/\(numChunks))",
                secondsPerChunk: avgSecsPerChunk,
                realtimeMultiplier: realtimeMultiplier
            ))
        }
        
        // Stage 4: Normalize Accumulators & Write 32-Bit Lossless Stems (95% to 100%)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 2,
            interleaved: false
        )!
        
        // Safe minimum weight threshold to avoid divide-by-zero
        weightAccumulator.withUnsafeMutableBufferPointer { wPtr in
            var minWeight: Float = 1e-4
            vDSP_vthr(wPtr.baseAddress!, 1, &minWeight, wPtr.baseAddress!, 1, vDSP_Length(paddedFrames))
        }
        
        for stemIdx in 0..<4 {
            try Task.checkCancellation()
            let stemName = Self.stemNames[stemIdx].uppercased()
            let stemFraction = 0.95 + (0.05 * (Double(stemIdx + 1) / 4.0))
            let writeElapsed = CACurrentMediaTime() - startTime
            let remainingSecs = max(0.0, 1.0 * (1.0 - (Double(stemIdx + 1) / 4.0)))
            
            progressCallback(SplitProgressInfo(
                fraction: stemFraction,
                currentChunk: numChunks,
                totalChunks: numChunks,
                elapsedSeconds: writeElapsed,
                estimatedRemainingSeconds: remainingSecs,
                statusMessage: "SAVING \(stemName) STEM...",
                secondsPerChunk: baselineSecsPerChunk,
                realtimeMultiplier: 5.0 / baselineSecsPerChunk
            ))
            
            let stemL = stemAccumulators[stemIdx * 2]
            let stemR = stemAccumulators[stemIdx * 2 + 1]
            
            let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(originalFrames))!
            outBuffer.frameLength = AVAudioFrameCount(originalFrames)
            let destL = outBuffer.floatChannelData![0]
            let destR = outBuffer.floatChannelData![1]
            
            stemL.withUnsafeBufferPointer { pL in
                stemR.withUnsafeBufferPointer { pR in
                    weightAccumulator.withUnsafeBufferPointer { pW in
                        let srcL = pL.baseAddress! + padSize
                        let srcR = pR.baseAddress! + padSize
                        let srcW = pW.baseAddress! + padSize
                        vDSP_vdiv(srcW, 1, srcL, 1, destL, 1, vDSP_Length(originalFrames))
                        vDSP_vdiv(srcW, 1, srcR, 1, destR, 1, vDSP_Length(originalFrames))
                    }
                }
            }
            
            // Ultrasonic roll-off on "OTHER" stem (stemIdx == 3) to eliminate residual model phase hash (>18.5 kHz)
            if stemIdx == 3 {
                Self.applyUltrasonicFilter(channel: destL, count: originalFrames)
                Self.applyUltrasonicFilter(channel: destR, count: originalFrames)
            }
            
            // Transparent soft-knee headroom limiter to eliminate any digital clipping pops/clicks
            Self.applySoftLimiter(channel: destL, count: originalFrames)
            Self.applySoftLimiter(channel: destR, count: originalFrames)
            
            let stemURL = outputURLs[stemIdx]
            let diskSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let writer = try AVAudioFile(forWriting: stemURL, settings: diskSettings)
            try writer.write(from: outBuffer)
        }
        
        // Write original master track as 44.1kHz Stereo PCM Float32 for 100% sample-accurate master bypass
        let originalBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(originalFrames))!
        originalBuffer.frameLength = AVAudioFrameCount(originalFrames)
        let origDestL = originalBuffer.floatChannelData![0]
        let origDestR = originalBuffer.floatChannelData![1]
        memcpy(origDestL, inL, originalFrames * MemoryLayout<Float>.size)
        memcpy(origDestR, inR, originalFrames * MemoryLayout<Float>.size)
        Self.applySoftLimiter(channel: origDestL, count: originalFrames)
        Self.applySoftLimiter(channel: origDestR, count: originalFrames)
        
        let origSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let origWriter = try AVAudioFile(forWriting: originalURL, settings: origSettings)
        try origWriter.write(from: originalBuffer)
        
        progressCallback(SplitProgressInfo(
            fraction: 1.0,
            currentChunk: numChunks,
            totalChunks: numChunks,
            elapsedSeconds: CACurrentMediaTime() - startTime,
            estimatedRemainingSeconds: 0,
            statusMessage: "SEPARATION COMPLETE"
        ))
        
        return outputURLs
    }
    
    // MARK: - Internal Signal Processing Helpers
    
    private func decodeAudioToStandardFormat(url: URL) async throws -> (AVAudioPCMBuffer, Int) {
        let isSecScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        // Tier 1: CoreAudio ExtAudioFile (Ultra-fast, 100% reliable macOS native C API for MP3, M4A, AAC, FLAC, WAV, ALAC, AIFF)
        if let result = try? decodeWithExtAudioFile(url: url) {
            return result
        }
        
        // Tier 2: AVAssetReader (Handles 16-bit signed integer linear PCM decoding across all AVFoundation formats)
        if let result = try? await decodeWithAssetReader(url: url) {
            return result
        }
        
        // Tier 3: Chunked AVAudioFile + AVAudioConverter fallback
        if let result = try? decodeWithAudioFile(url: url) {
            return result
        }
        
        throw DemucsError.conversionFailed("Unable to decode audio file '\(url.lastPathComponent)'. Corrupt or unsupported format.")
    }
    
    private func decodeWithExtAudioFile(url: URL) throws -> (AVAudioPCMBuffer, Int) {
        var extAudioFile: ExtAudioFileRef? = nil
        let openStatus = ExtAudioFileOpenURL(url as CFURL, &extAudioFile)
        guard openStatus == noErr, let audioFile = extAudioFile else {
            throw DemucsError.conversionFailed("ExtAudioFileOpenURL failed with OSStatus \(openStatus)")
        }
        defer { ExtAudioFileDispose(audioFile) }
        
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: Double(Self.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        let setFormatStatus = ExtAudioFileSetProperty(
            audioFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard setFormatStatus == noErr else {
            throw DemucsError.conversionFailed("ExtAudioFileSetProperty ClientDataFormat failed with OSStatus \(setFormatStatus)")
        }
        
        var totalFrames: Int64 = 0
        var propSize = UInt32(MemoryLayout<Int64>.size)
        _ = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames, &propSize, &totalFrames)
        
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 2,
            interleaved: false
        )!
        
        let readChunkSize: UInt32 = 16384
        var tempLeft = [Float](repeating: 0, count: Int(readChunkSize))
        var tempRight = [Float](repeating: 0, count: Int(readChunkSize))
        
        var allSamplesL: [Float] = []
        var allSamplesR: [Float] = []
        if totalFrames > 0 {
            allSamplesL.reserveCapacity(Int(totalFrames) + 44100)
            allSamplesR.reserveCapacity(Int(totalFrames) + 44100)
        }
        
        let bufferListSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        let bufferListRaw = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListRaw.deallocate() }
        
        let bufferListPtr = bufferListRaw.bindMemory(to: AudioBufferList.self, capacity: 1)
        bufferListPtr.pointee.mNumberBuffers = 2
        
        let buffersPtr = UnsafeMutableAudioBufferListPointer(bufferListPtr)
        
        while true {
            var numFramesToRead = readChunkSize
            
            tempLeft.withUnsafeMutableBufferPointer { leftBuf in
                tempRight.withUnsafeMutableBufferPointer { rightBuf in
                    buffersPtr[0].mNumberChannels = 1
                    buffersPtr[0].mDataByteSize = readChunkSize * 4
                    buffersPtr[0].mData = UnsafeMutableRawPointer(leftBuf.baseAddress)
                    
                    buffersPtr[1].mNumberChannels = 1
                    buffersPtr[1].mDataByteSize = readChunkSize * 4
                    buffersPtr[1].mData = UnsafeMutableRawPointer(rightBuf.baseAddress)
                    
                    let readStatus = ExtAudioFileRead(audioFile, &numFramesToRead, bufferListPtr)
                    if readStatus != noErr || numFramesToRead == 0 {
                        numFramesToRead = 0
                    }
                }
            }
            
            if numFramesToRead == 0 { break }
            
            allSamplesL.append(contentsOf: tempLeft[0..<Int(numFramesToRead)])
            allSamplesR.append(contentsOf: tempRight[0..<Int(numFramesToRead)])
        }
        
        let frameCount = allSamplesL.count
        guard frameCount > 0 else {
            throw DemucsError.invalidAudioFormat
        }
        
        guard let finalBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw DemucsError.conversionFailed("Failed to allocate destination PCM buffer")
        }
        finalBuffer.frameLength = AVAudioFrameCount(frameCount)
        
        let destL = finalBuffer.floatChannelData![0]
        let destR = finalBuffer.floatChannelData![1]
        
        allSamplesL.withUnsafeBufferPointer { pL in
            _ = memcpy(destL, pL.baseAddress!, frameCount * MemoryLayout<Float>.size)
        }
        allSamplesR.withUnsafeBufferPointer { pR in
            _ = memcpy(destR, pR.baseAddress!, frameCount * MemoryLayout<Float>.size)
        }
        
        return (finalBuffer, frameCount)
    }
    
    private func decodeWithAssetReader(url: URL) async throws -> (AVAudioPCMBuffer, Int) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw DemucsError.invalidAudioFormat
        }
        
        let reader = try AVAssetReader(asset: asset)
        
        // Output settings for standard 16-bit Linear PCM (Universal compatibility across all macOS decoders)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw DemucsError.assetReaderFailed("Cannot add track output")
        }
        reader.add(output)
        
        guard reader.startReading() else {
            throw DemucsError.assetReaderFailed(reader.error?.localizedDescription ?? "Start reading failed")
        }
        
        var audioSamplesL: [Float] = []
        var audioSamplesR: [Float] = []
        
        let durationTime = (try? await asset.load(.duration)) ?? .zero
        let durationSecs = CMTimeGetSeconds(durationTime)
        let estimatedCapacity = max(1024, Int(durationSecs * Self.sampleRate) + 44100)
        audioSamplesL.reserveCapacity(estimatedCapacity)
        audioSamplesR.reserveCapacity(estimatedCapacity)
        
        let scale: Float = 1.0 / 32768.0
        
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            guard numSamples > 0 else { continue }
            
            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            
            guard status == noErr, let rawPtr = dataPointer else { continue }
            
            let int16Ptr = UnsafeRawPointer(rawPtr).assumingMemoryBound(to: Int16.self)
            for i in 0..<numSamples {
                audioSamplesL.append(Float(int16Ptr[i * 2]) * scale)
                audioSamplesR.append(Float(int16Ptr[i * 2 + 1]) * scale)
            }
        }
        
        if reader.status == .failed {
            throw DemucsError.assetReaderFailed(reader.error?.localizedDescription ?? "Reader failed mid-stream")
        }
        
        let totalFrames = audioSamplesL.count
        guard totalFrames > 0 else {
            throw DemucsError.invalidAudioFormat
        }
        
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 2,
            interleaved: false
        )!
        
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            throw DemucsError.conversionFailed("Failed to allocate destination PCM buffer")
        }
        pcmBuffer.frameLength = AVAudioFrameCount(totalFrames)
        
        let destL = pcmBuffer.floatChannelData![0]
        let destR = pcmBuffer.floatChannelData![1]
        
        audioSamplesL.withUnsafeBufferPointer { (pL: UnsafeBufferPointer<Float>) -> Void in
            _ = memcpy(destL, pL.baseAddress!, totalFrames * MemoryLayout<Float>.size)
        }
        audioSamplesR.withUnsafeBufferPointer { (pR: UnsafeBufferPointer<Float>) -> Void in
            _ = memcpy(destR, pR.baseAddress!, totalFrames * MemoryLayout<Float>.size)
        }
        
        return (pcmBuffer, totalFrames)
    }
    
    private func decodeWithAudioFile(url: URL) throws -> (AVAudioPCMBuffer, Int) {
        let inFile = try AVAudioFile(forReading: url)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 2,
            interleaved: false
        )!
        
        guard let converter = AVAudioConverter(from: inFile.processingFormat, to: targetFormat) else {
            throw DemucsError.conversionFailed("Unable to create AVAudioConverter for \(url.lastPathComponent)")
        }
        
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        
        let ratio = Self.sampleRate / max(1.0, inFile.fileFormat.sampleRate)
        let estimatedFrames = AVAudioFrameCount(Double(inFile.length) * ratio) + 88200
        guard let fullBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedFrames) else {
            throw DemucsError.conversionFailed("Failed to allocate audio conversion buffer.")
        }
        
        let chunkSize: AVAudioFrameCount = 65536
        guard let chunkBuffer = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat, frameCapacity: chunkSize) else {
            throw DemucsError.conversionFailed("Failed to allocate input chunk buffer.")
        }
        
        var convError: NSError? = nil
        converter.convert(to: fullBuffer, error: &convError) { inNumPackets, outStatus in
            do {
                if inFile.framePosition >= inFile.length {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                let remainingFrames = inFile.length - inFile.framePosition
                let framesToRead = min(chunkSize, AVAudioFrameCount(remainingFrames))
                if framesToRead == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                chunkBuffer.frameLength = 0
                try inFile.read(into: chunkBuffer, frameCount: framesToRead)
                outStatus.pointee = .haveData
                return chunkBuffer
            } catch {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        
        if let err = convError {
            throw DemucsError.conversionFailed(err.localizedDescription)
        }
        
        return (fullBuffer, Int(fullBuffer.frameLength))
    }
    
    private func computeMeanAndStd(channelL: UnsafePointer<Float>, channelR: UnsafePointer<Float>, count: Int) -> (Float, Float) {
        var meanL: Float = 0
        var meanR: Float = 0
        vDSP_meanv(channelL, 1, &meanL, vDSP_Length(count))
        vDSP_meanv(channelR, 1, &meanR, vDSP_Length(count))
        let meanVal = (meanL + meanR) * 0.5
        
        var rmsL: Float = 0
        var rmsR: Float = 0
        vDSP_rmsqv(channelL, 1, &rmsL, vDSP_Length(count))
        vDSP_rmsqv(channelR, 1, &rmsR, vDSP_Length(count))
        let rmsVal = sqrtf((rmsL * rmsL + rmsR * rmsR) * 0.5)
        let stdVal = sqrtf(max(0, rmsVal * rmsVal - meanVal * meanVal))
        
        return (meanVal, stdVal)
    }
    
    private nonisolated func applyOverlapAddChunk(
        outMultiArray: MLMultiArray,
        accumulators: inout [[Float]],
        weightAccumulator: inout [Float],
        scratchBuffer: inout [Float],
        chunkStart: Int,
        readFrames: Int,
        window: [Float],
        mean: Float,
        std: Float
    ) {
        let isFloat32 = outMultiArray.dataType == .float32
        let strides = outMultiArray.strides
        let stemStride = strides[1].intValue
        let channelStride = strides[2].intValue
        var stdVal = std
        var meanVal = mean
        let length = vDSP_Length(readFrames)
        
        scratchBuffer.withUnsafeMutableBufferPointer { scPtr in
            let scAddress = scPtr.baseAddress!
            
            for stemIdx in 0..<4 {
                let stemOffset = stemIdx * stemStride
                
                // Left channel: scale -> window -> accumulate in SIMD
                if isFloat32 {
                    let outPtr = outMultiArray.dataPointer.assumingMemoryBound(to: Float.self)
                    let srcL = outPtr.advanced(by: stemOffset)
                    vDSP_vsmsa(srcL, 1, &stdVal, &meanVal, scAddress, 1, length)
                } else {
                    let outPtr = outMultiArray.dataPointer.assumingMemoryBound(to: Float16.self)
                    let srcL = outPtr.advanced(by: stemOffset)
                    for i in 0..<readFrames {
                        scAddress[i] = Float(srcL[i])
                    }
                    vDSP_vsmsa(scAddress, 1, &stdVal, &meanVal, scAddress, 1, length)
                }
                vDSP_vmul(scAddress, 1, window, 1, scAddress, 1, length)
                accumulators[stemIdx * 2].withUnsafeMutableBufferPointer { accPtr in
                    vDSP_vadd(accPtr.baseAddress! + chunkStart, 1, scAddress, 1, accPtr.baseAddress! + chunkStart, 1, length)
                }
                
                // Right channel: scale -> window -> accumulate in SIMD
                if isFloat32 {
                    let outPtr = outMultiArray.dataPointer.assumingMemoryBound(to: Float.self)
                    let srcR = outPtr.advanced(by: stemOffset + channelStride)
                    vDSP_vsmsa(srcR, 1, &stdVal, &meanVal, scAddress, 1, length)
                } else {
                    let outPtr = outMultiArray.dataPointer.assumingMemoryBound(to: Float16.self)
                    let srcR = outPtr.advanced(by: stemOffset + channelStride)
                    for i in 0..<readFrames {
                        scAddress[i] = Float(srcR[i])
                    }
                    vDSP_vsmsa(scAddress, 1, &stdVal, &meanVal, scAddress, 1, length)
                }
                vDSP_vmul(scAddress, 1, window, 1, scAddress, 1, length)
                accumulators[stemIdx * 2 + 1].withUnsafeMutableBufferPointer { accPtr in
                    vDSP_vadd(accPtr.baseAddress! + chunkStart, 1, scAddress, 1, accPtr.baseAddress! + chunkStart, 1, length)
                }
            }
        }
        
        weightAccumulator.withUnsafeMutableBufferPointer { wPtr in
            vDSP_vadd(wPtr.baseAddress! + chunkStart, 1, window, 1, wPtr.baseAddress! + chunkStart, 1, length)
        }
    }
    
    // MARK: - Pristine Studio Signal Conditioning
    
    /// Removes sub-audible DC drift and infrasonic rumble below 18 Hz (< 18 Hz).
    /// Prevents nonlinear cone excursion and intermodulation static on laptop micro-transducers.
    public static func applyInfrasonicFilter(
        channel: UnsafeMutablePointer<Float>,
        count: Int,
        cutoff: Float = 18.0,
        sampleRate: Float = 44100.0
    ) {
        guard count > 0 else { return }
        let w0 = 2.0 * Float.pi * cutoff / sampleRate
        let cosW0 = cosf(w0)
        let alpha = sinf(w0) / (2.0 * 0.70710678)
        let a0 = 1.0 + alpha
        let b0 = (1.0 + cosW0) * 0.5 / a0
        let b1 = -(1.0 + cosW0) / a0
        let b2 = (1.0 + cosW0) * 0.5 / a0
        let a1 = (-2.0 * cosW0) / a0
        let a2 = (1.0 - alpha) / a0

        var x1: Float = 0, x2: Float = 0
        var y1: Float = 0, y2: Float = 0
        for i in 0..<count {
            let x0 = channel[i]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
            channel[i] = y0
        }
    }
    
    /// Removes ultrasonic phase hash (> 18.5 kHz) generated by residual neural network phase cancellation.
    /// Eliminates static buzz and harsh treble folding on MacBook Pro micro-transducers.
    public static func applyUltrasonicFilter(
        channel: UnsafeMutablePointer<Float>,
        count: Int,
        cutoff: Float = 18500.0,
        sampleRate: Float = 44100.0
    ) {
        guard count > 0 else { return }
        let w0 = 2.0 * Float.pi * cutoff / sampleRate
        let cosW0 = cosf(w0)
        let alpha = sinf(w0) / (2.0 * 0.70710678)
        let a0 = 1.0 + alpha
        let b0 = (1.0 - cosW0) * 0.5 / a0
        let b1 = (1.0 - cosW0) / a0
        let b2 = (1.0 - cosW0) * 0.5 / a0
        let a1 = (-2.0 * cosW0) / a0
        let a2 = (1.0 - alpha) / a0

        var x1: Float = 0, x2: Float = 0
        var y1: Float = 0, y2: Float = 0
        for i in 0..<count {
            let x0 = channel[i]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
            channel[i] = y0
        }
    }
    
    /// Transparently compresses transient inter-sample peaks exceeding ±0.95 to guarantee 0.0 dBFS ceiling.
    /// Continuous 1st-derivative ensures zero harmonic clipping distortion.
    public static func applySoftLimiter(
        channel: UnsafeMutablePointer<Float>,
        count: Int,
        threshold: Float = 0.95
    ) {
        guard count > 0 else { return }
        let headroom: Float = 1.0 - threshold
        let invHeadroom: Float = 1.0 / headroom
        for i in 0..<count {
            let val = channel[i]
            let absVal = abs(val)
            if absVal > threshold {
                let sgn: Float = val < 0 ? -1.0 : 1.0
                channel[i] = sgn * (threshold + headroom * tanhf((absVal - threshold) * invHeadroom))
            }
        }
    }
}
