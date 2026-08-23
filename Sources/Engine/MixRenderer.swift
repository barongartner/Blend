// Turns a MixLayout into audio. Each song is rendered once into its "span"
// (its whole output, rate-mapped and level-matched); the composer then writes
// any output range by copying solo regions straight from spans and running
// the transition blend where two spans overlap. The full render streams the
// mix to a float CAF in chunks so only two or three songs are in memory.

import Foundation
import AVFoundation
import Accelerate

struct RenderError: Error, CustomStringConvertible {
    let description: String
}

struct StereoBuffer {
    var left: [Float]
    var right: [Float]
    var count: Int { left.count }
    init(count: Int) {
        left = [Float](repeating: 0, count: count)
        right = [Float](repeating: 0, count: count)
    }
    init(left: [Float], right: [Float]) { self.left = left; self.right = right }
}

final class MixRenderer {

    let layout: MixLayout
    let entries: [ResolvedEntry]
    let settings: MixSettings
    let clipProvider: (Int) throws -> AudioClip

    static let targetRMS: Float = 0.1585   // −16 dBFS
    static let maxMatchGainDB = 10.0

    private var spans: [Int: StereoBuffer] = [:]
    private var transitions: [Int: StereoBuffer] = [:]   // keyed by incoming track index
    private var gains: [Int: Float] = [:]

    init(layout: MixLayout, entries: [ResolvedEntry], settings: MixSettings, clipProvider: @escaping (Int) throws -> AudioClip) {
        self.layout = layout
        self.entries = entries
        self.settings = settings
        self.clipProvider = clipProvider
    }

    var sampleRate: Double { layout.sampleRate }

    // MARK: - Spans

    func span(_ i: Int) throws -> StereoBuffer {
        if let s = spans[i] { return s }
        let t = layout.tracks[i]
        let clip = try clipProvider(i)
        var out: StereoBuffer
        let keyLock = settings.keyLock
        if t.isStretched {
            // Stretch the entry + ramp, copy the rest exactly, crossfade at the seam
            // so beat positions in the body are sample-exact.
            let seam = t.entryOverlap + t.rampOut
            let fade = min(1024, t.span - seam)
            let stretched = TimeStretch.render(source: clip, count: min(t.span, seam + fade), keyLock: keyLock) { t.sourcePosition(atOutputOffset: $0) }
            let rest = TimeStretch.copy(source: clip, from: Int(t.sourcePosition(atOutputOffset: Double(seam)).rounded()), count: t.span - seam)
            out = StereoBuffer(count: t.span)
            for u in 0..<seam {
                out.left[u] = stretched.left[u]
                out.right[u] = stretched.right[u]
            }
            for j in 0..<(t.span - seam) {
                let u = seam + j
                if j < fade {
                    let w = Float(j) / Float(fade)
                    out.left[u] = stretched.left[u] * (1 - w) + rest.left[j] * w
                    out.right[u] = stretched.right[u] * (1 - w) + rest.right[j] * w
                } else {
                    out.left[u] = rest.left[j]
                    out.right[u] = rest.right[j]
                }
            }
        } else {
            let o = TimeStretch.copy(source: clip, from: Int(t.inSample.rounded()), count: t.span)
            out = StereoBuffer(left: o.left, right: o.right)
        }

        // Level.
        let g = gain(for: i, clip: clip)
        var gg = g
        vDSP_vsmul(out.left, 1, &gg, &out.left, 1, vDSP_Length(out.count))
        vDSP_vsmul(out.right, 1, &gg, &out.right, 1, vDSP_Length(out.count))

        // Anti-click fades at hard edges (cuts), 5 ms.
        let edge = Int(sampleRate * 0.005)
        if i > 0 && t.entryOverlap == 0 { applyFade(&out, from: 0, count: edge, fadeIn: true) }
        if i < layout.tracks.count - 1 && t.outroOverlap == 0 { applyFade(&out, from: out.count - edge, count: edge, fadeIn: false) }

        spans[i] = out
        return out
    }

