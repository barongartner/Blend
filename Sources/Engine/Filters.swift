// RBJ cookbook biquads, transposed direct form II. Coefficients can be
// recomputed mid-stream (filter sweeps); state carries across calls.

import Foundation

struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    mutating func setLowpass(cutoff: Double, sampleRate: Double, q: Double = 0.70710678) {
        let fc = max(10, min(cutoff, sampleRate * 0.49))
        let w0 = 2 * Double.pi * fc / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        b0 = Float((1 - cosw) / 2 / a0)
        b1 = Float((1 - cosw) / a0)
        b2 = Float((1 - cosw) / 2 / a0)
        a1 = Float(-2 * cosw / a0)
        a2 = Float((1 - alpha) / a0)
    }

    mutating func setHighpass(cutoff: Double, sampleRate: Double, q: Double = 0.70710678) {
        let fc = max(10, min(cutoff, sampleRate * 0.49))
        let w0 = 2 * Double.pi * fc / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        b0 = Float((1 + cosw) / 2 / a0)
        b1 = Float(-(1 + cosw) / a0)
        b2 = Float((1 + cosw) / 2 / a0)
        a1 = Float(-2 * cosw / a0)
        a2 = Float((1 - alpha) / a0)
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }
}

/// Two cascaded Butterworth low-passes = 4th-order Linkwitz-Riley: the split
/// used by DJ mixers' bass EQ. `high` is what's left after removing `low`.
struct CrossoverPair {
    private var lp1 = Biquad(), lp2 = Biquad()

    init(cutoff: Double, sampleRate: Double) {
        lp1.setLowpass(cutoff: cutoff, sampleRate: sampleRate)
        lp2.setLowpass(cutoff: cutoff, sampleRate: sampleRate)
    }

    @inline(__always)
    mutating func split(_ x: Float) -> (low: Float, high: Float) {
        let low = lp2.process(lp1.process(x))
        return (low, x - low)
    }
}
