import XCTest
@testable import GameAudioAssetManager

final class SoundEventTests: XCTestCase {
    private let three = [EventSound(path: "a.wav"), EventSound(path: "b.wav"), EventSound(path: "c.wav")]

    func testRandomNoRepeatNeverRepeats() {
        var last: Int?
        for _ in 0..<1000 {
            let index = Mix.pick(three, playback: .randomNoRepeat, last: last)!
            XCTAssertNotEqual(index, last)
            last = index
        }
    }

    func testSequenceCycles() {
        var last: Int?
        var order: [Int] = []
        for _ in 0..<6 {
            last = Mix.pick(three, playback: .sequence, last: last)
            order.append(last!)
        }
        XCTAssertEqual(order, [0, 1, 2, 0, 1, 2])
    }

    func testWeightsAreRespected() {
        let weighted = [EventSound(path: "common.wav", weight: 3), EventSound(path: "rare.wav", weight: 1)]
        var common = 0
        for _ in 0..<4000 where Mix.pick(weighted, playback: .random, last: nil) == 0 { common += 1 }
        XCTAssertEqual(Double(common) / 4000, 0.75, accuracy: 0.04)
    }

    func testSuggestedBusFromFolders() {
        let buses = Mix.defaultBuses
        XCTAssertEqual(Mix.suggestedBus(for: "music/theme.wav", buses: buses), "Music")
        XCTAssertEqual(Mix.suggestedBus(for: "sfx/ui/click_01.wav", buses: buses), "SFX/UI")
        XCTAssertEqual(Mix.suggestedBus(for: "sfx/player/jump.wav", buses: buses), "SFX/Player")
        XCTAssertEqual(Mix.suggestedBus(for: "enemies/growl.wav", buses: buses), "SFX")
    }

    func testEventKeys() {
        XCTAssertEqual(Mix.eventKey(for: "sfx/player/jump"), "player/jump")
        XCTAssertEqual(Mix.eventKey(for: "enemies/boss/roar"), "enemies/boss/roar")
        XCTAssertTrue(Mix.isValidEventKey("player/jump_big"))
        XCTAssertFalse(Mix.isValidEventKey("Player Jump"))
        XCTAssertFalse(Mix.isValidEventKey("player//jump"))
    }

    func testEventPathsFollowRenamesAndDeletes() {
        var config = ProjectConfig()
        config.events = ["player/jump": SoundEvent(sounds: [EventSound(path: "sfx/player/jump_01.wav"), EventSound(path: "sfx/other.wav")])]
        config.renameSoundPaths(from: "sfx/player", to: "sfx/hero")
        XCTAssertEqual(config.events?["player/jump"]?.sounds.map(\.path), ["sfx/hero/jump_01.wav", "sfx/other.wav"])
        config.removeSoundPaths(under: "sfx/other.wav")
        XCTAssertEqual(config.events?["player/jump"]?.sounds.map(\.path), ["sfx/hero/jump_01.wav"])
    }
}

final class EventExportTests: XCTestCase {
    private func sound(_ key: String, sprite: Double? = nil) -> ExportedSound {
        ExportedSound(key: key, sourcePath: key + ".wav", file: key + (sprite == nil ? ".wav" : ".ogg"), format: .wav,
                      duration: 0.5, loop: nil, tempo: nil, source: nil, spriteStart: sprite)
    }

    func testGodotBusNamesStayUnique() {
        let names = CodeGenerator.godotBusNames([AudioBus(path: "SFX"), AudioBus(path: "SFX/UI"), AudioBus(path: "Music"), AudioBus(path: "Music/UI")])
        XCTAssertEqual(names["SFX"], "SFX")
        XCTAssertEqual(names["SFX/UI"], "SFX_UI")
        XCTAssertEqual(names["Music/UI"], "Music_UI")
    }

    func testGodotBusLayout() {
        let text = CodeGenerator.godotBusLayout([AudioBus(path: "SFX/Player", volumeDb: -2), AudioBus(path: "SFX")])
        XCTAssertTrue(text.hasPrefix("[gd_resource type=\"AudioBusLayout\" format=3]"))
        XCTAssertTrue(text.contains("bus/1/name = &\"SFX\""), "parents first")
        XCTAssertTrue(text.contains("bus/2/name = &\"Player\""))
        XCTAssertTrue(text.contains("bus/2/volume_db = -2.0"))
        XCTAssertTrue(text.contains("bus/2/send = &\"SFX\""))
    }

    func testGodotEventResourceSkipsSpriteSounds() {
        let event = ExportedEvent(
            key: "player/jump",
            event: SoundEvent(playback: .sequence, pitchSemitones: 12, volumeRandomDb: 3),
            sounds: [(sound("sfx/jump_01"), 2), (sound("sfx/ui/click", sprite: 0.1), 1)],
            missing: []
        )
        let text = CodeGenerator.godotEvent(event, resourceBase: "res://audio/")
        XCTAssertTrue(text.contains("path=\"res://audio/sfx/jump_01.wav\""))
        XCTAssertFalse(text.contains("click"))
        XCTAssertTrue(text.contains("playback_mode = 2"))
        XCTAssertTrue(text.contains("random_pitch = 2.0"))
        XCTAssertTrue(text.contains("random_volume_offset_db = 3.0"))
        XCTAssertTrue(text.contains("streams_count = 1"))
        XCTAssertTrue(text.contains("stream_0/weight = 2.0"))
        XCTAssertEqual(CodeGenerator.godotEventPath("player/jump"), "events/player/jump.tres")
    }

    func testWebEngineAndManifestIncludeEventsAndBuses() throws {
        var spatialEvent = SoundEvent(bus: "SFX/World")
        spatialEvent.spatial = SpatialSettings(attenuation: .inverseSquare, unitSize: 4, maxDistance: 40)
        let events = [ExportedEvent(key: "world/door", event: spatialEvent, sounds: [(sound("sfx/door"), 1)], missing: [])]
        let buses = [AudioBus(path: "SFX"), AudioBus(path: "SFX/World", volumeDb: -3)]
        let engine = WebAudioGenerator.engine(events: events, buses: buses, projectName: "Test")
        XCTAssertTrue(engine.contains("'world/door': { sounds: [{ sound: 'sfx/door', weight: 1 }]"))
        XCTAssertTrue(engine.contains("spatial: { attenuation: 'inverseSquare', unitSize: 4, maxDistance: 40 }"))
        XCTAssertTrue(engine.contains("{ path: 'SFX/World', parent: 'SFX', volumeDb: -3 }"))
        XCTAssertTrue(engine.contains("export class AudioEngine"))

        let json = ProjectExporter.manifest([sound("sfx/door")], events: events, buses: buses, projectName: "Test")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let door = try XCTUnwrap((root["events"] as? [String: [String: Any]])?["world/door"])
        XCTAssertEqual(door["bus"] as? String, "SFX/World")
        XCTAssertEqual((door["spatial"] as? [String: Any])?["attenuation"] as? String, "inverseSquare")
        XCTAssertEqual((root["buses"] as? [[String: Any]])?.count, 2)
    }
}
