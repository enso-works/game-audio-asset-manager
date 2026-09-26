import Accelerate
import Foundation

/// Pure edit operations. Each returns a new clip; the caller keeps the old one for undo.
enum AudioOps {
    static func slice(_ clip: AudioClip, _ range: Range<Int>) -> AudioClip {
        AudioClip(channels: clip.channels.map { Array($0[range]) }, sampleRate: clip.sampleRate)
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
