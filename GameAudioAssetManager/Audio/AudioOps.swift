import Accelerate
import Foundation

enum FilterKind: Sendable {
    /// High-pass: removes rumble and low hum below the cutoff.
    case lowCut
    /// Low-pass: removes hiss and harshness above the cutoff.
    case highCut
}

/// Pure edit operations. Each returns a new clip; the caller keeps the old one for undo.
enum AudioOps {
    static func slice(_ clip: AudioClip, _ range: Range<Int>) -> AudioClip {
        AudioClip(channels: clip.channels.map { Array($0[range]) }, sampleRate: clip.sampleRate)
    }

    /// Replaces a range (empty to insert) with other audio of the same format.
    static func replace(_ clip: AudioClip, _ range: Range<Int>, with other: AudioClip) -> AudioClip {
        var out = clip
        for c in out.channels.indices {
            out.channels[c].replaceSubrange(range, with: other.channels[min(c, other.channelCount - 1)])
        }
        return out
    }

    static func delete(_ clip: AudioClip, _ range: Range<Int>) -> AudioClip {
        var out = clip
        for c in out.channels.indices { out.channels[c].removeSubrange(range) }
        return out
    }

    static func silence(_ clip: AudioClip, _ range: Range<Int>) -> AudioClip {
        modify(clip, range) { pointer, count in
            vDSP_vclr(pointer, 1, vDSP_Length(count))
        }
    }

    static func reverse(_ clip: AudioClip, _ range: Range<Int>) -> AudioClip {
        var out = clip
        for c in out.channels.indices { out.channels[c][range].reverse() }
        return out
    }

    static func gain(_ clip: AudioClip, _ range: Range<Int>, db: Double) -> AudioClip {
        var factor = Float(pow(10, db / 20))
        return modify(clip, range) { pointer, count in
            vDSP_vsmul(pointer, 1, &factor, pointer, 1, vDSP_Length(count))
        }
    }

    static func normalize(_ clip: AudioClip, _ range: Range<Int>, targetDb: Double) -> AudioClip {
        let current = peak(clip, range)
        guard current > 0 else { return clip }
        let target = pow(10, targetDb / 20)
        return gain(clip, range, db: 20 * log10(target / Double(current)))
    }

    /// Smooth (raised cosine) fade over the range.
    static func fade(_ clip: AudioClip, _ range: Range<Int>, fadeIn: Bool) -> AudioClip {
        let count = range.count
        guard count > 1 else { return clip }
        let curve = (0..<count).map { i -> Float in
            let t = Double(i) / Double(count - 1)
            let g = 0.5 - 0.5 * cos(Double.pi * t)
            return Float(fadeIn ? g : 1 - g)
        }
        return modify(clip, range) { pointer, count in
            vDSP_vmul(pointer, 1, curve, 1, pointer, 1, vDSP_Length(count))
        }
    }

    static func peak(_ clip: AudioClip, _ range: Range<Int>) -> Float {
        guard !range.isEmpty else { return 0 }
        var result: Float = 0
        for channel in clip.channels {
            channel.withUnsafeBufferPointer { pointer in
                var value: Float = 0
                vDSP_maxmgv(pointer.baseAddress! + range.lowerBound, 1, &value, vDSP_Length(range.count))
                result = max(result, value)
            }
        }
        return result
    }

    /// Range between the first and last sample louder than the threshold, or nil if all silent.
    static func nonSilentRange(_ clip: AudioClip, thresholdDb: Double) -> Range<Int>? {
        let threshold = Float(pow(10, thresholdDb / 20))
        var first = Int.max
        var last = -1
        for channel in clip.channels {
            if let index = channel.firstIndex(where: { abs($0) > threshold }) { first = min(first, index) }
            if let index = channel.lastIndex(where: { abs($0) > threshold }) { last = max(last, index) }
        }
        return last >= first ? first..<(last + 1) : nil
    }

    /// Nearest rising zero crossing within the window, so loop points don't click.
    static func nearestZeroCrossing(_ clip: AudioClip, near frame: Int, window: Int) -> Int {
        let n = clip.frameCount
        func value(_ i: Int) -> Float {
            var sum: Float = 0
            for channel in clip.channels { sum += channel[i] }
            return sum
        }
        for distance in 0...window {
            for i in [frame - distance, frame + distance] where i > 0 && i < n {
                if value(i - 1) < 0 && value(i) >= 0 { return i }
            }
        }
        return frame
    }

