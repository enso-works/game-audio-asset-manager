import XCTest
@testable import Audio_Prepare

final class ExportTests: XCTestCase {
    func testSanitize() {
        XCTAssertEqual(Exporter.sanitize("Me at the Zoo [jNQXAC9IVRw] – Čevapi!"), "me_at_the_zoo_jnqxac9ivrw_cevapi")
        XCTAssertEqual(Exporter.sanitize("  "), "sound")
        XCTAssertEqual(Exporter.sanitize("jump-01"), "jump-01")
    }

    func testPresetMatchingIgnoresLoudness() {
        var settings = ExportPreset.godotMusic.settings
        settings.loudness = -18
        XCTAssertEqual(settings.preset, .godotMusic)
        XCTAssertEqual(settings.applying(.godotSFX).loudness, -18)
        XCTAssertTrue(settings.summary.contains("-18 LUFS"))
    }

    func testCodecArguments() {
        XCTAssertEqual(Exporter.codecArguments(ExportPreset.godotSFX.settings), ["-ac", "1", "-ar", "44100", "-c:a", "pcm_s16le"])
        XCTAssertEqual(Array(Exporter.codecArguments(ExportPreset.godotMusic.settings).suffix(4)), ["-c:a", "libvorbis", "-q:a", "6"])
    }

    func testFolderSettingsInherit() {
        var config = ProjectConfig()
        config.folderSettings["music"] = ExportPreset.godotMusic.settings
        XCTAssertEqual(config.settings(forFolder: "music/boss"), ExportPreset.godotMusic.settings)
        XCTAssertEqual(config.settings(forFolder: "sfx"), config.defaultSettings)
    }

    @MainActor
    func testParseLinksWithRanges() {
        let links = DownloadQueue.parseLinks("https://youtu.be/a 1:30-2:05\nhttps://youtu.be/b\nx https://youtu.be/c 0:05–0:09\nhttps://youtu.be/a 1:30-2:05")
        XCTAssertEqual(links, [
            LinkRequest(url: "https://youtu.be/a", range: "1:30-2:05"),
            LinkRequest(url: "https://youtu.be/b", range: nil),
            LinkRequest(url: "https://youtu.be/c", range: "0:05-0:09"),
        ])
    }

    @MainActor
    func testVariationPitchesAreEvenlySpread() {
        XCTAssertEqual(EditorModel.variationPitches(count: 5, spread: 2), [-2, -1, 0, 1, 2])
        XCTAssertEqual(EditorModel.variationPitches(count: 1, spread: 2), [0])
    }

    func testLoudnessMatchingHitsTarget() async throws {
        guard let ffmpeg = Tools.ffmpeg else { throw XCTSkip("ffmpeg not installed") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rate = 48_000.0
        for (name, amplitude, seconds) in [("loud", 0.8, 2.0), ("quiet", 0.02, 2.0), ("short", 0.5, 0.25)] {
            let input = folder.appendingPathComponent("\(name).wav")
            let clip = AudioClip(channels: [(0..<Int(rate * seconds)).map { Float(amplitude * sin(2 * .pi * 440 * Double($0) / rate)) }], sampleRate: rate)
            try clip.writeWAV(to: input, range: 0..<clip.frameCount)
            var settings = ExportPreset.godotSFX.settings
            settings.loudness = -20
            let output = folder.appendingPathComponent("\(name)_out.wav")
            try await Exporter.convert(input, to: output, settings: settings, loop: nil, ffmpeg: ffmpeg)
            let result = await Exporter.measureLoudness(output, filters: [], ffmpeg: ffmpeg)
            let measured = try XCTUnwrap(result)
            XCTAssertEqual(measured.integrated, -20, accuracy: 0.5, name)
            XCTAssertLessThanOrEqual(measured.truePeak, -0.9, name)
        }
    }
}
