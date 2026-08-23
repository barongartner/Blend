// Background work: loading the Music library, importing files, getting audio
// for each song (capture when it's Apple Music), analysis, rendering and the
// preview player. Everything reports to AppModel on the main actor.

import Foundation
import AVFoundation
import AppKit

@MainActor
final class Services {

    weak var model: AppModel?

    private let libraryQueue = DispatchQueue(label: "blend.library", qos: .userInitiated)
    private let captureQueue = DispatchQueue(label: "blend.capture", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "blend.analysis", qos: .userInitiated)
    private let renderQueue = DispatchQueue(label: "blend.render", qos: .userInitiated)
    private let clipCache = ClipCache(capacity: 3)
    let preview = PreviewPlayer()

    private var captureRunning = false
    private var pendingCaptures: [TrackInfo] = []
    private var analysisInFlight: Set<String> = []
    private let cancelCapture = CancelFlag()
    private let cancelRender = CancelFlag()

    // MARK: - Library

    func loadPlaylists() {
        guard let model else { return }
        model.isLoadingLibrary = true
        model.libraryError = nil
        libraryQueue.async {
            let result = Result { try MusicBridge.fetchPlaylists() }
            Task { @MainActor in
                model.isLoadingLibrary = false
                switch result {
                case .success(let pls):
                    BlendLog.write("library: \(pls.count) playlists")
                    model.playlists = pls
                    if model.selection == nil, let first = pls.first { model.selection = .playlist(first.id) }
                case .failure(let err):
                    BlendLog.write("library error: \(err)")
                    model.libraryError = "\(err)"
                }
            }
        }
    }

    func loadTracks(playlistID: String, force: Bool = false) {
        guard let model else { return }
        if !force, model.playlistTracks[playlistID] != nil { return }
        model.loadingPlaylist = playlistID
        libraryQueue.async {
            let result = Result { try MusicBridge.fetchTracks(playlistID: playlistID) }
            Task { @MainActor in
                if model.loadingPlaylist == playlistID { model.loadingPlaylist = nil }
                switch result {
                case .success(let tracks):
                    BlendLog.write("playlist \(playlistID): \(tracks.count) songs, \(tracks.filter { $0.needsCapture }.count) need capture")
                    model.playlistTracks[playlistID] = tracks
                case .failure(let err):
                    BlendLog.write("playlist \(playlistID) error: \(err)")
                    model.libraryError = "\(err)"
                }
            }
        }
    }

    // MARK: - Files (MP3 mode)

    nonisolated static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf", "mp4", "m4b", "aifc"]