    private func gain(for i: Int, clip: AudioClip) -> Float {
        if let g = gains[i] { return g }
        let t = layout.tracks[i]
        var g: Float = 1
        if settings.matchLoudness {
            let rms = TrackAnalyzer.rmsLevel(clip.left, clip.right, from: max(0, Int(t.inSample)), to: min(clip.frameCount, Int(t.outSample)))
            if rms > 1e-5 {
                g = min(MixRenderer.targetRMS / rms, Float(pow(10, MixRenderer.maxMatchGainDB / 20)))
            }
        }
        g *= Float(pow(10, entries[i].entry.gainDB / 20))
        gains[i] = g
        return g
    }

    private func applyFade(_ buf: inout StereoBuffer, from: Int, count: Int, fadeIn: Bool) {
        guard count > 0, from >= 0, from + count <= buf.count else { return }
        for j in 0..<count {
            var w = Float(j) / Float(count)
            if !fadeIn { w = 1 - w }
            buf.left[from + j] *= w
            buf.right[from + j] *= w
        }
    }

    func evict(before sample: Int) {
        for (i, t) in layout.tracks.enumerated() where t.end < sample {
            spans[i] = nil
            transitions[i] = nil
        }
    }

    // MARK: - Transitions

    /// The blended overlap where song `i` comes in over song `i-1`.
    func transition(into i: Int) throws -> StereoBuffer {
        if let t = transitions[i] { return t }
        let cur = layout.tracks[i]
        let prev = layout.tracks[i - 1]
        let len = cur.entryOverlap
        let a = try span(i - 1)
        let b = try span(i)
        let aStart = prev.span - prev.outroOverlap
        var out = StereoBuffer(count: len)
        let style = entries[i - 1].transition.style
        let beatSamples = entries[i - 1].beatLength * sampleRate
        blend(a: a, aOffset: aStart, b: b, style: style, beatSamples: beatSamples, into: &out)
        transitions[i] = out
        return out
    }

    private func blend(a: StereoBuffer, aOffset: Int, b: StereoBuffer, style: TransitionStyle, beatSamples: Double, into out: inout StereoBuffer) {
        let len = out.count
        guard len > 0 else { return }
        let sr = sampleRate
        switch style {
        case .crossfade, .cut:
            for u in 0..<len {
                let x = Float(u) / Float(len)
                let ga = cosf(x * .pi / 2), gb = sinf(x * .pi / 2)
                out.left[u] = a.left[aOffset + u] * ga + b.left[u] * gb
                out.right[u] = a.right[aOffset + u] * ga + b.right[u] * gb
            }
        case .bassSwap:
            var xaL = CrossoverPair(cutoff: 200, sampleRate: sr), xaR = CrossoverPair(cutoff: 200, sampleRate: sr)
            var xbL = CrossoverPair(cutoff: 200, sampleRate: sr), xbR = CrossoverPair(cutoff: 200, sampleRate: sr)
            // Bass hands over across one beat centred on the midpoint.
            let half = min(Double(len) / 2, beatSamples / 2)
            let swapStart = Double(len) / 2 - half, swapEnd = Double(len) / 2 + half
            for u in 0..<len {
                let x = Float(u) / Float(len)
                let gah = cosf(x * .pi / 2), gbh = sinf(x * .pi / 2)
                var gbl: Float = 0
                if Double(u) >= swapEnd { gbl = 1 }
                else if Double(u) > swapStart { gbl = Float((Double(u) - swapStart) / (swapEnd - swapStart)) }
                let gal = 1 - gbl
                let (aLowL, aHighL) = xaL.split(a.left[aOffset + u])
                let (aLowR, aHighR) = xaR.split(a.right[aOffset + u])
                let (bLowL, bHighL) = xbL.split(b.left[u])
                let (bLowR, bHighR) = xbR.split(b.right[u])
                out.left[u] = aHighL * gah + aLowL * gal + bHighL * gbh + bLowL * gbl
                out.right[u] = aHighR * gah + aLowR * gal + bHighR * gbh + bLowR * gbl
            }
        case .filterSweep:
            var lpL = Biquad(), lpR = Biquad(), hpL = Biquad(), hpR = Biquad()
            let block = 64
            var u = 0
            while u < len {
                let x = Double(u) / Double(len)
                let lpCut = 18000 * pow(140 / 18000, x)
                let hpCut = 1500 * pow(20 / 1500, x)
                lpL.setLowpass(cutoff: lpCut, sampleRate: sr); lpR.setLowpass(cutoff: lpCut, sampleRate: sr)
                hpL.setHighpass(cutoff: hpCut, sampleRate: sr); hpR.setHighpass(cutoff: hpCut, sampleRate: sr)
                let end = min(len, u + block)
                for v in u..<end {
                    let xf = Float(v) / Float(len)
                    let ga = cosf(xf * .pi / 2), gb = sinf(xf * .pi / 2)
                    out.left[v] = lpL.process(a.left[aOffset + v]) * ga + hpL.process(b.left[v]) * gb
                    out.right[v] = lpR.process(a.right[aOffset + v]) * ga + hpR.process(b.right[v]) * gb
                }
                u = end
            }
        }
    }

