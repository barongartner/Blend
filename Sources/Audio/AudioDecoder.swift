// Decoding any audio file AVFoundation can open into plain Float32 arrays,
// resampled to the mix rate if needed. Everything downstream (analysis,
// stretching, mixing) works on these arrays; nothing else touches files.

import Foundation
import AVFoundation
import Accelerate

struct AudioClip {
    let sampleRate: Double
    var left: [Float]
    var right: [Float]

    var frameCount: Int { left.count }
    var duration: Double { Double(frameCount) / sampleRate }

    init(sampleRate: Double, left: [Float], right: [Float]) {
        self.sampleRate = sampleRate
        self.left = left
        self.right = right
    }

    /// (L+R)/2
    func mono() -> [Float] {
        var out = [Float](repeating: 0, count: frameCount)
        var half: Float = 0.5
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                vDSP_vasm(l.baseAddress!, 1, r.baseAddress!, 1, &half, &out, 1, vDSP_Length(frameCount))
            }
        }
        return out
    }
}

struct AudioDecodeError: Error, CustomStringConvertible {
    let description: String
}

enum AudioDecoder {

    /// Decodes `url` into a stereo clip. Mono files are duplicated to both
    /// channels; multichannel files keep their first two channels.
    static func decode(url: URL, sampleRate target: Double? = nil) throws -> AudioClip {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioDecodeError(description: "Can't open \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let srcFormat = file.processingFormat
        let srcRate = srcFormat.sampleRate
        let outRate = target ?? srcRate
        let channels = Int(srcFormat.channelCount)
        guard channels >= 1 else { throw AudioDecodeError(description: "No audio channels in \(url.lastPathComponent)") }

        let totalFrames = Int(file.length)
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(Int(Double(totalFrames) * outRate / srcRate) + 1024)
        right.reserveCapacity(left.capacity)

        let chunk: AVAudioFrameCount = 1 << 16
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunk) else {
            throw AudioDecodeError(description: "Buffer allocation failed")
        }

        if abs(outRate - srcRate) < 0.5 {
            while file.framePosition < file.length {
                try file.read(into: inBuf, frameCount: chunk)
                append(inBuf, channels: channels, to: &left, &right)
                if inBuf.frameLength == 0 { break }
            }
        } else {
            guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outRate,
                                                channels: AVAudioChannelCount(channels), interleaved: false),
                  let converter = AVAudioConverter(from: srcFormat, to: outFormat) else {
                throw AudioDecodeError(description: "Can't resample \(url.lastPathComponent) to \(Int(outRate)) Hz")
            }
            converter.sampleRateConverterQuality = .max
            let outChunk = AVAudioFrameCount(Double(chunk) * outRate / srcRate) + 64
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outChunk) else {
                throw AudioDecodeError(description: "Buffer allocation failed")
            }
            var reachedEnd = false
            var readError: Error?
            while true {
                var convError: NSError?
                let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                    if reachedEnd { outStatus.pointee = .endOfStream; return nil }
                    do {
                        try file.read(into: inBuf, frameCount: chunk)
                    } catch {
                        readError = error
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    if inBuf.frameLength == 0 {
                        reachedEnd = true
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    if file.framePosition >= file.length { reachedEnd = true }
                    outStatus.pointee = .haveData
                    return inBuf
                }
                if let readError { throw readError }
                if let convError { throw convError }
                if outBuf.frameLength > 0 { append(outBuf, channels: channels, to: &left, &right) }
                if status == .endOfStream || status == .error { break }
                if status == .inputRanDry && reachedEnd && outBuf.frameLength == 0 { break }
            }
        }
        guard !left.isEmpty else { throw AudioDecodeError(description: "\(url.lastPathComponent) decoded to nothing") }
        return AudioClip(sampleRate: outRate, left: left, right: right)
    }

    private static func append(_ buf: AVAudioPCMBuffer, channels: Int, to left: inout [Float], _ right: inout [Float]) {
        let n = Int(buf.frameLength)
        guard n > 0, let data = buf.floatChannelData else { return }
        left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
        if channels >= 2 {
            right.append(contentsOf: UnsafeBufferPointer(start: data[1], count: n))
        } else {
            right.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
        }
    }

    /// Duration in seconds without decoding.
    static func duration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    // MARK: - Analysis signal

    /// Mono, decimated by 2 through a half-band FIR. Beat/key analysis doesn't
    /// need anything above ~11 kHz and runs four times faster on half the samples.
    static func analysisSignal(from clip: AudioClip) -> (signal: [Float], sampleRate: Double) {
        let mono = clip.mono()
        let taps = 31
        var filter = [Float](repeating: 0, count: taps)
        let center = taps / 2
        var sum: Float = 0
        for i in 0..<taps {
            let x = Float(i - center)
            let sinc: Float = x == 0 ? 0.5 : sin(Float.pi * x * 0.5) / (Float.pi * x)
            let w = 0.54 - 0.46 * cos(2 * Float.pi * Float(i) / Float(taps - 1))
            filter[i] = sinc * w
            sum += filter[i]
        }
        for i in 0..<taps { filter[i] /= sum }

        let outCount = (mono.count - taps) / 2 + 1
        guard outCount > 0 else { return (mono, clip.sampleRate) }
        var out = [Float](repeating: 0, count: outCount)
        mono.withUnsafeBufferPointer { m in
            vDSP_desamp(m.baseAddress!, 2, filter, &out, vDSP_Length(outCount), vDSP_Length(taps))
        }
        return (out, clip.sampleRate / 2)
    }
}
