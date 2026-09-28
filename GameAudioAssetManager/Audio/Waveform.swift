import Accelerate
import AppKit

/// Min/max summary per block of frames, so zoomed-out drawing stays fast on long files.
struct Peaks: Sendable {
    static let blockSize = 256
    var mins: [Float] = []
    var maxs: [Float] = []

    init() {}

    init(clip: AudioClip) {
        let size = Self.blockSize
        let frames = clip.frameCount
        let blocks = (frames + size - 1) / size
        mins = Array(repeating: 0, count: blocks)
        maxs = Array(repeating: 0, count: blocks)
        for channel in clip.channels {
            channel.withUnsafeBufferPointer { pointer in
                for b in 0..<blocks {
                    let start = b * size
                    let count = vDSP_Length(min(size, frames - start))
                    var low: Float = 0
                    var high: Float = 0
                    vDSP_minv(pointer.baseAddress! + start, 1, &low, count)
                    vDSP_maxv(pointer.baseAddress! + start, 1, &high, count)
                    mins[b] = min(mins[b], low)
                    maxs[b] = max(maxs[b], high)
                }
            }
        }
    }
}

enum WaveformRenderer {
    static let color = NSColor(calibratedRed: 0.36, green: 0.82, blue: 0.74, alpha: 1)

    static func draw(in context: CGContext, rect: CGRect, clip: AudioClip, peaks: Peaks, start: Double, length: Double) {
        let width = Int(rect.width)
        let frames = clip.frameCount
        guard width > 0, length > 0, frames > 0 else { return }
        let framesPerPixel = length / Double(width)
        let mid = rect.midY
        let half = rect.height / 2 * 0.94
        let path = CGMutablePath()

        if framesPerPixel < 1.5 {
            // Zoomed in far enough to see individual samples: draw a connected line.
            let first = max(0, Int(start))
            let last = min(frames - 1, Int(ceil(start + length)))
            guard first <= last else { return }
            let scale = 1 / Float(clip.channelCount)
            for i in first...last {
                var value: Float = 0
                for channel in clip.channels { value += channel[i] }
                value *= scale
                let point = CGPoint(x: rect.minX + CGFloat((Double(i) - start) / framesPerPixel), y: mid - CGFloat(value) * half)
                if i == first { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.setLineWidth(1.2)
        } else {
            let size = Peaks.blockSize
            for x in 0..<width {
                let a = Int(start + Double(x) * framesPerPixel)
                let b = min(frames, max(a + 1, Int(start + Double(x + 1) * framesPerPixel)))
                guard a < frames else { break }
                var low: Float = 0
                var high: Float = 0
                if framesPerPixel >= Double(size) {
                    let blockEnd = min(peaks.mins.count, (b + size - 1) / size)
                    for block in (a / size)..<max(a / size + 1, blockEnd) {
                        low = min(low, peaks.mins[block])
                        high = max(high, peaks.maxs[block])
                    }
                } else {
                    for channel in clip.channels {
                        for i in a..<b {
                            low = min(low, channel[i])
                            high = max(high, channel[i])
                        }
                    }
                }
                let top = mid - CGFloat(high) * half
                let bottom = max(mid - CGFloat(low) * half, top + 1)
                let px = rect.minX + CGFloat(x) + 0.5
                path.move(to: CGPoint(x: px, y: top))
                path.addLine(to: CGPoint(x: px, y: bottom))
            }
            context.setLineWidth(1)
        }

        context.setStrokeColor(color.cgColor)
        context.addPath(path)
        context.strokePath()
    }
}

func formatTime(_ seconds: Double, decimals: Int = 3) -> String {
    let s = max(0, seconds)
    let minutes = Int(s) / 60
    let rest = s - Double(minutes * 60)
    if decimals == 0 { return String(format: "%d:%02d", minutes, Int(rest)) }
    let width = 3 + decimals
    return String(format: "%d:%0\(width).\(decimals)f", minutes, rest)
}
