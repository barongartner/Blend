import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } content: {
            TrackListView()
                .navigationSplitViewColumnWidth(min: 380, ideal: 480)
        } detail: {
            MixPanelView()
                .navigationSplitViewColumnWidth(min: 420, ideal: 520)
        }
        .sheet(item: Binding(get: { model.editingEntryID.map { EditorTarget(id: $0) } },
                             set: { model.editingEntryID = $0?.id })) { target in
            TrackEditorView(entryID: target.id)
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
        .onChange(of: model.selection) { _, new in
            if case .playlist(let id) = new { model.services.loadTracks(playlistID: id) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers {
                group.enter()
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                    else if let url = item as? URL { urls.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { model.services.importFiles(urls) }
            return true
        }
    }
}

struct EditorTarget: Identifiable {
    let id: UUID
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            Section {
                Label {
                    HStack {
                        Text("Imported files")
                        Spacer()
                        Text("\(model.fileTracks.count)").foregroundStyle(.secondary).font(.caption)
                    }
                } icon: { Image(systemName: "folder") }
                .tag(SourceSelection.files)
            } header: {
                Text("MP3 mode")
            }
            Section {
                if model.isLoadingLibrary && model.playlists.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Reading Music…").foregroundStyle(.secondary) }
                }
                ForEach(model.playlists) { pl in
                    Label {
                        HStack {
                            Text(pl.name).lineLimit(1)
                            Spacer()
                            Text("\(pl.trackCount)").foregroundStyle(.secondary).font(.caption)
                        }
                    } icon: {
                        Image(systemName: pl.isLibrary ? "music.note.house" : (pl.isSmart ? "gearshape" : "music.note.list"))
                    }
                    .tag(SourceSelection.playlist(pl.id))
                }
                if let err = model.libraryError {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(8)
                    HStack {
                        Button("Try again") { model.services.loadPlaylists() }.controlSize(.small)
                        Button("Privacy settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                        }.controlSize(.small)
                    }
                }
            } header: {
                HStack {
                    Text("Apple Music")
                    Spacer()
                    Button { model.services.loadPlaylists() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Reload playlists from Music")
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { addFiles() } label: { Label("Add Files", systemImage: "plus") }
                    .help("Add MP3s or other audio files (MP3 mode)")
            }
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .folder]
        if panel.runModal() == .OK { model.services.importFiles(panel.urls) }
    }
}

// MARK: - Track list

struct TrackListView: View {
    @EnvironmentObject var model: AppModel
    @State private var tableSelection: Set<String> = []

    var tracks: [TrackInfo] { model.tracks(for: model.selection) }

    var body: some View {
        VStack(spacing: 0) {
            if model.selection == nil {
                ContentUnavailableView("Pick a playlist", systemImage: "music.note.list",
                                       description: Text("Choose an Apple Music playlist on the left, or add MP3s."))
            } else if case .playlist(let id) = model.selection, model.loadingPlaylist == id, model.playlistTracks[id] == nil {
                VStack { ProgressView(); Text("Reading playlist…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                ContentUnavailableView(model.selection == .files ? "No files yet" : "No songs",
                                       systemImage: model.selection == .files ? "folder" : "music.note",
                                       description: Text(model.selection == .files ? "Drop MP3s anywhere in the window, or use Add Files." : "This playlist has no songs."))
            } else {
                Table(tracks, selection: $tableSelection) {
                    TableColumn("") { t in
                        Button {
                            if model.isInMix(t) {
                                if let e = model.project.entries.first(where: { $0.track.id == t.id }) { model.remove(e.id) }
                            } else {
                                model.add(t)
                            }
                        } label: {
                            Image(systemName: model.isInMix(t) ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(model.isInMix(t) ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(model.isInMix(t) ? "Remove from mix" : "Add to mix")
                    }
                    .width(24)
                    TableColumn("Title") { t in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).lineLimit(1)
                            Text(t.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    TableColumn("Length") { t in
                        Text(TimeFormat.short(t.duration)).monospacedDigit()
                    }
                    .width(50)
                    TableColumn("BPM") { t in
                        if let a = model.analyses[t.id] { Text(String(format: "%.1f", a.bpm)).monospacedDigit() }
                        else if let b = t.taggedBPM { Text(String(format: "%.0f", b)).foregroundStyle(.secondary).monospacedDigit() }
                        else { Text("–").foregroundStyle(.tertiary) }
                    }
                    .width(50)
                    TableColumn("Key") { t in
                        if let a = model.analyses[t.id] { Text(a.camelot).help(a.keyName) }
                        else { Text("–").foregroundStyle(.tertiary) }
                    }
                    .width(40)
                    TableColumn("Audio") { t in
                        // Passed explicitly: Table cells on macOS can be built without the
                        // environment and @EnvironmentObject then traps.
                        AudioStatusBadge(model: model, track: t)
                    }
                    .width(90)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Add to Mix") {
                        for t in tracks where ids.contains(t.id) { model.add(t) }
                    }
                } primaryAction: { ids in
                    for t in tracks where ids.contains(t.id) { model.add(t) }
                }
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter songs")
        .navigationTitle(title)
    }

    private var title: String {
        switch model.selection {
        case .playlist(let id): return model.playlists.first { $0.id == id }?.name ?? "Playlist"
        case .files: return "Imported files"
        case nil: return "Blend"
        }
    }
}

struct AudioStatusBadge: View {
    @ObservedObject var model: AppModel
    let track: TrackInfo

    var body: some View {
        let st = model.status[track.id]
        let cached = model.services.audioURL(for: track) != nil
        HStack(spacing: 4) {
            switch st?.availability {
            case .capturing(let p):
                ProgressView(value: p).frame(width: 50)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Failed").font(.caption)
            default:
                if cached {
                    Image(systemName: track.needsCapture ? "waveform.circle.fill" : "doc.circle.fill").foregroundStyle(.green)
                    Text(track.needsCapture ? "Captured" : "File").font(.caption).foregroundStyle(.secondary)
                } else if track.needsCapture {
                    Image(systemName: "icloud").foregroundStyle(.secondary)
                    Text("Apple Music").font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    Text("File").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .help(helpText(st))
    }

    private func helpText(_ st: TrackStatus?) -> String {
        if case .failed(let msg)? = st?.availability { return msg }
        if track.needsCapture { return model.services.audioURL(for: track) != nil ? "Captured from Music; ready" : "Apple Music track — Blend records it from the Music app when you add it to the mix" }
        return track.localPath ?? ""
    }
}
