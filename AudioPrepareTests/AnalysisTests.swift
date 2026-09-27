import AVFoundation
import XCTest
@testable import Audio_Prepare

final class AnalysisTests: XCTestCase {
    private let rate = 48_000.0

    func testTempoDetectsClickTrack() throws {
        var samples = [Float](repeating: 0, count: Int(rate * 20))
        var time = 0.3
        var beat = 0
        while time < 19.9 {
            let start = Int(time * rate)
            for i in 0..<400 {
                samples[start + i] += Float((beat % 4 == 0 ? 0.9 : 0.5) * sin(Double(i) * 0.3) * exp(-Double(i) / 80))
            }
            time += 60.0 / 128
            beat += 1
        }
        let clip = AudioClip(channels: [samples], sampleRate: rate)
        let tempo = try XCTUnwrap(TempoDetector.detect(clip, range: 0..<clip.frameCount))
        XCTAssertEqual(tempo.bpm, 128)
        XCTAssertEqual(tempo.offset, 0.3, accuracy: 0.015)
    }

    func testTempoRejectsNoise() {
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<Int(rate * 10)).map { _ in Float.random(in: -0.1...0.1, using: &generator) }
        XCTAssertNil(TempoDetector.detect(AudioClip(channels: [noise], sampleRate: rate), range: 0..<noise.count))
    }

    func testTempoShiftAndNearestBar() {
        let tempo = TempoInfo(bpm: 120, offset: 0.25, beatsPerBar: 4)
        XCTAssertEqual(tempo.barSeconds, 2)
        XCTAssertEqual(tempo.shifted(by: -1).offset, 1.25, accuracy: 1e-9)
        XCTAssertEqual(tempo.nearestBeat(to: 3.1, bars: true), 2.25, accuracy: 1e-9)
    }

    func testSpectrogramPeakFrequencyAndLevel() {
        let n = Int(rate)
        let clip = AudioClip(channels: [(0..<n).map { Float(0.5 * sin(2 * .pi * 1000 * Double($0) / rate)) }], sampleRate: rate)
        let spectrogram = Spectrogram(clip: clip)
        let column = spectrogram.columns / 2
        let row = Array(spectrogram.data[(column * spectrogram.bins)..<((column + 1) * spectrogram.bins)])
        let peak = row.indices.max { row[$0] < row[$1] }!
        XCTAssertEqual(Double(peak) * rate / Double(Spectrogram.fftSize), 1000, accuracy: rate / Double(Spectrogram.fftSize))
        XCTAssertEqual(Double(row[peak]) / 255 * 100 - 100, -6, accuracy: 1.5)
    }

    func testWAVLoopChunk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = AudioClip(channels: [[Float](repeating: 0.1, count: 48_000)], sampleRate: rate)
        try clip.writeWAV(to: url, range: 0..<clip.frameCount)
        try WAVLoop.embed(in: url, loop: LoopPoints(start: 0.25, end: 0.75))

        let data = try Data(contentsOf: url)
        XCTAssertEqual(Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }), data.count - 8)
        let chunk = try XCTUnwrap(data.range(of: Data("smpl".utf8)))
        let field = { (index: Int) in data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: chunk.lowerBound + 8 + index * 4, as: UInt32.self) } }
        XCTAssertEqual(field(7), 1)          // loop count
        XCTAssertEqual(field(11), 12_000)    // start frame
        XCTAssertEqual(field(12), 35_999)    // end frame, inclusive
        XCTAssertNotNil(try? AVAudioFile(forReading: url))
    }
}
