// Everything the analyzer learns about a song, cached per track so a song is
// only ever analyzed once. All times are seconds in the song's own timeline.
//
// The beat grid is the DJ-software model: a constant tempo plus a phase, with
// the downbeat (bar start) chosen as one of the four beat phases. Modern
// productions are quantized, so the grid is exact for them; for a live
// recording with drifting tempo `gridConfidence` drops and the editor says so.

import Foundation

struct TrackAnalysis: Codable, Equatable {
    /// Bumped whenever the analyzer changes; older cached results are redone.
    static let currentVersion = 4
    var version: Int
    var sampleRate: Double
    var duration: Double

    // Beat grid
    var bpm: Double
    /// Time of some grid beat; every other grid beat is `beatOffset + k * beatLength`.
    var beatOffset: Double
    /// Which grid beat (0...3, counted from `beatOffset`) is the bar's downbeat.
    var downbeatPhase: Int
    /// The raw tracked beats (not the grid) — shown faintly in the editor.
    var beats: [Double]
    /// 0...1, the share of tracked beats that sit on the grid within 40 ms.
    var gridConfidence: Double

    // Key
    var keyName: String       // "A minor"
    var camelot: String       // "8A"
    var keyConfidence: Double

    // Level and shape
    /// Overview for drawing: peak absolute sample per bin, `peaksPerSecond` bins per second.
    var peaks: [Float]
    var peaksPerSecond: Double
    /// RMS of the whole song, linear (0...1). Used for loudness matching.
    var rms: Float
    /// Auto in/out points: the first and last bar that isn't a quiet intro/outro.
    var suggestedIn: Double
    var suggestedOut: Double
    /// Sections, phrases, intro/outro/drops — what the transition planner reads.
    var structure: SongStructure?

    var beatLength: Double { 60.0 / bpm }
    var barLength: Double { beatLength * 4 }

    /// Time of the first downbeat at or after t = 0. `downbeatPhase` counts
    /// beats from the first grid beat at or after t = 0.
    var firstDownbeat: Double {
        let beat0 = beatOffset - floor(beatOffset / beatLength) * beatLength
        let d = beat0 + Double(downbeatPhase) * beatLength
        return d - floor(d / barLength) * barLength
    }

    func nearestBeat(to t: Double) -> Double {
        let k = ((t - beatOffset) / beatLength).rounded()
        return beatOffset + k * beatLength
    }

    func nearestDownbeat(to t: Double) -> Double {
        let k = ((t - firstDownbeat) / barLength).rounded()
        return firstDownbeat + k * barLength
    }

    func downbeat(atOrAfter t: Double) -> Double {
        let k = ((t - firstDownbeat) / barLength).rounded(.up)
        return firstDownbeat + k * barLength
    }

    func downbeat(atOrBefore t: Double) -> Double {
        let k = ((t - firstDownbeat) / barLength).rounded(.down)
        return firstDownbeat + k * barLength
    }

    /// Grid beats inside [from, to).
    func gridBeats(from: Double, to: Double) -> [Double] {
        guard bpm > 0, to > from else { return [] }
        let k0 = ((from - beatOffset) / beatLength).rounded(.up)
        var out: [Double] = []
        var k = k0
        while true {
            let t = beatOffset + k * beatLength
            if t >= to { break }
            out.append(t)
            k += 1
        }
        return out
    }

    func isDownbeat(_ t: Double) -> Bool {
        let k = ((t - beatOffset) / beatLength).rounded()
        return ((Int(k) - downbeatPhase) % 4 + 4) % 4 == 0
    }
}