    /// Bakes a seamless loop: keeps the loop body and crossfades its tail into its head, so the
    /// jump from the last sample back to the first is continuous. The result is only the loop.
    static func seamlessLoop(_ clip: AudioClip, _ loop: Range<Int>, crossfade: Int) -> AudioClip {
        let start = loop.lowerBound
        let end = loop.upperBound
        let fade = min(max(crossfade, 1), (end - start) / 2)
        let length = end - start - fade
        let gains = (0..<fade).map { j -> (Float, Float) in
            let t = (Double(j) + 0.5) / Double(fade) * Double.pi / 2
            return (Float(sin(t)), Float(cos(t)))
        }
        let channels = clip.channels.map { x -> [Float] in
            var out = Array(x[(start + fade)..<end])
            for j in 0..<fade {
                let (fadeIn, fadeOut) = gains[j]
                out[length - fade + j] = x[end - fade + j] * fadeOut + x[start + j] * fadeIn
            }
            return out
        }
        return AudioClip(channels: channels, sampleRate: clip.sampleRate)
    }

    /// Finds separate sounds: stretches louder than the threshold, where gaps shorter than
    /// `minSilenceMs` don't split a sound and blips shorter than `minSoundMs` are ignored.
    static func detectSounds(
        _ clip: AudioClip,
        thresholdDb: Double,
        minSilenceMs: Int,
        minSoundMs: Int,
        paddingMs: Int
    ) -> [Range<Int>] {
        let n = clip.frameCount
        let window = max(1, clip.frames(forMilliseconds: 5))
        let windows = (n + window - 1) / window
        guard windows > 0 else { return [] }
        let threshold = Float(pow(10, thresholdDb / 20))

        var loud = [Bool](repeating: false, count: windows)
        for channel in clip.channels {
            channel.withUnsafeBufferPointer { pointer in
                for w in 0..<windows where !loud[w] {
                    let start = w * window
                    var peak: Float = 0
                    vDSP_maxmgv(pointer.baseAddress! + start, 1, &peak, vDSP_Length(min(window, n - start)))
                    loud[w] = peak > threshold
                }
            }
        }

        var segments: [Range<Int>] = []
        var current: Int?
        for w in 0..<windows {
            if loud[w] {
                if current == nil { current = w }
            } else if let start = current {
                segments.append(start..<w)
                current = nil
            }
        }
        if let start = current { segments.append(start..<windows) }

        let minGap = max(1, clip.frames(forMilliseconds: minSilenceMs) / window)
        var merged: [Range<Int>] = []
        for segment in segments {
            if let last = merged.last, segment.lowerBound - last.upperBound < minGap {
                merged[merged.count - 1] = last.lowerBound..<segment.upperBound
            } else {
                merged.append(segment)
            }
        }

        let minLength = clip.frames(forMilliseconds: minSoundMs)
        let padding = clip.frames(forMilliseconds: paddingMs)
        var result: [Range<Int>] = []
        for segment in merged where segment.count * window >= minLength {
            var start = max(0, segment.lowerBound * window - padding)
            let end = min(n, segment.upperBound * window + padding)
            if let previous = result.last { start = max(start, previous.upperBound) }
            if end > start { result.append(start..<end) }
        }
        return result
    }

    /// 4th-order Butterworth filter (24 dB/octave), built from two cascaded biquads.
    static func filter(_ clip: AudioClip, _ range: Range<Int>, kind: FilterKind, frequency: Double) -> AudioClip {
        let cutoff = min(max(frequency, 10), clip.sampleRate * 0.45)
        let sections = [0.541_196_1, 1.306_563].map { q in biquad(kind, cutoff: cutoff, sampleRate: clip.sampleRate, q: q) }
        return modify(clip, range) { pointer, count in
            for section in sections { applyBiquad(pointer, count, section) }
        }
    }

    private struct Biquad {
        let b0, b1, b2, a1, a2: Double
    }

