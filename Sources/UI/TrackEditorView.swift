import SwiftUI
import AppKit

/// Full control over one song in the mix: start and end points on a zoomable
/// waveform with the beat grid, tempo/downbeat corrections, and the
/// transition into the next song.
struct TrackEditorView: View {
    @EnvironmentObject var model: AppModel
    let entryID: UUID

    @State private var pixelsPerSecond: Double = 60
    @State private var snapToBeats = true
    @State private var inText = ""
    @State private var outText = ""
    @State private var bpmText = ""
    @State private var dragging: Handle?

    enum Handle { case inPoint, outPoint }

    private var index: Int? { model.entryIndex(entryID) }
    private var entry: MixEntry? { model.entry(entryID) }
    private var resolved: ResolvedEntry? {
        guard let i = index else { return nil }
        return model.resolvedEntries[safe: i]
    }
    private var layoutTrack: TrackLayout? {
        guard let i = index else { return nil }
        return model.layout.tracks[safe: i]
    }
    private var isLast: Bool { index == model.project.entries.count - 1 }
    private var nextTitle: String? {
        guard let i = index else { return nil }
        return model.project.entries[safe: i + 1]?.track.title
    }

    var body: some View {
        VStack(spacing: 0) {
            if let entry, let resolved {
                titleBar(entry, resolved)
                Divider()
                waveform(resolved)
                Divider()
                controls(entry, resolved)
            } else {
                Text("This song is no longer in the mix.")
                Button("Close") { model.editingEntryID = nil }
            }
        }
        .onAppear { syncFields() }
        .onChange(of: resolved?.inTime) { _, _ in syncFields() }
        .onChange(of: resolved?.outTime) { _, _ in syncFields() }
        .onChange(of: resolved?.bpm) { _, _ in syncFields() }
    }

    private func syncFields() {
        guard let r = resolved else { return }
        inText = TimeFormat.clock(r.inTime)
        outText = TimeFormat.clock(r.outTime)
        bpmText = String(format: "%.2f", r.bpm)
    }

    // MARK: - Title bar

