// DSP self-test: synthesizes two drum tracks with known tempo, beat phase and
// downbeat, checks the analyzer recovers them, lays out a mix, renders it and
// verifies the kicks of both songs coincide through the overlap.
//
//   ./Tests/run.sh            runs everything
//   ./Tests/run.sh <audio…>   analyzes real files and prints BPM/key/downbeat

import Foundation
import AVFoundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    print((cond ? "  ok   " : "  FAIL ") + msg)
    if !cond { failures += 1 }
}

// MARK: - Synthesis

struct SynthSpec {
    var bpm: Double
    var firstBeat: Double      // seconds; downbeat is beat 0
    var seconds: Double
    var seed: UInt64
}

func synthTrack(_ s: SynthSpec, sampleRate sr: Double = 48000) -> AudioClip {
    let n = Int(s.seconds * sr)
    var l = [Float](repeating: 0, count: n)
    var r = [Float](repeating: 0, count: n)
    let beat = 60 / s.bpm
    var rng = s.seed
    func rand() -> Float { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Float((rng >> 33) & 0xFFFFFF) / Float(0xFFFFFF) }

    func add(at t: Double, _ gen: (Int) -> Float, length: Double, pan: Float = 0) {
        let start = Int(t * sr)
        let len = Int(length * sr)
        for i in 0..<len {
            let j = start + i
            if j < 0 || j >= n { continue }
            let v = gen(i)
            l[j] += v * (1 - pan) * 0.5 + v * 0.5
            r[j] += v * (1 + pan) * 0.5 + v * 0.5
        }
    }
    var k = 0
    var t = s.firstBeat
    // Chord root changes every 4 bars so the spectrum changes on downbeats.
    let roots: [Double] = [110, 130.81, 98, 123.47]
    while t < s.seconds {
        let inBar = k % 4
        let bar = k / 4
        // Kick on every beat, bigger on the downbeat.
        let kickAmp: Float = inBar == 0 ? 0.9 : 0.6
        add(at: t, { i in
            let x = Double(i) / sr
            let f = 150 * exp(-x * 25) + 50
            return kickAmp * Float(sin(2 * .pi * f * x)) * Float(exp(-x * 12))
        }, length: 0.3)
        // Snare on 2 and 4.
        if inBar == 1 || inBar == 3 {
            add(at: t, { i in
                let x = Double(i) / sr
                return 0.35 * (rand() * 2 - 1) * Float(exp(-x * 20))
            }, length: 0.2)
        }
        // Hats on eighths.
        for h in 0..<2 {
            add(at: t + Double(h) * beat / 2, { i in
                let x = Double(i) / sr
                return 0.12 * (rand() * 2 - 1) * Float(exp(-x * 60))
            }, length: 0.08, pan: 0.3)
        }
        // Bass + pad, root changes every 4 bars, accent on downbeat.
        let root = roots[(bar / 4) % roots.count]
        let amp: Float = inBar == 0 ? 0.35 : 0.22
        add(at: t, { i in
            let x = Double(i) / sr
            let env = Float(min(1, x * 200)) * Float(exp(-x * 3))
            return amp * env * (Float(sin(2 * .pi * root * x)) + 0.3 * Float(sin(2 * .pi * root * 2 * x)) + 0.2 * Float(sin(2 * .pi * root * 1.5 * x)))
        }, length: beat * 0.95)
        k += 1
        t += beat
    }
    return AudioClip(sampleRate: sr, left: l, right: r)
}

