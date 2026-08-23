import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct BlendApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Blend") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 640)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    BlendLog.write("launch \(CommandLine.arguments.dropFirst().joined(separator: " "))")
                    model.services.loadPlaylists()
                    if let i = CommandLine.arguments.firstIndex(of: "--capture"), i + 1 < CommandLine.arguments.count {
                        DebugCapture.run(model: model, persistentID: CommandLine.arguments[i + 1])
                    } else if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
                        model.services.prepareAll()
                        DebugSnapshot.run(model: model, dir: CommandLine.arguments[i + 1])
                    } else if let i = CommandLine.arguments.firstIndex(of: "--export"), i + 1 < CommandLine.arguments.count {
                        model.services.prepareAll()
                        DebugExport.run(model: model, path: CommandLine.arguments[i + 1])
                    } else {
                        model.services.prepareAll()
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Mix") { model.newProject() }.keyboardShortcut("n")
                Button("Open Mix…") { openProject() }.keyboardShortcut("o")
                Button("Save Mix As…") { saveProject() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Add Audio Files…") { addFiles() }.keyboardShortcut("i")
                Button("Export Mix…") { exportMix() }.keyboardShortcut("e")
            }
            CommandMenu("Mix") {
                Button("Prepare All Songs") { model.services.prepareAll() }.keyboardShortcut("p")
                Button("Fit Length to Target") { model.fitToTarget() }.keyboardShortcut("t")
                Button("Stop Preview") { model.services.stopPreview() }.keyboardShortcut(".")
                Divider()
                Button("Reload Music Library") { model.services.loadPlaylists() }.keyboardShortcut("r")
            }
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.message = "Choose MP3s (or any audio files), or a folder of them"
        if panel.runModal() == .OK { model.services.importFiles(panel.urls) }
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "blendmix") ?? .json]
        if panel.runModal() == .OK, let url = panel.url { model.open(url: url) }
    }

    private func saveProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "blendmix") ?? .json]
        panel.nameFieldStringValue = "\(model.project.name).blendmix"
        if panel.runModal() == .OK, let url = panel.url { model.save(to: url) }
    }

    private func exportMix() {
        ExportAction.run(model: model)
    }
}

enum ExportAction {
    @MainActor static func run(model: AppModel) {
        guard !model.project.entries.isEmpty else {
            model.alert = AppModel.AlertItem(title: "Nothing to export", message: "Add some songs to the mix first.")
            return
        }
        guard model.allEntriesReady else {
            model.alert = AppModel.AlertItem(title: "Not ready yet", message: "Every song needs its audio captured and analyzed before the mix can be rendered. Use Prepare All and wait for the list to show all songs ready.")
            return
        }
        let format = model.project.settings.exportFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .audio]
        panel.nameFieldStringValue = "\(model.project.name).\(format.fileExtension)"
        panel.message = "Export the mix as \(format.label) — \(TimeFormat.clock(model.totalSeconds)) long"
        if panel.runModal() == .OK, let url = panel.url {
            model.services.export(to: url)
        }
    }
}


/// `open Blend.app --args --capture <persistentID>`: captures one Music track
/// headlessly, logs everything to blend.log, and quits. For testing the
/// capture path without clicking through the UI.
enum DebugCapture {
    @MainActor static func run(model: AppModel, persistentID: String) {
        BlendLog.write("debug capture requested for \(persistentID)")
        DispatchQueue.global().async {
            var tracks = (try? MusicBridge.fetchTracks(playlistID: "library")) ?? []
            if !tracks.contains(where: { $0.persistentID == persistentID }) {
                for pl in (try? MusicBridge.fetchPlaylists()) ?? [] where !pl.isLibrary {
                    tracks += (try? MusicBridge.fetchTracks(playlistID: pl.id)) ?? []
                    if tracks.contains(where: { $0.persistentID == persistentID }) { break }
                }
            }
            guard let track = tracks.first(where: { $0.persistentID == persistentID }) else {
                BlendLog.write("debug capture: track \(persistentID) not in library")
                DispatchQueue.main.async { exit(0) }
                return
            }
            let result = Result {
                try MusicCapture.capture(track: track, progress: { p, msg in
                    if Int(p * 100) % 10 == 0 { BlendLog.write("debug capture: \(Int(p * 100))% \(msg)") }
                }, isCancelled: { false })
            }
            switch result {
            case .success(let r):
                BlendLog.write("debug capture OK: \(r.url.path) \(String(format: "%.2f", r.duration))s @ \(Int(r.sampleRate))")
                if let clip = try? AudioDecoder.decode(url: r.url, sampleRate: 48000) {
                    let a = TrackAnalyzer.analyze(clip: clip, taggedBPM: nil)
                    BlendLog.write("debug capture analysis: \(String(format: "%.2f", a.bpm)) BPM, \(a.keyName), rms \(String(format: "%.3f", a.rms)), grid \(String(format: "%.2f", a.gridConfidence))")
                }
            case .failure(let err):
                BlendLog.write("debug capture FAILED: \(err)")
            }
            DispatchQueue.main.async { exit(0) }
        }
    }
}

/// `open Blend.app --args --snapshot <dir>`: renders the app's windows to PNGs
/// (main window, then the editor sheet for the first song) and quits. Lets the
/// UI be checked on a machine where nobody can look at the screen.
enum DebugSnapshot {
    @MainActor static func run(model: AppModel, dir: String) {
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Offscreen rendering can't draw window materials; light appearance keeps text legible.
        NSApp.appearance = NSAppearance(named: .aqua)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            model.selection = .files
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                snapshotAll(prefix: "main", to: out)
                if let first = model.project.entries.first { model.editingEntryID = first.id }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    snapshotAll(prefix: "editor", to: out)
                    BlendLog.write("snapshots written to \(out.path)")
                    exit(0)
                }
            }
        }
    }

    @MainActor static func snapshotAll(prefix: String, to dir: URL) {
        for (i, w) in NSApp.windows.enumerated() where w.isVisible {
            guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("\(prefix)-\(i)-\(Int(w.frame.width))x\(Int(w.frame.height)).png"))
            }
        }
    }
}

/// `open Blend.app --args --export <file.mp3|wav|m4a>`: waits for the saved mix
/// to be ready, exports it through the same path the Export button uses, and quits.
enum DebugExport {
    @MainActor static func run(model: AppModel, path: String) {
        let url = URL(fileURLWithPath: path)
        if let f = ExportFormat.allCases.first(where: { $0.fileExtension == url.pathExtension.lowercased() }) {
            model.project.settings.exportFormat = f
        }
        var ticks = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            ticks += 1
            if model.allEntriesReady && model.renderProgress == nil && model.lastExportURL == nil {
                BlendLog.write("debug export → \(path), mix length \(TimeFormat.clock(model.totalSeconds))")
                model.services.export(to: url)
            }
            if model.lastExportURL != nil || ticks > 600 {
                BlendLog.write("debug export finished: \(model.lastExportURL?.path ?? "timeout")")
                exit(model.lastExportURL != nil ? 0 : 1)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
