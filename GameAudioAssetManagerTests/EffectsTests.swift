import XCTest
@testable import GameAudioAssetManager

final class EffectsTests: XCTestCase {
    private let rate = 48_000.0

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(samples.count, 1)))
    }

    private func db(_ value: Double) -> Double { 20 * log10(max(value, 1e-12)) }

    /// Tone for 1-3 s over steady white noise; noise-only elsewhere. The noise is seeded so results don't vary per run.
    private func noisyTone() -> (clip: AudioClip, tone: [Float]) {
        var generator = SeededGenerator(seed: 42)
        let n = Int(rate * 4)
        var tone = [Float](repeating: 0, count: n)
        for i in Int(rate)..<Int(rate * 3) { tone[i] = Float(0.4 * sin(2 * .pi * 440 * Double(i) / rate)) }
        let samples = (0..<n).map { tone[$0] + Float.random(in: -0.03...0.03, using: &generator) }
        return (AudioClip(channels: [samples], sampleRate: rate), tone)
    }

    func testDenoiseWithLearnedProfile() throws {
        let (clip, tone) = noisyTone()
        let profile = try XCTUnwrap(Denoiser.profile(clip, 0..<Int(rate * 0.8)))
        let cleaned = Denoiser.denoise(clip, 0..<clip.frameCount, profile: profile, reductionDb: 24, sensitivity: 1.5)
        let noiseBefore = db(rms(clip.channels[0][Int(rate * 3.3)..<Int(rate * 3.9)]))
        let noiseAfter = db(rms(cleaned.channels[0][Int(rate * 3.3)..<Int(rate * 3.9)]))
        XCTAssertLessThan(noiseAfter, noiseBefore - 15, "noise-only part should drop by more than 15 dB")
        // The tone should survive: compare against the clean tone.
        let toneRange = Int(rate * 1.5)..<Int(rate * 2.5)
        let residual = zip(cleaned.channels[0][toneRange], tone[toneRange]).map { $0 - $1 }
        XCTAssertLessThan(db(rms(residual[...])), db(rms(tone[toneRange])) - 15, "tone kept, remaining noise under it reduced")
        XCTAssertEqual(db(rms(cleaned.channels[0][toneRange])), db(rms(tone[toneRange])), accuracy: 1)
    }

    func testDenoiseEstimatesProfileAutomatically() {
        let (clip, _) = noisyTone()
        let cleaned = Denoiser.denoise(clip, 0..<clip.frameCount, profile: nil, reductionDb: 24, sensitivity: 1.5)
        let before = db(rms(clip.channels[0][0..<Int(rate * 0.8)]))
        let after = db(rms(cleaned.channels[0][0..<Int(rate * 0.8)]))
        XCTAssertLessThan(after, before - 12)
    }

    func testCompressorReducesLoudPartsOnly() {
        let n = Int(rate * 2)
        let samples = (0..<n).map { i -> Float in
            let amplitude: Float = i < n / 2 ? 0.05 : 0.9
            return amplitude * Float(sin(2 * .pi * 220 * Double(i) / rate))
        }
        let clip = AudioClip(channels: [samples], sampleRate: rate)
        var settings = CompressorSettings.punchy
        settings.makeupDb = 0
        let out = Effects.compress(clip, 0..<n, settings: settings)
        let quiet = db(rms(out.channels[0][Int(rate * 0.5)..<Int(rate * 0.9)])) - db(rms(clip.channels[0][Int(rate * 0.5)..<Int(rate * 0.9)]))
        let loud = db(rms(out.channels[0][Int(rate * 1.5)..<Int(rate * 1.9)])) - db(rms(clip.channels[0][Int(rate * 1.5)..<Int(rate * 1.9)]))
        XCTAssertEqual(quiet, 0, accuracy: 0.5, "below threshold: unchanged")
        XCTAssertLessThan(loud, -10, "well above threshold at 4:1: strongly reduced")
    }

    private func zeroCrossingFrequency(_ samples: [Float]) -> Double {
        var crossings = 0
        for i in 1..<samples.count where samples[i - 1] < 0 && samples[i] >= 0 { crossings += 1 }
        return Double(crossings) / (Double(samples.count) / rate)
    }

    func testPitchShiftKeepsLength() throws {
        let n = Int(rate * 2)
        let clip = AudioClip(channels: [(0..<n).map { Float(0.5 * sin(2 * .pi * 440 * Double($0) / rate)) }], sampleRate: rate)
        let shifted = try XCTUnwrap(Effects.pitchSpeed(clip, 0..<n, semitones: 12, speed: 1, tape: false))
        XCTAssertEqual(shifted.frameCount, n)
        let middle = Array(shifted.channels[0][Int(rate * 0.5)..<Int(rate * 1.5)])
        XCTAssertEqual(zeroCrossingFrequency(middle), 880, accuracy: 15)
    }

    func testSpeedChangeKeepsPitch() throws {
        let n = Int(rate * 2)
        let clip = AudioClip(channels: [(0..<n).map { Float(0.5 * sin(2 * .pi * 440 * Double($0) / rate)) }], sampleRate: rate)
        let faster = try XCTUnwrap(Effects.pitchSpeed(clip, 0..<n, semitones: 0, speed: 2, tape: false))
        XCTAssertEqual(faster.frameCount, n / 2)
        XCTAssertEqual(zeroCrossingFrequency(Array(faster.channels[0][Int(rate * 0.2)..<Int(rate * 0.8)])), 440, accuracy: 15)
        let tape = try XCTUnwrap(Effects.pitchSpeed(clip, 0..<n, semitones: 0, speed: 2, tape: true))
        XCTAssertEqual(tape.frameCount, n / 2)
        XCTAssertEqual(zeroCrossingFrequency(Array(tape.channels[0][Int(rate * 0.2)..<Int(rate * 0.8)])), 880, accuracy: 15)
    }

    func testReverbAddsTail() throws {
        var samples = [Float](repeating: 0, count: Int(rate))
        for i in 0..<2_000 { samples[i] = Float(sin(Double(i) * 0.2)) * 0.8 }
        let clip = AudioClip(channels: [samples], sampleRate: rate)
        let wet = try XCTUnwrap(Effects.reverb(clip, 0..<clip.frameCount, preset: .largeHall, mix: 50, tail: 1))
        XCTAssertEqual(wet.frameCount, Int(rate * 2))
        XCTAssertGreaterThan(rms(wet.channels[0][Int(rate * 0.3)..<Int(rate * 0.6)]), 0.001, "reverb continues after the dry sound ends")
    }
}

/// SplitMix64: a tiny deterministic generator for reproducible test noise.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
