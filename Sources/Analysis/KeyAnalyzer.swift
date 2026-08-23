// Musical key by chroma correlation with the Krumhansl-Kessler profiles, and
// the Camelot code DJs use to see at a glance whether two songs mix
// harmonically (same number, or ±1, or A↔B with the same number).

import Foundation
import Accelerate

struct KeyResult {
    var name: String       // "A minor"
    var camelot: String    // "8A"
    var confidence: Double // 0...1, how clearly the best key beats the runner-up
}

enum KeyAnalyzer {

    static let noteNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    // Camelot wheel, indexed by pitch class. Majors are "B", minors "A".
    static let camelotMajor = ["8B", "3B", "10B", "5B", "12B", "7B", "2B", "9B", "4B", "11B", "6B", "1B"]
    static let camelotMinor = ["5A", "12A", "7A", "2A", "9A", "4A", "11A", "6A", "1A", "8A", "3A", "10A"]

    /// Mean chroma vector over the signal (12 pitch classes, normalized).
    static func chroma(signal: [Float], sampleRate: Double) -> [Double] {
        let n = 8192
        let hop = 4096
        guard signal.count > n else { return [Double](repeating: 1.0 / 12, count: 12) }
        let fft = RealFFT(size: n)
        let half = n / 2
        let binHz = sampleRate / Double(n)
        // Map each bin in 55 Hz ... 1760 Hz to a pitch class.
        var binClass = [Int](repeating: -1, count: half)
        for k in 1..<half {
            let f = Double(k) * binHz
            if f < 55 || f > 1760 { continue }
            let midi = 69 + 12 * log2(f / 440)
            binClass[k] = ((Int(midi.rounded()) % 12) + 12) % 12
        }
        var chroma = [Double](repeating: 0, count: 12)
        var power = [Float](repeating: 0, count: half)
        let frames = (signal.count - n) / hop + 1
        signal.withUnsafeBufferPointer { sp in
            power.withUnsafeMutableBufferPointer { pp in
                for t in 0..<frames {
                    fft.powerSpectrum(sp.baseAddress! + t * hop, into: pp.baseAddress!)
                    for k in 1..<half where binClass[k] >= 0 {
                        chroma[binClass[k]] += Double(sqrtf(pp[k]))
                    }
                }
            }
        }
        let total = chroma.reduce(0, +)
        if total > 0 { for i in 0..<12 { chroma[i] /= total } }
        return chroma
    }

    static func detect(signal: [Float], sampleRate: Double) -> KeyResult {
        let c = chroma(signal: signal, sampleRate: sampleRate)
        var scores: [(score: Double, pc: Int, major: Bool)] = []
        for pc in 0..<12 {
            var rotated = [Double](repeating: 0, count: 12)
            for i in 0..<12 { rotated[i] = c[(i + pc) % 12] }
            scores.append((pearson(rotated, majorProfile), pc, true))
            scores.append((pearson(rotated, minorProfile), pc, false))
        }
        scores.sort { $0.score > $1.score }
        let best = scores[0], second = scores[1]
        let name = "\(noteNames[best.pc]) \(best.major ? "major" : "minor")"
        let camelot = best.major ? camelotMajor[best.pc] : camelotMinor[best.pc]
        let conf = max(0, min(1, (best.score - second.score) * 4))
        return KeyResult(name: name, camelot: camelot, confidence: conf)
    }

    private static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<a.count {
            num += (a[i] - ma) * (b[i] - mb)
            da += (a[i] - ma) * (a[i] - ma)
            db += (b[i] - mb) * (b[i] - mb)
        }
        let d = sqrt(da * db)
        return d > 0 ? num / d : 0
    }

    /// How well two Camelot codes mix: 2 = perfect, 1 = good, 0 = clash.
    static func compatibility(_ a: String, _ b: String) -> Int {
        guard let na = Int(a.dropLast()), let nb = Int(b.dropLast()), let la = a.last, let lb = b.last else { return 0 }
        if na == nb { return la == lb ? 2 : 1 }
        let diff = min(abs(na - nb), 12 - abs(na - nb))
        if diff == 1 && la == lb { return 1 }
        return 0
    }
}