func kickTimes(_ clip: AudioClip, from: Double, to: Double) -> [Double] {
    // Onsets in the low band: 1 ms RMS envelope of a 120 Hz low-pass, peak-pick
    // its rise. Kick and bass both start exactly on the beat, so this is the beat.
    let sr = clip.sampleRate
    var lp = Biquad(); lp.setLowpass(cutoff: 120, sampleRate: sr)
    let s = Int(from * sr), e = min(clip.frameCount, Int(to * sr))
    let step = Int(sr / 1000)
    let n = (e - s) / step
    var env = [Float](repeating: 0, count: n)
    for i in 0..<n {
        var acc: Float = 0
        for j in 0..<step { let v = lp.process(clip.left[s + i * step + j]); acc += v * v }
        env[i] = sqrt(acc / Float(step))
    }
    var rise = [Float](repeating: 0, count: n)
    for i in 8..<n { rise[i] = max(0, env[i] - env[i - 8]) }
    let threshold = (rise.max() ?? 0) * 0.3
    var times: [Double] = []
    var last = -1000
    for i in 1..<(n - 1) where rise[i] > threshold && rise[i] >= rise[i - 1] && rise[i] > rise[i + 1] && i - last > 300 {
        times.append(from + Double(i) / 1000)
        last = i
    }
    return times
}

// MARK: - Tests

