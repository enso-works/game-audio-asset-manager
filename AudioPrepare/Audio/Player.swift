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
    @ObservationIgnored private var range = 0..<0
    @ObservationIgnored private var looping = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var generation = 0

    init() {
        engine.attach(node)
    }

    func play(_ clip: AudioClip, range: Range<Int>, loop: Bool) {
        stop()
        guard let buffer = clip.makeBuffer(range) else { return }

        if connectedFormat != buffer.format {
            if engine.isRunning { engine.stop() }
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
            connectedFormat = buffer.format
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }

        generation += 1
        let current = generation
        self.range = range
        looping = loop
        node.scheduleBuffer(buffer, at: nil, options: loop ? .loops : [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    self.stop()
                }
            }
        }
        node.play()
        isPlaying = true
        position = range.lowerBound

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
        let played = max(0, Int(playerTime.sampleTime))
        let length = max(range.count, 1)
        position = range.lowerBound + (looping ? played % length : min(played, length))
        onTick?(position)
    }
}