    /// RBJ cookbook coefficients, normalized by a0.
    private static func biquad(_ kind: FilterKind, cutoff: Double, sampleRate: Double, q: Double) -> Biquad {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cosW = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        switch kind {
        case .lowCut:
            return Biquad(b0: (1 + cosW) / 2 / a0, b1: -(1 + cosW) / a0, b2: (1 + cosW) / 2 / a0,
                          a1: -2 * cosW / a0, a2: (1 - alpha) / a0)
        case .highCut:
            return Biquad(b0: (1 - cosW) / 2 / a0, b1: (1 - cosW) / a0, b2: (1 - cosW) / 2 / a0,
                          a1: -2 * cosW / a0, a2: (1 - alpha) / a0)
        }
    }

    /// Direct form I in double precision, stable even for low cutoffs.
    private static func applyBiquad(_ pointer: UnsafeMutablePointer<Float>, _ count: Int, _ c: Biquad) {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<count {
            let x = Double(pointer[i])
            let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            pointer[i] = Float(y)
        }
    }

    private static func modify(_ clip: AudioClip, _ range: Range<Int>, _ body: (UnsafeMutablePointer<Float>, Int) -> Void) -> AudioClip {
        guard !range.isEmpty else { return clip }
        var out = clip
        for c in out.channels.indices {
            out.channels[c].withUnsafeMutableBufferPointer { pointer in
                body(pointer.baseAddress! + range.lowerBound, range.count)
            }
        }
        return out
    }
}

/// Keeps regions aligned with the audio after structural edits.
enum RegionMath {
    static func trim(_ range: Range<Int>?, to kept: Range<Int>) -> Range<Int>? {
        guard let range else { return nil }
        let start = max(range.lowerBound, kept.lowerBound)
        let end = min(range.upperBound, kept.upperBound)
        return end > start ? (start - kept.lowerBound)..<(end - kept.lowerBound) : nil
    }

    /// Shifts a range for audio inserted at `position`; a range spanning the position grows.
    static func insert(_ range: Range<Int>, at position: Int, count: Int) -> Range<Int> {
        let start = range.lowerBound < position ? range.lowerBound : range.lowerBound + count
        let end = range.upperBound <= position ? range.upperBound : range.upperBound + count
        return start..<end
    }

    static func insert(_ region: Region, at position: Int, count: Int) -> Region? {
        var r = region
        let moved = insert(region.range, at: position, count: count)
        r.start = moved.lowerBound
        r.end = moved.upperBound
        return r
    }

    /// Maps positions when `range` is replaced by audio of `count` frames. With `stretch` (speed
    /// change) positions inside the range scale with it; otherwise they stay (e.g. a reverb tail).
    static func replacing(_ range: Range<Int>, count: Int, stretch: Bool) -> (Int) -> Int {
        { x in
            if x < range.lowerBound { return x }
            if x > range.upperBound { return x + count - range.count }
            guard stretch else { return min(x, range.lowerBound + count) }
            return range.lowerBound + Int((Double(x - range.lowerBound) * Double(count) / Double(max(range.count, 1))).rounded())
        }
    }

    static func delete(_ range: Range<Int>?, _ removed: Range<Int>) -> Range<Int>? {
        guard let range else { return nil }
        func map(_ x: Int) -> Int {
            if x <= removed.lowerBound { return x }
            if x < removed.upperBound { return removed.lowerBound }
            return x - removed.count
        }
        let start = map(range.lowerBound)
        let end = map(range.upperBound)
        return end > start ? start..<end : nil
    }

    static func afterTrim(_ regions: [Region], to range: Range<Int>) -> [Region] {
        regions.compactMap { region in
            var r = region
            let start = max(r.start, range.lowerBound)
            let end = min(r.end, range.upperBound)
            guard end > start else { return nil }
            r.start = start - range.lowerBound
            r.end = end - range.lowerBound
            return r
        }
    }

    static func afterDelete(_ regions: [Region], _ range: Range<Int>) -> [Region] {
        func map(_ x: Int) -> Int {
            if x <= range.lowerBound { return x }
            if x < range.upperBound { return range.lowerBound }
            return x - range.count
        }
        return regions.compactMap { region in
            var r = region
            r.start = map(r.start)
            r.end = map(r.end)
            return r.end > r.start ? r : nil
        }
    }
}