    // MARK: - Composition

    /// Output samples [from, to) of the finished mix.
    func compose(from: Int, to: Int) throws -> StereoBuffer {
        let count = max(0, to - from)
        var out = StereoBuffer(count: count)
        guard count > 0 else { return out }
        for t in layout.tracks where t.end > from && t.start < to {
            // Entry overlap (blend with the previous song).
            if t.entryOverlap > 0 && t.index > 0 {
                let r0 = max(from, t.start), r1 = min(to, t.soloStart)
                if r1 > r0 {
                    let mixed = try transition(into: t.index)
                    for s in r0..<r1 {
                        out.left[s - from] = mixed.left[s - t.start]
                        out.right[s - from] = mixed.right[s - t.start]
                    }
                }
            }
            // Solo region.
            let s0 = max(from, t.soloStart), s1 = min(to, t.outroStart)
            if s1 > s0 {
                let sp = try span(t.index)
                for s in s0..<s1 {
                    out.left[s - from] = sp.left[s - t.start]
                    out.right[s - from] = sp.right[s - t.start]
                }
            }
        }
        // Global fades.
        let total = layout.totalSamples
        let fadeIn = Int(sampleRate * 0.01)
        let fadeOut = max(Int(sampleRate * 0.01), Int(settings.endFadeSeconds * sampleRate))
        for s in from..<to {
            var w: Float = 1
            if s < fadeIn { w = Float(s) / Float(fadeIn) }
            if s >= total - fadeOut { w *= Float(total - s) / Float(fadeOut) }
            if w != 1 {
                out.left[s - from] *= w
                out.right[s - from] *= w
            }
        }
        return out
    }

    // MARK: - Full render

    struct Result {
        var url: URL
        var peak: Float
        var frames: Int
    }

    /// Streams the whole mix to a 32-bit float CAF.
    func render(to url: URL, progress: (Double) -> Void, isCancelled: () -> Bool) throws -> Result {
        let total = layout.totalSamples
        guard total > 0 else { throw RenderError(description: "The mix is empty.") }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false) else {
            throw RenderError(description: "Bad audio format")
        }
        try? FileManager.default.removeItem(at: url)
        let settingsDict: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settingsDict, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = Int(sampleRate * 5)
        var peak: Float = 0
        var pos = 0
        while pos < total {
            if isCancelled() { throw RenderError(description: "Cancelled") }
            let end = min(total, pos + chunk)
            let buf = try compose(from: pos, to: end)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(buf.count)) else {
                throw RenderError(description: "Buffer allocation failed")
            }
            pcm.frameLength = AVAudioFrameCount(buf.count)
            buf.left.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: buf.count) }
            buf.right.withUnsafeBufferPointer { pcm.floatChannelData![1].update(from: $0.baseAddress!, count: buf.count) }
            try file.write(from: pcm)
            var pl: Float = 0, pr: Float = 0
            vDSP_maxmgv(buf.left, 1, &pl, vDSP_Length(buf.count))
            vDSP_maxmgv(buf.right, 1, &pr, vDSP_Length(buf.count))
            peak = max(peak, pl, pr)
            pos = end
            evict(before: pos)
            progress(Double(pos) / Double(total))
        }
        return Result(url: url, peak: peak, frames: total)
    }
}

