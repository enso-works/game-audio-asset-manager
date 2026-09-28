import XCTest
@testable import GameAudioAssetManager

final class CodeGenerationTests: XCTestCase {
    private let sounds = [
        ExportedSound(key: "music/theme", file: "music/theme.ogg", format: .ogg, duration: 12.5,
                      loop: LoopPoints(start: 2, end: 10), tempo: TempoInfo(bpm: 120, offset: 0, beatsPerBar: 4), source: nil),
        ExportedSound(key: "sfx/jump_01", file: "sfx/jump_01.wav", format: .wav, duration: 0.5, loop: nil, tempo: nil, source: nil),
        ExportedSound(key: "sfx/jump_02", file: "sfx/jump_02.wav", format: .wav, duration: 0.45, loop: nil, tempo: nil, source: nil),
        ExportedSound(key: "sfx/ui/click", file: "sfx/ui.ogg", format: .ogg, duration: 0.2, loop: nil, tempo: nil, source: nil, spriteStart: 0.1),
    ]

    func testGroupsNeedTwoNumberedMembers() {
        let groups = ProjectExporter.groups(["sfx/jump_01", "sfx/jump_02", "sfx/hit_01", "music/theme"])
        XCTAssertEqual(groups, ["sfx/jump": ["sfx/jump_01", "sfx/jump_02"]])
    }

    func testIdentifier() {
        XCTAssertEqual(CodeGenerator.identifier("sfx/player/jump-01"), "SFX_PLAYER_JUMP_01")
        XCTAssertEqual(CodeGenerator.identifier("8bit/coin"), "SOUND_8BIT_COIN")
    }

    func testGodotScript() {
        let script = CodeGenerator.godot(sounds, projectName: "Test", exportFolder: URL(fileURLWithPath: "/nonexistent/audio"))
        XCTAssertTrue(script.contains("class_name Sounds"))
        XCTAssertTrue(script.contains("const SFX_JUMP_01 := preload(\"sfx/jump_01.wav\")"))
        XCTAssertTrue(script.contains("\"sfx/jump\": [SFX_JUMP_01, SFX_JUMP_02],"))
        XCTAssertTrue(script.contains("loop_offset = 2.000"))
        XCTAssertFalse(script.contains("sfx/ui/click"), "sprite sounds are web-only")
    }

    func testGodotResourcePathFindsProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audio = root.appendingPathComponent("assets/audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("project.godot"))
        XCTAssertEqual(CodeGenerator.godotResourcePath(for: audio), "res://assets/audio/")
    }

    func testTypeScript() {
        let source = CodeGenerator.typeScript(sounds, projectName: "Test")
        XCTAssertTrue(source.contains("'music/theme': { url: 'music/theme.ogg', duration: 12.500, loop: true, loopStart: 2.000, loopEnd: 10.000, bpm: 120 },"))
        XCTAssertTrue(source.contains("'sfx/ui/click': { url: 'sfx/ui.ogg', duration: 0.200, loop: false, spriteStart: 0.100 },"))
        XCTAssertTrue(source.contains("'sfx/jump': ['sfx/jump_01', 'sfx/jump_02'],"))
        XCTAssertTrue(source.contains("export function pickVariant(group: SoundGroup): SoundKey"))
    }

    func testManifestIncludesGroups() throws {
        let json = ProjectExporter.manifest(sounds, projectName: "Test")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((root["groups"] as? [String: [String]])?["sfx/jump"], ["sfx/jump_01", "sfx/jump_02"])
        let theme = try XCTUnwrap((root["sounds"] as? [String: [String: Any]])?["music/theme"])
        XCTAssertEqual(theme["bpm"] as? Double, 120)
    }
}