func runSynthetic() throws {
    print("Synthetic tracks")
    let specA = SynthSpec(bpm: 124, firstBeat: 0.37, seconds: 70, seed: 1)
    let specB = SynthSpec(bpm: 128, firstBeat: 0.81, seconds: 70, seed: 2)
    let a = synthTrack(specA), b = synthTrack(specB)

    let t0 = Date()
    let aa = TrackAnalyzer.analyze(clip: a, taggedBPM: nil)
    let ab = TrackAnalyzer.analyze(clip: b, taggedBPM: nil)
    print(String(format: "  analysis took %.2fs for 2×70s", Date().timeIntervalSince(t0)))
    for (spec, an, name) in [(specA, aa, "A"), (specB, ab, "B")] {
        let beatLen = 60 / spec.bpm
        let phaseErr = abs(an.firstDownbeat - spec.firstBeat).truncatingRemainder(dividingBy: beatLen * 4)
        let phaseErrWrapped = min(phaseErr, beatLen * 4 - phaseErr)
        print(String(format: "  %@: bpm %.3f (true %.0f)  firstDownbeat %.3f (true %.2f)  conf %.2f  key %@ (%@)  in %.2f out %.2f",
                     name, an.bpm, spec.bpm, an.firstDownbeat, spec.firstBeat, an.gridConfidence, an.keyName, an.camelot, an.suggestedIn, an.suggestedOut))
        check(abs(an.bpm - spec.bpm) < 0.15, "\(name) tempo within 0.15 BPM")
        check(phaseErrWrapped < 0.015, "\(name) downbeat within 15 ms (err \(Int(phaseErrWrapped * 1000)) ms)")
        check(an.gridConfidence > 0.9, "\(name) grid confidence > 0.9")
    }

    // Layout: A then B, 8-bar bass swap with tempo sync; in/out on downbeats.
    let trackA = TrackInfo.file(path: "/a.wav", title: "A", artist: "", album: "", duration: 70, taggedBPM: nil)
    let trackB = TrackInfo.file(path: "/b.wav", title: "B", artist: "", album: "", duration: 70, taggedBPM: nil)
    var eA = MixEntry(track: trackA)
    eA.inTime = aa.downbeat(atOrAfter: 1)
    eA.outTime = aa.downbeat(atOrBefore: 60)
    eA.transition = TransitionSettings(style: .bassSwap, overlapBars: 8, tempoSync: true, rampBars: 8)
    var eB = MixEntry(track: trackB)
    eB.inTime = ab.downbeat(atOrAfter: 1)
    eB.outTime = ab.downbeat(atOrBefore: 60)
    let entries = [ResolvedEntry(entry: eA, analysis: aa), ResolvedEntry(entry: eB, analysis: ab)]
    let layout = MixLayout.build(entries: entries, sampleRate: 48000)
    let la = layout.tracks[0], lb = layout.tracks[1]
    print(String(format: "  layout: total %.3fs; A body %d outro %d; B entry %d rho %.4f ramp %d body %d",
                 layout.totalSeconds, la.body, la.outroOverlap, lb.entryOverlap, lb.rho, lb.rampOut, lb.body))
    let expectedOverlap = 8 * 240 / aa.bpm
    check(abs(Double(lb.entryOverlap) / 48000 - expectedOverlap) < 0.001, "overlap is 8 bars of A")
    check(abs(lb.rho - aa.bpm / ab.bpm) < 1e-6, "B plays at A's tempo during the overlap")
    // Source consumed by B equals out-in exactly.
    let consumed = lb.entrySrc + lb.rampSrc + Double(lb.body)
    check(abs(consumed - (lb.outSample - lb.inSample)) < 1.5, "B consumes exactly its in→out range (diff \(consumed - (lb.outSample - lb.inSample)))")
    let expectedTotal = (la.outSample - la.inSample - Double(la.outroOverlap)) + Double(lb.entryOverlap + lb.rampOut + lb.body)
    check(abs(Double(layout.totalSamples) - expectedTotal) < 1, "total = A's solo + B's span")

    // Render.
    let clips = [a, b]
    let settings = MixSettings()
    let renderer = MixRenderer(layout: layout, entries: entries, settings: settings) { clips[$0] }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("blend-test-\(UUID().uuidString).caf")
    let t1 = Date()
    let result = try renderer.render(to: tmp, progress: { _ in }, isCancelled: { false })
    print(String(format: "  render took %.2fs, peak %.3f, %d frames", Date().timeIntervalSince(t1), result.peak, result.frames))
    check(result.frames == layout.totalSamples, "rendered frame count matches layout")
    let mixed = try AudioDecoder.decode(url: tmp)
    check(mixed.frameCount == layout.totalSamples, "file frame count matches layout (\(mixed.frameCount) vs \(layout.totalSamples))")

    // Beat alignment through the overlap: A's grid downbeats in output time vs B's kicks.
    // In output time, A's beats are at (gridBeat - inA) + startA. B entering at B's in-point (a downbeat),
    // stretched to A's tempo, should put B's beats on the same instants.
    let overlapStart = Double(lb.start) / 48000
    let overlapEnd = Double(lb.soloStart) / 48000
    let spanB = try renderer.span(1)   // B alone, level matched
    let bClip = AudioClip(sampleRate: 48000, left: spanB.left, right: spanB.right)
    let bKicks = kickTimes(bClip, from: 0, to: Double(lb.entryOverlap) / 48000).map { $0 + overlapStart }
    var maxErr = 0.0
    var nChecked = 0
    for kt in bKicks where kt > overlapStart + 0.5 && kt < overlapEnd - 0.5 {
        // nearest A grid beat in output time
        let srcT = (kt - Double(la.start) / 48000) + la.inSample / 48000
        let nearest = aa.nearestBeat(to: srcT)
        let err = abs(nearest - srcT)
        maxErr = max(maxErr, err)
        nChecked += 1
    }
    print(String(format: "  overlap: %d B kicks checked, max misalignment vs A grid %.1f ms", nChecked, maxErr * 1000))
    check(nChecked > 10, "found B kicks in the overlap")
    check(maxErr < 0.012, "B's kicks within 12 ms of A's beats through the overlap")

    // After the ramp, B runs at its own tempo: kicks spaced by 60/128.
    let bodyStart = Double(lb.soloStart + lb.rampOut) / 48000 + 0.5
    let bodyKicks = kickTimes(mixed, from: bodyStart, to: bodyStart + 10)
    if bodyKicks.count > 3 {
        let gaps = zip(bodyKicks.dropFirst(), bodyKicks).map { $0 - $1 }
        let meanGap = gaps.reduce(0, +) / Double(gaps.count)
        print(String(format: "  body: mean kick gap %.4fs (expected %.4f)", meanGap, 60 / 128.0))
        check(abs(meanGap - 60 / 128.0) < 0.003, "B returns to 128 BPM after the ramp")
    } else {
        check(false, "kicks found in B's body")
    }

    // Duration readout vs. file: the point of the whole thing.
    print(String(format: "  mix length %.3fs (file %.3fs)", layout.totalSeconds, mixed.duration))

    // Export paths.
    let wav = tmp.deletingPathExtension().appendingPathExtension("wav")
    try Exporter.export(master: tmp, peak: result.peak, to: wav, format: .wav24, sampleRate: 48000, ffmpeg: nil)
    let wavDur = AudioDecoder.duration(of: wav) ?? 0
    check(abs(wavDur - layout.totalSeconds) < 0.001, "WAV duration matches (\(wavDur))")
    if let ff = Exporter.findFFmpeg() {
        let mp3 = tmp.deletingPathExtension().appendingPathExtension("mp3")
        try Exporter.export(master: tmp, peak: result.peak, to: mp3, format: .mp3, sampleRate: 48000, ffmpeg: ff)
        let mp3Dur = AudioDecoder.duration(of: mp3) ?? 0
        print(String(format: "  mp3 via %@: %.3fs", ff, mp3Dur))
        check(abs(mp3Dur - layout.totalSeconds) < 0.1, "MP3 duration matches within 100 ms")
    } else {
        print("  (no ffmpeg found; MP3 export not tested)")
    }
    print("  files: \(tmp.path)")
}

