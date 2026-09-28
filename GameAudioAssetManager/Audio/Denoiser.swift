import Accelerate
import Foundation

/// Average magnitude spectrum of background noise, used as the reference for denoising.
struct NoiseProfile: Sendable, Equatable {
    let magnitudes: [Float]
    let sampleRate: Double
    let seconds: Double
}

/// Spectral noise reduction: short-time FFT, per-bin gain from how far each bin sits above the
/// noise profile, gains smoothed across frequency and time (to avoid "musical noise"), then
/// overlap-add resynthesis.
enum Denoiser {
    static let fftSize = 2048
    static let hop = 512

    /// Learns the noise from a range that contains only background noise.
    static func profile(_ clip: AudioClip, _ range: Range<Int>) -> NoiseProfile? {
        let spectra = frameSpectra(mono(clip, range))
        guard !spectra.isEmpty else { return nil }
        return NoiseProfile(magnitudes: average(spectra), sampleRate: clip.sampleRate, seconds: Double(range.count) / clip.sampleRate)
    }

    /// Without a learned profile, uses the quietest 10% of frames as the noise estimate.
    static func estimateProfile(_ clip: AudioClip, _ range: Range<Int>) -> NoiseProfile? {
        let spectra = frameSpectra(mono(clip, range))
        guard !spectra.isEmpty else { return nil }
        let energies = spectra.map { $0.reduce(0) { $0 + $1 * $1 } }
        let count = max(4, spectra.count / 10)
        let quietest = energies.indices.sorted { energies[$0] < energies[$1] }.prefix(count).map { spectra[$0] }
        return NoiseProfile(magnitudes: average(quietest), sampleRate: clip.sampleRate, seconds: Double(count * hop) / clip.sampleRate)
    }

    /// - Parameters:
    ///   - reductionDb: How far noise-only bins are turned down.
    ///   - sensitivity: Multiplier on the noise profile; higher removes more but can dull the sound.
    static func denoise(_ clip: AudioClip, _ range: Range<Int>, profile: NoiseProfile?, reductionDb: Double, sensitivity: Double) -> AudioClip {
        guard range.count > fftSize else { return clip }
        let usable = profile.flatMap { $0.sampleRate == clip.sampleRate ? $0 : nil } ?? estimateProfile(clip, range)
        guard let noise = usable?.magnitudes else { return clip }
        let floor = Float(pow(10, -reductionDb / 20))
        var out = clip
        for c in out.channels.indices {
            let processed = process(Array(clip.channels[c][range]), noise: noise, floor: floor, sensitivity: Float(sensitivity))
            out.channels[c].replaceSubrange(range, with: processed)
        }
        return out
    }

    // MARK: - STFT

    private static func mono(_ clip: AudioClip, _ range: Range<Int>) -> [Float] {
        let scale = 1 / Float(clip.channelCount)
        var mix = [Float](repeating: 0, count: range.count)
        for channel in clip.channels {
            channel.withUnsafeBufferPointer { vDSP_vadd(mix, 1, $0.baseAddress! + range.lowerBound, 1, &mix, 1, vDSP_Length(range.count)) }
        }
        vDSP_vsmul(mix, 1, [scale], &mix, 1, vDSP_Length(range.count))
        return mix
    }

    /// RMS magnitude per bin (noise power, not mean magnitude, which underestimates noise by ~1 dB).
    private static func average(_ spectra: [[Float]]) -> [Float] {
        var sum = [Float](repeating: 0, count: spectra[0].count)
        for spectrum in spectra {
            for k in sum.indices { sum[k] += spectrum[k] * spectrum[k] }
        }
        return sum.map { sqrt($0 / Float(spectra.count)) }
    }

    private final class FFT {
        let n = fftSize
        let half = fftSize / 2
        let log2n = vDSP_Length(log2(Double(fftSize)))
        let setup: FFTSetup
        let window: [Float]
        var real: [Float]
        var imaginary: [Float]

