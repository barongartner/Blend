// Beat tracking, the classic way: spectral-flux onset envelope → tempo by
// autocorrelation (with a prior on plausible DJ tempos) → beat positions by
// dynamic programming (Ellis 2007, the algorithm behind librosa.beat) → a
// constant-tempo grid fitted to the tracked beats → downbeat phase from where
// the bass hits and the spectrum changes.
//
// No neural network: for quantized music this lands within a few ms, and the
// editor lets you fix the rare track it gets wrong (shift downbeat, ×2/÷2).

import Foundation
import Accelerate

struct BeatGrid {
    var bpm: Double
    var offset: Double        // seconds of some grid beat
    var downbeatPhase: Int    // 0...3
    var beats: [Double]       // tracked beats (seconds)
    var confidence: Double    // 0...1
}

enum BeatAnalyzer {

    struct Onsets {
        var envelope: [Float]   // normalized, ≥ 0
        var lowEnvelope: [Float]
        var fps: Double
    }

    // MARK: - Onset envelope

    static func onsets(from mel: Spectrogram.MelResult) -> Onsets {
        let T = mel.frames, B = mel.bands
        guard T > 2 else { return Onsets(envelope: [], lowEnvelope: [], fps: mel.fps) }
        let lowBands = mel.bandCenterHz.enumerated().filter { $0.element < 180 }.map { $0.offset }
        var env = [Float](repeating: 0, count: T)
        var low = [Float](repeating: 0, count: T)
        mel.logMel.withUnsafeBufferPointer { m in
            for t in 1..<T {
                var acc: Float = 0
                var accLow: Float = 0
                let cur = m.baseAddress! + t * B
                let prev = m.baseAddress! + (t - 1) * B
                for b in 0..<B {
                    let d = cur[b] - prev[b]
                    if d > 0 { acc += d }
                }
                for b in lowBands {
                    let d = cur[b] - prev[b]
                    if d > 0 { accLow += d }
                }
                env[t] = acc / Float(B)
                low[t] = lowBands.isEmpty ? 0 : accLow / Float(lowBands.count)
            }
        }
        // Remove the slow-moving mean so sustained loudness doesn't read as onsets.
        env = highPass(env, window: Int(mel.fps * 0.6))
        low = highPass(low, window: Int(mel.fps * 0.6))
        normalize(&env)
        normalize(&low)
        return Onsets(envelope: env, lowEnvelope: low, fps: mel.fps)
    }

