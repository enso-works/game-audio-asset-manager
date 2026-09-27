import AVFoundation
import Observation

@MainActor
@Observable
final class Player {
    private(set) var isPlaying = false
    private(set) var position = 0
    /// Pitch of the current game-preview hit in semitones, nil during normal playback.
    private(set) var previewPitch: Double?
    /// Set when the audio output can't be used (no device, device removed mid-play).
    private(set) var outputError: String?

    @ObservationIgnored var onTick: ((Int) -> Void)?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    /// Changes playback rate (pitch and speed together), like a game engine's pitch scale.
    @ObservationIgnored private let varispeed = AVAudioUnitVarispeed()
    @ObservationIgnored private var connectedFormat: AVAudioFormat?
    @ObservationIgnored private var positionMap: (Int) -> Int = { $0 }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var generation = 0

    init() {
        engine.attach(node)
        engine.attach(varispeed)
        // Device changes (headphones unplugged, new output) stop the engine and invalidate the graph.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetAfterDeviceChange() }
        }
    }

    private func resetAfterDeviceChange() {
        stop()
        connectedFormat = nil
    }

    /// Runs AVAudioEngine calls that may raise Objective-C exceptions; reports instead of crashing.
    private func guarded(_ body: () -> Void) -> Bool {
        if let reason = ObjCException.catching(body) {
            outputError = "Audio output unavailable: \(reason)"
            isPlaying = false
            timer?.invalidate()
            timer = nil
            connectedFormat = nil
            if engine.isRunning { engine.stop() }
            return false
        }
        return true
    }

    func clearOutputError() {
        outputError = nil
    }

    func play(_ clip: AudioClip, range: Range<Int>, loop: Bool, positionMap: ((Int) -> Int)? = nil) {
        let length = max(range.count, 1)
        let map = positionMap ?? { range.lowerBound + (loop ? $0 % length : min($0, length)) }
        schedule(clip, segments: [(range, loop)], map: map)
    }

    /// Plays the intro once, then repeats the loop, like a game engine with a loop start point.
    func playIntroLoop(_ clip: AudioClip, loop: Range<Int>) {
        guard loop.lowerBound > 0 else {
            play(clip, range: loop, loop: true)
            return
        }
        let intro = 0..<loop.lowerBound
        let length = max(loop.count, 1)
        schedule(clip, segments: [(intro, false), (loop, true)]) { played in
            played < intro.count ? played : loop.lowerBound + (played - intro.count) % length
        }
    }

    private func schedule(_ clip: AudioClip, segments: [(Range<Int>, Bool)], map: @escaping (Int) -> Int) {
        stop()
        let buffers = segments.compactMap { segment in clip.makeBuffer(segment.0).map { ($0, segment.1) } }
        guard buffers.count == segments.count, let format = buffers.first?.0.format, prepare(format) else { return }
        varispeed.rate = 1
        node.volume = 1

        generation += 1
        let current = generation
        positionMap = map
        for (index, (segment, loops)) in buffers.enumerated() {
            let isLast = index == buffers.count - 1
            node.scheduleBuffer(segment, at: nil, options: loops ? .loops : [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard isLast else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == current else { return }
                        self.stop()
                    }
                }
            }
        }
        guard guarded({ node.play() }) else { return }
        isPlaying = true
        position = map(0)
        startTimer()
    }

    private func prepare(_ format: AVAudioFormat) -> Bool {
        if connectedFormat != format {
            let connected = guarded {
                if engine.isRunning { engine.stop() }
                engine.disconnectNodeOutput(node)
                engine.disconnectNodeOutput(varispeed)
                engine.connect(node, to: varispeed, format: format)
                engine.connect(varispeed, to: engine.mainMixerNode, format: format)
            }
            guard connected else { return false }
            connectedFormat = format
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                outputError = "Audio output unavailable: \(error.localizedDescription)"
                return false
            }
        }
        outputError = nil
        return true
    }

    /// Plays the sound several times with random pitch and volume, the way a game triggers it,
    /// to judge whether variation hides repetition.
    func playGamePreview(_ clip: AudioClip, range: Range<Int>, hits: Int, semitones: Double, volumeJitterDb: Double, gap: Double) {
        stop()
        guard let buffer = clip.makeBuffer(range), prepare(buffer.format) else { return }
        generation += 1
        let current = generation
        positionMap = { range.lowerBound + min($0, range.count) }
        isPlaying = true
        startTimer()
        trigger(buffer, remaining: hits, generation: current, semitones: semitones, volumeJitterDb: volumeJitterDb, gap: gap)
    }

    private func trigger(_ buffer: AVAudioPCMBuffer, remaining: Int, generation current: Int, semitones: Double, volumeJitterDb: Double, gap: Double) {
        guard generation == current else { return }
        guard remaining > 0 else {
            stop()
            return
        }
        let pitch = semitones > 0 ? Double.random(in: -semitones...semitones) : 0
        varispeed.rate = Float(pow(2, pitch / 12))
        node.volume = Float(pow(10, -Double.random(in: 0...max(volumeJitterDb, 0)) / 20))
        previewPitch = pitch
        guard guarded({ node.stop() }) else { return }
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
                MainActor.assumeIsolated {
                    self?.trigger(buffer, remaining: remaining - 1, generation: current, semitones: semitones,
                                  volumeJitterDb: volumeJitterDb, gap: gap)
                }
            }
        }
        _ = guarded { node.play() }
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        if isPlaying || node.isPlaying { _ = ObjCException.catching { node.stop() } }
        isPlaying = false
        previewPitch = nil
    }

    private func tick() {
        guard isPlaying,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime)
        else { return }
        position = positionMap(max(0, Int(playerTime.sampleTime)))
        onTick?(position)
    }
}
