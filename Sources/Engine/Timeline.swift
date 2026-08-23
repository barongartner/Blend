// The mix laid out on a sample grid. This is the arithmetic behind the length
// readout and the renderer alike — both use exactly these numbers, so the
// length shown before rendering is the length of the file that comes out.
//
// Planning happens here too: for each pair of songs the transition is
// resolved (Auto picks a style from tempo, key and structure), and songs
// without hand-set IN/OUT points get them from structure — mix out at the end
// of the last drop, mix in so the next song's drop lands as the old one
// leaves, all on phrase boundaries.
//
// Each song's output is five regions in order:
//   entry   — overlapping the previous song's outro/tail, played at rate ρ so
//             its tempo matches the previous song (ρ = 1 when not synced)
//   ramp    — alone, rate easing linearly (in output time) from ρ back to 1
//   body    — alone, at its own tempo
//   outro   — source audio overlapping the next song's entry (blends)
//   tail    — synthesized echo ringing under the next song (echo out, filter drop)
// The next song starts where the outro (or tail) starts.

import Foundation

// MARK: - Resolved transition

enum ResolvedStyle: String {
    case blend, echoOut, filterDrop, cut

    var label: String {
        switch self {
        case .blend: return "Blend"
        case .echoOut: return "Echo out"
        case .filterDrop: return "Filter drop"
        case .cut: return "Cut"
        }
    }
}

struct ResolvedTransition {
    var style: ResolvedStyle
    /// Bars of the outgoing song's source overlapping the incoming (blend).
    var overlapBars: Int
    /// Bars of synthesized echo after the cut (echo out / filter drop).
    var tailBars: Int
    /// Bars of high-pass sweep before the cut (filter drop).
    var sweepBars: Int
    var riser: Bool
    /// Why Auto chose this, for the UI.
    var reason: String
    var tempoSynced: Bool
}

// MARK: - Resolved entry

/// A song with its mix settings resolved against its analysis.
struct ResolvedEntry {
    var entry: MixEntry
    var analysis: TrackAnalysis?
    var bpm: Double
    var inTime: Double
    var outTime: Double
    /// First downbeat, after the user's downbeat shift and grid nudge.
    var firstDownbeat: Double
    /// Set by the planner: the transition out of this song (nil for the last).
    var transitionOut: ResolvedTransition?
    var autoIn: Bool
    var autoOut: Bool

    var barLength: Double { 240 / bpm }
    var beatLength: Double { 60 / bpm }
    var transition: TransitionSettings { entry.transition }
    var title: String { entry.track.title }
    var duration: Double { analysis?.duration ?? entry.track.duration }

    init(entry: MixEntry, analysis: TrackAnalysis?) {
        self.entry = entry
        self.analysis = analysis
        let duration = analysis?.duration ?? entry.track.duration
        bpm = entry.bpmOverride ?? analysis?.bpm ?? entry.track.taggedBPM ?? 120
        if bpm <= 0 { bpm = 120 }
        autoIn = entry.inTime == nil
        autoOut = entry.outTime == nil
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

    // MARK: Structure helpers (bars counted from firstDownbeat)

    func time(ofBar b: Int) -> Double { firstDownbeat + Double(b) * barLength }
    func bar(at t: Double) -> Double { (t - firstDownbeat) / barLength }

    /// The structure's bar numbering assumes its own first bar; if the user
    /// shifted the downbeat/grid, bar indices still refer to the same musical
    /// bars (shifts are whole bars or tiny nudges), so use them directly.
    var structure: SongStructure? { analysis?.structure }

    /// Nearest 8-bar phrase boundary to `t`, on this song's grid.
    func nearestPhrase(to t: Double) -> Double {
        guard let st = structure else { return nearestDownbeat(to: t) }
        let b = st.phraseBoundary(nearest: bar(at: t))
        return time(ofBar: b)
    }

    /// Bars of low-energy outro available after the last drop, up to `out`.
    var outroBarsAvailable: Int {
        guard let st = structure, let last = st.lastHigh else { return 0 }
        let outBar = Int(bar(at: outTime).rounded())
        return max(0, min(outBar, st.barCount) - last.endBar)
    }

    /// Bars of intro available before the first drop, from `in`.
    var introBarsAvailable: Int {
        guard let st = structure, let first = st.firstHigh else { return 0 }
        let inBar = Int(bar(at: inTime).rounded())
        return max(0, first.startBar - inBar)
    }
}

// MARK: - Planner

enum MixPlanner {

