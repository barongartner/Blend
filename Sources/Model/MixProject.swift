// A mix: an ordered list of songs, each with its own in/out points and the
// transition into the song after it, plus the mix-wide settings. Saved as JSON
// (.blendmix) and autosaved to Application Support between launches.

import Foundation

enum TransitionStyle: String, Codable, CaseIterable, Identifiable {
    case auto, blend, echoOut, filterDrop, cut
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .blend: return "Blend"
        case .echoOut: return "Echo out"
        case .filterDrop: return "Filter drop"
        case .cut: return "Cut"
        }
    }

    var help: String {
        switch self {
        case .auto: return "Picks per pair: a blend when both songs have room for it and the keys agree, otherwise an echo-out or filter drop on the phrase."
        case .blend: return "The next song comes in filtered under this song's outro, the bass hands over halfway, this song's highs roll off. Needs an outro and an intro."
        case .echoOut: return "This song's last beat echoes away in time while the next song starts clean on the 1. The go-to for songs with vocals or different tempos."
        case .filterDrop: return "This song thins out under a rising high-pass over the last bars, then cuts as the next song drops on the 1."
        case .cut: return "Hard cut on the phrase boundary."
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "bassSwap": self = .auto          // 1.0's default; nobody chose it
        case "crossfade": self = .blend
        case "filterSweep": self = .filterDrop
        default: self = TransitionStyle(rawValue: raw) ?? .auto
        }
    }

    /// The explicit style matching a resolved one (for its description).
    static func describe(_ resolved: ResolvedStyle) -> TransitionStyle {
        switch resolved {
        case .blend: return .blend
        case .echoOut: return .echoOut
        case .filterDrop: return .filterDrop
        case .cut: return .cut
        }
    }
}

struct TransitionSettings: Codable, Hashable {
    var style: TransitionStyle = .auto
    /// Bars of overlap for a blend, or of filter sweep for a filter drop. 0 = auto.
    var overlapBars: Int = 0
    /// Time-stretch the incoming song to the outgoing tempo for the overlap.
    var tempoSync: Bool = true
    /// Bars over which the incoming song eases back to its own tempo afterwards.
    var rampBars: Int = 8
    /// Bars the echo tail rings out over (echo out / filter drop).
    var tailBars: Int = 2
    /// Noise riser under the last bars of a filter drop.
    var riser: Bool = false

    static let overlapChoices = [0, 2, 4, 8, 16]

    init() {}

    init(style: TransitionStyle, overlapBars: Int = 0, tempoSync: Bool = true, rampBars: Int = 8, tailBars: Int = 2, riser: Bool = false) {
        self.style = style; self.overlapBars = overlapBars; self.tempoSync = tempoSync
        self.rampBars = rampBars; self.tailBars = tailBars; self.riser = riser
    }

    enum CodingKeys: String, CodingKey { case style, overlapBars, tempoSync, rampBars, tailBars, riser }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decodeIfPresent(TransitionStyle.self, forKey: .style) ?? .auto
        overlapBars = try c.decodeIfPresent(Int.self, forKey: .overlapBars) ?? 0
        tempoSync = try c.decodeIfPresent(Bool.self, forKey: .tempoSync) ?? true
        rampBars = try c.decodeIfPresent(Int.self, forKey: .rampBars) ?? 8
        tailBars = try c.decodeIfPresent(Int.self, forKey: .tailBars) ?? 2
        riser = try c.decodeIfPresent(Bool.self, forKey: .riser) ?? false
    }
}

struct MixEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var track: TrackInfo
    /// Seconds into the song. nil = use the analyzer's suggestion.
    var inTime: Double?
    var outTime: Double?
    var bpmOverride: Double?
    /// Moves the downbeat by this many beats (mod 4) when the analyzer guessed wrong.
    var downbeatShift: Int = 0
    /// Slides the whole beat grid by this many seconds (half-beat fixes, fine nudges).
    var gridShift: Double = 0
    /// Manual trim in dB on top of loudness matching.
    var gainDB: Double = 0
    /// The transition from this song into the next one.
    var transition: TransitionSettings = TransitionSettings()

    init(track: TrackInfo) { self.track = track }

    enum CodingKeys: String, CodingKey { case id, track, inTime, outTime, bpmOverride, downbeatShift, gridShift, gainDB, transition }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        track = try c.decode(TrackInfo.self, forKey: .track)
        inTime = try c.decodeIfPresent(Double.self, forKey: .inTime)
        outTime = try c.decodeIfPresent(Double.self, forKey: .outTime)
        bpmOverride = try c.decodeIfPresent(Double.self, forKey: .bpmOverride)
        downbeatShift = try c.decodeIfPresent(Int.self, forKey: .downbeatShift) ?? 0
        gridShift = try c.decodeIfPresent(Double.self, forKey: .gridShift) ?? 0
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        transition = try c.decodeIfPresent(TransitionSettings.self, forKey: .transition) ?? TransitionSettings()
    }
}

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case wav24, wav16, mp3, m4a
    var id: String { rawValue }
    var label: String {
        switch self {
        case .wav24: return "WAV (24-bit)"
        case .wav16: return "WAV (16-bit)"
        case .mp3: return "MP3 (320 kbps)"
        case .m4a: return "AAC (.m4a, 256 kbps)"
        }
    }
    var fileExtension: String {
        switch self {
        case .wav24, .wav16: return "wav"
        case .mp3: return "mp3"
        case .m4a: return "m4a"
        }
    }
}

struct MixSettings: Codable, Hashable {
    var sampleRate: Double = 48000
    /// The video's length, if known. Blend shows how far off the mix is.
    var targetLength: Double?
    var matchLoudness: Bool = true
    /// Fade the very end of the mix over this many seconds (0 = none).
    var endFadeSeconds: Double = 0
    /// Keep pitch while tempo-matching (WSOLA). Off = vinyl-style pitch shift.
    var keyLock: Bool = true
    var exportFormat: ExportFormat = .wav24
}

struct MixProject: Codable {
    var name: String = "Untitled Mix"
    var entries: [MixEntry] = []
    var settings: MixSettings = MixSettings()
}
