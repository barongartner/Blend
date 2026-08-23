// The two kinds of song Blend can mix, and what we know about each before any
// audio has been decoded.
//
//  - `.music`: a track in the Music app's library, identified by its persistent
//    ID. Almost always an Apple Music subscription track, which means no file
//    we can open — the audio has to be captured from the Music app (see
//    MusicCapture). Local, DRM-free library tracks carry a `localPath` and are
//    decoded directly.
//  - `.file`: an audio file the user dropped in (MP3 mode: YouTube rips etc.).

import Foundation

enum TrackSource: Codable, Hashable {
    case music(persistentID: String)
    case file(path: String)
}

struct TrackInfo: Identifiable, Codable, Hashable {
    let id: String
    var source: TrackSource
    var title: String
    var artist: String
    var album: String
    /// Seconds, from metadata. The decoded audio is authoritative once we have it.
    var duration: Double
    var taggedBPM: Double?
    /// A file we can open directly, if there is one.
    var localPath: String?
    /// True when the only way to get the audio is capturing Music app playback.
    var needsCapture: Bool
    /// The Music playlist the song was picked from ("library" for the whole
    /// library). Apple Music playlists can hold songs that were never added to
    /// the library, so captures look the song up there first.
    var playlistID: String?

    static func music(persistentID: String, title: String, artist: String, album: String,
                      duration: Double, taggedBPM: Double?, localPath: String?, needsCapture: Bool, playlistID: String?) -> TrackInfo {
        TrackInfo(id: "music:\(persistentID)", source: .music(persistentID: persistentID),
                  title: title, artist: artist, album: album, duration: duration,
                  taggedBPM: taggedBPM, localPath: localPath, needsCapture: needsCapture, playlistID: playlistID)
    }

    static func file(path: String, title: String, artist: String, album: String, duration: Double, taggedBPM: Double?) -> TrackInfo {
        TrackInfo(id: "file:\(path)", source: .file(path: path),
                  title: title, artist: artist, album: album, duration: duration,
                  taggedBPM: taggedBPM, localPath: path, needsCapture: false, playlistID: nil)
    }

    var persistentID: String? {
        if case .music(let pid) = source { return pid }
        return nil
    }

    var displayArtist: String { artist.isEmpty ? "Unknown Artist" : artist }
}

struct PlaylistInfo: Identifiable, Hashable {
    let id: String          // Music persistent ID
    var name: String
    var trackCount: Int
    var isSmart: Bool
    var isLibrary: Bool     // the whole-library pseudo playlist
}

/// Where a track's audio currently lives, from Blend's point of view.
enum AudioAvailability: Equatable {
    case ready(URL)          // decodable file (local track, imported file, or a finished capture)
    case needsCapture        // Apple Music track not captured yet
    case capturing(Double)   // progress 0..1
    case failed(String)
}
