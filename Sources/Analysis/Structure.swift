// Song structure on the beat grid: per-beat timbre, harmony and energy; the
// novelty between what came before and what comes next; and from that, the
// things a DJ reads off a track before mixing it — which beat is the "1",
// where the 8-bar phrases start, where the intro ends, where the drops and
// choruses are, where the outro begins.
//
// The downbeat is decided here rather than in the beat tracker because the
// best evidence for it is structural: section changes, chord changes and
// drops land on the first beat of a bar. Kick patterns alone can't tell
// beat 1 from beat 3 in four-on-the-floor music.

import Foundation
import Accelerate

struct SongSection: Codable, Equatable {
    enum Level: String, Codable { case low, mid, high }
    var startBar: Int
    var endBar: Int          // exclusive
    var energy: Float        // 0...1 relative to the song's loudest part
    var level: Level
    var bars: Int { endBar - startBar }
}

struct SongStructure: Codable, Equatable {
    var barLength: Double
    /// Time of bar 0 (the first downbeat at or after t = 0).
    var firstBar: Double
    var barCount: Int
    /// RMS per bar, linear.
    var barEnergy: [Float]
    /// Bars b with (b - phraseOffset) % 8 == 0 start an 8-bar phrase.
    var phraseOffset: Int
    var sections: [SongSection]
    /// Novelty at each bar start (how different the next two bars are from the previous two).
    var novelty: [Float]

    func time(ofBar b: Int) -> Double { firstBar + Double(b) * barLength }
    func bar(at t: Double) -> Double { (t - firstBar) / barLength }

    func isPhraseStart(_ b: Int) -> Bool { ((b - phraseOffset) % 8 + 8) % 8 == 0 }

    /// Nearest bar on the phrase grid (every `bars` bars from the phrase offset).
    func phraseBoundary(nearest b: Double, every bars: Int = 8) -> Int {
        let k = ((b - Double(phraseOffset)) / Double(bars)).rounded()
        return phraseOffset + Int(k) * bars
    }

    func phraseBoundary(atOrBefore b: Int, every bars: Int = 8) -> Int {
        var k = Int(floor(Double(b - phraseOffset) / Double(bars)))
        var r = phraseOffset + k * bars
        while r > b { k -= 1; r = phraseOffset + k * bars }
        return r
    }

    func phraseBoundary(atOrAfter b: Int, every bars: Int = 8) -> Int {
        var k = Int(ceil(Double(b - phraseOffset) / Double(bars)))
        var r = phraseOffset + k * bars
        while r < b { k += 1; r = phraseOffset + k * bars }
        return r
    }

    var firstHigh: SongSection? { sections.first { $0.level == .high } }
    var lastHigh: SongSection? { sections.last { $0.level == .high } }

    /// Bars before the first drop (the intro).
    var introBars: Int { firstHigh?.startBar ?? barCount }
    /// Bars after the last drop (the outro).
    var outroBars: Int { lastHigh.map { barCount - $0.endBar } ?? 0 }

    func section(containingBar b: Int) -> SongSection? {
        sections.first { b >= $0.startBar && b < $0.endBar }
    }
}

enum StructureAnalyzer {

    struct Result {
        var downbeatPhase: Int
        var structure: SongStructure
    }