    /// Auto blends stretch at most ±8% (more than that is audible even with
    /// key lock); a blend the user asked for explicitly may go to ±15%.
    static let autoSyncLimit = 0.08
    static let forcedSyncLimit = 0.15

    static func syncRatio(from a: ResolvedEntry, to b: ResolvedEntry) -> Double? {
        var ratio = a.bpm / b.bpm
        while ratio > 1.5 { ratio /= 2 }
        while ratio < 1 / 1.5 { ratio *= 2 }
        let limit = a.transition.style == .blend ? forcedSyncLimit : autoSyncLimit
        return abs(ratio - 1) <= limit ? ratio : nil
    }

    /// nil when either key is unknown or detected with little confidence.
    static func keyCompatibility(_ a: ResolvedEntry, _ b: ResolvedEntry) -> Int? {
        guard let aa = a.analysis, let ab = b.analysis, aa.keyConfidence >= 0.3, ab.keyConfidence >= 0.3 else { return nil }
        return KeyAnalyzer.compatibility(aa.camelot, ab.camelot)
    }

    /// Resolves the transition a → b. Uses structure-based availability when
    /// in/out are automatic, the user's points when they are set.
    static func resolve(from a: ResolvedEntry, to b: ResolvedEntry) -> ResolvedTransition {
        let s = a.transition
        let canSync = s.tempoSync && syncRatio(from: a, to: b) != nil
        let compat = keyCompatibility(a, b)
        let tempoNote = Int(a.bpm.rounded()) == Int(b.bpm.rounded()) ? "" : " (\(Int(a.bpm.rounded()))→\(Int(b.bpm.rounded())) BPM)"

        // Room for a blend: the outgoing song's outro and the incoming song's intro.
        let outroBars: Int = a.autoOut ? (a.structure?.outroBars ?? 0) : a.outroBarsAvailable
        let introBars: Int = b.autoIn ? (b.structure?.introBars ?? 0) : b.introBarsAvailable
        let room = min(outroBars, introBars)
        func blendBars(_ requested: Int) -> Int {
            if requested > 0 { return requested }
            if room >= 16 { return 8 }
            if room >= 8 { return 8 }
            if room >= 4 { return 4 }
            return 2
        }

        switch s.style {
        case .blend:
            return ResolvedTransition(style: .blend, overlapBars: blendBars(s.overlapBars), tailBars: 0, sweepBars: 0, riser: false,
                                      reason: canSync ? "" : "tempos too far apart to sync — plain overlap", tempoSynced: canSync)
        case .echoOut:
            return ResolvedTransition(style: .echoOut, overlapBars: 0, tailBars: max(1, s.tailBars), sweepBars: 0, riser: false, reason: "", tempoSynced: false)
        case .filterDrop:
            return ResolvedTransition(style: .filterDrop, overlapBars: 0, tailBars: 1, sweepBars: s.overlapBars > 0 ? min(s.overlapBars, 8) : 2,
                                      riser: s.riser, reason: "", tempoSynced: false)
        case .cut:
            return ResolvedTransition(style: .cut, overlapBars: 0, tailBars: 0, sweepBars: 0, riser: false, reason: "", tempoSynced: false)
        case .auto:
            if !canSync {
                return ResolvedTransition(style: .echoOut, overlapBars: 0, tailBars: 2, sweepBars: 0, riser: false,
                                          reason: "tempos too far apart to blend\(tempoNote)", tempoSynced: false)
            }
            if let compat, compat == 0 {
                return ResolvedTransition(style: .filterDrop, overlapBars: 0, tailBars: 1, sweepBars: 2, riser: s.riser,
                                          reason: "keys clash — a blend would be muddy", tempoSynced: false)
            }
            if room >= 4 {
                let bars = room >= 8 ? 8 : 4
                return ResolvedTransition(style: .blend, overlapBars: bars, tailBars: 0, sweepBars: 0, riser: false,
                                          reason: "\(bars)-bar blend: outro \(outroBars) bars, intro \(introBars) bars", tempoSynced: true)
            }
            if a.structure == nil || b.structure == nil {
                return ResolvedTransition(style: .blend, overlapBars: 4, tailBars: 0, sweepBars: 0, riser: false,
                                          reason: "not analyzed yet", tempoSynced: true)
            }
            return ResolvedTransition(style: .echoOut, overlapBars: 0, tailBars: 2, sweepBars: 0, riser: false,
                                      reason: outroBars < 4 ? "no outro to blend over (\(outroBars) bars)" : "no intro to blend into (\(introBars) bars)",
                                      tempoSynced: false)
        }
    }

