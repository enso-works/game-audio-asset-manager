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
    @ObservationIgnored private var streamClip: AudioClip?
    @ObservationIgnored private var pendingChunks: [(Range<Int>, Bool)] = []
    @ObservationIgnored private var isOffline = false

    /// `offlineFormat` renders without an audio device (unit tests pull audio with `renderOffline`).
    init(offlineFormat: AVAudioFormat? = nil) {
        engine.attach(node)
        engine.attach(varispeed)
        if let offlineFormat {
            try? engine.enableManualRenderingMode(.offline, format: offlineFormat, maximumFrameCount: 4096)
            isOffline = true
        }
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

    /// Seconds per streamed chunk; two chunks are kept queued ahead of the playhead.
    private static let chunkSeconds = 2.0

    /// Plays segments in order. Non-looping audio is streamed in short chunks so starting playback
    /// never copies a whole (possibly hour-long) file; a looping segment is one buffer that repeats.
    private func schedule(_ clip: AudioClip, segments: [(Range<Int>, Bool)], map: @escaping (Int) -> Int) {
        stop()
        guard !segments.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: AVAudioChannelCount(clip.channelCount)),
              prepare(format)
        else { return }
        varispeed.rate = 1
        node.volume = 1

        let chunk = max(1, Int(Self.chunkSeconds * clip.sampleRate))
        var chunks: [(Range<Int>, Bool)] = []
        for (range, loops) in segments where !range.isEmpty {
            if loops {
                chunks.append((range, true))
            } else {
                var start = range.lowerBound
                while start < range.upperBound {
                    chunks.append((start..<min(start + chunk, range.upperBound), false))
                    start += chunk
                }
            }
        }
        guard !chunks.isEmpty else { return }

        generation += 1
        let current = generation
        positionMap = map
        streamClip = clip
        pendingChunks = chunks
        scheduleNextChunk(generation: current)
        scheduleNextChunk(generation: current)
        guard guarded({ node.play() }) else { return }
        isPlaying = true
        position = map(0)
        startTimer()
    }

    private func scheduleNextChunk(generation current: Int) {
        guard generation == current, !pendingChunks.isEmpty, let clip = streamClip else { return }
        let (range, loops) = pendingChunks.removeFirst()
        let isLast = pendingChunks.isEmpty && !loops
        guard let buffer = clip.makeBuffer(range) else { return }
        // Queue the next chunk as soon as this one is consumed; stop once the final one has played.
        node.scheduleBuffer(buffer, at: nil, options: loops ? .loops : [], completionCallbackType: isLast ? .dataPlayedBack : .dataConsumed) { [weak self] _ in
            // After the last chunk, wait briefly so the varispeed unit's ~1 ms latency plays out
            // instead of being cut off (which could click).
            DispatchQueue.main.asyncAfter(deadline: .now() + (isLast ? 0.05 : 0)) {
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    if isLast { self.stop() } else { self.scheduleNextChunk(generation: current) }
                }
            }
        }
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

    /// Pulls rendered audio in offline mode. Only for tests.
    func renderOffline(frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard isOffline,
              let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames),
              (try? engine.renderOffline(frames, to: buffer)) != nil
        else { return nil }
        return buffer
    }

    func stop() {
        generation += 1
        pendingChunks = []
        streamClip = nil
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
