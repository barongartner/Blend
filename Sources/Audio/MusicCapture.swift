// Getting audio out of Apple Music. Subscription tracks are FairPlay files we
// can't open, so Blend records the Music app playing them — silently, via a
// Core Audio process tap with the process muted at the speaker — into a float
// CAF in Blend's cache. It's real time (a 4-minute song takes 4 minutes), but
// it only ever happens once per song.
//
// Flow: make sure Music is running → find its audio process object (Music has
// to have played *something* since launch for one to exist, so the first
// capture of a session starts playback, waits for the object, then restarts
// the song from the top) → tap + aggregate → IOProc appends frames → play the
// song alone in a "Blend Capture" playlist with repeat off → poll Music until
// it stops → trim leading/trailing digital silence → write the CAF.
//
// Permissions: System Audio Recording (prompted on the first AudioDeviceStart,
// which BLOCKS until answered — never call on the main thread) and Automation
// for Music (prompted by the first osascript).

import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import AVFoundation

struct CaptureError: Error, CustomStringConvertible {
    let description: String
}

final class MusicCapture {

    struct Result {
        let url: URL
        let duration: Double
        let sampleRate: Double
    }

    static let musicBundleID = "com.apple.Music"

    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Blend/Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cachedURL(for persistentID: String) -> URL {
        cacheDirectory.appendingPathComponent("\(persistentID).caf")
    }

    static func isCached(_ persistentID: String) -> Bool {
        FileManager.default.fileExists(atPath: cachedURL(for: persistentID).path)
    }

    // MARK: - Recording state (shared with the IO thread)

    private final class Recording {
        var lock = os_unfair_lock()
        var samples: [Float] = []      // interleaved
        var channels = 2
        var droppedCallbacks = 0
    }

