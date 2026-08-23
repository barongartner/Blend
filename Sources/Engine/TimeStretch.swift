// Renders a song's output span from its source through an arbitrary
// output→source position map (TrackLayout.sourcePosition). Two modes:
//
//  - Key lock (default): WSOLA — waveform-similarity overlap-add. Output is
//    built from overlapping Hann-windowed grains of the source; each grain is
//    taken from near the nominal position, nudged (±8 ms) to where it best
//    continues the previous grain, so pitch stays put and beats stay sharp.
//    At rate 1 every grain lands exactly on its nominal position and the
//    output is a bit-exact copy of the source.
//  - Varispeed: plain resampling, like pitching a record. Pitch moves with
//    tempo; some DJs prefer it for small changes.
//
// Everything is driven by the position map, so the renderer's notion of where
// a beat lands is the same one the stretcher uses — beats stay aligned with
// the song being mixed over.

import Foundation
import Accelerate

enum TimeStretch {

    static let grain = 2048
    static let hop = 1024
    static let tolerance = 384   // ±8 ms at 48 kHz

    struct Output {
        var left: [Float]
        var right: [Float]
    }

    /// Renders `count` output frames.
    static func render(source: AudioClip, count: Int, keyLock: Bool,
                       position: (Double) -> Double) -> Output {
        guard count > 0 else { return Output(left: [], right: []) }
        // Fast path: rate 1 throughout → straight copy.
        let p0 = position(0), p1 = position(Double(count))
        let r = (p1 - p0) / Double(count)
        if abs(r - 1) < 1e-9 && abs(p0 - p0.rounded()) < 1e-6 {
            return copy(source: source, from: Int(p0.rounded()), count: count)
        }
        if !keyLock {
            return varispeed(source: source, count: count, position: position)
        }
        return wsola(source: source, count: count, position: position)
    }

    static func copy(source: AudioClip, from start: Int, count: Int) -> Output {
        var l = [Float](repeating: 0, count: count)
        var rr = [Float](repeating: 0, count: count)
        let s0 = max(0, start), s1 = min(source.frameCount, start + count)
        if s1 > s0 {
            let o = s0 - start
            l.withUnsafeMutableBufferPointer { lp in
                source.left.withUnsafeBufferPointer { sp in
                    lp.baseAddress!.advanced(by: o).update(from: sp.baseAddress! + s0, count: s1 - s0)
                }
            }
            rr.withUnsafeMutableBufferPointer { rp in
                source.right.withUnsafeBufferPointer { sp in
                    rp.baseAddress!.advanced(by: o).update(from: sp.baseAddress! + s0, count: s1 - s0)
                }
            }
        }
        return Output(left: l, right: rr)
    }

    // MARK: - Varispeed

    private static func varispeed(source: AudioClip, count: Int, position: (Double) -> Double) -> Output {
        var l = [Float](repeating: 0, count: count)
        var rr = [Float](repeating: 0, count: count)
        let n = source.frameCount
        source.left.withUnsafeBufferPointer { sl in
            source.right.withUnsafeBufferPointer { sr in
                for u in 0..<count {
                    let p = position(Double(u))
                    let i = Int(floor(p))
                    let f = Float(p - Double(i))
                    guard i >= 0 && i + 1 < n else { continue }
                    l[u] = sl[i] + (sl[i + 1] - sl[i]) * f
                    rr[u] = sr[i] + (sr[i + 1] - sr[i]) * f
                }
            }
        }
        return Output(left: l, right: rr)
    }

    // MARK: - WSOLA

