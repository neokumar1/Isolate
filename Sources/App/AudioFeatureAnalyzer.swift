import Foundation
@preconcurrency import AVFoundation

/// Estimates tempo and tonal center from decoded audio when a file has no tags.
/// Analysis runs off the main actor and never guesses from a filename or genre.
enum AudioFeatureAnalyzer {
    struct Result: Codable, Sendable {
        let bpm: Double?
        let key: String?
    }

    private static let cacheName = "analysis-v1.json"
    private static let targetRate = 11_025.0
    private static let maximumDuration = 90.0
    private static let notes = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func analyze(original: URL, drums: URL?) throws -> Result {
        let cache = original.deletingLastPathComponent().appending(path: cacheName)
        let mayCache = original.lastPathComponent == "original.wav" && StemCache.owns(original.deletingLastPathComponent())
        if mayCache, let data = try? Data(contentsOf: cache),
           let saved = try? JSONDecoder().decode(Result.self, from: data) { return saved }

        let originalSamples = try readMono(original)
        let drumSamples = drums.flatMap { try? readMono($0) }
        let result = Result(
            bpm: estimateTempo(in: drumSamples ?? originalSamples),
            key: estimateKey(in: originalSamples)
        )
        try Task.checkCancellation()
        if mayCache, let data = try? JSONEncoder().encode(result) {
            try? data.write(to: cache, options: .atomic)
        }
        return result
    }

