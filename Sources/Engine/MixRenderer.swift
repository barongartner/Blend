// Turns a MixLayout into audio. Each song is rendered once into its "span"
// (its whole output: rate-mapped source, level-matched, plus any filter sweep
// at its end and any synthesized echo tail); the composer then writes any
// output range by copying solo regions straight from spans and mixing the
// regions where two songs meet. The full render streams the mix to a float
// CAF in chunks so only two or three songs are in memory.

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

    /// −14 dBFS RMS per song; the export limiter catches the peaks.
    static let targetRMS: Float = 0.2
    static let maxMatchGainDB = 12.0

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
        let keyLock = settings.keyLock
        var out = StereoBuffer(count: t.span)

        // Source audio: stretched entry + ramp, exact copy of the rest.
        if t.isStretched {
            let seam = t.entryOverlap + t.rampOut
            let fade = max(0, min(1024, t.sourceSpan - seam))
            let stretched = TimeStretch.render(source: clip, count: min(t.sourceSpan, seam + fade), keyLock: keyLock) { t.sourcePosition(atOutputOffset: $0) }
            let rest = TimeStretch.copy(source: clip, from: Int(t.sourcePosition(atOutputOffset: Double(seam)).rounded()), count: t.sourceSpan - seam)
            for u in 0..<min(seam, stretched.left.count) {
                out.left[u] = stretched.left[u]
                out.right[u] = stretched.right[u]
            }
            for j in 0..<(t.sourceSpan - seam) {
                let u = seam + j
                if j < fade, u < stretched.left.count {
                    let w = Float(j) / Float(fade)
                    out.left[u] = stretched.left[u] * (1 - w) + rest.left[j] * w
                    out.right[u] = stretched.right[u] * (1 - w) + rest.right[j] * w
                } else {
                    out.left[u] = rest.left[j]
                    out.right[u] = rest.right[j]
                }
            }
        } else {
            let o = TimeStretch.copy(source: clip, from: Int(t.inSample.rounded()), count: t.sourceSpan)
            for u in 0..<t.sourceSpan {
                out.left[u] = o.left[u]
                out.right[u] = o.right[u]
            }
        }

        // Level.
        var g = gain(for: i, clip: clip)
        vDSP_vsmul(out.left, 1, &g, &out.left, 1, vDSP_Length(out.count))
        vDSP_vsmul(out.right, 1, &g, &out.right, 1, vDSP_Length(out.count))

        let isLast = i == layout.tracks.count - 1
        let transition = entries[i].transitionOut
        let beatSamples = entries[i].beatLength * sampleRate

        // Filter drop: high-pass sweep over the last bars of the source, optional riser.
        if !isLast, let tr = transition, tr.style == .filterDrop, t.sweep > 0 {
            Effects.highPassSweep(&out, from: t.sourceSpan - t.sweep, count: t.sweep, sampleRate: sampleRate)
            if tr.riser {
                Effects.addRiser(&out, from: t.sourceSpan - t.sweep, count: t.sweep, sampleRate: sampleRate, level: 0.12)
            }
        }

        // Echo tail: the last two beats feed a tempo-synced delay that rings out under the next song.
        if !isLast, t.tail > 0 {
            Effects.echoTail(&out, sourceEnd: t.sourceSpan, feedBeats: 2, beatSamples: beatSamples, tail: t.tail, sampleRate: sampleRate)
        }

        // Anti-click fades at hard edges, 5 ms.
        let edge = Int(sampleRate * 0.005)
        if i > 0 && t.entryOverlap == 0 { applyFade(&out, from: 0, count: edge, fadeIn: true) }
        if !isLast && t.outroOverlap == 0 {
            // Dry signal stops at the cut; a short fade avoids a click (the echo tail, if any, continues).
            applyFade(&out, from: max(0, t.sourceSpan - edge), count: min(edge, t.sourceSpan), fadeIn: false)
        }

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

    /// The mixed region where song `i` comes in over song `i-1`'s outro or tail.
    func transition(into i: Int) throws -> StereoBuffer {
        if let t = transitions[i] { return t }
        let cur = layout.tracks[i]
        let prev = layout.tracks[i - 1]
        let len = cur.entryOverlap
        let a = try span(i - 1)
        let b = try span(i)
        let aStart = prev.span - len
        var out = StereoBuffer(count: len)
        let style = entries[i - 1].transitionOut?.style ?? .cut
        let beatSamples = entries[i - 1].beatLength * sampleRate
        switch style {
        case .blend:
            Effects.blend(a: a, aOffset: aStart, b: b, beatSamples: beatSamples, sampleRate: sampleRate, into: &out)
        case .echoOut, .filterDrop, .cut:
            // Incoming at full level; the outgoing contributes only its ringing tail.
            for u in 0..<len {
                out.left[u] = b.left[u] + a.left[aStart + u]
                out.right[u] = b.right[u] + a.right[aStart + u]
            }
        }
        transitions[i] = out
        return out
    }

    // MARK: - Composition

    /// Output samples [from, to) of the finished mix.
    func compose(from: Int, to: Int) throws -> StereoBuffer {
        let count = max(0, to - from)
        var out = StereoBuffer(count: count)
        guard count > 0 else { return out }
        for t in layout.tracks where t.end > from && t.start < to {
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
            let s0 = max(from, t.soloStart), s1 = min(to, t.outroStart)
            if s1 > s0 {
                let sp = try span(t.index)
                for s in s0..<s1 {
                    out.left[s - from] = sp.left[s - t.start]
                    out.right[s - from] = sp.right[s - t.start]
                }
            }
        }
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

// MARK: - Effects

enum Effects {

    /// Blend: the incoming song opens up from under a low-pass while its bass
    /// is held back; at the midpoint the bass hands over in one beat; the
    /// outgoing song's highs roll off over the last quarter. Equal-power gains.
    static func blend(a: StereoBuffer, aOffset: Int, b: StereoBuffer, beatSamples: Double, sampleRate sr: Double, into out: inout StereoBuffer) {
        let len = out.count
        guard len > 0 else { return }
        var xaL = CrossoverPair(cutoff: 200, sampleRate: sr), xaR = CrossoverPair(cutoff: 200, sampleRate: sr)
        var xbL = CrossoverPair(cutoff: 200, sampleRate: sr), xbR = CrossoverPair(cutoff: 200, sampleRate: sr)
        var lpBL = Biquad(), lpBR = Biquad(), lpAL = Biquad(), lpAR = Biquad()
        let half = min(Double(len) / 2, beatSamples / 2)
        let swapStart = Double(len) / 2 - half, swapEnd = Double(len) / 2 + half
        let block = 64
        var u = 0
        while u < len {
            let x = Double(u) / Double(len)
            // Incoming opens from 600 Hz to wide open over the first 60%.
            let openX = min(1, x / 0.6)
            let bCut = 600 * pow(20000 / 600, openX)
            lpBL.setLowpass(cutoff: bCut, sampleRate: sr); lpBR.setLowpass(cutoff: bCut, sampleRate: sr)
            // Outgoing's top rolls off over the last 35%.
            let closeX = max(0, (x - 0.65) / 0.35)
            let aCut = 20000 * pow(1500 / 20000, closeX)
            lpAL.setLowpass(cutoff: aCut, sampleRate: sr); lpAR.setLowpass(cutoff: aCut, sampleRate: sr)
            let end = min(len, u + block)
            for v in u..<end {
                let xf = Float(v) / Float(len)
                let gah = cosf(xf * .pi / 2), gbh = sinf(xf * .pi / 2)
                var gbl: Float = 0
                if Double(v) >= swapEnd { gbl = 1 }
                else if Double(v) > swapStart { gbl = Float((Double(v) - swapStart) / (swapEnd - swapStart)) }
                let gal = 1 - gbl
                let aL = lpAL.process(a.left[aOffset + v]), aR = lpAR.process(a.right[aOffset + v])
                let bL = lpBL.process(b.left[v]), bR = lpBR.process(b.right[v])
                let (aLowL, aHighL) = xaL.split(aL)
                let (aLowR, aHighR) = xaR.split(aR)
                let (bLowL, bHighL) = xbL.split(bL)
                let (bLowR, bHighR) = xbR.split(bR)
                out.left[v] = aHighL * gah + aLowL * gal + bHighL * gbh + bLowL * gbl
                out.right[v] = aHighR * gah + aLowR * gal + bHighR * gbh + bLowR * gbl
            }
            u = end
        }
    }

    /// High-pass sweep from 30 Hz to 1.5 kHz over `count` samples (the song thins out).
    static func highPassSweep(_ buf: inout StereoBuffer, from: Int, count: Int, sampleRate sr: Double) {
        guard count > 0, from >= 0, from + count <= buf.count else { return }
        var hpL = Biquad(), hpR = Biquad()
        let block = 64
        var u = 0
        while u < count {
            let x = Double(u) / Double(count)
            let cut = 30 * pow(1500 / 30, x * x)   // slow start, fast finish
            hpL.setHighpass(cutoff: cut, sampleRate: sr); hpR.setHighpass(cutoff: cut, sampleRate: sr)
            let end = min(count, u + block)
            for v in u..<end {
                buf.left[from + v] = hpL.process(buf.left[from + v])
                buf.right[from + v] = hpR.process(buf.right[from + v])
            }
            u = end
        }
    }

    /// White-noise riser: band-pass sweeping up, volume swelling to `level`.
    static func addRiser(_ buf: inout StereoBuffer, from: Int, count: Int, sampleRate sr: Double, level: Float) {
        guard count > 0, from >= 0, from + count <= buf.count else { return }
        var bp = Biquad()
        var rng: UInt64 = 0x9E3779B97F4A7C15
        let block = 64
        var u = 0
        while u < count {
            let x = Double(u) / Double(count)
            bp.setHighpass(cutoff: 300 * pow(4000 / 300, x), sampleRate: sr, q: 1.2)
            let end = min(count, u + block)
            for v in u..<end {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                let n = Float(Int64(bitPattern: rng) >> 40) / Float(1 << 23)
                let xf = Float(v) / Float(count)
                let s = bp.process(n) * level * xf * xf
                buf.left[from + v] += s
                buf.right[from + v] += s
            }
            u = end
        }
    }

    /// Feeds the last `feedBeats` beats of the dry signal into a half-beat
    /// feedback delay (low-passed, decaying) and writes the wet signal over the
    /// end of the source and the whole tail, fading out across the tail.
    static func echoTail(_ buf: inout StereoBuffer, sourceEnd: Int, feedBeats: Int, beatSamples: Double, tail: Int, sampleRate sr: Double) {
        let feed = min(sourceEnd, Int(Double(feedBeats) * beatSamples))
        guard feed > 0, tail > 0, sourceEnd + tail <= buf.count else { return }
        let delay = max(1, Int((beatSamples / 2).rounded()))
        let feedback: Float = 0.62
        var lpL = Biquad(), lpR = Biquad()
        lpL.setLowpass(cutoff: 2500, sampleRate: sr); lpR.setLowpass(cutoff: 2500, sampleRate: sr)
        let start = sourceEnd - feed
        let total = feed + tail
        var wetL = [Float](repeating: 0, count: total)
        var wetR = [Float](repeating: 0, count: total)
        for n in 0..<total {
            var fbL: Float = 0, fbR: Float = 0
            if n - delay >= 0 {
                fbL = (wetL[n - delay] + (n - delay < feed ? buf.left[start + n - delay] : 0)) * feedback
                fbR = (wetR[n - delay] + (n - delay < feed ? buf.right[start + n - delay] : 0)) * feedback
            }
            wetL[n] = lpL.process(fbL)
            wetR[n] = lpR.process(fbR)
        }
        // Write: during the feed beats add the wet to the dry; the tail is wet only, fading out.
        for n in 0..<total {
            var w: Float = 1
            if n >= feed { w = 1 - Float(n - feed) / Float(tail) }
            buf.left[start + n] += wetL[n] * w
            buf.right[start + n] += wetR[n] * w
        }
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

    /// Converts the float CAF master to the chosen format through a brickwall
    /// limiter (ceiling −1 dBFS) so the louder loudness target never clips.
    static func export(master: URL, peak: Float, to dest: URL, format: ExportFormat, sampleRate: Double, ffmpeg: String?) throws {
        try? FileManager.default.removeItem(at: dest)
        switch format {
        case .wav16, .wav24:
            try writePCM(master: master, to: dest, bits: format == .wav16 ? 16 : 24, sampleRate: sampleRate)
        case .m4a:
            let settingsDict: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000,
            ]
            try transcode(master: master, to: dest, settings: settingsDict, sampleRate: sampleRate)
        case .mp3:
            guard let ffmpeg else {
                throw RenderError(description: "MP3 export needs ffmpeg. Install it (brew install ffmpeg) or run TrackForge once so it downloads one — or export WAV and convert.")
            }
            let tmpWav = dest.deletingPathExtension().appendingPathExtension("blend-tmp.wav")
            try writePCM(master: master, to: tmpWav, bits: 16, sampleRate: sampleRate)
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

    private static func writePCM(master: URL, to dest: URL, bits: Int, sampleRate: Double) throws {
        let settingsDict: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: bits,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        try transcode(master: master, to: dest, settings: settingsDict, sampleRate: sampleRate)
    }

    private static func transcode(master: URL, to dest: URL, settings: [String: Any], sampleRate: Double) throws {
        let input = try AVAudioFile(forReading: master, commonFormat: .pcmFormatFloat32, interleaved: false)
        let output = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk) else {
            throw RenderError(description: "Buffer allocation failed")
        }
        var limiter = Limiter(sampleRate: sampleRate, ceiling: 0.891)
        while input.framePosition < input.length {
            try input.read(into: buf, frameCount: chunk)
            guard buf.frameLength > 0, let data = buf.floatChannelData else { break }
            limiter.process(left: data[0], right: data[1], count: Int(buf.frameLength))
            try output.write(from: buf)
        }
    }
}

/// Brickwall peak limiter with 2 ms lookahead: instant attack (via the
/// lookahead delay), 80 ms release. Transparent on normal material, holds
/// the loud overlaps at the ceiling instead of clipping.
struct Limiter {
    private let ceiling: Float
    private let lookahead: Int
    private let releaseCoef: Float
    private var delayL: [Float]
    private var delayR: [Float]
    private var gainHold: [Float]
    private var writeIndex = 0
    private var gain: Float = 1

    init(sampleRate: Double, ceiling: Float) {
        self.ceiling = ceiling
        lookahead = max(1, Int(sampleRate * 0.002))
        releaseCoef = Float(exp(-1 / (0.080 * sampleRate)))
        delayL = [Float](repeating: 0, count: lookahead)
        delayR = [Float](repeating: 0, count: lookahead)
        gainHold = [Float](repeating: 1, count: lookahead)
    }

    mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count {
            let inL = left[i], inR = right[i]
            let peak = max(abs(inL), abs(inR))
            // Gain needed for this sample; it applies to the delayed signal via the hold buffer.
            let needed: Float = peak > ceiling ? ceiling / peak : 1
            // Spread the reduction back over the lookahead window (minimum over the window).
            if needed < 1 {
                for k in 0..<lookahead where needed < gainHold[(writeIndex + k) % lookahead] {
                    gainHold[(writeIndex + k) % lookahead] = needed
                }
            }
            let outL = delayL[writeIndex], outR = delayR[writeIndex]
            let target = gainHold[writeIndex]
            if target < gain { gain = target } else { gain = target + (gain - target) * releaseCoef }
            left[i] = outL * gain
            right[i] = outR * gain
            delayL[writeIndex] = inL
            delayR[writeIndex] = inR
            gainHold[writeIndex] = 1
            writeIndex = (writeIndex + 1) % lookahead
        }
    }
}