// MARK: - Export

enum Exporter {

    /// Finds an ffmpeg to encode MP3 with: an explicit path, TrackForge's
    /// downloaded copy, Homebrew/MacPorts locations, then PATH.
    static func findFFmpeg(explicit: String? = nil) -> String? {
        var candidates: [String] = []
        if let explicit, !explicit.isEmpty { candidates.append(explicit) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates += [
            "\(home)/Library/Application Support/Blend/tools/ffmpeg",
            "\(home)/Library/Application Support/TrackForge/tools/ffmpeg",
            "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let p = "\(dir)/ffmpeg"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    /// Converts the float CAF master to the chosen format, normalizing so the
    /// loudest peak sits at −1 dBFS when the render exceeded that.
    static func export(master: URL, peak: Float, to dest: URL, format: ExportFormat, sampleRate: Double, ffmpeg: String?) throws {
        let ceiling: Float = 0.891   // −1 dBFS
        let scale: Float = peak > ceiling ? ceiling / peak : 1
        try? FileManager.default.removeItem(at: dest)
        switch format {
        case .wav16, .wav24:
            try writePCM(master: master, to: dest, bits: format == .wav16 ? 16 : 24, scale: scale, sampleRate: sampleRate)
        case .m4a:
            let settingsDict: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000,
            ]
            try transcode(master: master, to: dest, settings: settingsDict, scale: scale, sampleRate: sampleRate)
        case .mp3:
            guard let ffmpeg else {
                throw RenderError(description: "MP3 export needs ffmpeg. Install it (brew install ffmpeg) or run TrackForge once so it downloads one — or export WAV and convert.")
            }
            let tmpWav = dest.deletingPathExtension().appendingPathExtension("blend-tmp.wav")
            try writePCM(master: master, to: tmpWav, bits: 16, scale: scale, sampleRate: sampleRate)
            defer { try? FileManager.default.removeItem(at: tmpWav) }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            proc.arguments = ["-y", "-loglevel", "error", "-i", tmpWav.path, "-codec:a", "libmp3lame", "-b:a", "320k", dest.path]
            let err = Pipe()
            proc.standardError = err
            proc.standardOutput = Pipe()
            try proc.run()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw RenderError(description: "ffmpeg failed: \(String(data: errData, encoding: .utf8) ?? "")")
            }
        }
    }

    private static func writePCM(master: URL, to dest: URL, bits: Int, scale: Float, sampleRate: Double) throws {
        let settingsDict: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: bits,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        try transcode(master: master, to: dest, settings: settingsDict, scale: scale, sampleRate: sampleRate)
    }

    private static func transcode(master: URL, to dest: URL, settings: [String: Any], scale: Float, sampleRate: Double) throws {
        let input = try AVAudioFile(forReading: master, commonFormat: .pcmFormatFloat32, interleaved: false)
        let output = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk) else {
            throw RenderError(description: "Buffer allocation failed")
        }
        while input.framePosition < input.length {
            try input.read(into: buf, frameCount: chunk)
            guard buf.frameLength > 0 else { break }
            if scale != 1, let data = buf.floatChannelData {
                var s = scale
                for ch in 0..<Int(buf.format.channelCount) {
                    vDSP_vsmul(data[ch], 1, &s, data[ch], 1, vDSP_Length(buf.frameLength))
                }
            }
            try output.write(from: buf)
        }
    }
}
