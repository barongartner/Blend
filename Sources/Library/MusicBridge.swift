// Talks to the Music app through osascript. Bulk reads use JavaScript for
// Automation (one call returns a whole playlist as JSON — AppleScript would
// need a string-building loop that is quadratic on big playlists); playback
// control uses plain AppleScript because creating and playing playlists is
// straightforward there.
//
// The first call triggers macOS's "Blend wants to control Music" prompt. The
// grant is keyed to Blend's signing identity + bundle ID (see build.sh).

import Foundation

struct MusicBridgeError: Error, CustomStringConvertible {
    let description: String
}

struct PlaybackStatus {
    enum State: String { case playing, paused, stopped }
    var state: State
    var position: Double      // seconds, -1 when nothing is loaded
    var persistentID: String  // of the current track, "" when none
}

enum MusicBridge {

    static let captureplaylistName = "Blend Capture"

    static var isMusicInstalled: Bool {
        FileManager.default.fileExists(atPath: "/System/Applications/Music.app")
    }

    // MARK: - Reads

    static func fetchPlaylists() throws -> [PlaylistInfo] {
        let script = """
        const m = Application('Music');
        const lib = m.libraryPlaylists[0];
        const out = [{name: 'Library', id: 'library', kind: 'library', smart: false, count: lib.tracks.length}];
        for (const p of m.userPlaylists()) {
            const kind = String(p.specialKind());
            if (kind !== 'none') continue;
            out.push({name: p.name(), id: p.persistentID(), kind: kind, smart: p.smart(), count: p.tracks.length});
        }
        JSON.stringify(out);
        """
        let json = try runJXA(script)
        struct Row: Decodable { let name: String; let id: String; let kind: String; let smart: Bool; let count: Int }
        let rows = try JSONDecoder().decode([Row].self, from: Data(json.utf8))
        return rows.map { PlaylistInfo(id: $0.id, name: $0.name, trackCount: $0.count, isSmart: $0.smart, isLibrary: $0.kind == "library") }
    }

    static func fetchTracks(playlistID: String) throws -> [TrackInfo] {
        let script = """
        function run(argv) {
            const m = Application('Music');
            const id = argv[0];
            let p;
            if (id === 'library') {
                p = m.libraryPlaylists[0];
            } else {
                const arr = m.playlists.whose({persistentID: id});
                if (arr.length === 0) return '[]';
                p = arr[0];
            }
            const t = p.tracks;
            const ids = t.persistentID(), names = t.name(), artists = t.artist(), albums = t.album(),
                  durs = t.duration(), cloud = t.cloudStatus(), kinds = t.kind(), bpm = t.bpm(),
                  mediaKind = t.mediaKind();
            const rows = [];
            for (let i = 0; i < ids.length; i++) {
                if (String(mediaKind[i]) !== 'song') continue;
                const c = String(cloud[i]);
                let loc = null;
                if (c !== 'subscription') {
                    try { const l = t[i].location(); loc = l ? l.toString() : null; } catch (e) { loc = null; }
                }
                rows.push({id: ids[i], name: names[i] || '', artist: artists[i] || '', album: albums[i] || '',
                           duration: durs[i] || 0, cloud: c, kind: kinds[i] || '', bpm: bpm[i] || 0, location: loc});
            }
            return JSON.stringify(rows);
        }
        """
        let json = try runJXA(script, arguments: [playlistID])
        struct Row: Decodable {
            let id: String; let name: String; let artist: String; let album: String
            let duration: Double; let cloud: String; let kind: String; let bpm: Double; let location: String?
        }
        let rows = try JSONDecoder().decode([Row].self, from: Data(json.utf8))
        return rows.map { r in
            let protected = r.kind.localizedCaseInsensitiveContains("protected") || r.cloud == "subscription"
            var path: String? = nil
            if !protected, let loc = r.location, FileManager.default.fileExists(atPath: loc),
               !loc.lowercased().hasSuffix(".m4p") {
                path = loc
            }
            return TrackInfo.music(persistentID: r.id, title: r.name, artist: r.artist, album: r.album,
                                   duration: r.duration, taggedBPM: r.bpm > 0 ? r.bpm : nil,
                                   localPath: path, needsCapture: path == nil)
        }
    }

