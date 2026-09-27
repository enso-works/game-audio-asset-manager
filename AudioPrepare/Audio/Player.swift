import AVFoundation
import Observation

@MainActor
@Observable
final class Player {
    private(set) var isPlaying = false
    private(set) var position = 0

    @ObservationIgnored var onTick: ((Int) -> Void)?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private var connectedFormat: AVAudioFormat?
    @ObservationIgnored private var positionMap: (Int) -> Int = { $0 }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var generation = 0

    init() {
        engine.attach(node)
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
        guard buffers.count == segments.count, let format = buffers.first?.0.format else { return }

        if connectedFormat != format {
            if engine.isRunning { engine.stop() }
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }

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
        node.play()
        isPlaying = true
        position = map(0)

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
        if isPlaying || node.isPlaying { node.stop() }
        isPlaying = false
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
