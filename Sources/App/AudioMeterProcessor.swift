import AVFoundation
import Accelerate

/// One processor per tap. Its mutable DSP state is confined to that tap's audio callback.
final class AudioMeterProcessor: @unchecked Sendable {
    struct Reading: Sendable {
        let spectrum: [Float]
        let waveform: [Float]
        let peak: Float
    }

    private let fft = FFTAnalyzer()
    private var magnitudes = [Float](repeating: 0, count: 512)
    private var channelMagnitudes = [Float](repeating: 0, count: 512)
    private var smoothed: [Float]
    private var lastUpdate: TimeInterval = 0
    private let bandCount: Int

    init(bandCount: Int) {
        self.bandCount = bandCount
        smoothed = Array(repeating: 0, count: bandCount)
    }

    func process(_ buffer: AVAudioPCMBuffer) -> Reading? {
        let now = CACurrentMediaTime()
        guard now - lastUpdate >= 1.0 / 30.0,
              buffer.frameLength > 0, let channels = buffer.floatChannelData else { return nil }
        lastUpdate = now
        fft.computeFFT(buffer: channels[0], frameCount: Int(buffer.frameLength), outMagnitudes: &magnitudes)
        // Preserve right-only and opposite-phase stereo content in the display.
        for channel in 1..<Int(buffer.format.channelCount) {
            fft.computeFFT(buffer: channels[channel], frameCount: Int(buffer.frameLength), outMagnitudes: &channelMagnitudes)
            for bin in magnitudes.indices { magnitudes[bin] = max(magnitudes[bin], channelMagnitudes[bin]) }
        }
        let nyquist = Float(buffer.format.sampleRate / 2)
        let maxFrequency = min(nyquist, 19_000)
        for band in 0..<bandCount {
            let low = 28 * pow(maxFrequency / 28, Float(band) / Float(bandCount))
            let high = 28 * pow(maxFrequency / 28, Float(band + 1) / Float(bandCount))
            let first = max(0, min(511, Int(low / nyquist * 512)))
            let last = max(first, min(511, Int(high / nyquist * 512)))
            var peak: Float = 0
            for bin in first...last { peak = max(peak, magnitudes[bin]) }
            let target = min(1, max(0, peak - 0.0015) * 18)
            let smoothing: Float = target > smoothed[band] ? 0.88 : 0.28
            smoothed[band] += (target - smoothed[band]) * smoothing
        }
        var waveform = [Float](repeating: 0.05, count: 30)
        let blockSize = Int(buffer.frameLength) / waveform.count
        if blockSize > 0 {
            for index in waveform.indices {
                for channel in 0..<Int(buffer.format.channelCount) {
                    var rms: Float = 0
                    vDSP_rmsqv(channels[channel] + index * blockSize, 1, &rms, vDSP_Length(blockSize))
                    if rms.isFinite { waveform[index] = min(1, max(waveform[index], rms * 5)) }
                }
            }
        }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            var channelPeak: Float = 0
            vDSP_maxmgv(channels[channel], 1, &channelPeak, vDSP_Length(buffer.frameLength))
            peak = max(peak, channelPeak)
        }
        return Reading(spectrum: smoothed, waveform: waveform, peak: peak)
    }
}