    func importFiles(_ urls: [URL]) {
        guard let model else { return }
        libraryQueue.async {
            var found: [URL] = []
            for url in urls {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
                        for case let f as URL in en where Services.audioExtensions.contains(f.pathExtension.lowercased()) { found.append(f) }
                    }
                } else if Services.audioExtensions.contains(url.pathExtension.lowercased()) {
                    found.append(url)
                }
            }
            found.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            var tracks: [TrackInfo] = []
            for f in found {
                guard let duration = AudioDecoder.duration(of: f) else { continue }
                let meta = Services.metadata(of: f)
                tracks.append(TrackInfo.file(path: f.path, title: meta.title ?? f.deletingPathExtension().lastPathComponent,
                                             artist: meta.artist ?? "", album: meta.album ?? "", duration: duration, taggedBPM: meta.bpm))
            }
            Task { @MainActor in
                var existing = model.fileTracks
                for t in tracks where !existing.contains(where: { $0.id == t.id }) { existing.append(t) }
                model.fileTracks = existing
                model.selection = .files
            }
        }
    }

    nonisolated private static func metadata(of url: URL) -> (title: String?, artist: String?, album: String?, bpm: Double?) {
        let asset = AVURLAsset(url: url)
        var title: String?, artist: String?, album: String?, bpm: Double?
        let sem = DispatchSemaphore(value: 0)
        Task {
            defer { sem.signal() }
            guard let common = try? await asset.load(.commonMetadata) else { return }
            for item in common {
                guard let key = item.commonKey?.rawValue, let v = try? await item.load(.stringValue) else { continue }
                switch key {
                case "title": title = v
                case "artist": artist = v
                case "albumName": album = v
                default: break
                }
            }
            if let all = try? await asset.load(.metadata) {
                for item in all where (item.identifier?.rawValue ?? "").lowercased().contains("tbpm") || (item.key as? String) == "TBPM" {
                    if let v = try? await item.load(.stringValue), let d = Double(v) { bpm = d }
                }
            }
        }
        _ = sem.wait(timeout: .now() + 5)
        return (title, artist, album, bpm)
    }

    // MARK: - Audio availability

    func audioURL(for track: TrackInfo) -> URL? {
        if let p = track.localPath, FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        if let pid = track.persistentID, MusicCapture.isCached(pid) { return MusicCapture.cachedURL(for: pid) }
        return nil
    }

    // MARK: - Prepare (capture → analyze)

    func prepareAll() {
        guard let model else { return }
        for e in model.project.entries { prepare(e.track) }
    }

    func prepare(_ track: TrackInfo) {
        guard let model else { return }
        if let url = audioURL(for: track) {
            if model.analyses[track.id] == nil {
                if let data = try? Data(contentsOf: AppModel.analysisURL(for: track.id)),
                   let a = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
                   a.version == TrackAnalysis.currentVersion {
                    model.storeAnalysis(a, for: track.id)
                } else {
                    analyze(track, url: url)
                }
            }
            return
        }
        guard track.persistentID != nil else {
            model.status[track.id, default: TrackStatus()].availability = .failed("File is missing: \(track.localPath ?? "?")")
            return
        }
        enqueueCapture(track)
    }

    private func enqueueCapture(_ track: TrackInfo) {
        guard let model else { return }
        guard !pendingCaptures.contains(where: { $0.id == track.id }), model.activeCapture?.trackID != track.id else { return }
        pendingCaptures.append(track)
        model.captureQueue = pendingCaptures.map { $0.id }
        model.status[track.id, default: TrackStatus()].availability = .needsCapture
        runNextCapture()
    }

    func cancelCaptures() {
        pendingCaptures.removeAll()
        model?.captureQueue = []
        cancelCapture.set()
    }

    private func runNextCapture() {
        guard let model, !captureRunning, !pendingCaptures.isEmpty else { return }
        let track = pendingCaptures.removeFirst()
        model.captureQueue = pendingCaptures.map { $0.id }
        captureRunning = true
        cancelCapture.reset()
        model.activeCapture = (track.id, 0, "Starting…")
        model.status[track.id, default: TrackStatus()].availability = .capturing(0)
        let cancelCapture = self.cancelCapture
        BlendLog.write("capture start: \(track.title) [\(track.persistentID ?? "?")] \(Int(track.duration))s")
        captureQueue.async { [weak self] in
            let result = Result {
                try MusicCapture.capture(track: track, progress: { p, msg in
                    Task { @MainActor in
                        model.activeCapture = (track.id, p, msg)
                        model.status[track.id, default: TrackStatus()].availability = .capturing(p)
                    }
                }, isCancelled: { cancelCapture.isSet })
            }
            Task { @MainActor in
                guard let self else { return }
                self.captureRunning = false
                model.activeCapture = nil
                switch result {
                case .success(let r):
                    BlendLog.write("capture done: \(track.title) → \(r.url.lastPathComponent), \(String(format: "%.1f", r.duration))s @ \(Int(r.sampleRate)) Hz")
                    model.status[track.id, default: TrackStatus()].availability = .ready(r.url)
                    self.analyze(track, url: r.url)
                case .failure(let err):
                    BlendLog.write("capture FAILED: \(track.title): \(err)")
                    model.status[track.id, default: TrackStatus()].availability = .failed("\(err)")
                    if !cancelCapture.isSet {
                        model.alert = AppModel.AlertItem(title: "Couldn't capture \(track.title)", message: "\(err)")
                    }
                }
                self.runNextCapture()
            }
        }
    }

    func analyze(_ track: TrackInfo, url: URL, force: Bool = false) {
        guard let model else { return }
        guard !analysisInFlight.contains(track.id) else { return }
        analysisInFlight.insert(track.id)
        model.status[track.id, default: TrackStatus()].analyzing = true
        let sr = model.project.settings.sampleRate
        let cache = clipCache
        analysisQueue.async { [weak self] in
            let result = Result { () -> TrackAnalysis in
                let clip = try cache.clip(for: track.id, url: url, sampleRate: sr)
                return TrackAnalyzer.analyze(clip: clip, taggedBPM: track.taggedBPM)
            }
            Task { @MainActor in
                guard let self else { return }
                self.analysisInFlight.remove(track.id)
                model.status[track.id, default: TrackStatus()].analyzing = false
                switch result {
                case .success(let a):
                    BlendLog.write("analyzed: \(track.title): \(String(format: "%.2f", a.bpm)) BPM, \(a.keyName), downbeat \(String(format: "%.3f", a.firstDownbeat)), grid \(String(format: "%.2f", a.gridConfidence)), in \(String(format: "%.1f", a.suggestedIn)) out \(String(format: "%.1f", a.suggestedOut))")
                    model.storeAnalysis(a, for: track.id)
                case .failure(let err):
                    BlendLog.write("analysis FAILED: \(track.title): \(err)")
                    model.status[track.id, default: TrackStatus()].error = "\(err)"
                    model.alert = AppModel.AlertItem(title: "Couldn't analyze \(track.title)", message: "\(err)")
                }
            }
        }
    }

    func reanalyze(_ track: TrackInfo) {
        guard let url = audioURL(for: track) else { return }
        model?.analyses[track.id] = nil
        analyze(track, url: url, force: true)
    }

    func recapture(_ track: TrackInfo) {
        guard let pid = track.persistentID else { return }
        try? FileManager.default.removeItem(at: MusicCapture.cachedURL(for: pid))
        model?.analyses[track.id] = nil
        clipCache.remove(track.id)
        model?.refreshStatuses()
        enqueueCapture(track)
    }

    // MARK: - Render & export

    func makeRenderer() -> MixRenderer? {
        guard let model else { return nil }
        let layout = model.layout
        let entries = layout.entries
        let settings = model.project.settings
        let urls: [URL?] = entries.map { audioURL(for: $0.entry.track) }
        let ids = entries.map { $0.entry.track.id }
        let cache = clipCache
        return MixRenderer(layout: layout, entries: entries, settings: settings) { i in
            guard let url = urls[i] else { throw RenderError(description: "No audio yet for \(entries[i].title)") }
            return try cache.clip(for: ids[i], url: url, sampleRate: settings.sampleRate)
        }
    }

    func export(to dest: URL) {
        guard let model, let renderer = makeRenderer() else { return }
        let format = model.project.settings.exportFormat
        let sr = model.project.settings.sampleRate
        model.renderProgress = 0
        model.renderMessage = "Rendering…"
        cancelRender.reset()
        let cancelRender = self.cancelRender
        let master = AppModel.supportDirectory.appendingPathComponent("master.caf")
        renderQueue.async {
            let result = Result {
                let r = try renderer.render(to: master, progress: { p in
                    Task { @MainActor in model.renderProgress = p * 0.9; model.renderMessage = "Rendering… \(Int(p * 100))%" }
                }, isCancelled: { cancelRender.isSet })
                Task { @MainActor in model.renderProgress = 0.92; model.renderMessage = "Encoding \(format.label)…" }
                try Exporter.export(master: master, peak: r.peak, to: dest, format: format, sampleRate: sr, ffmpeg: Exporter.findFFmpeg())
                return r
            }
            Task { @MainActor in
                model.renderProgress = nil
                model.renderMessage = nil
                switch result {
                case .success(let r):
                    BlendLog.write("exported \(dest.lastPathComponent): \(r.frames) frames, peak \(String(format: "%.3f", r.peak))")
                    model.lastExportURL = dest
                case .failure(let err):
                    BlendLog.write("export FAILED: \(err)")
                    if !cancelRender.isSet {
                        model.alert = AppModel.AlertItem(title: "Export failed", message: "\(err)")
                    }
                }
            }
        }
    }

    func cancelExport() { cancelRender.set() }

    // MARK: - Preview

    /// Plays the transition into entry `index` (a few seconds each side).
    func previewTransition(into index: Int) {
        guard let model, index > 0, let renderer = makeRenderer() else { return }
        let lay = model.layout
        guard index < lay.tracks.count else { return }
        let t = lay.tracks[index]
        let sr = lay.sampleRate
        let lead = Int(sr * 6)
        let from = max(0, t.start - lead)
        let to = min(lay.totalSamples, t.soloStart + Int(sr * 6) + (t.entryOverlap == 0 ? Int(sr * 4) : 0))
        let id = "transition-\(index)"
        model.previewPlaying = id
        let player = preview
        renderQueue.async {
            let result = Result { try renderer.compose(from: from, to: to) }
            Task { @MainActor in
                switch result {
                case .success(let buf):
                    player.play(buf, sampleRate: sr, id: id) { model.previewPlaying = nil }
                case .failure(let err):
                    model.previewPlaying = nil
                    model.alert = AppModel.AlertItem(title: "Can't preview", message: "\(err)")
                }
            }
        }
    }

    /// Plays `seconds` of a song from `start`, level matched like the mix.
    func previewSong(_ track: TrackInfo, from start: Double, seconds: Double, id: String) {
        guard let model, let url = audioURL(for: track) else { return }
        let sr = model.project.settings.sampleRate
        model.previewPlaying = id
        let cache = clipCache
        let player = preview
        renderQueue.async {
            let result = Result { try cache.clip(for: track.id, url: url, sampleRate: sr) }
            Task { @MainActor in
                switch result {
                case .success(let clip):
                    let s = max(0, min(clip.frameCount, Int(start * sr)))
                    let e = max(s, min(clip.frameCount, Int((start + seconds) * sr)))
                    let o = TimeStretch.copy(source: clip, from: s, count: e - s)
                    player.play(StereoBuffer(left: o.left, right: o.right), sampleRate: sr, id: id) { model.previewPlaying = nil }
                case .failure(let err):
                    model.previewPlaying = nil
                    model.alert = AppModel.AlertItem(title: "Can't play", message: "\(err)")
                }
            }
        }
    }

    func stopPreview() {
        preview.stop()
        model?.previewPlaying = nil
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
    func reset() { lock.lock(); flag = false; lock.unlock() }
}