/// Builds a mix from real songs, renders it, and measures how well the beats of
/// each pair line up inside the overlap (cross-correlation of their low-band
/// onset envelopes, rendered separately — lag 0 = perfect).
func runRealMix(_ paths: [String]) throws {
    print("Real mix: \(paths.count) songs")
    let sr = 48000.0
    var clips: [AudioClip] = []
    var entries: [MixEntry] = []
    var analyses: [TrackAnalysis] = []
    for p in paths {
        let url = URL(fileURLWithPath: p)
        let clip = try AudioDecoder.decode(url: url, sampleRate: sr)
        let a = TrackAnalyzer.analyze(clip: clip, taggedBPM: nil)
        clips.append(clip)
        analyses.append(a)
        var e = MixEntry(track: TrackInfo.file(path: p, title: url.deletingPathExtension().lastPathComponent, artist: "", album: "", duration: clip.duration, taggedBPM: nil))
        e.transition = TransitionSettings(style: .bassSwap, overlapBars: 8, tempoSync: true, rampBars: 8)
        entries.append(e)
        print(String(format: "  %@: %.2f BPM, downbeat %.3f, in %.1f out %.1f", url.lastPathComponent.prefix(28) as CVarArg, a.bpm, a.firstDownbeat, a.suggestedIn, a.suggestedOut))
    }
    let resolved = zip(entries, analyses).map { ResolvedEntry(entry: $0, analysis: $1) }
    let layout = MixLayout.build(entries: resolved, sampleRate: sr)
    print(String(format: "  layout total %.3fs", layout.totalSeconds))
    for t in layout.tracks where !t.warnings.isEmpty { print("  warning [\(t.index)]: \(t.warnings.joined(separator: " "))") }
    let renderer = MixRenderer(layout: layout, entries: resolved, settings: MixSettings()) { clips[$0] }

    // Per-transition alignment.
    for i in 1..<layout.tracks.count {
        let cur = layout.tracks[i], prev = layout.tracks[i - 1]
        guard cur.entryOverlap > 0 else { print("  transition \(i): cut"); continue }
        let a = try renderer.span(i - 1), b = try renderer.span(i)
        let aStart = prev.span - prev.outroOverlap
        let len = cur.entryOverlap
        let ea = lowOnsetEnvelope(Array(a.left[aStart..<(aStart + len)]), sr: sr)
        let eb = lowOnsetEnvelope(Array(b.left[0..<len]), sr: sr)
        let lag = bestLagMs(ea, eb, maxLagMs: 150)
        let beatMs = resolved[i - 1].beatLength * 1000
        // Phase of each song's kicks against the outgoing tempo, independently.
        let bpmA = resolved[i - 1].bpm
        let pa = BeatAnalyzer.combScore(BeatAnalyzer.strongRises(ea.map { sqrtf($0) }), bpm: bpmA)
        let pb = BeatAnalyzer.combScore(BeatAnalyzer.strongRises(eb.map { sqrtf($0) }), bpm: bpmA)
        var diff = pb.phaseMs - pa.phaseMs
        if diff > beatMs / 2 { diff -= beatMs }
        if diff < -beatMs / 2 { diff += beatMs }
        let synced = abs(cur.rho - 1) < 1e-6 ? abs(resolved[i - 1].bpm - resolved[i].bpm) < 0.5 : true
        // Only conclusive when both sides actually have kicks here (intros/outros often don't).
        let conclusive = synced && pa.score >= 2.5 && pb.score >= 2.5
        print(String(format: "  transition %d: overlap %.1fs, rho %.4f, xcorr lag %+.0f ms, kick phase A %.0f (%.1f) B %.0f (%.1f) → diff %+.0f ms (beat %.0f ms)%@", i, Double(len) / sr, cur.rho, lag, pa.phaseMs, pa.score, pb.phaseMs, pb.score, diff, beatMs, !synced ? " [not synced — skipped]" : (conclusive ? "" : " [no clear kicks on both sides — inconclusive]")))
        if conclusive { check(abs(diff) < 20, "transition \(i) kicks within 20 ms (diff \(Int(diff)) ms)") }
    }

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("blend-realmix-\(UUID().uuidString).caf")
    let t0 = Date()
    let result = try renderer.render(to: tmp, progress: { _ in }, isCancelled: { false })
    print(String(format: "  rendered in %.1fs, peak %.3f", Date().timeIntervalSince(t0), result.peak))
    let wav = tmp.deletingPathExtension().appendingPathExtension("wav")
    try Exporter.export(master: tmp, peak: result.peak, to: wav, format: .wav24, sampleRate: sr, ffmpeg: nil)
    let d = AudioDecoder.duration(of: wav) ?? 0
    check(abs(d - layout.totalSeconds) < 0.001, String(format: "WAV is %.3fs, layout said %.3fs", d, layout.totalSeconds))
    print("  mix: \(wav.path)")
}

