// The mix laid out on a sample grid. This is the arithmetic behind the length
// readout and the renderer alike — both use exactly these numbers, so the
// length shown before rendering is the length of the file that comes out.
//
// Each song's output is four regions in order:
//   entry   — overlapping the previous song's outro, played at rate ρ so its
//             tempo matches the previous song (ρ = 1 when not synced)
//   ramp    — alone, rate easing linearly (in output time) from ρ back to 1
//   body    — alone, at its own tempo
//   outro   — overlapping the next song's entry, rate 1
// The next song starts exactly where this song's outro starts.

import Foundation

/// A song with its mix settings resolved against its analysis.
struct ResolvedEntry {
    var entry: MixEntry
    var analysis: TrackAnalysis?
    var bpm: Double
    var inTime: Double
    var outTime: Double
    /// First downbeat, after the user's downbeat shift.
    var firstDownbeat: Double
    var barLength: Double { 240 / bpm }
    var beatLength: Double { 60 / bpm }
    var transition: TransitionSettings { entry.transition }
    var title: String { entry.track.title }

    init(entry: MixEntry, analysis: TrackAnalysis?) {
        self.entry = entry
        self.analysis = analysis
        let duration = analysis?.duration ?? entry.track.duration
        bpm = entry.bpmOverride ?? analysis?.bpm ?? entry.track.taggedBPM ?? 120
        if bpm <= 0 { bpm = 120 }
        inTime = max(0, min(duration, entry.inTime ?? analysis?.suggestedIn ?? 0))
        outTime = max(inTime, min(duration, entry.outTime ?? analysis?.suggestedOut ?? duration))
        if let a = analysis {
            let beat = 60 / bpm
            var d = a.firstDownbeat + Double(entry.downbeatShift) * beat + entry.gridShift
            let bar = beat * 4
            d -= floor(d / bar) * bar
            firstDownbeat = d
        } else {
            firstDownbeat = 0
        }
    }

    func nearestBeat(to t: Double) -> Double {
        let k = ((t - firstDownbeat) / beatLength).rounded()
        return firstDownbeat + k * beatLength
    }

    func nearestDownbeat(to t: Double) -> Double {
        let k = ((t - firstDownbeat) / barLength).rounded()
        return firstDownbeat + k * barLength
    }

    func isDownbeat(_ t: Double, tolerance: Double = 0.002) -> Bool {
        abs(t - nearestDownbeat(to: t)) < tolerance
    }
}

struct TrackLayout {
    var index: Int
    var start: Int              // output sample where the song begins
    var entryOverlap: Int       // output samples overlapping the previous song
    var rho: Double             // rate during the entry overlap
    var rampOut: Int            // output samples of the tempo ramp
    var body: Int               // output samples alone at rate 1
    var outroOverlap: Int       // output samples overlapping the next song
    var inSample: Double        // source sample of the in point
    var outSample: Double
    var warnings: [String]

    var entrySrc: Double { Double(entryOverlap) * rho }
    var rampSrc: Double { Double(rampOut) * (1 + rho) / 2 }
    var span: Int { entryOverlap + rampOut + body + outroOverlap }
    var end: Int { start + span }
    var soloStart: Int { start + entryOverlap }
    var outroStart: Int { start + entryOverlap + rampOut + body }

    /// Source sample index for output offset `u` (0 ≤ u < span) into this song.
    func sourcePosition(atOutputOffset u: Double) -> Double {
        if u < Double(entryOverlap) {
            return inSample + u * rho
        }
        let v = u - Double(entryOverlap)
        if v < Double(rampOut), rampOut > 0 {
            return inSample + entrySrc + rho * v + (1 - rho) * v * v / (2 * Double(rampOut))
        }
        return inSample + entrySrc + rampSrc + (v - Double(rampOut))
    }

    /// Playback rate at output offset `u`.
    func rate(atOutputOffset u: Double) -> Double {
        if u < Double(entryOverlap) { return rho }
        let v = u - Double(entryOverlap)
        if v < Double(rampOut), rampOut > 0 { return rho + (1 - rho) * v / Double(rampOut) }
        return 1
    }

    var isStretched: Bool { abs(rho - 1) > 1e-6 }
}

struct MixLayout {
    var sampleRate: Double
    var tracks: [TrackLayout]
    var totalSamples: Int { tracks.last?.end ?? 0 }
    var totalSeconds: Double { Double(totalSamples) / sampleRate }

    static let minSyncRatio = 0.8
    static let maxSyncRatio = 1.25

    static func build(entries: [ResolvedEntry], sampleRate sr: Double) -> MixLayout {
        var layouts: [TrackLayout] = []
        var cursor = 0
        for (i, e) in entries.enumerated() {
            var warnings: [String] = []
            let prev = i > 0 ? entries[i - 1] : nil
            let prevLayout = layouts.last
            let barSamples = e.barLength * sr

            let entryOverlap = prevLayout?.outroOverlap ?? 0
            var rho = 1.0
            if let prev, entryOverlap > 0, prev.transition.tempoSync {
                var ratio = prev.bpm / e.bpm
                while ratio > 1.5 { ratio /= 2 }
                while ratio < 1 / 1.5 { ratio *= 2 }
                if ratio >= minSyncRatio && ratio <= maxSyncRatio {
                    rho = ratio
                } else {
                    warnings.append("Tempo too far from \(prev.title) to sync (\(Int(prev.bpm.rounded())) → \(Int(e.bpm.rounded())) BPM); plain overlap instead.")
                }
            }
            if e.analysis == nil { warnings.append("Not analyzed yet — length is an estimate.") }

            var rampSrc = 0.0
            var rampOut = 0
            if abs(rho - 1) > 1e-6, let prev {
                rampSrc = Double(prev.transition.rampBars) * barSamples
                rampOut = Int((2 * rampSrc / (1 + rho)).rounded())
                rampSrc = Double(rampOut) * (1 + rho) / 2
            }
            let isLast = i == entries.count - 1
            var outroOverlap = 0
            if !isLast && e.transition.style != .cut {
                outroOverlap = Int((Double(e.transition.overlapBars) * barSamples).rounded())
            }

            let inSample = e.inTime * sr
            let outSample = e.outTime * sr
            let entrySrc = Double(entryOverlap) * rho
            var available = (outSample - inSample) - entrySrc - rampSrc - Double(outroOverlap)
            if available < 0 {
                // Too short for everything: give up the ramp first, then shorten the outro.
                let take = min(-available, rampSrc)
                rampSrc -= take
                rampOut = Int((2 * rampSrc / (1 + rho)).rounded())
                rampSrc = Double(rampOut) * (1 + rho) / 2
                available = (outSample - inSample) - entrySrc - rampSrc - Double(outroOverlap)
                if available < 0 {
                    let cut = min(-available, Double(outroOverlap))
                    outroOverlap -= Int(cut.rounded())
                    available = (outSample - inSample) - entrySrc - rampSrc - Double(outroOverlap)
                    warnings.append("Too short for the transitions around it — overlap shortened.")
                }
                if available < 0 {
                    warnings.append("The previous song's overlap is longer than this whole song.")
                    available = 0
                }
            }
            let body = Int(available.rounded())
            let layout = TrackLayout(index: i, start: cursor, entryOverlap: entryOverlap, rho: rho,
                                     rampOut: rampOut, body: body, outroOverlap: outroOverlap,
                                     inSample: inSample, outSample: outSample, warnings: warnings)
            layouts.append(layout)
            cursor = layout.outroStart
        }
        return MixLayout(sampleRate: sr, tracks: layouts)
    }
}
