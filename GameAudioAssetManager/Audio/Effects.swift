import AVFoundation
import Foundation

struct CompressorSettings: Equatable, Sendable {
    var thresholdDb: Double
    var ratio: Double
    var attackMs: Double
    var releaseMs: Double
    var makeupDb: Double

    static let gentle = CompressorSettings(thresholdDb: -18, ratio: 2, attackMs: 10, releaseMs: 150, makeupDb: 3)
    static let punchy = CompressorSettings(thresholdDb: -20, ratio: 4, attackMs: 15, releaseMs: 100, makeupDb: 6)
    static let limiter = CompressorSettings(thresholdDb: -6, ratio: 20, attackMs: 0.5, releaseMs: 80, makeupDb: 5)
}

enum ReverbPreset: String, CaseIterable, Identifiable, Sendable {
    case smallRoom, mediumRoom, largeRoom, mediumHall, largeHall, plate, cathedral

    var id: Self { self }

    var title: String {
        switch self {
        case .smallRoom: "Small Room"
        case .mediumRoom: "Medium Room"
        case .largeRoom: "Large Room"
        case .mediumHall: "Medium Hall"
        case .largeHall: "Large Hall"
        case .plate: "Plate"
        case .cathedral: "Cathedral"
        }
    }

    var factory: AVAudioUnitReverbPreset {
        switch self {
        case .smallRoom: .smallRoom
        case .mediumRoom: .mediumRoom
        case .largeRoom: .largeRoom
        case .mediumHall: .mediumHall
        case .largeHall: .largeHall
        case .plate: .plate
        case .cathedral: .cathedral
        }
    }
}

enum Effects {
    /// Stereo-linked feed-forward compressor with a 6 dB soft knee.
    static func compress(_ clip: AudioClip, _ range: Range<Int>, settings: CompressorSettings) -> AudioClip {
        guard !range.isEmpty else { return clip }
        let rate = clip.sampleRate
        let attack = exp(-1 / (max(settings.attackMs, 0.05) / 1000 * rate))
        let release = exp(-1 / (max(settings.releaseMs, 1) / 1000 * rate))
        let knee = 6.0
        let slope = 1 - 1 / max(settings.ratio, 1)
        var reduction = 0.0
        var out = clip
        for i in range {
            var peak: Float = 0
            for channel in clip.channels { peak = max(peak, abs(channel[i])) }
            let level = 20 * log10(max(Double(peak), 1e-9))
            let over = level - settings.thresholdDb
            let target: Double
            if over <= -knee / 2 {
                target = 0
            } else if over >= knee / 2 {
                target = over * slope
            } else {
                target = pow(over + knee / 2, 2) / (2 * knee) * slope
            }
            let coefficient = target > reduction ? attack : release
            reduction = target + (reduction - target) * coefficient
            let gain = Float(pow(10, (settings.makeupDb - reduction) / 20))
            for c in out.channels.indices { out.channels[c][i] = clip.channels[c][i] * gain }
        }
        return out
    }

    /// Changes pitch and speed independently (time-pitch) or together like tape (varispeed).
    /// Returns the processed range only; its length is `range.count / speed`.
    static func pitchSpeed(_ clip: AudioClip, _ range: Range<Int>, semitones: Double, speed: Double, tape: Bool) -> AudioClip? {
        let unit: AVAudioUnit
        if tape {
            let varispeed = AVAudioUnitVarispeed()
            varispeed.rate = Float(speed)
            unit = varispeed
        } else {
            let timePitch = AVAudioUnitTimePitch()
            timePitch.pitch = Float(semitones * 100)
            timePitch.rate = Float(speed)
            timePitch.overlap = 16
            unit = timePitch
        }
        return render(clip, range, outputFrames: Int((Double(range.count) / speed).rounded()), units: [unit])
    }

    /// Adds reverb. With `tail`, the result is longer by that many seconds so the decay isn't cut.
    static func reverb(_ clip: AudioClip, _ range: Range<Int>, preset: ReverbPreset, mix: Double, tail: Double) -> AudioClip? {
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(preset.factory)
        reverb.wetDryMix = Float(mix)
        // Apple's reverb only accepts stereo; mono sounds go through as stereo and fold back.
        guard clip.channelCount == 1 else {
            return render(clip, range, outputFrames: range.count + Int(tail * clip.sampleRate), units: [reverb])
        }
        let part = AudioClip(channels: [Array(clip.channels[0][range])], sampleRate: clip.sampleRate)
        let stereo = part.conformed(sampleRate: clip.sampleRate, channelCount: 2)
        return render(stereo, 0..<stereo.frameCount, outputFrames: part.frameCount + Int(tail * clip.sampleRate), units: [reverb])?
            .conformed(sampleRate: clip.sampleRate, channelCount: 1)
    }

    /// Plays a range through audio units in an offline engine and collects `outputFrames` frames,
    /// skipping the units' reported latency so the result lines up with the input.
    static func render(_ clip: AudioClip, _ range: Range<Int>, outputFrames: Int, units: [AVAudioUnit]) -> AudioClip? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: AVAudioChannelCount(clip.channelCount)),
              let input = clip.makeBuffer(range)
        else { return nil }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let chunk: AVAudioFrameCount = 4096
        var started = false
        // Audio units report unsupported formats by raising Objective-C exceptions.
        let failure = ObjCException.catching {
            engine.attach(player)
            var previous: AVAudioNode = player
            for unit in units {
                engine.attach(unit)
                engine.connect(previous, to: unit, format: format)
                previous = unit
            }
            engine.connect(previous, to: engine.mainMixerNode, format: format)
            do {
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
                try engine.start()
                started = true
            } catch {}
            if started {
                player.scheduleBuffer(input, at: nil)
                player.play()
            }
        }
        guard failure == nil, started else { return nil }
        defer { engine.stop() }

        let latency = Int((units.map { $0.auAudioUnit.latency }.reduce(0, +) * clip.sampleRate).rounded())
        let wanted = outputFrames + latency
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk) else { return nil }
        var channels = [[Float]](repeating: [], count: clip.channelCount)
        for c in channels.indices { channels[c].reserveCapacity(wanted) }
        while channels[0].count < wanted {
            let frames = min(chunk, AVAudioFrameCount(wanted - channels[0].count))
            guard (try? engine.renderOffline(frames, to: buffer)) == .success, let data = buffer.floatChannelData else { return nil }
            for c in channels.indices {
                channels[c] += UnsafeBufferPointer(start: data[c], count: Int(buffer.frameLength))
            }
        }
        return AudioClip(channels: channels.map { Array($0[latency..<wanted]) }, sampleRate: clip.sampleRate)
    }
}
