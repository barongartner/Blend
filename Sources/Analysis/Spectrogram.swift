// STFT on Accelerate. Produces power spectra and mel-band log spectra that the
// beat and key analyzers consume. All plain arrays; frames are rows.

import Foundation
import Accelerate

final class RealFFT {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var realp: [Float]
    private var imagp: [Float]
    private var windowed: [Float]
    let window: [Float]

    init(size n: Int) {
        precondition(n > 0 && (n & (n - 1)) == 0, "FFT size must be a power of two")
        self.n = n
        log2n = vDSP_Length(log2(Double(n)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        realp = [Float](repeating: 0, count: n / 2)
        imagp = [Float](repeating: 0, count: n / 2)
        windowed = [Float](repeating: 0, count: n)
        var w = [Float](repeating: 0, count: n)
        vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        window = w
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Power spectrum (n/2 bins, DC first, Nyquist dropped) of one Hann-windowed frame.
    func powerSpectrum(_ frame: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(n))
        let half = n / 2
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                let dc = rp[0]
                ip[0] = 0
                vDSP_zvmags(&split, 1, out, 1, vDSP_Length(half))
                out[0] = dc * dc
                var scale = 1 / Float(n * n)
                vDSP_vsmul(out, 1, &scale, out, 1, vDSP_Length(half))
            }
        }
    }
}

struct MelFilter {
    let startBin: Int
    let weights: [Float]
}

enum Spectrogram {

    static func hzToMel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
    static func melToHz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }

    /// Triangular mel filters over `nBins` linear bins spanning 0...sampleRate/2.
    static func melFilterbank(bands: Int, bins: Int, sampleRate: Double, fMin: Double, fMax: Double) -> [MelFilter] {
        let mMin = hzToMel(fMin), mMax = hzToMel(fMax)
        let points = (0...(bands + 1)).map { melToHz(mMin + (mMax - mMin) * Double($0) / Double(bands + 1)) }
        let binHz = sampleRate / 2 / Double(bins)
        var filters: [MelFilter] = []
        for b in 0..<bands {
            let lo = points[b], mid = points[b + 1], hi = points[b + 2]
            let b0 = max(0, Int(floor(lo / binHz)))
            let b1 = min(bins - 1, Int(ceil(hi / binHz)))
            var w: [Float] = []
            for k in b0...max(b0, b1) {
                let f = Double(k) * binHz
                var v = 0.0
                if f >= lo && f <= mid && mid > lo { v = (f - lo) / (mid - lo) }
                else if f > mid && f <= hi && hi > mid { v = (hi - f) / (hi - mid) }
                w.append(Float(v))
            }
            if w.allSatisfy({ $0 == 0 }), b0 < bins { w[0] = 1 }   // very narrow filter at low bins
            filters.append(MelFilter(startBin: b0, weights: w))
        }
        return filters
    }

    struct MelResult {
        var frames: Int
        var bands: Int
        /// Row-major frames × bands, log power in dB relative to the track maximum, floored at -80.
        var logMel: [Float]
        var fps: Double
        /// Hz of each band's center, for picking "low" bands.
        var bandCenterHz: [Double]
    }

    /// Log-mel spectrogram of a mono signal.
    static func logMel(signal: [Float], sampleRate: Double, fftSize n: Int = 2048, hop: Int = 512, bands: Int = 96) -> MelResult {
        let fft = RealFFT(size: n)
        let half = n / 2
        let filters = melFilterbank(bands: bands, bins: half, sampleRate: sampleRate, fMin: 30, fMax: min(11000, sampleRate / 2 - 100))
        let frames = max(0, (signal.count - n) / hop + 1)
        var out = [Float](repeating: 0, count: frames * bands)
        var power = [Float](repeating: 0, count: half)
        signal.withUnsafeBufferPointer { sp in
            power.withUnsafeMutableBufferPointer { pp in
                for t in 0..<frames {
                    fft.powerSpectrum(sp.baseAddress! + t * hop, into: pp.baseAddress!)
                    for (b, f) in filters.enumerated() {
                        var acc: Float = 0
                        vDSP_dotpr(pp.baseAddress! + f.startBin, 1, f.weights, 1, &acc, vDSP_Length(f.weights.count))
                        out[t * bands + b] = acc
                    }
                }
            }
        }
        // dB relative to max, floored at -80
        var maxV: Float = 1e-12
        vDSP_maxv(out, 1, &maxV, vDSP_Length(out.count))
        let floorV = maxV * 1e-8
        for i in 0..<out.count {
            let v = max(out[i], floorV)
            out[i] = 10 * log10f(v / maxV)
        }
        let mMin = hzToMel(30), mMax = hzToMel(min(11000, sampleRate / 2 - 100))
        let centers = (0..<bands).map { melToHz(mMin + (mMax - mMin) * Double($0 + 1) / Double(bands + 1)) }
        return MelResult(frames: frames, bands: bands, logMel: out, fps: sampleRate / Double(hop), bandCenterHz: centers)
    }
}