    private static func highPass(_ x: [Float], window: Int) -> [Float] {
        let w = max(3, window | 1)
        let half = w / 2
        var out = [Float](repeating: 0, count: x.count)
        var prefix = [Double](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { prefix[i + 1] = prefix[i] + Double(x[i]) }
        for i in 0..<x.count {
            let a = max(0, i - half), b = min(x.count, i + half + 1)
            let mean = Float((prefix[b] - prefix[a]) / Double(b - a))
            out[i] = max(0, x[i] - mean)
        }
        return out
    }

    private static func normalize(_ x: inout [Float]) {
        guard !x.isEmpty else { return }
        var mean: Float = 0, sd: Float = 0
        vDSP_normalize(x, 1, nil, 1, &mean, &sd, vDSP_Length(x.count))
        if sd > 1e-9 {
            var s = 1 / sd
            vDSP_vsmul(x, 1, &s, &x, 1, vDSP_Length(x.count))
        }
    }

    // MARK: - Tempo

    /// Autocorrelation tempo candidates (BPM), best first, with a log-normal
    /// prior on plausible tempos. The comb refinement below picks among them.
    static func tempoCandidates(_ on: Onsets, minBPM: Double = 55, maxBPM: Double = 210, count: Int = 6) -> [Double] {
        let x = on.envelope
        let fps = on.fps
        guard x.count > Int(fps * 4) else { return [120] }
        let lagMin = max(2, Int(fps * 60 / maxBPM))
        let lagMax = min(x.count / 2, Int(fps * 60 / minBPM) + 1)
        guard lagMax > lagMin + 2 else { return [120] }

        var ac = [Float](repeating: 0, count: lagMax + 1)
        x.withUnsafeBufferPointer { xp in
            for lag in lagMin...lagMax {
                var acc: Float = 0
                vDSP_dotpr(xp.baseAddress!, 1, xp.baseAddress! + lag, 1, &acc, vDSP_Length(x.count - lag))
                ac[lag] = acc / Float(x.count - lag)
            }
        }
        func prior(_ bpm: Double) -> Float {
            let d = log2(bpm / 118) / 0.8
            return Float(exp(-0.5 * d * d))
        }
        var scored: [(score: Float, lag: Int)] = []
        for lag in (lagMin + 1)..<lagMax {
            // Local peaks only.
            guard ac[lag] >= ac[lag - 1], ac[lag] >= ac[lag + 1] else { continue }
            let bpm = fps * 60 / Double(lag)
            let harmonic: Float = (2 * lag <= lagMax) ? 0.35 * ac[2 * lag] : 0
            scored.append(((ac[lag] + harmonic) * prior(bpm), lag))
        }
        scored.sort { $0.score > $1.score }
        var out: [Double] = []
        for (_, lag) in scored.prefix(count) {
            var lagF = Double(lag)
            let a = Double(ac[lag - 1]), b = Double(ac[lag]), c = Double(ac[lag + 1])
            let denom = a - 2 * b + c
            if abs(denom) > 1e-9 {
                let delta = 0.5 * (a - c) / denom
                if abs(delta) < 1 { lagF += delta }
            }
            out.append(fps * 60 / lagF)
        }
        return out.isEmpty ? [120] : out
    }

    // MARK: - Fine grid (comb filter on a 1 ms envelope)

    /// Energy rises at 1 ms resolution, straight from the waveform. Sharp
    /// enough to pin a quantized song's tempo to two decimals.
    static func fineRise(signal: [Float], sampleRate: Double) -> [Float] {
        let step = max(1, Int(sampleRate / 1000))
        let n = signal.count / step
        guard n > 100 else { return [] }
        var env = [Float](repeating: 0, count: n)
        signal.withUnsafeBufferPointer { sp in
            for i in 0..<n {
                var v: Float = 0
                vDSP_rmsqv(sp.baseAddress! + i * step, 1, &v, vDSP_Length(step))
                env[i] = v
            }
        }
        var rise = [Float](repeating: 0, count: n)
        for i in 6..<n { rise[i] = max(0, env[i] - env[i - 6]) }
        // Compress so a few loud hits don't own the vote.
        for i in 0..<n { rise[i] = sqrtf(rise[i]) }
        return rise
    }

    /// Indices of the strongest rises (top share by value), the only ones worth voting.
    static func strongRises(_ rise: [Float], share: Double = 0.15) -> [(index: Int, weight: Float)] {
        guard !rise.isEmpty else { return [] }
        let sorted = rise.sorted(by: >)
        let threshold = max(1e-6, sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))])
        var out: [(Int, Float)] = []
        for i in 0..<rise.count where rise[i] >= threshold { out.append((i, rise[i])) }
        return out
    }

    /// Phase histogram of the rises at one tempo: how peaked it is says how
    /// well that tempo fits; where the peak sits is the beat phase (ms).
    static func combScore(_ rises: [(index: Int, weight: Float)], bpm: Double) -> (score: Double, phaseMs: Double) {
        let period = 60000 / bpm
        let bins = Int(period.rounded(.up))
        guard bins > 2, !rises.isEmpty else { return (0, 0) }
        var hist = [Float](repeating: 0, count: bins)
        let inv = 1 / period
        for (i, w) in rises {
            let x = Double(i)
            let ph = x - floor(x * inv) * period
            hist[min(bins - 1, Int(ph))] += w
        }
        // Smooth over ±2 ms (circular) and find the peak.
        var best: Float = -1
        var bestBin = 0
        var total: Float = 0
        for b in 0..<bins {
            var v: Float = 0
            for d in -2...2 { v += hist[((b + d) % bins + bins) % bins] }
            total += v
            if v > best { best = v; bestBin = b }
        }
        let mean = total / Float(bins)
        let score = mean > 0 ? Double(best / mean) : 0
        return (score, Double(bestBin))
    }

    /// 1 ms RMS envelope of the low band (< 150 Hz): kicks and bass.
    static func lowBandEnvelope(signal: [Float], sampleRate: Double) -> [Float] {
        var lp = Biquad()
        lp.setLowpass(cutoff: 150, sampleRate: sampleRate)
        let step = max(1, Int(sampleRate / 1000))
        let n = signal.count / step
        var env = [Float](repeating: 0, count: n)
        signal.withUnsafeBufferPointer { sp in
            var acc: Float = 0
            var count = 0
            var idx = 0
            for i in 0..<(n * step) {
                let v = lp.process(sp[i])
                acc += v * v
                count += 1
                if count == step {
                    env[idx] = sqrtf(acc / Float(step))
                    idx += 1
                    acc = 0
                    count = 0
                }
            }
        }
        return env
    }

    /// Phase histogram of discrete low-band attacks (sharp rises out of a
    /// quieter moment — kicks, bass-note starts). Returns (phase ms, peakiness).
    static func kickPhase(lowEnv env: [Float], bpm: Double) -> (phaseMs: Double, score: Double) {
        let n = env.count
        guard n > 2000, bpm > 0 else { return (0, 0) }
        var onset = [Float](repeating: 0, count: n)
        for i in 20..<(n - 10) {
            let rise = env[i] - env[i - 5]
            guard rise > 0 else { continue }
            if env[i - 20] < 0.5 * env[i + 5] { onset[i] = rise }
        }
        var events: [(index: Int, weight: Float)] = []
        var i = 1
        var maxW: Float = 0
        while i < n - 1 {
            if onset[i] > 0, onset[i] >= onset[i - 1], onset[i] > onset[i + 1] {
                events.append((i, onset[i]))
                maxW = max(maxW, onset[i])
                i += 100
            } else {
                i += 1
            }
        }
        let strong = events.filter { $0.weight > maxW * 0.1 }.map { (index: $0.index, weight: sqrtf($0.weight)) }
        guard strong.count > 8 else { return (0, 0) }
        return combScore(strong, bpm: bpm)
    }

    /// How much louder the low band gets right after the grid beats than right
    /// before them. Kicks and bass notes start ON the beat, so the true beat
    /// phase scores high; the off-beat (where sidechained synths swell back and
    /// the full-band onset detector gets fooled) scores about 1.
    static func jumpScore(lowEnv env: [Float], bpm: Double, phaseMs: Double, window: Int) -> Double {
        let period = 60000 / bpm
        var before = 0.0, after = 0.0
        var t = phaseMs - floor(phaseMs / period) * period
        while t < Double(window) { t += period }
        while Int(t) + window < env.count {
            let c = Int(t)
            var b: Float = 0, a: Float = 0
            for k in 0..<window { b += env[c - window + k]; a += env[c + k] }
            before += Double(b)
            after += Double(a)
            t += period
        }
        return (after + 1e-6) / (before + 1e-6)
    }

    /// Searches ±3% around `bpm` for the tempo whose comb is sharpest.
    static func refineTempo(_ rises: [(index: Int, weight: Float)], around bpm: Double) -> (bpm: Double, score: Double, phaseMs: Double) {
        var best = (bpm: bpm, score: -1.0, phaseMs: 0.0)
        func probe(_ b: Double) {
            let r = combScore(rises, bpm: b)
            if r.score > best.score { best = (b, r.score, r.phaseMs) }
        }
        var b = bpm * 0.97
        while b <= bpm * 1.03 { probe(b); b += 0.1 }
        let coarse = best.bpm
        b = coarse - 0.12
        while b <= coarse + 0.12 { probe(b); b += 0.005 }
        // Snap to a whole or half BPM when that is just as good — producers set integers.
        for snap in [best.bpm.rounded(), (best.bpm * 2).rounded() / 2] {
            let r = combScore(rises, bpm: snap)
            if r.score >= best.score * 0.97 { best = (snap, r.score, r.phaseMs); break }
        }
        return best
    }

    // MARK: - Beat tracking (dynamic programming)

    static func trackBeats(_ on: Onsets, bpm: Double, tightness: Double = 100) -> [Double] {
        let fps = on.fps
        let period = fps * 60 / bpm
        let n = on.envelope.count
        guard n > Int(period * 2) else { return [] }

        // Smooth the envelope with a Gaussian (σ = period/32) — the "localscore".
        let sigma = max(1.0, period / 32)
        let radius = Int(sigma * 4)
        var kernel = [Float](repeating: 0, count: 2 * radius + 1)
        for i in -radius...radius { kernel[i + radius] = Float(exp(-0.5 * pow(Double(i) / sigma, 2))) }
        let ksum = kernel.reduce(0, +)
        for i in 0..<kernel.count { kernel[i] /= ksum }
        var local = [Float](repeating: 0, count: n)
        for t in 0..<n {
            var acc: Float = 0
            for k in -radius...radius {
                let j = t + k
                if j >= 0 && j < n { acc += on.envelope[j] * kernel[k + radius] }
            }
            local[t] = acc
        }

        let windowLo = Int((period * 0.5).rounded())
        let windowHi = Int((period * 2).rounded())
        var penalty = [Double](repeating: 0, count: windowHi + 1)
        for j in windowLo...windowHi {
            let r = log(Double(j) / period)
            penalty[j] = -tightness * r * r
        }

        var cumscore = [Double](repeating: 0, count: n)
        var backlink = [Int](repeating: -1, count: n)
        for t in 0..<n {
            var best = -Double.infinity
            var bestJ = -1
            let jMax = min(windowHi, t)
            if jMax >= windowLo {
                for j in windowLo...jMax {
                    let s = cumscore[t - j] + penalty[j]
                    if s > best { best = s; bestJ = t - j }
                }
            }
            if bestJ < 0 { best = 0 }
            cumscore[t] = Double(local[t]) + best
            backlink[t] = bestJ
        }

        // Pick the final beat: the best-scoring frame in the last period-and-a-half.
        var end = n - 1
        var endScore = -Double.infinity
        let tail = max(0, n - Int(period * 1.5))
        for t in tail..<n where cumscore[t] > endScore { endScore = cumscore[t]; end = t }

        var beats: [Int] = []
        var t = end
        while t >= 0 {
            beats.append(t)
            t = backlink[t]
        }
        beats.reverse()
        return beats.map { Double($0) / fps }
    }

    // MARK: - Downbeat

    /// Which of the four beat phases starts the bar. Scores each phase by the
    /// low-frequency onset energy on its beats plus how much the spectrum
    /// changes there (sections and chords change on downbeats).
    static func downbeatPhase(on: Onsets, mel: Spectrogram.MelResult, bpm: Double, offset: Double, duration: Double) -> Int {
        let beatLen = 60 / bpm
        let fps = on.fps
        let B = mel.bands
        var scores = [Double](repeating: 0, count: 4)
        var k = 0
        var t = offset
        let barFrames = Int(beatLen * 4 * fps)
        while t < duration {
            let frame = Int(t * fps)
            if frame >= 5 && frame < on.envelope.count - 2 {
                var lowHit = 0.0
                var hit = 0.0
                // Spectral flux for a beat at `frame` peaks a few frames earlier (window latency).
                for d in -5...1 {
                    lowHit = max(lowHit, Double(on.lowEnvelope[frame + d]))
                    hit = max(hit, Double(on.envelope[frame + d]))
                }
                // Spectral change across the beat: mean |Δ| between the bar before and after.
                var change = 0.0
                if barFrames > 4 && frame - barFrames >= 0 && frame + barFrames < mel.frames {
                    var acc = 0.0
                    for b in 0..<B {
                        var before = 0.0, after = 0.0
                        for f in stride(from: frame - barFrames, to: frame, by: max(1, barFrames / 8)) { before += Double(mel.logMel[f * B + b]) }
                        for f in stride(from: frame, to: frame + barFrames, by: max(1, barFrames / 8)) { after += Double(mel.logMel[f * B + b]) }
                        acc += abs(after - before)
                    }
                    change = acc / Double(B * 8)
                }
                scores[k % 4] += lowHit + 0.5 * hit + 0.08 * change
            }
            k += 1
            t += beatLen
        }
        var best = 0
        for p in 1..<4 where scores[p] > scores[best] { best = p }
        return best
    }

    // MARK: - Entry point

    static func analyze(signal: [Float], sampleRate: Double, taggedBPM: Double?) -> BeatGrid {
        let mel = Spectrogram.logMel(signal: signal, sampleRate: sampleRate)
        let on = onsets(from: mel)
        let duration = Double(signal.count) / sampleRate
        guard on.envelope.count > Int(on.fps * 5) else {
            return BeatGrid(bpm: taggedBPM ?? 120, offset: 0, downbeatPhase: 0, beats: [], confidence: 0)
        }
        // Candidates from autocorrelation, folded into the DJ octave, plus the tag.
        var candidates: [Double] = []
        for c in tempoCandidates(on) {
            var b = c
            while b > 150 { b /= 2 }
            while b < 68 { b *= 2 }
            if !candidates.contains(where: { abs($0 - b) < 0.5 }) { candidates.append(b) }
        }
        if let tagged = taggedBPM, tagged > 50, !candidates.contains(where: { abs($0 - tagged) < 0.5 }) {
            candidates.insert(tagged, at: 0)
        }
        // Pick the candidate whose fine comb is sharpest (the first candidate gets a small edge).
        let rise = fineRise(signal: signal, sampleRate: sampleRate)
        let rises = strongRises(rise)
        var best = (bpm: candidates[0], score: -1.0, phaseMs: 0.0)
        for (i, c) in candidates.prefix(5).enumerated() {
            var r = refineTempo(rises, around: c)
            if i == 0 { r.score *= 1.08 }
            if r.score > best.score { best = r }
        }
        let bpm = best.bpm
        let beatLen = 60 / bpm
        // Phase. Candidates: the full-band comb peak and the kick-attack peak,
        // each with its half-beat alternative. The low band's energy jump at the
        // beat picks the winner; a fine search then lands on the attack's start.
        let lowEnv = lowBandEnvelope(signal: signal, sampleRate: sampleRate)
        let kick = kickPhase(lowEnv: lowEnv, bpm: bpm)
        let periodMs = 60000 / bpm
        var candidates2: [Double] = [best.phaseMs, best.phaseMs + periodMs / 2]
        if kick.score > 1.5 { candidates2 += [kick.phaseMs, kick.phaseMs + periodMs / 2] }
        var phaseMs = best.phaseMs
        var bestJump = -1.0
        for c in candidates2 {
            let j = jumpScore(lowEnv: lowEnv, bpm: bpm, phaseMs: c, window: 70)
            if j > bestJump { bestJump = j; phaseMs = c }
        }
        let coarse = phaseMs
        var fineBest = -1.0
        for d in stride(from: -60.0, through: 60.0, by: 1) {
            let j = jumpScore(lowEnv: lowEnv, bpm: bpm, phaseMs: coarse + d, window: 30)
            if j > fineBest { fineBest = j; phaseMs = coarse + d }
        }
        if ProcessInfo.processInfo.environment["BLEND_DEBUG"] != nil {
            print("  phase: full-band \(Int(best.phaseMs)) ms, kick \(Int(kick.phaseMs)) ms (score \(String(format: "%.2f", kick.score))), jump-pick \(Int(coarse)) → fine \(Int(phaseMs)) ms (jump \(String(format: "%.2f", fineBest)))")
        }
        var offset = phaseMs / 1000
        offset -= floor(offset / beatLen) * beatLen

        // Tracked beats sit a constant ~60 ms early (STFT window latency); remove
        // that with their median offset from the grid, then score how many agree.
        var beats = trackBeats(on, bpm: bpm)
        var confidence = 0.0
        if !beats.isEmpty {
            let residuals = beats.map { b -> Double in
                let r = (b - offset).truncatingRemainder(dividingBy: beatLen)
                return r > beatLen / 2 ? r - beatLen : (r < -beatLen / 2 ? r + beatLen : r)
            }
            let median = residuals.sorted()[residuals.count / 2]
            beats = beats.map { $0 - median }
            let onGrid = residuals.filter { abs($0 - median) <= 0.035 }.count
            confidence = Double(onGrid) / Double(beats.count)
        }
        let combNorm = max(0, min(1, (best.score - 1.5) / 4))
        let jumpNorm = max(0, min(1, (fineBest - 1) / 2.5))
        confidence = max(confidence, 0.5 * combNorm + 0.5 * jumpNorm)
        if ProcessInfo.processInfo.environment["BLEND_DEBUG"] != nil {
            let residuals = beats.map { b -> Double in
                let r = (b - offset).truncatingRemainder(dividingBy: beatLen)
                return r > beatLen / 2 ? r - beatLen : (r < -beatLen / 2 ? r + beatLen : r)
            }.sorted()
            let med = residuals.isEmpty ? 0 : residuals[residuals.count / 2]
            print("  candidates: \(candidates.map { String(format: "%.2f", $0) })  chosen \(bpm) score \(String(format: "%.2f", best.score))  DP-vs-comb phase: median \(Int(med * 1000)) ms, q1 \(Int((residuals.isEmpty ? 0 : residuals[residuals.count / 4]) * 1000)) q3 \(Int((residuals.isEmpty ? 0 : residuals[residuals.count * 3 / 4]) * 1000)), \(beats.count) beats")
        }
        let phase = downbeatPhase(on: on, mel: mel, bpm: bpm, offset: offset, duration: duration)
        return BeatGrid(bpm: bpm, offset: offset, downbeatPhase: phase, beats: beats, confidence: confidence)
    }
}