    private static func wsola(source: AudioClip, count: Int, position: (Double) -> Double) -> Output {
        let N = grain, H = hop, D = tolerance
        let n = source.frameCount
        var window = [Float](repeating: 0, count: N)
        vDSP_hann_window(&window, vDSP_Length(N), Int32(vDSP_HANN_DENORM))   // periodic: sums to 1 at 50% overlap

        // Mono copy for the similarity search.
        let mono = source.mono()

        // Output is assembled with a lead-in grain (k = -1) so the first samples
        // get full window coverage; `pad` samples at the front are discarded.
        let pad = H
        let totalOut = count + pad + N
        var outL = [Float](repeating: 0, count: totalOut)
        var outR = [Float](repeating: 0, count: totalOut)

        // Rate at the start, for extrapolating the lead-in grain's position.
        let rate0 = position(1) - position(0)

        var prevStart = 0          // source start of the previous grain
        var k = -1
        var scratch = [Float](repeating: 0, count: H)
        var natural = [Float](repeating: 0, count: H)

        while true {
            let o = k * H                   // output offset of this grain's first sample
            if o >= count { break }
            let nominalF: Double = o >= 0 ? position(Double(o)) : position(0) + Double(o) * rate0
            var start = Int(nominalF.rounded())

            if k > -1 {
                // Best continuation of the previous grain within ±D of nominal.
                let nat = prevStart + H
                if abs(nat - start) <= D && nat != start {
                    // Cheap case: if the natural continuation is inside the window,
                    // it is usually the best match — but check against nominal too.
                }
                readMono(mono, from: nat, count: H, into: &natural)
                var bestScore: Float = -Float.greatestFiniteMagnitude
                var bestStart = start
                let lo = start - D, hi = start + D
                // Coarse search every 4 samples, then refine ±4 around the best.
                var cand = lo
                while cand <= hi {
                    let s = similarity(mono, cand, natural, H, &scratch)
                    if s > bestScore { bestScore = s; bestStart = cand }
                    cand += 4
                }
                let rlo = max(lo, bestStart - 3), rhi = min(hi, bestStart + 3)
                for c in rlo...rhi where c != bestStart {
                    let s = similarity(mono, c, natural, H, &scratch)
                    if s > bestScore { bestScore = s; bestStart = c }
                }
                start = bestStart
            }

            // Overlap-add this grain.
            let outPos = o + pad
            overlapAdd(source.left, from: start, n: n, window: window, into: &outL, at: outPos, limit: totalOut)
            overlapAdd(source.right, from: start, n: n, window: window, into: &outR, at: outPos, limit: totalOut)

            prevStart = start
            k += 1
        }

        let l = Array(outL[pad..<(pad + count)])
        let r = Array(outR[pad..<(pad + count)])
        return Output(left: l, right: r)
    }

    private static func readMono(_ mono: [Float], from start: Int, count: Int, into out: inout [Float]) {
        let n = mono.count
        for i in 0..<count {
            let j = start + i
            out[i] = (j >= 0 && j < n) ? mono[j] : 0
        }
    }

    /// Normalized cross-correlation of source[cand..<cand+H] against `natural`.
    private static func similarity(_ mono: [Float], _ cand: Int, _ natural: [Float], _ H: Int, _ scratch: inout [Float]) -> Float {
        let n = mono.count
        var dot: Float = 0
        var energy: Float = 0
        if cand >= 0 && cand + H <= n {
            mono.withUnsafeBufferPointer { mp in
                vDSP_dotpr(mp.baseAddress! + cand, 1, natural, 1, &dot, vDSP_Length(H))
                vDSP_dotpr(mp.baseAddress! + cand, 1, mp.baseAddress! + cand, 1, &energy, vDSP_Length(H))
            }
        } else {
            readMono(mono, from: cand, count: H, into: &scratch)
            vDSP_dotpr(scratch, 1, natural, 1, &dot, vDSP_Length(H))
            vDSP_dotpr(scratch, 1, scratch, 1, &energy, vDSP_Length(H))
        }
        return dot / (sqrtf(energy) + 1e-6)
    }

    private static func overlapAdd(_ src: [Float], from start: Int, n: Int, window: [Float],
                                   into out: inout [Float], at outPos: Int, limit: Int) {
        let N = window.count
        // Clip to valid source and output ranges.
        var i0 = 0
        var i1 = N
        if start < 0 { i0 = -start }
        if start + i1 > n { i1 = n - start }
        if outPos + i1 > limit { i1 = limit - outPos }
        if outPos < 0 { i0 = max(i0, -outPos) }
        guard i1 > i0 else { return }
        let len = i1 - i0
        src.withUnsafeBufferPointer { sp in
            window.withUnsafeBufferPointer { wp in
                out.withUnsafeMutableBufferPointer { op in
                    // out[outPos+i] += src[start+i] * window[i]
                    vDSP_vma(sp.baseAddress! + start + i0, 1, wp.baseAddress! + i0, 1,
                             op.baseAddress! + outPos + i0, 1, op.baseAddress! + outPos + i0, 1, vDSP_Length(len))
                }
            }
        }
    }
}