        init() {
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            var w = [Float](repeating: 0, count: fftSize)
            vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
            window = w
            real = [Float](repeating: 0, count: fftSize / 2)
            imaginary = [Float](repeating: 0, count: fftSize / 2)
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        /// Windowed forward FFT into `real`/`imaginary` (packed: DC in real[0], Nyquist in imaginary[0]).
        func forward(_ samples: UnsafePointer<Float>) {
            var frame = [Float](repeating: 0, count: n)
            vDSP_vmul(samples, 1, window, 1, &frame, 1, vDSP_Length(n))
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    frame.withUnsafeBufferPointer {
                        $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
        }

        /// Inverse FFT of `real`/`imaginary`, windowed again for overlap-add.
        func inverse() -> [Float] {
            var frame = [Float](repeating: 0, count: n)
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    frame.withUnsafeMutableBufferPointer {
                        $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half)) }
                    }
                }
            }
            // zrip forward scales by 2 and the inverse by n.
            vDSP_vsmul(frame, 1, [1 / Float(2 * n)], &frame, 1, vDSP_Length(n))
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(n))
            return frame
        }

        /// Magnitudes for bins 0...half (DC and Nyquist included).
        func magnitudes() -> [Float] {
            var result = [Float](repeating: 0, count: half + 1)
            result[0] = abs(real[0])
            result[half] = abs(imaginary[0])
            for k in 1..<half { result[k] = sqrt(real[k] * real[k] + imaginary[k] * imaginary[k]) }
            return result
        }
    }

    private static func padded(_ samples: [Float]) -> [Float] {
        [Float](repeating: 0, count: fftSize) + samples + [Float](repeating: 0, count: fftSize + hop)
    }

    private static func frameSpectra(_ samples: [Float]) -> [[Float]] {
        guard samples.count >= fftSize else { return [] }
        let fft = FFT()
        var spectra: [[Float]] = []
        samples.withUnsafeBufferPointer { pointer in
            var start = 0
            while start + fftSize <= samples.count {
                fft.forward(pointer.baseAddress! + start)
                spectra.append(fft.magnitudes())
                start += hop
            }
        }
        return spectra
    }

    private static func process(_ samples: [Float], noise: [Float], floor: Float, sensitivity: Float) -> [Float] {
        let fft = FFT()
        let n = fftSize
        let half = n / 2
        let input = padded(samples)
        var output = [Float](repeating: 0, count: input.count)
        var norm = [Float](repeating: 0, count: input.count)
        var squaredWindow = [Float](repeating: 0, count: n)
        vDSP_vsq(fft.window, 1, &squaredWindow, 1, vDSP_Length(n))
        var previous = [Float](repeating: 1, count: half + 1)
        // Gains may rise instantly but fall at most ~6 dB per hop, which suppresses musical noise.
        let fallPerHop: Float = 0.5
        // Per-bin power smoothed over time: raw noise bins fluctuate wildly around their mean, and
        // deciding on the raw value lets many of them through.
        var smoothedPower = [Float](repeating: -1, count: half + 1)
        let noisePower = noise.map { (sensitivity * $0) * (sensitivity * $0) }

        input.withUnsafeBufferPointer { pointer in
            var start = 0
            while start + n <= input.count {
                fft.forward(pointer.baseAddress! + start)
                let magnitudes = fft.magnitudes()
                var gains = [Float](repeating: 1, count: half + 1)
                for k in 0...half {
                    let power = magnitudes[k] * magnitudes[k]
                    smoothedPower[k] = smoothedPower[k] < 0 ? power : 0.5 * smoothedPower[k] + 0.5 * power
                    gains[k] = max(floor, sqrt(max(0, 1 - noisePower[k] / max(smoothedPower[k], 1e-20))))
                }
                // Smooth across neighbouring bins, then limit how fast gains can drop.
                var smoothed = gains
                for k in 1..<half { smoothed[k] = (gains[k - 1] + 2 * gains[k] + gains[k + 1]) / 4 }
                for k in 0...half {
                    smoothed[k] = max(smoothed[k], previous[k] * fallPerHop, floor)
                    previous[k] = smoothed[k]
                }
                fft.real[0] *= smoothed[0]
                fft.imaginary[0] *= smoothed[half]
                for k in 1..<half {
                    fft.real[k] *= smoothed[k]
                    fft.imaginary[k] *= smoothed[k]
                }
                let frame = fft.inverse()
                output.withUnsafeMutableBufferPointer { out in
                    vDSP_vadd(out.baseAddress! + start, 1, frame, 1, out.baseAddress! + start, 1, vDSP_Length(n))
                }
                norm.withUnsafeMutableBufferPointer { out in
                    vDSP_vadd(out.baseAddress! + start, 1, squaredWindow, 1, out.baseAddress! + start, 1, vDSP_Length(n))
                }
                start += hop
            }
        }
        var result = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let index = i + n
            result[i] = norm[index] > 1e-6 ? output[index] / norm[index] : 0
        }
        return result
    }
}