    /// Read at most 90 seconds at roughly 11 kHz. This bounds both I/O and memory
    /// for arbitrarily long source files while covering more than a short intro.
    private static func readMono(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let step = max(1, Int((file.processingFormat.sampleRate / targetRate).rounded()))
        let rate = file.processingFormat.sampleRate / Double(step)
        let limit = min(Int(file.length), Int(maximumDuration * file.processingFormat.sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
            throw DemucsError.invalidAudioFormat
        }
        var samples: [Float] = []
        samples.reserveCapacity(limit / step + 1)
        var read = 0
        while read < limit {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, limit - read)))
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { break }
            let channelCount = Int(file.processingFormat.channelCount)
            let first = (step - read % step) % step
            if first < count {
                for i in stride(from: first, to: count, by: step) {
                    var sum: Float = 0
                    for channel in 0..<channelCount { sum += channels[channel][i] }
                    samples.append(sum / Float(channelCount))
                }
            }
            read += count
        }
        return (samples, rate)
    }

    static func estimateTempo(in signal: (samples: [Float], sampleRate: Double)) -> Double? {
        let window = max(1, Int((signal.sampleRate / 100).rounded()))
        let frames = signal.samples.count / window
        guard frames >= 800 else { return nil }
        var levels = [Double](repeating: 0, count: frames)
        for frame in 0..<frames {
            var energy = 0.0
            for i in (frame * window)..<((frame + 1) * window) {
                let value = Double(signal.samples[i])
                energy += value * value
            }
            levels[frame] = sqrt(energy / Double(window))
        }
        let meanLevel = levels.reduce(0, +) / Double(frames)
        guard meanLevel > 0.001 else { return nil }
        var onset = [Double](repeating: 0, count: frames)
        for i in 1..<frames { onset[i] = max(0, levels[i] - levels[i - 1]) }
        guard (onset.max() ?? 0) > meanLevel * 0.04 else { return nil }
        let onsetEnergy = onset.reduce(0) { $0 + $1 * $1 }
        guard onsetEnergy > 1e-8 else { return nil }

        let envelopeRate = signal.sampleRate / Double(window)
        let shortestLag = Int((60 * envelopeRate / 190).rounded())
        let longestLag = Int((60 * envelopeRate / 65).rounded())
        var scores: [(lag: Int, score: Double)] = []
        for lag in shortestLag...longestLag {
            var product = 0.0
            var left = 0.0
            var right = 0.0
            for i in lag..<frames {
                product += onset[i] * onset[i - lag]
                left += onset[i] * onset[i]
                right += onset[i - lag] * onset[i - lag]
            }
            let correlation = product / sqrt(max(left * right, 1e-20))
            // Equal quarter-note pulse trains have octave-related peaks. The
            // longer-lag agreement rewards a steady beat without hard-coding 120 BPM.
            let beat = 60 * envelopeRate / Double(lag)
            let prior = 1 - 0.06 * abs(log2(beat / 120))
            scores.append((lag, correlation * prior))
        }
        guard let best = scores.max(by: { $0.score < $1.score }), best.score >= 0.16 else { return nil }
        // A broad or nearly tied non-harmonic peak is not a defensible estimate.
        let competitor = scores.filter { abs($0.lag - best.lag) > 2 &&
            abs(Double($0.lag) / Double(best.lag) - 2) > 0.07 &&
            abs(Double(best.lag) / Double($0.lag) - 2) > 0.07 }
            .map(\.score).max() ?? 0
        guard best.score >= competitor * 1.12 else { return nil }
        return (60 * envelopeRate / Double(best.lag) * 10).rounded() / 10
    }

    static func estimateKey(in signal: (samples: [Float], sampleRate: Double)) -> String? {
        let size = 16_384
        let hop = 8_192
        guard signal.samples.count >= max(size, Int(signal.sampleRate * 8)) else { return nil }
        let fft = FFTAnalyzer(fftSize: size)
        var magnitudes = [Float](repeating: 0, count: size / 2)
        var chroma = [Double](repeating: 0, count: 12)
        var windows = 0
        signal.samples.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            for start in stride(from: 0, through: samples.count - size, by: hop) {
                if Task.isCancelled { return }
                fft.computeFFT(buffer: base + start, frameCount: size, outMagnitudes: &magnitudes)
                let peak = magnitudes.max() ?? 0
                guard peak > 0.0005 else { continue }
                var frameChroma = [Double](repeating: 0, count: 12)
                let low = max(2, Int(80 * Double(size) / signal.sampleRate))
                let high = min(magnitudes.count - 2, Int(1_600 * Double(size) / signal.sampleRate))
                guard low < high else { continue }
                for bin in low...high where magnitudes[bin] > peak * 0.045 &&
                    magnitudes[bin] >= magnitudes[bin - 1] && magnitudes[bin] >= magnitudes[bin + 1] {
                    let frequency = Double(bin) * signal.sampleRate / Double(size)
                    let note = Int((69 + 12 * log2(frequency / 440)).rounded())
                    let pitchClass = (note % 12 + 12) % 12
                    frameChroma[pitchClass] += Double(magnitudes[bin])
                }
                let total = frameChroma.reduce(0, +)
                guard total > 0 else { continue }
                for pitch in 0..<12 { chroma[pitch] += frameChroma[pitch] / total }
                windows += 1
            }
        }
        guard windows >= 8 else { return nil }
        let total = chroma.reduce(0, +)
        guard total > 0 else { return nil }
        chroma = chroma.map { $0 / total }
        let strongest = chroma.max() ?? 0
        guard chroma.filter({ $0 > strongest * 0.18 }).count >= 3 else { return nil }

        func correlation(_ profile: [Double], root: Int) -> Double {
            let rotated = (0..<12).map { profile[($0 - root + 12) % 12] }
            let meanProfile = rotated.reduce(0, +) / 12
            let meanChroma = 1.0 / 12
            let dot = (0..<12).reduce(0.0) { $0 + (chroma[$1] - meanChroma) * (rotated[$1] - meanProfile) }
            let x = chroma.reduce(0.0) { $0 + pow($1 - meanChroma, 2) }
            let y = rotated.reduce(0.0) { $0 + pow($1 - meanProfile, 2) }
            return dot / sqrt(max(x * y, 1e-20))
        }
        var candidates: [(root: Int, minor: Bool, score: Double)] = []
        for root in 0..<12 {
            candidates.append((root, false, correlation(majorProfile, root: root)))
            candidates.append((root, true, correlation(minorProfile, root: root)))
        }
        candidates.sort { $0.score > $1.score }
        guard candidates[0].score >= 0.48,
              candidates[0].score - candidates[1].score >= 0.025 else { return nil }
        return notes[candidates[0].root] + (candidates[0].minor ? "m" : " major")
    }
}