    /// Captures one Music track. Blocking; run on a background queue.
    static func capture(track: TrackInfo, progress: @escaping (Double, String) -> Void, isCancelled: @escaping () -> Bool) throws -> Result {
        guard let pid = track.persistentID else { throw CaptureError(description: "Not a Music track") }
        progress(0, "Opening Music…")

        // 1. Music running?
        MusicBridge.launchMusic()
        var musicApp: NSRunningApplication?
        for _ in 0..<40 {
            musicApp = NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID).first
            if musicApp != nil { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let musicApp else { throw CaptureError(description: "The Music app didn't launch.") }
        let originalVolume = (try? MusicBridge.soundVolume()) ?? 100
        defer { MusicBridge.setSoundVolume(originalVolume) }

        // 2. Music's audio process object. If it hasn't made a sound yet there is none;
        //    start the song so one appears, then we'll restart it once the tap is live.
        var processObject = CA.translatePID(musicApp.processIdentifier)
        var startedEarly = false
        if processObject == nil {
            progress(0, "Waking Music's audio…")
            try MusicBridge.playForCapture(persistentID: pid)
            startedEarly = true
            for _ in 0..<60 {
                if isCancelled() { MusicBridge.stop(); throw CaptureError(description: "Cancelled") }
                Thread.sleep(forTimeInterval: 0.25)
                processObject = CA.translatePID(musicApp.processIdentifier)
                if processObject != nil { break }
            }
        }
        guard let processObject else {
            MusicBridge.stop()
            throw CaptureError(description: "Music never produced audio. Is this song playable (subscription active, song available in your country)?")
        }

        // 3. Tap + aggregate on the default output device.
        guard let outDev = CA.defaultOutputDevice(), let outUID = CA.deviceUID(outDev) else {
            throw CaptureError(description: "No default output device.")
        }
        BlendLog.write("capture: Music pid \(musicApp.processIdentifier), audio object \(processObject), output \(outUID)")
        let tap = try TapAggregate(processObjectID: processObject, destinationUID: outUID, mute: true)
        BlendLog.write("capture: tap format \(Int(tap.format.mSampleRate)) Hz, \(tap.format.mChannelsPerFrame) ch")
        defer { tap.invalidate() }
        let channels = max(1, Int(tap.format.mChannelsPerFrame))
        let sampleRate = tap.format.mSampleRate
        let rec = Recording()
        rec.channels = channels
        rec.samples.reserveCapacity(Int(sampleRate) * channels * Int(track.duration + 30))

        var ioProcID: AudioDeviceIOProcID?
        var err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, tap.aggregateID, nil) { _, inInputData, _, outOutputData, _ in
            // Silence the aggregate's output side (we never play anything through it).
            let outABL = UnsafeMutableAudioBufferListPointer(outOutputData)
            for buf in outABL where buf.mData != nil { memset(buf.mData, 0, Int(buf.mDataByteSize)) }

            let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let inBuf = inABL.first(where: { $0.mData != nil }), let data = inBuf.mData else { return }
            let ch = max(1, Int(inBuf.mNumberChannels))
            let frames = Int(inBuf.mDataByteSize) / (MemoryLayout<Float32>.size * ch)
            guard frames > 0 else { return }
            let p = data.bindMemory(to: Float32.self, capacity: frames * ch)
            if os_unfair_lock_trylock(&rec.lock) {
                rec.channels = ch
                rec.samples.append(contentsOf: UnsafeBufferPointer(start: p, count: frames * ch))
                os_unfair_lock_unlock(&rec.lock)
            } else {
                rec.droppedCallbacks += 1
            }
        }
        guard err == noErr, let ioProcID else { throw CaptureError(description: "IOProc creation failed (\(err))") }
        defer {
            AudioDeviceStop(tap.aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(tap.aggregateID, ioProcID)
        }
        progress(0, "Starting capture (allow System Audio Recording if asked)…")
        err = AudioDeviceStart(tap.aggregateID, ioProcID)   // blocks on the permission prompt the first time
        guard err == noErr else { throw CaptureError(description: "Couldn't start the capture device (\(err)).") }
        BlendLog.write("capture: device started")

        // 4. Play the song from the top.
        if startedEarly { MusicBridge.stop(); Thread.sleep(forTimeInterval: 0.3) }
        let markerFrames: Int = {
            os_unfair_lock_lock(&rec.lock); defer { os_unfair_lock_unlock(&rec.lock) }
            return rec.samples.count / rec.channels
        }()
        try MusicBridge.playForCapture(persistentID: pid)
        defer { MusicBridge.stop() }

        // 5. Wait for playback to start, then for it to end.
        var status: PlaybackStatus?
        let startDeadline = Date().addingTimeInterval(20)
        while Date() < startDeadline {
            if isCancelled() { throw CaptureError(description: "Cancelled") }
            status = try? MusicBridge.playbackStatus()
            if let s = status, s.state == .playing, s.persistentID == pid { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let s0 = status, s0.state == .playing, s0.persistentID == pid else {
            throw CaptureError(description: "Music didn't start playing \(track.title). Check that it plays in Music itself.")
        }
        let expected = max(track.duration, 1)
        var lastPos = -1.0
        var lastAdvance = Date()
        let hardDeadline = Date().addingTimeInterval(expected + 45)
        progress(0.01, "Recording…")
        while true {
            if isCancelled() { throw CaptureError(description: "Cancelled") }
            Thread.sleep(forTimeInterval: 0.3)
            guard let s = try? MusicBridge.playbackStatus() else { continue }
            if s.state == .stopped || (s.persistentID != pid && !s.persistentID.isEmpty) { break }
            if s.state == .paused { throw CaptureError(description: "Playback was paused in Music — capture aborted.") }
            if s.position > lastPos + 0.01 { lastPos = s.position; lastAdvance = Date() }
            else if Date().timeIntervalSince(lastAdvance) > 15 { throw CaptureError(description: "Playback stalled (streaming problem?).") }
            if Date() > hardDeadline { throw CaptureError(description: "Playback ran far past the song's length.") }
            progress(min(0.99, max(0.01, s.position / expected)), "Recording \(formatTime(s.position)) / \(formatTime(expected))")
        }
        Thread.sleep(forTimeInterval: 0.4)   // let the last buffers arrive

        // 6. Trim and save.
        let interleaved: [Float] = {
            os_unfair_lock_lock(&rec.lock); defer { os_unfair_lock_unlock(&rec.lock) }
            return Array(rec.samples[min(rec.samples.count, markerFrames * rec.channels)...])
        }()
        let ch = rec.channels
        let frames = interleaved.count / ch
        guard frames > Int(sampleRate) else { throw CaptureError(description: "Nothing was recorded.") }
        let threshold: Float = 1e-4
        var first = -1, last = -1
        for f in 0..<frames {
            var audible = false
            for c in 0..<ch where abs(interleaved[f * ch + c]) > threshold { audible = true; break }
            if audible { if first < 0 { first = f }; last = f }
        }
        guard first >= 0, last > first else {
            throw CaptureError(description: "Captured only silence. Either macOS hasn't granted Blend System Audio Recording (System Settings → Privacy & Security → Screen & System Audio Recording), or this song's audio is protected from capture.")
        }
        let captured = last - first + 1
        let capturedSeconds = Double(captured) / sampleRate
        BlendLog.write("capture: \(frames) frames recorded, audible \(first)...\(last) = \(String(format: "%.2f", capturedSeconds))s (expected \(String(format: "%.2f", expected))s), dropped callbacks \(rec.droppedCallbacks)")
        if capturedSeconds < expected * 0.8 {
            throw CaptureError(description: "Capture came out too short (\(formatTime(capturedSeconds)) of \(formatTime(expected))). Try again.")
        }
        progress(0.995, "Saving…")
        let url = cachedURL(for: pid)
        try writeCAF(interleaved: interleaved, firstFrame: first, frameCount: captured, channels: ch, sampleRate: sampleRate, to: url)
        return Result(url: url, duration: capturedSeconds, sampleRate: sampleRate)
    }

    private static func writeCAF(interleaved: [Float], firstFrame: Int, frameCount: Int, channels: Int, sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false) else {
            throw CaptureError(description: "Bad format")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 1 << 16
        var pos = 0
        while pos < frameCount {
            let n = min(chunk, frameCount - pos)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
            for i in 0..<n {
                let base = (firstFrame + pos + i) * channels
                l[i] = interleaved[base]
                r[i] = channels >= 2 ? interleaved[base + 1] : interleaved[base]
            }
            try file.write(from: buf)
            pos += n
        }
    }

    static func formatTime(_ t: Double) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
