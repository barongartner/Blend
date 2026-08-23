import SwiftUI
import AppKit

struct MixPanelView: View {
    @EnvironmentObject var model: AppModel
    @State private var targetText = ""
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.project.entries.isEmpty {
                ContentUnavailableView("Your mix is empty", systemImage: "slider.horizontal.3",
                                       description: Text("Add songs from a playlist with the + buttons. Drag rows here to reorder; click a song to set its start, end and transition."))
            } else {
                entryList
            }
            Divider()
            footer
        }
        .navigationTitle("Mix")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.services.prepareAll() } label: { Label("Prepare All", systemImage: "waveform.badge.magnifyingglass") }
                    .disabled(model.project.entries.isEmpty || model.allEntriesReady || model.activeCapture != nil)
                    .help(model.allEntriesReady && !model.project.entries.isEmpty
                          ? "Prepare All — every song is already captured and analyzed, nothing to do"
                          : "Prepare All — record any Apple Music songs that aren't captured yet and analyze every song")
                Button { showSettings.toggle() } label: { Label("Settings", systemImage: "gearshape") }
                    .help("Mix settings: format, sample rate, loudness, end fade")
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) { MixSettingsView().environmentObject(model) }
                Button { ExportAction.run(model: model) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    .disabled(model.renderProgress != nil)
            }
        }
        .onAppear { targetText = model.project.settings.targetLength.map(TimeFormat.clock) ?? "" }
    }

    // MARK: Header

    private var header: some View {
        let total = model.totalSeconds
        let target = model.project.settings.targetLength
        let estimate = model.project.entries.contains { model.analyses[$0.track.id] == nil }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mix length").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(TimeFormat.clock(total))
                            .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                        if estimate { Text("estimate").font(.caption).foregroundStyle(.orange).help("Some songs aren't analyzed yet; their length is guessed.") }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Video length").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("m:ss.mmm", text: $targetText)
                            .textFieldStyle(.roundedBorder).frame(width: 110).multilineTextAlignment(.trailing)
                            .onSubmit { commitTarget() }
                        Button("Fit") { commitTarget(); model.fitToTarget() }
                            .disabled(target == nil || model.project.entries.isEmpty)
                            .help("Move the last song's end so the mix is exactly this long")
                    }
                    if let target {
                        let delta = total - target
                        Text(abs(delta) < 0.0005 ? "exact match" : (delta > 0 ? "\(TimeFormat.clock(delta)) too long" : "\(TimeFormat.clock(-delta)) short"))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(abs(delta) < 0.0005 ? Color.green : (delta > 0 ? Color.orange : Color.secondary))
                    }
                }
            }
            Text("\(model.project.entries.count) songs · \(Int(model.project.settings.sampleRate / 1000)) kHz · \(model.project.settings.exportFormat.label)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func commitTarget() {
        let trimmed = targetText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { model.project.settings.targetLength = nil; return }
        if let t = TimeFormat.parse(trimmed) {
            model.project.settings.targetLength = t
            targetText = TimeFormat.clock(t)
        }
    }

    // MARK: List

    private var entryList: some View {
        List {
            ForEach(Array(model.resolvedEntries.enumerated()), id: \.element.entry.id) { i, re in
                MixEntryRow(index: i, resolved: re, layout: model.layout)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.editingEntryID = re.entry.id }
                    .contextMenu {
                        Button("Edit Start, End & Transition…") { model.editingEntryID = re.entry.id }
                        if i > 0 { Button("Preview Transition Into This Song") { model.services.previewTransition(into: i) } }
                        Divider()
                        Button("Re-analyze") { model.services.reanalyze(re.entry.track) }
                        if re.entry.track.needsCapture { Button("Capture Again") { model.services.recapture(re.entry.track) } }
                        Divider()
                        Button("Remove from Mix", role: .destructive) { model.remove(re.entry.id) }
                    }
            }
            .onMove { model.move(from: $0, to: $1) }
            .onDelete { idx in for i in idx.sorted(by: >) { model.remove(model.project.entries[i].id) } }
        }
        .listStyle(.inset)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cap = model.activeCapture, let e = model.project.entries.first(where: { $0.track.id == cap.trackID }) {
                HStack(spacing: 8) {
                    ProgressView(value: cap.progress).frame(width: 140)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Capturing \(e.track.title)").font(.caption).lineLimit(1)
                        Text(cap.message).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if !model.captureQueue.isEmpty { Text("+\(model.captureQueue.count) queued").font(.caption2).foregroundStyle(.secondary) }
                    Button("Cancel") { model.services.cancelCaptures() }.controlSize(.small)
                }
            }
            if let p = model.renderProgress {
                HStack(spacing: 8) {
                    ProgressView(value: p).frame(width: 140)
                    Text(model.renderMessage ?? "Rendering…").font(.caption)
                    Spacer()
                    Button("Cancel") { model.services.cancelExport() }.controlSize(.small)
                }
            } else if let url = model.lastExportURL {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Exported \(url.lastPathComponent)").font(.caption).lineLimit(1)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.controlSize(.small)
                    Button("Play") { NSWorkspace.shared.open(url) }.controlSize(.small)
                    Spacer()
                }
            }
            if model.previewPlaying != nil {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill")
                    Text("Previewing…").font(.caption)
                    Button("Stop") { model.services.stopPreview() }.controlSize(.small)
                    Spacer()
                }
            }
            if model.activeCapture == nil && model.renderProgress == nil && model.lastExportURL == nil && model.previewPlaying == nil {
                Text(model.project.entries.isEmpty ? " " : (model.allEntriesReady ? "All songs ready — Export when the length looks right." : "Some songs still need capturing or analysis (Prepare All)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }
}

// MARK: - Row

struct MixEntryRow: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    let resolved: ResolvedEntry
    let layout: MixLayout

    var body: some View {
        let e = resolved.entry
        let st = model.status[e.track.id]
        let tl = index < layout.tracks.count ? layout.tracks[index] : nil
        let isLast = index == model.project.entries.count - 1
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.track.title).fontWeight(.medium).lineLimit(1)
                    Text(e.track.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let a = resolved.analysis {
                        HStack(spacing: 6) {
                            Text(String(format: "%.1f BPM", resolved.bpm)).monospacedDigit()
                            KeyBadge(camelot: a.camelot, previous: index > 0 ? model.analyses[model.project.entries[index - 1].track.id]?.camelot : nil)
                        }.font(.caption)
                    } else if st?.analyzing == true {
                        HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Analyzing…").font(.caption).foregroundStyle(.secondary) }
                    } else if case .capturing(let p)? = st?.availability {
                        HStack(spacing: 4) { ProgressView(value: p).frame(width: 60); Text("Capturing").font(.caption).foregroundStyle(.secondary) }
                    } else if case .failed(let msg)? = st?.availability {
                        Label("Failed", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).help(msg)
                    } else if model.captureQueue.contains(e.track.id) {
                        Text("Waiting to capture").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Not ready").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(TimeFormat.clock(resolved.inTime)) → \(TimeFormat.clock(resolved.outTime))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Button { model.editingEntryID = e.id } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless).help("Edit start, end and transition")
            }
            if !isLast {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary).padding(.leading, 26)
                    Text(transitionSummary(tl)).font(.caption2).foregroundStyle(.secondary)
                    if let next = tl.map({ layout.tracks[safe: $0.index + 1] }) ?? nil, !next.warnings.isEmpty {
                        Image(systemName: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange).help(next.warnings.joined(separator: "\n"))
                    }
                    Spacer()
                    Button { model.services.previewTransition(into: index + 1) } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.borderless).font(.caption).help("Preview this transition")
                        .disabled(!(model.allEntriesReady))
                }
            }
            if let tl, !tl.warnings.isEmpty, isLast || index == 0 {
                Text(tl.warnings.joined(separator: " ")).font(.caption2).foregroundStyle(.orange).padding(.leading, 26)
            }
        }
        .padding(.vertical, 3)
    }

    private func transitionSummary(_ tl: TrackLayout?) -> String {
        let t = resolved.transition
        if t.style == .cut { return "Cut on the downbeat" }
        var s = "\(t.style.label), \(t.overlapBars) bar\(t.overlapBars == 1 ? "" : "s")"
        if t.tempoSync { s += ", tempo-synced" }
        if let tl { s += " · \(TimeFormat.short(Double(tl.outroOverlap) / layout.sampleRate))" }
        return s
    }
}

