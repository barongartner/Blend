// All app state in one observable object, plus persistence. Services
// (library loading, capture, analysis, rendering, preview) live in
// Services.swift and report back here on the main actor.

import Foundation
import SwiftUI
import Combine

enum SourceSelection: Hashable {
    case playlist(String)
    case files
}

struct TrackStatus: Equatable {
    var availability: AudioAvailability = .needsCapture
    var analyzed: Bool = false
    var analyzing: Bool = false
    var error: String?
}

@MainActor
final class AppModel: ObservableObject {

    // Library
    @Published var playlists: [PlaylistInfo] = []
    @Published var playlistTracks: [String: [TrackInfo]] = [:]
    @Published var loadingPlaylist: String?
    @Published var libraryError: String?
    @Published var isLoadingLibrary = false
    @Published var selection: SourceSelection? = nil
    @Published var searchText = ""

    // Files (MP3 mode)
    @Published var fileTracks: [TrackInfo] = []

    // Mix
    @Published var project = MixProject()
    @Published var analyses: [String: TrackAnalysis] = [:]
    @Published var status: [String: TrackStatus] = [:]
    @Published var editingEntryID: UUID?
    @Published var projectURL: URL?

    // Work in progress
    @Published var captureQueue: [String] = []
    @Published var activeCapture: (trackID: String, progress: Double, message: String)?
    @Published var renderProgress: Double?
    @Published var renderMessage: String?
    @Published var lastExportURL: URL?
    @Published var alert: AlertItem?
    @Published var previewPlaying: String?

