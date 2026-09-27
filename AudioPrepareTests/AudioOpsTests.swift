import XCTest
@testable import Audio_Prepare

final class AudioOpsTests: XCTestCase {
    private let rate = 48_000.0

    private func ramp(_ count: Int) -> AudioClip {
        AudioClip(channels: [(0..<count).map { Float($0) }], sampleRate: rate)
    }

    private func sine(_ hz: Double, seconds: Double = 1, amplitude: Double = 0.5) -> AudioClip {
        let n = Int(rate * seconds)
        return AudioClip(channels: [(0..<n).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / rate)) }], sampleRate: rate)
    }

    private func rmsDb(_ clip: AudioClip) -> Double {
        let tail = clip.channels[0][clip.frameCount / 2..<clip.frameCount]
        let rms = sqrt(tail.reduce(0.0) { $0 + Double($1 * $1) } / Double(tail.count))
        return 20 * log10(rms / (0.5 / sqrt(2)))
    }

    func testSliceDeleteReplace() {
        let clip = ramp(10)
        XCTAssertEqual(AudioOps.slice(clip, 2..<5).channels[0], [2, 3, 4])
        XCTAssertEqual(AudioOps.delete(clip, 2..<8).channels[0], [0, 1, 8, 9])
        let inserted = AudioOps.replace(clip, 3..<3, with: AudioClip(channels: [[100, 101]], sampleRate: rate))
        XCTAssertEqual(inserted.channels[0], [0, 1, 2, 100, 101, 3, 4, 5, 6, 7, 8, 9])
    }

    func testFadeEndpointsAndNormalize() {
        let clip = AudioClip(channels: [[Float](repeating: 0.5, count: 1000)], sampleRate: rate)
        let faded = AudioOps.fade(clip, 0..<1000, fadeIn: true)
        XCTAssertEqual(faded.channels[0][0], 0, accuracy: 1e-6)
        XCTAssertEqual(faded.channels[0][999], 0.5, accuracy: 1e-6)
        let normalized = AudioOps.normalize(clip, 0..<1000, targetDb: -1)
        XCTAssertEqual(AudioOps.peak(normalized, 0..<1000), Float(pow(10, -1.0 / 20)), accuracy: 1e-5)
    }

    func testNonSilentRange() {
        var samples = [Float](repeating: 0, count: 100)
        samples[20] = 0.5
        samples[70] = -0.5
        XCTAssertEqual(AudioOps.nonSilentRange(AudioClip(channels: [samples], sampleRate: rate), thresholdDb: -40), 20..<71)
    }

    func testFiltersAreMinus3dBAtCutoffAnd24dBPerOctave() {
        let lowCut = { (hz: Double) in self.rmsDb(AudioOps.filter(self.sine(hz), 0..<48_000, kind: .lowCut, frequency: 200)) }
        XCTAssertEqual(lowCut(200), -3, accuracy: 0.3)
        XCTAssertEqual(lowCut(100), -24, accuracy: 1)
        XCTAssertEqual(lowCut(2000), 0, accuracy: 0.2)
        let highCut = { (hz: Double) in self.rmsDb(AudioOps.filter(self.sine(hz), 0..<48_000, kind: .highCut, frequency: 4000)) }
        XCTAssertEqual(highCut(4000), -3, accuracy: 0.3)
        XCTAssertEqual(highCut(500), 0, accuracy: 0.2)
    }

    func testDetectSoundsMergesShortGapsAndDropsBlips() {
        var samples = [Float](repeating: 0.0005, count: Int(rate * 4))
        for (a, b) in [(0.5, 0.8), (1.0, 1.05), (1.1, 1.3), (2.0, 2.02), (3.0, 3.5)] {
            for i in Int(a * rate)..<Int(b * rate) { samples[i] = Float(0.5 * sin(Double(i) * 0.05)) }
        }
        let found = AudioOps.detectSounds(AudioClip(channels: [samples], sampleRate: rate),
                                          thresholdDb: -40, minSilenceMs: 150, minSoundMs: 60, paddingMs: 20)
        let seconds = found.map { (Double($0.lowerBound) / rate, Double($0.upperBound) / rate) }
        XCTAssertEqual(seconds.count, 3)
        XCTAssertEqual(seconds[0].0, 0.48, accuracy: 0.006)
        XCTAssertEqual(seconds[1].1, 1.32, accuracy: 0.006)
        XCTAssertEqual(seconds[2].0, 2.98, accuracy: 0.006)
    }

    func testSeamlessLoopWrapIsContinuous() {
        let clip = sine(220, seconds: 2)
        let loop = AudioOps.seamlessLoop(clip, 10_000..<60_000, crossfade: 4_800)
        XCTAssertEqual(loop.frameCount, 50_000 - 4_800)
        let samples = loop.channels[0]
        let wrapJump = abs(samples[samples.count - 1] - samples[0])
        let maxStep = zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max()!
        XCTAssertLessThanOrEqual(wrapJump, maxStep * 1.5)
    }

    func testZeroCrossingIsRising() {
        let clip = sine(100)
        let index = AudioOps.nearestZeroCrossing(clip, near: 1_000, window: 480)
        XCTAssertLessThan(clip.channels[0][index - 1], 0)
        XCTAssertGreaterThanOrEqual(clip.channels[0][index], 0)
    }

    func testConformResamplesAndMixes() {
        let stereo = AudioClip(channels: [[Float](repeating: 0.2, count: 48_000), [Float](repeating: 0.4, count: 48_000)], sampleRate: rate)
        let mono = stereo.conformed(sampleRate: 24_000, channelCount: 1)
        XCTAssertEqual(mono.channelCount, 1)
        XCTAssertEqual(mono.frameCount, 24_000, accuracy: 64)
        XCTAssertEqual(mono.channels[0][12_000], 0.3, accuracy: 0.01)
    }
}

final class RegionMathTests: XCTestCase {
    private func region(_ start: Int, _ end: Int) -> Region {
        Region(id: UUID(), name: "r", start: start, end: end, colorIndex: 0)
    }

    func testTrimAndDelete() {
        XCTAssertEqual(RegionMath.afterTrim([region(100, 300)], to: 200..<1000).map(\.range), [0..<100])
        XCTAssertEqual(RegionMath.afterDelete([region(100, 300)], 150..<200).map(\.range), [100..<250])
        XCTAssertTrue(RegionMath.afterDelete([region(100, 200)], 50..<250).isEmpty)
        XCTAssertEqual(RegionMath.trim(10..<50, to: 20..<100), 0..<30)
        XCTAssertNil(RegionMath.delete(10..<20, 0..<30))
    }

    func testInsertShiftsAndGrows() {
        XCTAssertEqual(RegionMath.insert(10..<20, at: 5, count: 3), 13..<23)
        XCTAssertEqual(RegionMath.insert(10..<20, at: 15, count: 3), 10..<23)
        XCTAssertEqual(RegionMath.insert(10..<20, at: 20, count: 3), 10..<20)
    }
}