// MARK: - Clip cache

final class ClipCache {
    private var clips: [String: (clip: AudioClip, sampleRate: Double)] = [:]
    private var order: [String] = []
    private let lock = NSLock()
    let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    func clip(for id: String, url: URL, sampleRate: Double) throws -> AudioClip {
        lock.lock()
        if let c = clips[id], abs(c.sampleRate - sampleRate) < 1 {
            order.removeAll { $0 == id }
            order.append(id)
            lock.unlock()
            return c.clip
        }
        lock.unlock()
        let clip = try AudioDecoder.decode(url: url, sampleRate: sampleRate)
        lock.lock()
        clips[id] = (clip, sampleRate)
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > capacity {
            let evict = order.removeFirst()
            clips[evict] = nil
        }
        lock.unlock()
        return clip
    }

    func remove(_ id: String) {
        lock.lock()
        clips[id] = nil
        order.removeAll { $0 == id }
        lock.unlock()
    }
}

// MARK: - Preview player

final class PreviewPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var currentFormat: AVAudioFormat?
    private var completion: (() -> Void)?

    init() {
        engine.attach(node)
    }

    func play(_ buf: StereoBuffer, sampleRate: Double, id: String, onFinish: @escaping () -> Void) {
        stop()
        guard buf.count > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(buf.count)) else { onFinish(); return }
        pcm.frameLength = AVAudioFrameCount(buf.count)
        buf.left.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: buf.count) }
        buf.right.withUnsafeBufferPointer { pcm.floatChannelData![1].update(from: $0.baseAddress!, count: buf.count) }
        if currentFormat == nil || currentFormat!.sampleRate != sampleRate {
            engine.stop()
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            currentFormat = format
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            onFinish()
            return
        }
        completion = onFinish
        node.scheduleBuffer(pcm, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.completion != nil else { return }
                let c = self.completion
                self.completion = nil
                c?()
            }
        }
        node.play()
    }

    func stop() {
        completion = nil
        node.stop()
    }
}