    private func titleBar(_ entry: MixEntry, _ r: ResolvedEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.track.title).font(.title2).fontWeight(.semibold)
                Text(entry.track.displayArtist).foregroundStyle(.secondary)
            }
            Spacer()
            if let a = r.analysis {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("BPM")
                        TextField("", text: $bpmText)
                            .textFieldStyle(.roundedBorder).frame(width: 70).multilineTextAlignment(.trailing)
                            .onSubmit { commitBPM() }
                        Button("½") { setBPM(r.bpm / 2) }.help("Halve the tempo")
                        Button("×2") { setBPM(r.bpm * 2) }.help("Double the tempo")
                        if entry.bpmOverride != nil { Button("Reset") { model.update(entryID) { $0.bpmOverride = nil } } }
                    }
                    HStack(spacing: 8) {
                        Text("Key \(a.keyName) (\(a.camelot))").foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text("Downbeat")
                        Button { model.update(entryID) { $0.downbeatShift = (($0.downbeatShift - 1) % 4 + 4) % 4 } } label: { Image(systemName: "chevron.left") }
                        Text("\(entry.downbeatShift)").monospacedDigit().frame(width: 14)
                        Button { model.update(entryID) { $0.downbeatShift = ($0.downbeatShift + 1) % 4 } } label: { Image(systemName: "chevron.right") }
                            .help("Shift which beat counts as the start of the bar")
                        if a.gridConfidence < 0.4 {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                .help("The beat isn't steady, or the grid didn't lock on. Check the grid lines against the drums and adjust BPM or nudge the grid if needed.")
                        }
                    }.font(.callout)
                    HStack(spacing: 8) {
                        Text("Grid")
                        Button("−½ beat") { shiftGrid(-r.beatLength / 2) }.help("Slide the grid back half a beat (when lines sit between the kicks)")
                        Button("−10 ms") { shiftGrid(-0.010) }
                        Button("+10 ms") { shiftGrid(0.010) }
                        Button("+½ beat") { shiftGrid(r.beatLength / 2) }
                        if entry.gridShift != 0 {
                            Text(String(format: "%+.0f ms", entry.gridShift * 1000)).monospacedDigit().foregroundStyle(.secondary)
                            Button("Reset") { model.update(entryID) { $0.gridShift = 0 } }
                        }
                    }.font(.callout).controlSize(.small)
                }
            } else {
                Text("Not analyzed yet").foregroundStyle(.secondary)
            }
            Button("Done") { model.editingEntryID = nil }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func shiftGrid(_ delta: Double) {
        model.update(entryID) { $0.gridShift += delta }
    }

    private func commitBPM() {
        if let v = Double(bpmText), v > 30, v < 300 { setBPM(v) } else { syncFields() }
    }

    private func setBPM(_ v: Double) {
        model.update(entryID) { $0.bpmOverride = v }
    }

    // MARK: - Waveform

    private func waveform(_ r: ResolvedEntry) -> some View {
        let duration = r.analysis?.duration ?? r.entry.track.duration
        let tl = layoutTrack
        let sr = model.project.settings.sampleRate
        let entryOverlapSec = tl.map { $0.entrySrc / sr } ?? 0
        let rampSec = tl.map { $0.rampSrc / sr } ?? 0
        let outroSec = tl.map { Double($0.outroOverlap) / sr } ?? 0
        return VStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    WaveformCanvas(analysis: r.analysis, resolved: r, duration: duration, pixelsPerSecond: pixelsPerSecond,
                                   entryOverlap: entryOverlapSec, ramp: rampSec, outroOverlap: outroSec)
                        .frame(width: max(300, duration * pixelsPerSecond), height: 260)
                        .overlay(alignment: .topLeading) { scrollAnchors(duration) }
                        .gesture(dragGesture(r, duration: duration))
                }
                .onAppear { proxy.scrollTo(anchorID(for: r.inTime), anchor: .leading) }
                .onChange(of: pixelsPerSecond) { _, _ in proxy.scrollTo(anchorID(for: r.inTime), anchor: .leading) }
            }
            HStack(alignment: .top) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: Binding(get: { log2(pixelsPerSecond) }, set: { pixelsPerSecond = pow(2, $0) }), in: log2(8)...log2(400))
                    .frame(width: 200)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Toggle("Snap to beats", isOn: $snapToBeats).toggleStyle(.checkbox)
                Spacer()
                Text("Drag the IN and OUT handles. Faint lines are beats, bold lines are bars (numbered), orange lines are 8-bar phrases. The band along the top shows sections: orange = drop/chorus, gray = verse, blue = quiet. Green shading: the previous song is still playing; blue: the next one has come in.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 560, alignment: .leading)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
    }

    private func anchorID(for t: Double) -> String { "anchor-\(max(0, Int(t / 5) - 1))" }

    private func scrollAnchors(_ duration: Double) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<max(1, Int(duration / 5) + 1), id: \.self) { i in
                Color.clear.frame(width: 5 * pixelsPerSecond, height: 1).id("anchor-\(i)")
            }
        }
    }

    private func dragGesture(_ r: ResolvedEntry, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let t = g.location.x / pixelsPerSecond
                if dragging == nil {
                    let dIn = abs(g.startLocation.x - r.inTime * pixelsPerSecond)
                    let dOut = abs(g.startLocation.x - r.outTime * pixelsPerSecond)
                    if min(dIn, dOut) > 40 { return }
                    dragging = dIn <= dOut ? .inPoint : .outPoint
                }
                var v = max(0, min(duration, t))
                if snapToBeats, r.analysis != nil { v = r.nearestBeat(to: v); v = max(0, min(duration, v)) }
                switch dragging {
                case .inPoint: model.update(entryID) { $0.inTime = min(v, r.outTime - 1) }
                case .outPoint: model.update(entryID) { $0.outTime = max(v, r.inTime + 1) }
                case nil: break
                }
            }
            .onEnded { _ in dragging = nil }
    }

    // MARK: - Controls

    private func controls(_ entry: MixEntry, _ r: ResolvedEntry) -> some View {
        let duration = r.analysis?.duration ?? entry.track.duration
        return HStack(alignment: .top, spacing: 24) {
            // In / out
            VStack(alignment: .leading, spacing: 10) {
                Text("Start & end").font(.headline)
                pointRow(label: "IN", text: $inText, value: r.inTime, duration: duration, r: r,
                         set: { v in model.update(entryID) { $0.inTime = min(v, r.outTime - 1) } },
                         play: { model.services.previewSong(entry.track, from: r.inTime, seconds: 8, id: "in") })
                pointRow(label: "OUT", text: $outText, value: r.outTime, duration: duration, r: r,
                         set: { v in model.update(entryID) { $0.outTime = max(v, r.inTime + 1) } },
                         play: { model.services.previewSong(entry.track, from: max(0, r.outTime - 8), seconds: 8, id: "out") })
                HStack {
                    Button("Auto") {
                        model.update(entryID) { $0.inTime = nil; $0.outTime = nil }
                    }.help("Let the planner place IN and OUT from the song's structure and the transitions around it")
                    if r.autoIn || r.autoOut { Text("auto-placed").font(.caption).foregroundStyle(.secondary) }
                    Button("Whole song") {
                        model.update(entryID) { $0.inTime = 0; $0.outTime = duration }
                    }
                    if model.previewPlaying != nil { Button("Stop") { model.services.stopPreview() } }
                }
                Text("Using \(TimeFormat.clock(r.outTime - r.inTime)) of \(TimeFormat.clock(duration))").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Gain")
                    Slider(value: Binding(get: { entry.gainDB }, set: { v in model.update(entryID) { $0.gainDB = v } }), in: -12...12, step: 0.5)
                        .frame(width: 160)
                    Text(String(format: "%+.1f dB", entry.gainDB)).monospacedDigit().frame(width: 64, alignment: .trailing)
                }
                .font(.callout)
            }
            Divider()
            // Transition
            VStack(alignment: .leading, spacing: 10) {
                if isLast {
                    Text("End of mix").font(.headline)
                    Text("This is the last song. The mix ends at its OUT point\(model.project.settings.endFadeSeconds > 0 ? ", with a \(model.project.settings.endFadeSeconds, specifier: "%.1f") s fade" : ""). Use Fit in the mix panel to land exactly on the video length.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Transition into \(nextTitle ?? "next song")").font(.headline)
                    Picker("Style", selection: Binding(get: { entry.transition.style }, set: { v in model.update(entryID) { $0.transition.style = v } })) {
                        ForEach(TransitionStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 300)
                    if let t = r.transitionOut {
                        if entry.transition.style == .auto {
                            Text("Auto chose **\(t.style.label)**" + (t.reason.isEmpty ? "" : " — \(t.reason)"))
                                .font(.callout)
                        }
                        Text(TransitionStyle.describe(t.style).help).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(entry.transition.style.help).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    let effective = r.transitionOut?.style
                    if entry.transition.style == .blend || entry.transition.style == .filterDrop || (entry.transition.style == .auto && (effective == .blend || effective == .filterDrop)) {
                        Picker(effective == .filterDrop ? "Sweep" : "Overlap",
                               selection: Binding(get: { entry.transition.overlapBars }, set: { v in model.update(entryID) { $0.transition.overlapBars = v } })) {
                            ForEach(TransitionSettings.overlapChoices, id: \.self) { Text($0 == 0 ? "Auto" : "\($0) bars").tag($0) }
                        }
                        .frame(width: 300)
                    }
                    if effective == .blend {
                        Toggle("Tempo-sync the next song to this one", isOn: Binding(get: { entry.transition.tempoSync }, set: { v in model.update(entryID) { $0.transition.tempoSync = v } }))
                        if entry.transition.tempoSync {
                            Picker("Ease back over", selection: Binding(get: { entry.transition.rampBars }, set: { v in model.update(entryID) { $0.transition.rampBars = v } })) {
                                ForEach([0, 2, 4, 8, 16, 32], id: \.self) { Text($0 == 0 ? "instantly" : "\($0) bars").tag($0) }
                            }
                            .frame(width: 300)
                        }
                    }
                    if effective == .echoOut {
                        Picker("Echo tail", selection: Binding(get: { entry.transition.tailBars }, set: { v in model.update(entryID) { $0.transition.tailBars = v } })) {
                            ForEach([1, 2, 4], id: \.self) { Text("\($0) bar\($0 == 1 ? "" : "s")").tag($0) }
                        }
                        .frame(width: 300)
                    }
                    if effective == .filterDrop {
                        Toggle("Noise riser under the sweep", isOn: Binding(get: { entry.transition.riser }, set: { v in model.update(entryID) { $0.transition.riser = v } }))
                    }
                    if let i = index, let next = model.layout.tracks[safe: i + 1], !next.warnings.isEmpty {
                        Text(next.warnings.joined(separator: " ")).font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button {
                            if let i = index { model.services.previewTransition(into: i + 1) }
                        } label: { Label("Preview transition", systemImage: "play.fill") }
                        .disabled(!model.allEntriesReady)
                        if model.previewPlaying != nil { Button("Stop") { model.services.stopPreview() } }
                    }
                    if let i = index, let cur = model.layout.tracks[safe: i] {
                        let sr = model.project.settings.sampleRate
                        Text("Next song starts at \(TimeFormat.clock(Double(cur.outroStart) / sr)) into the mix" +
                             (cur.outroOverlap > 0 ? " · overlap \(TimeFormat.clock(Double(cur.outroOverlap) / sr))" : "") +
                             (cur.tail > 0 ? " · tail \(TimeFormat.clock(Double(cur.tail) / sr))" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }

    private func pointRow(label: String, text: Binding<String>, value: Double, duration: Double, r: ResolvedEntry,
                          set: @escaping (Double) -> Void, play: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).fontWeight(.bold).frame(width: 30, alignment: .leading)
            TextField("m:ss.mmm", text: text)
                .textFieldStyle(.roundedBorder).frame(width: 100).multilineTextAlignment(.trailing)
                .onSubmit { if let v = TimeFormat.parse(text.wrappedValue) { set(max(0, min(duration, v))) } else { syncFields() } }
            Button { set(max(0, value - r.barLength)) } label: { Text("−bar") }.help("Earlier by one bar")
            Button { set(max(0, value - r.beatLength)) } label: { Text("−beat") }
            Button { set(min(duration, value + r.beatLength)) } label: { Text("+beat") }
            Button { set(min(duration, value + r.barLength)) } label: { Text("+bar") }.help("Later by one bar")
            Button { set(max(0, min(duration, r.nearestDownbeat(to: value)))) } label: { Image(systemName: "arrow.down.to.line") }
                .help("Snap to the nearest bar start (downbeat)")
                .disabled(r.analysis == nil)
            Button { set(max(0, min(duration, r.nearestPhrase(to: value)))) } label: { Text("phrase") }
                .help("Snap to the nearest 8-bar phrase boundary — where DJs make the switch")
                .disabled(r.structure == nil)
            Button { play() } label: { Image(systemName: "play.fill") }.help("Play 8 seconds from here")
            if r.analysis != nil {
                Image(systemName: r.isDownbeat(value) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(r.isDownbeat(value) ? Color.green : Color.secondary)
                    .help(r.isDownbeat(value) ? "On a downbeat — transitions line up bar-for-bar" : "Not on a downbeat; use the snap button for a bar-aligned transition")
            }
        }
        .controlSize(.small)
    }
}

// MARK: - Canvas

struct WaveformCanvas: View {
    let analysis: TrackAnalysis?
    let resolved: ResolvedEntry
    let duration: Double
    let pixelsPerSecond: Double
    let entryOverlap: Double
    let ramp: Double
    let outroOverlap: Double

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let pps = pixelsPerSecond
            let h = size.height
            let mid = h / 2
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .textBackgroundColor)))

            // Regions: outside in/out dimmed; entry overlap green; outro overlap blue; ramp faint green.
            let inX = resolved.inTime * pps, outX = resolved.outTime * pps
            ctx.fill(Path(CGRect(x: 0, y: 0, width: inX, height: h)), with: .color(.black.opacity(0.25)))
            ctx.fill(Path(CGRect(x: outX, y: 0, width: size.width - outX, height: h)), with: .color(.black.opacity(0.25)))
            if entryOverlap > 0 {
                ctx.fill(Path(CGRect(x: inX, y: 0, width: entryOverlap * pps, height: h)), with: .color(.green.opacity(0.18)))
                if ramp > 0 { ctx.fill(Path(CGRect(x: inX + entryOverlap * pps, y: 0, width: ramp * pps, height: h)), with: .color(.green.opacity(0.07))) }
            }
            if outroOverlap > 0 {
                ctx.fill(Path(CGRect(x: outX - outroOverlap * pps, y: 0, width: outroOverlap * pps, height: h)), with: .color(.blue.opacity(0.18)))
            }

            // Sections (structure): colored band along the top.
            if let st = analysis?.structure {
                for sec in st.sections {
                    let x0 = resolved.time(ofBar: sec.startBar) * pps
                    let x1 = resolved.time(ofBar: sec.endBar) * pps
                    let color: Color = sec.level == .high ? .orange : (sec.level == .low ? .blue : .gray)
                    ctx.fill(Path(CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: 6)), with: .color(color.opacity(0.8)))
                }
                // Phrase lines every 8 bars.
                var b = st.phraseOffset % 8
                while b < st.barCount {
                    let x = resolved.time(ofBar: b) * pps
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 6)); p.addLine(to: CGPoint(x: x, y: h))
                    ctx.stroke(p, with: .color(.orange.opacity(0.55)), lineWidth: 1.5)
                    b += 8
                }
            }

            // Beat grid.
            if let a = analysis, pps >= 12 {
                let beatLen = resolved.beatLength
                let barLen = resolved.barLength
                let first = resolved.firstDownbeat
                var t = first - floor(first / beatLen) * beatLen
                var k = Int(((t - first) / beatLen).rounded())
                while t < duration {
                    let x = t * pps
                    let isBar = ((k % 4) + 4) % 4 == 0
                    if isBar || pps >= 40 {
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                        ctx.stroke(p, with: .color(isBar ? .primary.opacity(0.35) : .primary.opacity(0.12)), lineWidth: isBar ? 1 : 0.5)
                        if isBar && pps >= 20 {
                            let bar = Int(((t - first) / barLen).rounded()) + 1
                            ctx.draw(Text("\(bar)").font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                        }
                    }
                    t += beatLen
                    k += 1
                }
                _ = a
            }

            // Waveform.
            if let a = analysis, !a.peaks.isEmpty {
                let binsPerPx = a.peaksPerSecond / pps
                var path = Path()
                let w = Int(size.width)
                for px in 0..<w {
                    let b0 = Int(Double(px) * binsPerPx)
                    let b1 = max(b0 + 1, Int(Double(px + 1) * binsPerPx))
                    guard b0 < a.peaks.count else { break }
                    var m: Float = 0
                    for b in b0..<min(b1, a.peaks.count) { m = max(m, a.peaks[b]) }
                    let amp = CGFloat(m) * (mid - 14)
                    path.move(to: CGPoint(x: CGFloat(px) + 0.5, y: mid - amp))
                    path.addLine(to: CGPoint(x: CGFloat(px) + 0.5, y: mid + amp))
                }
                ctx.stroke(path, with: .color(Color.accentColor.opacity(0.85)), lineWidth: 1)
            } else {
                ctx.draw(Text("Waveform appears once the song is analyzed").foregroundColor(.secondary), at: CGPoint(x: 160, y: mid))
            }

            // Time ruler.
            let step: Double = pps >= 100 ? 1 : (pps >= 30 ? 5 : (pps >= 12 ? 10 : 30))
            var tt = 0.0
            while tt <= duration {
                let x = tt * pps
                var p = Path(); p.move(to: CGPoint(x: x, y: h - 14)); p.addLine(to: CGPoint(x: x, y: h))
                ctx.stroke(p, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                ctx.draw(Text(TimeFormat.short(tt)).font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: x + 3, y: h - 7), anchor: .leading)
                tt += step
            }

            // Handles.
            for (x, label, color) in [(inX, "IN", Color.green), (outX, "OUT", Color.red)] {
                var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                ctx.stroke(p, with: .color(color), lineWidth: 2)
                let flag = CGRect(x: label == "IN" ? x : x - 34, y: 18, width: 34, height: 16)
                ctx.fill(Path(roundedRect: flag, cornerRadius: 3), with: .color(color))
                ctx.draw(Text(label).font(.system(size: 10, weight: .bold)).foregroundColor(.white), at: CGPoint(x: flag.midX, y: flag.midY))
            }
        }
    }
}
