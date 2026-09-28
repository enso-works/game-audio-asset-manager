import Accelerate
import Foundation

/// Tempo and beat phase of a sound. The offset is the time of a downbeat, in seconds.
struct TempoInfo: Codable, Equatable, Sendable {
    var bpm: Double
    var offset: Double
    var beatsPerBar: Int

    var beatSeconds: Double { 60 / bpm }
    var barSeconds: Double { beatSeconds * Double(beatsPerBar) }

    /// Keeps the grid on the same audio after cutting `seconds` from the start.
    func shifted(by seconds: Double) -> TempoInfo {
        var copy = self
        let bar = barSeconds
        copy.offset = ((offset + seconds).truncatingRemainder(dividingBy: bar) + bar).truncatingRemainder(dividingBy: bar)
        return copy
    }

    /// Nearest beat (or bar) time to `seconds`.
    func nearestBeat(to seconds: Double, bars: Bool = false) -> Double {
        let step = bars ? barSeconds : beatSeconds
        return offset + ((seconds - offset) / step).rounded() * step
    }
}

enum TempoDetector {
    private static let fftSize = 1024
    private static let hop = 512

    /// Estimates BPM (60-200) and the first downbeat of a range, or nil for audio without a clear pulse.
    static func detect(_ clip: AudioClip, range: Range<Int>, beatsPerBar: Int = 4) -> TempoInfo? {
        detectWithConfidence(clip, range: range, beatsPerBar: beatsPerBar).flatMap { $0.confidence >= minimumConfidence ? $0.tempo : nil }
    }

    /// Normalized autocorrelation at the beat period; below this the pulse is too weak to trust.
    static let minimumConfidence: Float = 0.3

    static func detectWithConfidence(_ clip: AudioClip, range: Range<Int>, beatsPerBar: Int = 4) -> (tempo: TempoInfo, confidence: Float)? {
        let sampleRate = clip.sampleRate
        let limited = range.lowerBound..<min(range.upperBound, range.lowerBound + Int(sampleRate * 90))
        let envelope = onsetEnvelope(clip, limited)
        guard envelope.count > 64 else { return nil }
        let framesPerSecond = sampleRate / Double(hop)

        // Autocorrelation over the lags for 60-200 BPM, weighted toward ~120 BPM to avoid octave errors.
        let mean = envelope.reduce(0, +) / Float(envelope.count)
        let centered = envelope.map { $0 - mean }
        let minLag = Int(framesPerSecond * 60 / 200)
        let maxLag = min(Int(framesPerSecond * 60 / 60), centered.count / 2)
        guard maxLag > minLag + 2 else { return nil }
        func autocorrelation(_ lag: Int) -> Float {
            var sum: Float = 0
            vDSP_dotpr(centered, 1, Array(centered[lag...]), 1, &sum, vDSP_Length(centered.count - lag))
            return sum / Float(centered.count - lag)
        }
        var scores = [Float](repeating: 0, count: maxLag + 2)
        for lag in minLag...(maxLag + 1) where lag < centered.count {
            scores[lag] = autocorrelation(lag)
        }
        var bestLag = minLag
        var bestScore = -Float.infinity
        for lag in minLag...maxLag {
            let bpm = 60 * framesPerSecond / Double(lag)
            let prior = Float(exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2)))
            let doubled = 2 * lag < scores.count ? scores[2 * lag] : 0
            let score = (scores[lag] + 0.5 * doubled) * prior
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        let variance = autocorrelation(0)
        guard bestScore > 0, variance > 0 else { return nil }
        let confidence = scores[bestLag] / variance

        // Parabolic interpolation around the peak for sub-frame precision.
        var lag = Double(bestLag)
        if bestLag > minLag, bestLag + 1 < scores.count {
            let (a, b, c) = (Double(scores[bestLag - 1]), Double(scores[bestLag]), Double(scores[bestLag + 1]))
            let denominator = a - 2 * b + c
            if denominator != 0 { lag += 0.5 * (a - c) / denominator }
        }
        var bpm = (60 * framesPerSecond / lag * 10).rounded() / 10
        // Most music sits on whole BPM values; snap when within measurement error.
        if abs(bpm - bpm.rounded()) <= 0.2 { bpm = bpm.rounded() }

        // Beat phase: the offset whose beat positions collect the most onset energy.
        let period = 60 * framesPerSecond / bpm
        var bestPhase = 0
        var bestPhaseScore = -Float.infinity
        for phase in 0..<max(1, Int(period)) {
            var sum: Float = 0
            var position = Double(phase)
            while Int(position) < envelope.count {
                sum += envelope[Int(position)]
                position += period
            }
            if sum > bestPhaseScore {
                bestPhaseScore = sum
                bestPhase = phase
            }
        }
        // Downbeat: of the beats in one bar, the one where bar-spaced positions collect the most energy.
        var bestBeat = 0
        var bestBarScore = -Float.infinity
        for beat in 0..<max(beatsPerBar, 1) {
            var sum: Float = 0
            var position = Double(bestPhase) + Double(beat) * period
            while Int(position) < envelope.count {
                sum += envelope[Int(position)]
                position += period * Double(beatsPerBar)
            }
            if sum > bestBarScore {
                bestBarScore = sum
                bestBeat = beat
            }
        }
        let downbeatFrame = Double(bestPhase) + Double(bestBeat) * period
        let offset = (Double(limited.lowerBound) + downbeatFrame * Double(hop) + Double(fftSize / 2)) / sampleRate
        return (TempoInfo(bpm: bpm, offset: offset, beatsPerBar: beatsPerBar), confidence)
    }

    /// Spectral flux: how much louder each frequency bin got since the previous frame, summed.
    private static func onsetEnvelope(_ clip: AudioClip, _ range: Range<Int>) -> [Float] {
        let n = fftSize
        let half = n / 2
        let log2n = vDSP_Length(log2(Double(n)))
        guard range.count > n, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))

        let frames = (range.count - n) / hop
        var envelope = [Float](repeating: 0, count: frames)
        var frame = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitude = [Float](repeating: 0, count: half)
        var previous = [Float](repeating: 0, count: half)
        for index in 0..<frames {
            let start = range.lowerBound + index * hop
            for i in 0..<n { frame[i] = 0 }
            for channel in clip.channels {
                channel.withUnsafeBufferPointer { vDSP_vadd(frame, 1, $0.baseAddress! + start, 1, &frame, 1, vDSP_Length(n)) }
            }
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(n))
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    frame.withUnsafeBufferPointer {
                        $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitude, 1, vDSP_Length(half))
                }
            }
            // Log compression makes quiet and loud hits count similarly.
            var flux: Float = 0
            for bin in 1..<half {
                let value = log1p(magnitude[bin])
                flux += max(0, value - previous[bin])
                previous[bin] = value
            }
            envelope[index] = index == 0 ? 0 : flux
        }
        return envelope
    }
}