    /// Fills in automatic IN/OUT points from structure, given the resolved
    /// transitions. `entries` must already carry `transitionOut`.
    static func placePoints(_ entries: inout [ResolvedEntry]) {
        for i in entries.indices {
            let e = entries[i]
            guard let st = e.structure else { continue }
            let isFirst = i == 0, isLast = i == entries.count - 1

            if e.autoIn {
                var inBar: Int
                if isFirst {
                    // Start the mix near the top of the song, but skip a very long intro.
                    inBar = st.introBars > 16 ? st.phraseBoundary(atOrBefore: st.introBars - 16) : 0
                } else if let first = st.firstHigh, let t = entries[i - 1].transitionOut {
                    switch t.style {
                    case .blend:
                        // The drop lands as the blend completes.
                        inBar = first.startBar - t.overlapBars
                    case .echoOut, .filterDrop, .cut:
                        // Come in with the last intro phrase if it has some energy, else straight at the drop.
                        let phraseBefore = first.startBar - 8
                        if phraseBefore >= 0, let sec = st.section(containingBar: phraseBefore), sec.level != .low {
                            inBar = phraseBefore
                        } else {
                            inBar = first.startBar
                        }
                    }
                } else {
                    inBar = 0
                }
                inBar = max(0, min(max(0, st.barCount - 2), inBar))
                entries[i].inTime = e.time(ofBar: inBar)
            }

            if e.autoOut {
                var outBar: Int
                if isLast {
                    // Play out to the natural end of the last drop and its outro.
                    outBar = st.barCount
                    if let last = st.lastHigh, st.outroBars > 16 { outBar = last.endBar + 8 }
                } else if let last = st.lastHigh, let t = e.transitionOut {
                    switch t.style {
                    case .blend: outBar = min(st.barCount, last.endBar + t.overlapBars)
                    case .echoOut, .filterDrop, .cut: outBar = last.endBar
                    }
                } else {
                    outBar = st.barCount
                }
                outBar = max(1, min(st.barCount, outBar))
                entries[i].outTime = min(e.duration, e.time(ofBar: outBar))
            }
            if entries[i].outTime < entries[i].inTime + e.barLength * 2 {
                entries[i].outTime = min(e.duration, entries[i].inTime + e.barLength * 8)
            }
        }
    }

