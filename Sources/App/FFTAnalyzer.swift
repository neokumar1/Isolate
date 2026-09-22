import Foundation
import Accelerate

/// Accelerate FFT setups are immutable and may be shared by analyzers with the
/// same transform size. Keep them alive for the process instead of repeatedly
/// creating and destroying opaque setup handles as short-lived audio graphs
/// are rebuilt.
private final class FFTSetupCache: @unchecked Sendable {
    static let shared = FFTSetupCache()

    private let lock = NSLock()
    private var setups: [vDSP_Length: FFTSetup] = [:]

    func setup(for log2n: vDSP_Length) -> FFTSetup {
        lock.lock()
        defer { lock.unlock() }
        if let setup = setups[log2n] { return setup }
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        setups[log2n] = setup
        return setup
    }
}

/// Reuses FFT working buffers. Confine each instance to one audio tap or caller.
public final class FFTAnalyzer {
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
        precondition(fftSize >= 2 && fftSize.nonzeroBitCount == 1, "FFT size must be a power of two")
        self.fftSize = fftSize
        let half = fftSize / 2
        self.halfSize = half
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.windowSize = vDSP_Length(fftSize)
        self.fftSetup = FFTSetupCache.shared.setup(for: log2n)
        
        self.window = [Float](repeating: 0, count: fftSize)
        self.windowedBuffer = [Float](repeating: 0, count: fftSize)
        self.realp = [Float](repeating: 0, count: half)
        self.imagp = [Float](repeating: 0, count: half)
        self.cachedMagnitudes = [Float](repeating: 0, count: half)
        self.scale = Float(1.0 / Float(fftSize))
        
        vDSP_hann_window(&window, windowSize, Int32(vDSP_HANN_NORM))
    }
    
    /// Transform at most frameCount samples, zero-padding short buffers.
    public func computeFFT(buffer: UnsafePointer<Float>, frameCount: Int, outMagnitudes: inout [Float]) {
        precondition(outMagnitudes.count >= halfSize)
        let count = max(0, min(frameCount, fftSize))
        windowedBuffer.withUnsafeMutableBufferPointer { target in
            target.initialize(repeating: 0)
            if count > 0 { vDSP_vmul(buffer, 1, window, 1, target.baseAddress!, 1, vDSP_Length(count)) }
        }
        
        realp.withUnsafeMutableBufferPointer { realpPtr in
            imagp.withUnsafeMutableBufferPointer { imagpPtr in
                var splitComplex = DSPSplitComplex(realp: realpPtr.baseAddress!, imagp: imagpPtr.baseAddress!)
                
                windowedBuffer.withUnsafeBytes { ptr in
                    let bound = ptr.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(bound.baseAddress!, 2, &splitComplex, 1, vDSP_Length(halfSize))
                }
                
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                
                outMagnitudes.withUnsafeMutableBufferPointer { outPtr in
                    // Real FFT packs Nyquist into the imaginary DC slot.
                    splitComplex.imagp[0] = 0
                    vDSP_zvabs(&splitComplex, 1, outPtr.baseAddress!, 1, vDSP_Length(halfSize))
                    vDSP_vsmul(outPtr.baseAddress!, 1, &scale, outPtr.baseAddress!, 1, vDSP_Length(halfSize))
                }
            }
        }
    }
    
    public func computeFFT(buffer: inout [Float]) -> [Float] {
        buffer.withUnsafeBufferPointer { p in
            if let address = p.baseAddress {
                computeFFT(buffer: address, frameCount: p.count, outMagnitudes: &cachedMagnitudes)
            } else {
                cachedMagnitudes = Array(repeating: 0, count: halfSize)
            }
            return cachedMagnitudes
        }
    }
}