    /// `mel` is the analysis-rate log-mel spectrogram; `signal` the same mono
    /// analysis signal (for chroma); `clip` the full-rate stereo audio (for RMS).
    /// `beatOffset` is the grid phase from the beat tracker (any beat).
    static func analyze(clip: AudioClip, signal: [Float], analysisRate: Double, mel: Spectrogram.MelResult,
                        bpm: Double, beatOffset: Double) -> Result {
        let beatLength = 60 / bpm
        let duration = clip.duration
        let sr = clip.sampleRate
        // Beat 0 = first grid beat at or after t = 0.
        let beat0 = beatOffset - floor(beatOffset / beatLength) * beatLength
        let beatCount = max(0, Int((duration - beat0) / beatLength))
        func beatTime(_ k: Int) -> Double { beat0 + Double(k) * beatLength }

        var empty = SongStructure(barLength: beatLength * 4, firstBar: beat0, barCount: beatCount / 4,
                                  barEnergy: [], phraseOffset: 0, sections: [], novelty: [])
        guard beatCount >= 32 else {
            empty.sections = [SongSection(startBar: 0, endBar: max(1, beatCount / 4), energy: 1, level: .high)]
            return Result(downbeatPhase: 0, structure: empty)
        }

        // MARK: Per-beat features: 24 timbre groups + 12 chroma + log energy, z-scored.
        let groups = 24
        let per = mel.bands / groups
        let (chromaFrames, cfps) = KeyAnalyzer.chromaFrames(signal: signal, sampleRate: analysisRate)
        var beatEnergy = [Float](repeating: 0, count: beatCount)
        var features = [[Float]](repeating: [], count: beatCount)
        for k in 0..<beatCount {
            let t0 = beatTime(k), t1 = beatTime(k + 1)
            var timbre = [Float](repeating: 0, count: groups)
            let f0 = max(0, Int(t0 * mel.fps)), f1 = min(mel.frames, max(f0 + 1, Int(t1 * mel.fps)))
            if f1 > f0 {
                for g in 0..<groups {
                    var acc: Float = 0
                    for f in f0..<f1 { for j in 0..<per { acc += mel.logMel[f * mel.bands + g * per + j] } }
                    timbre[g] = acc / Float((f1 - f0) * per)
                }
            }
            var chroma = [Float](repeating: 0, count: 12)
            let c0 = max(0, Int(t0 * cfps)), c1 = min(chromaFrames.count, max(c0 + 1, Int(t1 * cfps)))
            if c1 > c0 {
                var acc = [Double](repeating: 0, count: 12)
                for f in c0..<c1 { for i in 0..<12 { acc[i] += chromaFrames[f][i] } }
                let total = acc.reduce(0, +)
                if total > 0 { for i in 0..<12 { chroma[i] = Float(acc[i] / total) * 6 } }
            }
            let s = Int(t0 * sr), e = min(clip.frameCount, Int(t1 * sr))
            beatEnergy[k] = TrackAnalyzer.rmsLevel(clip.left, clip.right, from: s, to: e)
            features[k] = timbre + chroma + [log10f(max(beatEnergy[k], 1e-4)) * 10]
        }
        let dims = features[0].count
        for d in 0..<dims {
            var mean: Float = 0, sd: Float = 0
            for k in 0..<beatCount { mean += features[k][d] }
            mean /= Float(beatCount)
            for k in 0..<beatCount { sd += (features[k][d] - mean) * (features[k][d] - mean) }
            sd = sqrt(sd / Float(beatCount))
            if sd < 1e-6 { sd = 1 }
            for k in 0..<beatCount { features[k][d] = (features[k][d] - mean) / sd }
        }

        // MARK: Beat-level novelty: the 8 beats before vs the 8 beats after each beat.
        let w = 8
        var beatNovelty = [Float](repeating: 0, count: beatCount + 1)
        var prefix = [[Float]](repeating: [Float](repeating: 0, count: dims), count: beatCount + 1)
        for k in 0..<beatCount { for d in 0..<dims { prefix[k + 1][d] = prefix[k][d] + features[k][d] } }
        for k in 1..<beatCount {
            let a0 = max(0, k - w), b1 = min(beatCount, k + w)
            let na = Float(k - a0), nb = Float(b1 - k)
            var dist: Float = 0
            for d in 0..<dims {
                let p = (prefix[k][d] - prefix[a0][d]) / na
                let q = (prefix[b1][d] - prefix[k][d]) / nb
                dist += (p - q) * (p - q)
            }
            beatNovelty[k] = sqrt(dist / Float(dims))
        }
        // Clip outliers (the song's end is a huge "change") and ignore the edges when voting.
        let nMean = beatNovelty.reduce(0, +) / Float(beatNovelty.count)
        var nSD: Float = 0
        for v in beatNovelty { nSD += (v - nMean) * (v - nMean) }
        nSD = sqrt(nSD / Float(beatNovelty.count))
        let cap = nMean + 2 * nSD
        let voteRange = w..<max(w + 1, beatCount - w)

        // MARK: Downbeat: the beat phase (mod 4) where changes happen. The
        // novelty curve peaks exactly on the beat a section or chord changes,
        // so only local maxima vote (summing the whole curve would smear the
        // 8-beat-wide bumps across all four phases). Two curves vote: the full
        // feature set (sections) and chroma alone with a short window (chords).
        var chromaNovelty = [Float](repeating: 0, count: beatCount + 1)
        let cw = 4
        for k in 1..<beatCount {
            let a0 = max(0, k - cw), b1 = min(beatCount, k + cw)
            var dist: Float = 0
            for d in groups..<(groups + 12) {
                let p = (prefix[k][d] - prefix[a0][d]) / Float(k - a0)
                let q = (prefix[b1][d] - prefix[k][d]) / Float(b1 - k)
                dist += (p - q) * (p - q)
            }
            chromaNovelty[k] = sqrt(dist / 12)
        }
        func peakVotes(_ curve: [Float], radius: Int, into score: inout [Float], weight: Float) {
            let m = curve.reduce(0, +) / Float(curve.count)
            for k in voteRange {
                var isPeak = curve[k] > m
                if isPeak {
                    for d in -radius...radius where d != 0 {
                        let j = k + d
                        if j >= 0 && j < curve.count && curve[j] > curve[k] { isPeak = false; break }
                    }
                }
                if isPeak { score[k % 4] += weight * min(curve[k], cap) }
            }
        }
        var phaseScore = [Float](repeating: 0, count: 4)
        peakVotes(beatNovelty, radius: 3, into: &phaseScore, weight: 1)
        peakVotes(chromaNovelty, radius: 2, into: &phaseScore, weight: 0.5)
        // A little weight for the low end hitting harder on beat 1.
        var lowAccent = [Float](repeating: 0, count: 4)
        let lowGroups = max(1, groups / 8)
        for k in voteRange {
            var low: Float = 0
            for g in 0..<lowGroups { low += features[k][g] }
            lowAccent[k % 4] += low
        }
        let accentMean = lowAccent.reduce(0, +) / 4
        var best = 0
        var bestScore = -Float.greatestFiniteMagnitude
        for p in 0..<4 {
            let s = phaseScore[p] + 0.1 * (lowAccent[p] - accentMean)
            if s > bestScore { bestScore = s; best = p }
        }
        if ProcessInfo.processInfo.environment["BLEND_DEBUG"] != nil {
            print("  downbeat votes: \(phaseScore.map { String(format: "%.1f", $0) }) accent \(lowAccent.map { String(format: "%.0f", $0) }) → phase \(best)")
        }
        let downbeatPhase = best

        // MARK: Bars.
        let firstBar = beatTime(downbeatPhase)
        let barLength = beatLength * 4
        let barCount = (beatCount - downbeatPhase) / 4
        var structure = SongStructure(barLength: barLength, firstBar: firstBar, barCount: barCount,
                                      barEnergy: [], phraseOffset: 0, sections: [], novelty: [])
        guard barCount >= 8 else {
            structure.sections = [SongSection(startBar: 0, endBar: max(1, barCount), energy: 1, level: .high)]
            return Result(downbeatPhase: downbeatPhase, structure: structure)
        }
        var barEnergy = [Float](repeating: 0, count: barCount)
        var novelty = [Float](repeating: 0, count: barCount + 1)
        for b in 0..<barCount {
            let k = downbeatPhase + b * 4
            barEnergy[b] = sqrt((0..<4).map { beatEnergy[k + $0] * beatEnergy[k + $0] }.reduce(0, +) / 4)
            novelty[b] = min(beatNovelty[k], cap)
        }
        structure.barEnergy = barEnergy
        structure.novelty = novelty

        // MARK: Phrase grid: the 8-bar offset where section changes pile up.
        func offsetScore(_ o: Int) -> Float {
            var score: Float = 0
            var b = o
            while b < barCount - 1 { if b >= 1 { score += novelty[b] }; b += 8 }
            var h = o % 4
            while h < barCount - 1 { if h >= 1 { score += 0.4 * novelty[h] }; h += 4 }
            return score
        }
        var bestOffset = 0
        var bestOffsetScore = offsetScore(0) * 1.15   // phrases usually start on the first downbeat
        for o in 1..<8 {
            let s = offsetScore(o)
            if s > bestOffsetScore { bestOffsetScore = s; bestOffset = o }
        }
        structure.phraseOffset = bestOffset

        // MARK: Sections: novelty peaks snapped to the 4-bar grid, at least 4 bars apart.
        let bMean = novelty.reduce(0, +) / Float(novelty.count)
        var bSD: Float = 0
        for v in novelty { bSD += (v - bMean) * (v - bMean) }
        bSD = sqrt(bSD / Float(novelty.count))
        let threshold = bMean + 0.3 * bSD
        var cuts: [Int] = [0]
        for b in 1..<barCount where novelty[b] > threshold && novelty[b] >= novelty[b - 1] && novelty[b] >= novelty[b + 1] {
            let snapped = structure.phraseBoundary(nearest: Double(b), every: 4)
            guard snapped > 0, snapped < barCount, snapped - cuts.last! >= 4 else { continue }
            cuts.append(snapped)
        }
        if barCount - cuts.last! < 2, cuts.count > 1 { cuts.removeLast() }
        cuts.append(barCount)

        var sections: [SongSection] = []
        let topCount = max(1, barCount / 10)
        let loudest = barEnergy.sorted(by: >).prefix(topCount).reduce(0, +) / Float(topCount)
        for i in 0..<(cuts.count - 1) {
            let s = cuts[i], e = cuts[i + 1]
            let m = barEnergy[s..<e].reduce(0, +) / Float(e - s)
            let rel = loudest > 0 ? m / loudest : 1
            let level: SongSection.Level = rel >= 0.72 ? .high : (rel <= 0.45 ? .low : .mid)
            sections.append(SongSection(startBar: s, endBar: e, energy: rel, level: level))
        }
        var merged: [SongSection] = []
        for sec in sections {
            if let last = merged.last, last.level == sec.level {
                let total = Float(last.bars + sec.bars)
                merged[merged.count - 1] = SongSection(startBar: last.startBar, endBar: sec.endBar,
                                                       energy: (last.energy * Float(last.bars) + sec.energy * Float(sec.bars)) / total, level: sec.level)
            } else {
                merged.append(sec)
            }
        }
        structure.sections = merged
        return Result(downbeatPhase: downbeatPhase, structure: structure)
    }
}