    // MARK: - Playback control (capture)

    /// Current Music app output volume (0...100), so it can be restored after a capture.
    static func soundVolume() throws -> Int {
        let s = try runAppleScript("tell application \"Music\" to get sound volume")
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 100
    }

    static func setSoundVolume(_ v: Int) {
        _ = try? runAppleScript("tell application \"Music\" to set sound volume to \(max(0, min(100, v)))")
    }

    /// Puts exactly one track into the "Blend Capture" playlist and plays it. With
    /// repeat off and nothing after it, Music stops at the end — and crucially,
    /// Music's own crossfade/AutoMix has no next song to blend into.
    static func playForCapture(persistentID: String) throws {
        let script = """
        on run argv
            set pid to item 1 of argv
            tell application "Music"
                if not (exists user playlist "\(captureplaylistName)") then
                    make new user playlist with properties {name:"\(captureplaylistName)"}
                end if
                set capPL to user playlist "\(captureplaylistName)"
                try
                    delete every track of capPL
                end try
                set srcTracks to (every track of library playlist 1 whose persistent ID is pid)
                if (count of srcTracks) is 0 then error "Track not found in the Music library"
                duplicate (item 1 of srcTracks) to capPL
                set song repeat to off
                set shuffle enabled to false
                try
                    set EQ enabled to false
                end try
                set sound volume to 100
                play capPL
            end tell
        end run
        """
        _ = try runAppleScript(script, arguments: [persistentID])
    }

    static func playbackStatus() throws -> PlaybackStatus {
        let script = """
        tell application "Music"
            set st to "stopped"
            if player state is playing then set st to "playing"
            if player state is paused then set st to "paused"
            set pos to -1
            set pid to ""
            try
                set pos to player position
                set pid to persistent ID of current track
            end try
            return st & "|" & pos & "|" & pid
        end tell
        """
        let s = try runAppleScript(script).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.components(separatedBy: "|")
        guard parts.count == 3, let state = PlaybackStatus.State(rawValue: parts[0]) else {
            throw MusicBridgeError(description: "Unexpected player status: \(s)")
        }
        return PlaybackStatus(state: state, position: Double(parts[1]) ?? -1, persistentID: parts[2])
    }

    static func stop() {
        _ = try? runAppleScript("tell application \"Music\" to stop")
    }

    static func seek(to seconds: Double) {
        _ = try? runAppleScript("tell application \"Music\" to set player position to \(seconds)")
    }

    static func removeCapturePlaylist() {
        _ = try? runAppleScript("""
        tell application "Music"
            if exists user playlist "\(captureplaylistName)" then delete user playlist "\(captureplaylistName)"
        end tell
        """)
    }

    static func launchMusic() {
        _ = try? runAppleScript("tell application \"Music\" to launch")
    }

    // MARK: - osascript plumbing

    private static func runJXA(_ source: String, arguments: [String] = []) throws -> String {
        try runOSAScript(source, language: "JavaScript", arguments: arguments)
    }

    private static func runAppleScript(_ source: String, arguments: [String] = []) throws -> String {
        try runOSAScript(source, language: "AppleScript", arguments: arguments)
    }

    private static func runOSAScript(_ source: String, language: String, arguments: [String]) throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("blend-\(UUID().uuidString).\(language == "JavaScript" ? "js" : "applescript")")
        try source.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-l", language, tmp.path] + arguments
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if msg.contains("-1743") || msg.localizedCaseInsensitiveContains("not allowed") {
                throw MusicBridgeError(description: "Blend isn't allowed to control Music. Open System Settings → Privacy & Security → Automation, turn on Music under Blend, then reload (⌘R).")
            }
            if msg.contains("-1712") {
                throw MusicBridgeError(description: "Music didn't answer in time. If macOS showed a \"Blend wants to control Music\" prompt, click Allow and reload (⌘R); otherwise check System Settings → Privacy & Security → Automation → Blend → Music.")
            }
            throw MusicBridgeError(description: msg.isEmpty ? "osascript failed (\(proc.terminationStatus))" : msg)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
