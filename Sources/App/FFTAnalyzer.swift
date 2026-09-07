import Foundation
import Accelerate

/// High-performance, real-time audio thread safe FFT analyzer with pre-allocated buffers.
/// Guarantees ZERO heap allocations in computeFFT to prevent audio thread lock contention or underrun crackle.
public final class FFTAnalyzer: @unchecked Sendable {
    public let fftSize: Int
    public let halfSize: Int
    private let log2n: vDSP_Length
    private let windowSize: vDSP_Length
    private let fftSetup: FFTSetup
    
    private var window: [Float]
    private var windowedBuffer: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var cachedMagnitudes: [Float]
    private var scale: Float
    
    public init(fftSize: Int = 1024) {
        self.fftSize = fftSize
        let half = fftSize / 2
        self.halfSize = half
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.windowSize = vDSP_Length(fftSize)
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        
        self.window = [Float](repeating: 0, count: fftSize)
        self.windowedBuffer = [Float](repeating: 0, count: fftSize)
        self.realp = [Float](repeating: 0, count: half)
        self.imagp = [Float](repeating: 0, count: half)
        self.cachedMagnitudes = [Float](repeating: 0, count: half)
        self.scale = Float(1.0 / Float(fftSize))
        
        vDSP_hann_window(&window, windowSize, Int32(vDSP_HANN_NORM))
    }
    
    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }
    
    /// Zero-allocation in-place FFT computation.
    public func computeFFT(buffer: UnsafePointer<Float>, outMagnitudes: inout [Float]) {
        vDSP_vmul(buffer, 1, window, 1, &windowedBuffer, 1, windowSize)
        
        realp.withUnsafeMutableBufferPointer { realpPtr in
            imagp.withUnsafeMutableBufferPointer { imagpPtr in
                var splitComplex = DSPSplitComplex(realp: realpPtr.baseAddress!, imagp: imagpPtr.baseAddress!)
                
                windowedBuffer.withUnsafeBytes { ptr in
                    let bound = ptr.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(bound.baseAddress!, 2, &splitComplex, 1, vDSP_Length(halfSize))
                }
                
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                
                outMagnitudes.withUnsafeMutableBufferPointer { outPtr in
                    vDSP_zvabs(&splitComplex, 1, outPtr.baseAddress!, 1, vDSP_Length(halfSize))
                    vDSP_vsmul(outPtr.baseAddress!, 1, &scale, outPtr.baseAddress!, 1, vDSP_Length(halfSize))
                }
            }
        }
    }
    
    /// Backward-compatible computeFFT returning a copy of magnitudes.
    public func computeFFT(buffer: UnsafePointer<Float>) -> [Float] {
        computeFFT(buffer: buffer, outMagnitudes: &cachedMagnitudes)
        return cachedMagnitudes
    }
    
    public func computeFFT(buffer: inout [Float]) -> [Float] {
        buffer.withUnsafeBufferPointer { p in
            computeFFT(buffer: p.baseAddress!)
        }
    }
}

/// Dedicated real-time 7-band parametric stem meter analyzer.
/// Avoids lock contention and executes with zero memory allocation.
public final class StemMeterAnalyzer: @unchecked Sendable {
    private let fft: FFTAnalyzer
    private var rawMagnitudes: [Float]
    public var bands: [Float] = Array(repeating: 0, count: 7)
    
    public init() {
        self.fft = FFTAnalyzer(fftSize: 1024)
        self.rawMagnitudes = Array(repeating: 0, count: 512)
    }
    
    public func computeBands(buffer: UnsafePointer<Float>, stem: Int) -> [Float] {
        fft.computeFFT(buffer: buffer, outMagnitudes: &rawMagnitudes)
        
        func bandEnergy(start: Int, end: Int) -> Float {
            let s = max(0, min(start, 511))
            let e = max(s, min(end, 511))
            var sum: Float = 0
            var count = 0
            for i in s...e {
                sum += rawMagnitudes[i]
                count += 1
            }
            return count > 0 ? (sum / Float(count)) : 0.0
        }
        
        switch stem {
        case 0: // VOCALS: Tuned to human vocal formants (150 Hz - 9.5 kHz)
            bands[0] = bandEnergy(start: 3, end: 7)     // 130 - 300 Hz
            bands[1] = bandEnergy(start: 7, end: 14)    // 300 - 600 Hz
            bands[2] = bandEnergy(start: 14, end: 28)   // 600 - 1.2 kHz
            bands[3] = bandEnergy(start: 28, end: 52)   // 1.2 - 2.2 kHz
            bands[4] = bandEnergy(start: 52, end: 85)   // 2.2 - 3.6 kHz
            bands[5] = bandEnergy(start: 85, end: 135)  // 3.6 - 5.8 kHz
            bands[6] = bandEnergy(start: 135, end: 220) // 5.8 - 9.5 kHz
            
        case 1: // DRUMS: Transient-optimized (Kick, Snare, Hi-hats, Cymbals)
            bands[0] = bandEnergy(start: 1, end: 2)     // 40 - 80 Hz
            bands[1] = bandEnergy(start: 2, end: 4)     // 80 - 160 Hz
            bands[2] = bandEnergy(start: 4, end: 9)     // 160 - 380 Hz
            bands[3] = bandEnergy(start: 9, end: 24)    // 380 - 1.0 kHz
            bands[4] = bandEnergy(start: 24, end: 70)   // 1.0 - 3.0 kHz
            bands[5] = bandEnergy(start: 70, end: 175)  // 3.0 - 7.5 kHz
            bands[6] = bandEnergy(start: 175, end: 350) // 7.5 - 15 kHz
            
        case 2: // BASS: Low-frequency weighted (808s, Sub, Bass guitar)
            bands[0] = bandEnergy(start: 1, end: 1)     // 30 - 55 Hz
            bands[1] = bandEnergy(start: 2, end: 2)     // 55 - 90 Hz
            bands[2] = bandEnergy(start: 3, end: 4)     // 90 - 170 Hz
            bands[3] = bandEnergy(start: 4, end: 6)     // 170 - 260 Hz
            bands[4] = bandEnergy(start: 6, end: 10)    // 260 - 430 Hz
            bands[5] = bandEnergy(start: 10, end: 18)   // 430 - 770 Hz
            bands[6] = bandEnergy(start: 18, end: 40)   // 770 - 1.7 kHz
            
        case 3: // OTHER: Full musical range (Pianos, Guitars, Synths, FX)
            bands[0] = bandEnergy(start: 3, end: 6)     // 130 - 260 Hz
            bands[1] = bandEnergy(start: 6, end: 14)    // 260 - 600 Hz
            bands[2] = bandEnergy(start: 14, end: 30)   // 600 - 1.3 kHz
            bands[3] = bandEnergy(start: 30, end: 60)   // 1.3 - 2.6 kHz
            bands[4] = bandEnergy(start: 60, end: 115)  // 2.6 - 5.0 kHz
            bands[5] = bandEnergy(start: 115, end: 210) // 5.0 - 9.0 kHz
            bands[6] = bandEnergy(start: 210, end: 370) // 9.0 - 16 kHz
            
        default: break
        }
        
        return bands
    }
}
