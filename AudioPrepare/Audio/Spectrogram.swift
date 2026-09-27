import Accelerate
import AppKit

/// Short-time Fourier transform of the mono mix, stored as 8-bit dB values per column.
struct Spectrogram: Sendable {
    static let fftSize = 2048
    static let floorDb: Float = -100

    let id = UUID()
    let hop: Int
    let bins: Int
    let columns: Int
    let sampleRate: Double
    /// columns × bins, 0 = floorDb, 255 = 0 dBFS.
    let data: [UInt8]

    init(clip: AudioClip) {
        let n = Self.fftSize
        let half = n / 2
        let log2n = vDSP_Length(log2(Double(n)))
        let frames = clip.frameCount
        sampleRate = clip.sampleRate
        bins = half
        // Cap the column count so long files stay around 20 MB.
        hop = max(256, frames / 20_000)
        columns = max(1, (frames + hop - 1) / hop)

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            data = []
            return
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var output = [UInt8](repeating: 0, count: columns * half)
        var frame = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        var decibels = [Float](repeating: 0, count: half)
        // A full-scale sine through a Hann window (coherent gain 0.5) peaks at (n/2)^2 in power,
        // counting zrip's factor of 2, so that is 0 dBFS.
        var reference = Float(half * half)
        let scale = 1 / Float(clip.channelCount)

        for column in 0..<columns {
            let start = column * hop
            let count = min(n, frames - start)
            for i in 0..<n { frame[i] = 0 }
            if count > 0 {
                for channel in clip.channels {
                    channel.withUnsafeBufferPointer { pointer in
                        vDSP_vadd(frame, 1, pointer.baseAddress! + start, 1, &frame, 1, vDSP_Length(count))
                    }
                }
            }
            var s = scale
            vDSP_vsmul(frame, 1, &s, &frame, 1, vDSP_Length(n))
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(n))

            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    frame.withUnsafeBufferPointer { framePointer in
                        framePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                }
            }
            vDSP_vdbcon(power, 1, &reference, &decibels, 1, vDSP_Length(half), 0)
            let base = column * half
            for bin in 0..<half {
                let value = (decibels[bin] - Self.floorDb) / -Self.floorDb * 255
                output[base + bin] = UInt8(min(max(value, 0), 255))
            }
        }
        data = output
    }

    /// Renders the visible frames into an image with a log frequency axis (30 Hz at the bottom).
    func image(start: Double, length: Double, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, !data.isEmpty else { return nil }
        let binWidth = sampleRate / Double(Self.fftSize)
        let minHz = 30.0
        let maxHz = sampleRate / 2
        let rowBins = (0..<height).map { y -> Int in
            let t = 1 - (Double(y) + 0.5) / Double(height)
            let hz = minHz * pow(maxHz / minHz, t)
            return min(max(Int(hz / binWidth), 1), bins - 1)
        }
        var pixels = [UInt32](repeating: 0, count: width * height)
        let framesPerPixel = length / Double(width)
        let lut = Self.colormap
        for x in 0..<width {
            // Each column describes the window starting at column * hop, centered half a window later.
            let offset = Double(Self.fftSize / 2)
            let a = Int(((start + Double(x) * framesPerPixel - offset) / Double(hop)).rounded(.down))
            let b = Int(((start + Double(x + 1) * framesPerPixel - offset) / Double(hop)).rounded(.down))
            guard a < columns else { break }
            guard b >= 0 else { continue }
            let first = max(a, 0)
            let last = min(max(b, first + 1), columns)
            let stride = max(1, (last - first) / 6)
            for y in 0..<height {
                let bin = rowBins[y]
                var value: UInt8 = 0
                var column = first
                while column < last {
                    value = max(value, data[column * bins + bin])
                    column += stride
                }
                pixels[y * width + x] = lut[Int(value)]
            }
        }
        let provider = CGDataProvider(data: Data(bytes: pixels, count: pixels.count * 4) as CFData)
        return provider.flatMap {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                    provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    /// Magma-like gradient packed as big-endian RGBX.
    static let colormap: [UInt32] = {
        let stops: [(Double, Double, Double, Double)] = [
            (0.00, 0, 0, 4), (0.20, 40, 11, 84), (0.40, 101, 21, 110), (0.60, 172, 51, 123),
            (0.75, 231, 88, 96), (0.88, 251, 155, 106), (1.00, 252, 253, 191),
        ]
        return (0..<256).map { index in
            let t = Double(index) / 255
            let upper = stops.firstIndex { $0.0 >= t } ?? stops.count - 1
            let lower = max(upper - 1, 0)
            let (t0, r0, g0, b0) = stops[lower]
            let (t1, r1, g1, b1) = stops[upper]
            let f = t1 > t0 ? (t - t0) / (t1 - t0) : 0
            let r = UInt32(r0 + (r1 - r0) * f), g = UInt32(g0 + (g1 - g0) * f), b = UInt32(b0 + (b1 - b0) * f)
            return (r << 24 | g << 16 | b << 8 | 0xFF).bigEndian
        }
    }()
}