    struct AlertItem: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    let services = Services()
    private var saveWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        services.model = self
        loadPersisted()
        $project
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSave() }
            .store(in: &cancellables)
        $fileTracks
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSave() }
            .store(in: &cancellables)
        refreshStatuses()
    }

    // MARK: - Derived

    /// The mix as planned: transitions resolved, automatic IN/OUT points placed.
    var layout: MixLayout {
        MixLayout.build(entries: project.entries.map { ResolvedEntry(entry: $0, analysis: analyses[$0.track.id]) },
                        sampleRate: project.settings.sampleRate)
    }

    var resolvedEntries: [ResolvedEntry] { layout.entries }

    var totalSeconds: Double { layout.totalSeconds }

    var allEntriesReady: Bool {
        project.entries.allSatisfy { e in
            if case .ready = status[e.track.id]?.availability, analyses[e.track.id] != nil { return true }
            return false
        }
    }

    func tracks(for selection: SourceSelection?) -> [TrackInfo] {
        let all: [TrackInfo]
        switch selection {
        case .playlist(let id): all = playlistTracks[id] ?? []
        case .files: all = fileTracks
        case nil: all = []
        }
        guard !searchText.isEmpty else { return all }
        let q = searchText.lowercased()
        return all.filter { $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) || $0.album.lowercased().contains(q) }
    }

    func isInMix(_ track: TrackInfo) -> Bool {
        project.entries.contains { $0.track.id == track.id }
    }

    func entry(_ id: UUID) -> MixEntry? {
        project.entries.first { $0.id == id }
    }

    func entryIndex(_ id: UUID) -> Int? {
        project.entries.firstIndex { $0.id == id }
    }

    // MARK: - Mix editing

    func add(_ track: TrackInfo) {
        guard !isInMix(track) else { return }
        project.entries.append(MixEntry(track: track))
        refreshStatuses()
        services.prepare(track)
    }

    func remove(_ entryID: UUID) {
        project.entries.removeAll { $0.id == entryID }
        if editingEntryID == entryID { editingEntryID = nil }
    }

    func move(from source: IndexSet, to destination: Int) {
        project.entries.move(fromOffsets: source, toOffset: destination)
    }

    func update(_ entryID: UUID, _ change: (inout MixEntry) -> Void) {
        guard let i = entryIndex(entryID) else { return }
        change(&project.entries[i])
    }

    /// Sets the last song's out point so the mix is exactly `target` seconds.
    func fitToTarget() {
        guard let target = project.settings.targetLength, !project.entries.isEmpty else { return }
        let lay = layout
        let entries = resolvedEntries
        let last = entries[entries.count - 1]
        let delta = target - lay.totalSeconds
        let newOut = last.outTime + delta
        let duration = last.analysis?.duration ?? last.entry.track.duration
        if newOut > duration + 0.0005 {
            alert = AlertItem(title: "Too short", message: "\(last.title) ends \(TimeFormat.clock(newOut - duration)) before the mix would reach \(TimeFormat.clock(target)). Add a song, or extend the overlap less.")
            return
        }
        if newOut < last.inTime + 1 {
            alert = AlertItem(title: "Too long", message: "Even cutting \(last.title) to nothing, the mix is \(TimeFormat.clock(-delta - (last.outTime - last.inTime - 1))) over. Remove a song or shorten an earlier one.")
            return
        }
        update(last.entry.id) { $0.outTime = newOut }
    }

    func refreshStatuses() {
        for e in project.entries {
            var s = status[e.track.id] ?? TrackStatus()
            s.analyzed = analyses[e.track.id] != nil
            if case .capturing = s.availability { } else {
                if let url = services.audioURL(for: e.track) { s.availability = .ready(url) }
                else if case .failed = s.availability { } else { s.availability = .needsCapture }
            }
            status[e.track.id] = s
        }
    }

    // MARK: - Persistence

    nonisolated static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Blend", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static var analysisDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("Analysis", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var autosaveURL: URL { AppModel.supportDirectory.appendingPathComponent("current.blendmix") }
    private var filesURL: URL { AppModel.supportDirectory.appendingPathComponent("files.json") }

    nonisolated static func analysisURL(for trackID: String) -> URL {
        let safe = trackID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        // Stable across launches (String.hashValue is randomized per process).
        var h: UInt64 = 0xcbf29ce484222325
        for b in trackID.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return analysisDirectory.appendingPathComponent("\(safe.suffix(50))-\(String(h, radix: 36)).json")
    }

    private func loadPersisted() {
        if let data = try? Data(contentsOf: autosaveURL), let p = try? JSONDecoder().decode(MixProject.self, from: data) {
            project = p
        }
        if let data = try? Data(contentsOf: filesURL), let f = try? JSONDecoder().decode([TrackInfo].self, from: data) {
            fileTracks = f.filter { FileManager.default.fileExists(atPath: $0.localPath ?? "") }
        }
        for e in project.entries {
            if let data = try? Data(contentsOf: AppModel.analysisURL(for: e.track.id)),
               let a = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
               a.version == TrackAnalysis.currentVersion {
                analyses[e.track.id] = a
            }
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(project) { try? data.write(to: autosaveURL) }
        if let data = try? enc.encode(fileTracks) { try? data.write(to: filesURL) }
    }

    func storeAnalysis(_ a: TrackAnalysis, for trackID: String) {
        analyses[trackID] = a
        if let data = try? JSONEncoder().encode(a) { try? data.write(to: AppModel.analysisURL(for: trackID)) }
        refreshStatuses()
    }

    func save(to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(project).write(to: url)
            projectURL = url
        } catch {
            alert = AlertItem(title: "Couldn't save", message: error.localizedDescription)
        }
    }

    func open(url: URL) {
        do {
            let p = try JSONDecoder().decode(MixProject.self, from: Data(contentsOf: url))
            project = p
            projectURL = url
            for e in p.entries where analyses[e.track.id] == nil {
                if let data = try? Data(contentsOf: AppModel.analysisURL(for: e.track.id)),
                   let a = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
                   a.version == TrackAnalysis.currentVersion {
                    analyses[e.track.id] = a
                }
            }
            refreshStatuses()
            services.prepareAll()
        } catch {
            alert = AlertItem(title: "Couldn't open", message: error.localizedDescription)
        }
    }

    func newProject() {
        project = MixProject()
        projectURL = nil
        editingEntryID = nil
    }
}

enum TimeFormat {
    /// m:ss.mmm
    static func clock(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let m = Int(total) / 60
        let s = total - Double(m) * 60
        return String(format: "%d:%06.3f", m, s)
    }

    /// m:ss
    static func short(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Parses "m:ss", "m:ss.mmm", "h:mm:ss" or plain seconds.
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    static func signed(_ seconds: Double) -> String {
        (seconds < 0 ? "−" : "+") + clock(abs(seconds))
    }
}