struct KeyBadge: View {
    let camelot: String
    let previous: String?

    var body: some View {
        let compat = previous.map { KeyAnalyzer.compatibility($0, camelot) }
        Text(camelot)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color(compat).opacity(0.18)))
            .foregroundStyle(color(compat))
            .help(previous == nil ? "Key (Camelot)" : (compat == 2 ? "Same key as the previous song" : compat == 1 ? "Compatible with the previous song" : "Key clash with the previous song — a longer blend may sound muddy"))
    }

    private func color(_ c: Int?) -> Color {
        switch c {
        case 2: return .green
        case 1: return .teal
        case 0: return .orange
        default: return .secondary
        }
    }
}

// MARK: - Settings popover

struct MixSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mix settings").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Export format").gridColumnAlignment(.trailing)
                    Picker("Export format", selection: $model.project.settings.exportFormat) {
                        ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 220)
                }
                GridRow {
                    Text("Sample rate")
                    Picker("Sample rate", selection: $model.project.settings.sampleRate) {
                        Text("48 kHz (video)").tag(48000.0)
                        Text("44.1 kHz (music)").tag(44100.0)
                    }
                    .labelsHidden().frame(width: 220)
                }
                GridRow {
                    Text("Fade out the end")
                    HStack(spacing: 6) {
                        TextField("0", value: $model.project.settings.endFadeSeconds, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 60).multilineTextAlignment(.trailing)
                        Text("seconds (0 = none)").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Mix name")
                    TextField("Mix name", text: $model.project.name)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }
            }
            Toggle("Match loudness between songs", isOn: $model.project.settings.matchLoudness)
            Toggle("Key lock — keep pitch when tempo-matching (off = vinyl-style pitch shift)", isOn: $model.project.settings.keyLock)
            Text(Exporter.findFFmpeg() == nil
                 ? "MP3 export needs ffmpeg, and none was found on this Mac — WAV and AAC still work."
                 : "MP3 export uses ffmpeg. WAV is exact to the millisecond; MP3 comes out about 50 ms longer (encoder padding).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 440)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
