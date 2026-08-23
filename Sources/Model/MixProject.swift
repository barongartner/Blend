// A mix: an ordered list of songs, each with its own in/out points and the
// transition into the song after it, plus the mix-wide settings. Saved as JSON
// (.blendmix) and autosaved to Application Support between launches.

import Foundation

enum TransitionStyle: String, Codable, CaseIterable, Identifiable {
    case bassSwap, crossfade, filterSweep, cut
    var id: String { rawValue }

    var label: String {
        switch self {
        case .bassSwap: return "Bass swap"
        case .crossfade: return "Crossfade"
        case .filterSweep: return "Filter sweep"
        case .cut: return "Cut"
        }
    }

    var help: String {
        switch self {
        case .bassSwap: return "Highs crossfade; the bass switches over halfway — the standard club blend."
        case .crossfade: return "Plain equal-power crossfade of both songs."
        case .filterSweep: return "Outgoing song sinks under a low-pass filter while the new one opens up."
        case .cut: return "Hard cut on the downbeat. No overlap."
        }
    }
}

struct TransitionSettings: Codable, Hashable {
    var style: TransitionStyle = .bassSwap
    /// Bars of the outgoing song that overlap the incoming one (0 for cut).
    var overlapBars: Int = 8
    /// Time-stretch the incoming song to the outgoing tempo for the overlap.
    var tempoSync: Bool = true
    /// Bars over which the incoming song eases back to its own tempo afterwards.
    var rampBars: Int = 8

    static let overlapChoices = [1, 2, 4, 8, 16, 32]
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