/// 1 ms onset-rise envelope of the low band (kick/bass).
func lowOnsetEnvelope(_ x: [Float], sr: Double) -> [Float] {
    var lp = Biquad(); lp.setLowpass(cutoff: 150, sampleRate: sr)
    let step = Int(sr / 1000)
    let n = x.count / step
    var env = [Float](repeating: 0, count: n)
    for i in 0..<n {
        var acc: Float = 0
        for j in 0..<step { let v = lp.process(x[i * step + j]); acc += v * v }
        env[i] = sqrt(acc / Float(step))
    }
    var rise = [Float](repeating: 0, count: n)
    for i in 8..<n { rise[i] = max(0, env[i] - env[i - 8]) }
    return rise
}

/// Lag (ms) of b relative to a with the highest normalized cross-correlation.
func bestLagMs(_ a: [Float], _ b: [Float], maxLagMs: Int) -> Double {
    let n = min(a.count, b.count)
    var best = -Double.infinity, bestLag = 0
    for lag in -maxLagMs...maxLagMs {
        var dot: Float = 0
        var ea: Float = 0, eb: Float = 0
        for i in max(0, -lag)..<min(n, n - lag) {
            let va = a[i], vb = b[i + lag]
            dot += va * vb; ea += va * va; eb += vb * vb
        }
        let c = Double(dot) / Double(sqrt(ea * eb) + 1e-9)
        if c > best { best = c; bestLag = lag }
    }
    return Double(bestLag)
}

func analyzeFiles(_ paths: [String]) throws {
    for p in paths {
        let url = URL(fileURLWithPath: p)
        let t0 = Date()
        let clip = try AudioDecoder.decode(url: url, sampleRate: 48000)
        let a = TrackAnalyzer.analyze(clip: clip, taggedBPM: nil)
        print(String(format: "%@\n  %.1fs  bpm %.2f  firstDownbeat %.3f  grid conf %.2f  key %@ (%@, conf %.2f)  rms %.3f  in %.1f out %.1f  (%.1fs)",
                     url.lastPathComponent, clip.duration, a.bpm, a.firstDownbeat, a.gridConfidence, a.keyName, a.camelot, a.keyConfidence, a.rms, a.suggestedIn, a.suggestedOut, Date().timeIntervalSince(t0)))
    }
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    if args.isEmpty {
        try runSynthetic()
    } else if args.first == "--mix" {
        try runRealMix(Array(args.dropFirst()))
    } else {
        try analyzeFiles(args)
    }
} catch {
    print("ERROR: \(error)")
    failures += 1
}
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