    /// Resolves transitions and points for a whole mix.
    static func plan(_ entries: [ResolvedEntry]) -> [ResolvedEntry] {
        var out = entries
        guard !out.isEmpty else { return out }
        for i in 0..<(out.count - 1) {
            out[i].transitionOut = resolve(from: out[i], to: out[i + 1])
        }
        placePoints(&out)
        // Points may change the room available; resolve once more with the final points.
        for i in 0..<(out.count - 1) where out[i].transition.style == .auto {
            out[i].transitionOut = resolve(from: out[i], to: out[i + 1])
        }
        placePoints(&out)
        return out
    }
}

// MARK: - Layout

struct TrackLayout {
    var index: Int
    var start: Int              // output sample where the song begins
    var entryOverlap: Int       // output samples overlapping the previous song (its outro + tail)
    var rho: Double             // rate during the entry overlap
    var rampOut: Int            // output samples of the tempo ramp
    var body: Int               // output samples alone at rate 1
    var outroOverlap: Int       // source samples overlapping the next song (blend)
    var tail: Int               // synthesized samples ringing under the next song (echo)
    var sweep: Int              // samples of filter sweep at the end of the source (filter drop)
    var inSample: Double        // source sample of the in point
    var outSample: Double
    var warnings: [String]

    var entrySrc: Double { Double(entryOverlap) * rho }
    var rampSrc: Double { Double(rampOut) * (1 + rho) / 2 }
    /// Samples of source audio in the span.
    var sourceSpan: Int { entryOverlap + rampOut + body + outroOverlap }
    var span: Int { sourceSpan + tail }
    var end: Int { start + span }
    var soloStart: Int { start + entryOverlap }
    var outroStart: Int { start + entryOverlap + rampOut + body }

    /// Source sample index for output offset `u` (0 ≤ u < sourceSpan) into this song.
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

    var isStretched: Bool { abs(rho - 1) > 1e-6 }
}

struct MixLayout {
    var sampleRate: Double
    var tracks: [TrackLayout]
    /// The planned entries (with resolved transitions and points).
    var entries: [ResolvedEntry]
    var totalSamples: Int { tracks.last?.end ?? 0 }
    var totalSeconds: Double { Double(totalSamples) / sampleRate }

    static func build(entries input: [ResolvedEntry], sampleRate sr: Double) -> MixLayout {
        let entries = MixPlanner.plan(input)
        var layouts: [TrackLayout] = []
        var cursor = 0
        for (i, e) in entries.enumerated() {
            var warnings: [String] = []
            let prev = i > 0 ? entries[i - 1] : nil
            let prevLayout = layouts.last
            let barSamples = e.barLength * sr

            let entryOverlap = (prevLayout?.outroOverlap ?? 0) + (prevLayout?.tail ?? 0)
            var rho = 1.0
            if let prev, let t = prev.transitionOut, t.style == .blend, t.tempoSynced, let ratio = MixPlanner.syncRatio(from: prev, to: e) {
                rho = ratio
            } else if let prev, let t = prev.transitionOut, t.style == .blend, prev.transition.tempoSync, MixPlanner.syncRatio(from: prev, to: e) == nil {
                warnings.append("Tempo too far from \(prev.title) to sync (\(Int(prev.bpm.rounded())) → \(Int(e.bpm.rounded())) BPM); plain overlap.")
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
            var tail = 0
            var sweep = 0
            if !isLast, let t = e.transitionOut {
                switch t.style {
                case .blend: outroOverlap = Int((Double(t.overlapBars) * barSamples).rounded())
                case .echoOut: tail = Int((Double(t.tailBars) * barSamples).rounded())
                case .filterDrop:
                    tail = Int((Double(t.tailBars) * barSamples).rounded())
                    sweep = Int((Double(t.sweepBars) * barSamples).rounded())
                case .cut: break
                }
            }

            let inSample = e.inTime * sr
            let outSample = e.outTime * sr
            let entrySrc = Double(entryOverlap) * rho
            var available = (outSample - inSample) - entrySrc - rampSrc - Double(outroOverlap)
            if available < 0 {
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
            sweep = min(sweep, body)
            let layout = TrackLayout(index: i, start: cursor, entryOverlap: entryOverlap, rho: rho,
                                     rampOut: rampOut, body: body, outroOverlap: outroOverlap, tail: tail, sweep: sweep,
                                     inSample: inSample, outSample: outSample, warnings: warnings)
            layouts.append(layout)
            cursor = layout.outroStart
        }
        return MixLayout(sampleRate: sr, tracks: layouts, entries: entries)
    }
}
