import AVFoundation
import XCTest
@testable import Audio_Prepare

/// Renders the player offline (no audio device) to check streamed playback is gapless and exact.
@MainActor
final class PlayerTests: XCTestCase {
    private let rate = 48_000.0

    private func render(_ player: Player, seconds: Double) -> [Float] {
        var output: [Float] = []
        let target = Int(seconds * rate)
        while output.count < target {
            guard let buffer = player.renderOffline(frames: 4096), let data = buffer.floatChannelData else { break }
            output += UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
            // Let chunk-completion callbacks (dispatched to main) queue the next chunk.
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        return output
    }

    /// The varispeed unit adds a small constant latency; find it so comparisons can line up.
    private func latency(_ output: [Float], _ source: [Float]) -> Int {
        func error(_ lag: Int) -> Float { (0..<2_000).reduce(Float(0)) { $0 + abs(output[$1 + lag] - source[$1]) } }
        return (0..<512).min { error($0) < error($1) } ?? 0
    }

    func testStreamedPlaybackMatchesSourceAcrossChunks() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let player = Player(offlineFormat: format)
        let frames = Int(rate * 7.3)   // several 2 s chunks plus a partial one
        let source = (0..<frames).map { Float(sin(Double($0) * 0.01) * 0.5) }
        player.play(AudioClip(channels: [source], sampleRate: rate), range: 0..<frames, loop: false)
        XCTAssertNil(player.outputError)
        let output = render(player, seconds: 8)
        let lag = latency(output, source)
        XCTAssertLessThan(lag, 256, "latency should be tiny")
        XCTAssertGreaterThanOrEqual(output.count, frames + lag)
        var maxError: Float = 0
        // The last few samples are smoothed by the resampling filter as the signal stops abruptly.
        for i in 0..<(frames - 32) { maxError = max(maxError, abs(output[i + lag] - source[i])) }
        XCTAssertLessThan(maxError, 1e-3, "streamed audio should equal the source (a gap would show as ~0.5)")
        XCTAssertLessThan(output[(frames + lag + 1000)..<(frames + lag + 5000)].map(abs).max() ?? 1, 1e-6, "silence after the end")
    }

    func testIntroThenLoopRepeats() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let player = Player(offlineFormat: format)
        let frames = Int(rate * 5)
        let source = (0..<frames).map { Float($0) / Float(frames) }  // ramp: value identifies the position
        let loop = Int(rate * 3)..<Int(rate * 4)
        player.playIntroLoop(AudioClip(channels: [source], sampleRate: rate), loop: loop)
        let output = render(player, seconds: 6)
        let lag = latency(output, source)
        // After the 3 s intro, each second should replay the loop.
        for second in [3.0, 4.0, 5.0] {
            let index = Int(second * rate) + 100 + lag
            XCTAssertEqual(output[index], source[loop.lowerBound + 100], accuracy: 1e-4, "at \(second) s")
        }
        XCTAssertTrue(player.isPlaying)
        player.stop()
    }
}
