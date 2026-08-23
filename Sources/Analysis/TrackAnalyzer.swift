// Runs the whole analysis for one song and packages the result.

import Foundation
import Accelerate

enum TrackAnalyzer {

    static let peaksPerSecond = 50.0

    static func analyze(clip: AudioClip, taggedBPM: Double?) -> TrackAnalysis {
        let (signal, rate) = AudioDecoder.analysisSignal(from: clip)
        let mel = Spectrogram.logMel(signal: signal, sampleRate: rate)
        let grid = BeatAnalyzer.analyze(signal: signal, sampleRate: rate, taggedBPM: taggedBPM, mel: mel)
        let key = KeyAnalyzer.detect(signal: signal, sampleRate: rate)
        let peaks = overviewPeaks(clip: clip)
        let rms = rmsLevel(clip.left, clip.right)

        var analysis = TrackAnalysis(
            version: TrackAnalysis.currentVersion,
            sampleRate: clip.sampleRate, duration: clip.duration,
            bpm: grid.bpm, beatOffset: grid.offset, downbeatPhase: grid.downbeatPhase,
            beats: grid.beats, gridConfidence: grid.confidence,
            keyName: key.name, camelot: key.camelot, keyConfidence: key.confidence,
            peaks: peaks, peaksPerSecond: peaksPerSecond, rms: rms,
            suggestedIn: 0, suggestedOut: clip.duration, structure: nil)
        // The downbeat comes from structure (section changes land on the "1");
        // the beat tracker's guess is only a fallback for very short audio.
        let st = StructureAnalyzer.analyze(clip: clip, signal: signal, analysisRate: rate, mel: mel,
                                           bpm: analysis.bpm, beatOffset: analysis.beatOffset)
        analysis.downbeatPhase = st.downbeatPhase
        analysis.structure = st.structure
        let (inT, outT) = suggestedRange(clip: clip, analysis: analysis)
        analysis.suggestedIn = inT
        analysis.suggestedOut = outT
        return analysis
    }

    /// Peak absolute sample per 1/50 s, from the louder channel.
    static func overviewPeaks(clip: AudioClip) -> [Float] {
        let binLen = Int(clip.sampleRate / peaksPerSecond)
        guard binLen > 0 else { return [] }
        let bins = clip.frameCount / binLen
        var out = [Float](repeating: 0, count: bins)
        clip.left.withUnsafeBufferPointer { l in
            clip.right.withUnsafeBufferPointer { r in
                for i in 0..<bins {
                    var ml: Float = 0, mr: Float = 0
                    vDSP_maxmgv(l.baseAddress! + i * binLen, 1, &ml, vDSP_Length(binLen))
                    vDSP_maxmgv(r.baseAddress! + i * binLen, 1, &mr, vDSP_Length(binLen))
                    out[i] = max(ml, mr)
                }
            }
        }
        return out
    }

    static func rmsLevel(_ l: [Float], _ r: [Float], from: Int = 0, to: Int? = nil) -> Float {
        let end = min(to ?? l.count, l.count)
        guard end > from else { return 0 }
        var rl: Float = 0, rr: Float = 0
        l.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + from, 1, &rl, vDSP_Length(end - from)) }
        r.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + from, 1, &rr, vDSP_Length(end - from)) }
        return sqrt((rl * rl + rr * rr) / 2)
    }

    /// First and last bar that are "in the song" — louder than half the median
    /// bar level — so quiet intros and fade-out outros are skipped by default.
    static func suggestedRange(clip: AudioClip, analysis a: TrackAnalysis) -> (Double, Double) {
        guard a.bpm > 0, clip.duration > a.barLength * 4 else { return (0, clip.duration) }
        let sr = clip.sampleRate
        var bars: [(start: Double, rms: Float)] = []
        var t = a.firstDownbeat
        while t + a.barLength <= clip.duration {
            let s = Int(t * sr), e = Int((t + a.barLength) * sr)
            bars.append((t, rmsLevel(clip.left, clip.right, from: s, to: e)))
            t += a.barLength
        }
        guard bars.count >= 4 else { return (0, clip.duration) }
        let sorted = bars.map { $0.rms }.sorted()
        let median = sorted[sorted.count / 2]
        let threshold = median * 0.5
        var first = bars.firstIndex { $0.rms >= threshold } ?? 0
        var last = bars.lastIndex { $0.rms >= threshold } ?? (bars.count - 1)
        if last < first { first = 0; last = bars.count - 1 }
        // Don't skip more than 32 bars at the start even if it's quiet (long intros are a choice).
        first = min(first, 32)
        let inT = bars[first].start
        let outT = min(clip.duration, bars[last].start + a.barLength)
        return (inT, outT)
    }
}
