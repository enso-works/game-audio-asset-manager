import Foundation

/// How an event picks among its sounds. Matches Godot's AudioStreamRandomizer playback modes.
enum EventPlayback: String, Codable, CaseIterable, Identifiable, Sendable {
    case randomNoRepeat, random, sequence

    var id: Self { self }

    var title: String {
        switch self {
        case .randomNoRepeat: "Random, no repeat"
        case .random: "Random"
        case .sequence: "In order"
        }
    }

    var godotValue: Int {
        switch self {
        case .randomNoRepeat: 0
        case .random: 1
        case .sequence: 2
        }
    }
}

/// Distance falloff for positional sounds. Values follow Godot's AudioStreamPlayer3D models.
enum Attenuation: String, Codable, CaseIterable, Identifiable, Sendable {
    case inverse, inverseSquare, logarithmic, none

    var id: Self { self }

    var title: String {
        switch self {
        case .inverse: "Inverse (natural)"
        case .inverseSquare: "Inverse square (fast)"
        case .logarithmic: "Logarithmic"
        case .none: "None"
        }
    }

    var godotValue: Int {
        switch self {
        case .inverse: 0
        case .inverseSquare: 1
        case .logarithmic: 2
        case .none: 3
        }
    }
}

struct SpatialSettings: Codable, Equatable, Sendable {
    var attenuation: Attenuation = .inverse
    /// Distance at which the sound plays at full volume (Godot unit_size, Web Audio refDistance).
    var unitSize: Double = 10
    /// Beyond this the sound is silent; 0 means no limit.
    var maxDistance: Double = 0
}

struct EventSound: Codable, Equatable, Hashable, Sendable {
    /// Sound file path relative to the project folder.
    var path: String
    var weight: Double = 1
}

/// Something the game triggers ("player/jump"): which sounds, how they vary and where they play.
struct SoundEvent: Codable, Equatable, Sendable {
    var sounds: [EventSound] = []
    var playback: EventPlayback = .randomNoRepeat
    /// Random pitch range in semitones (plus or minus).
    var pitchSemitones: Double = 0
    var volumeDb: Double = 0
    /// Random volume reduction per play, 0 to this many dB.
    var volumeRandomDb: Double = 0
    var bus: String = "SFX"
    /// Maximum simultaneous plays; the oldest stops when exceeded. 0 means unlimited.
    var maxInstances: Int = 0
    var cooldownMs: Double = 0
    /// Positional (3D) settings, or nil for a 2D sound.
    var spatial: SpatialSettings?
}

/// A mixer bus. Paths nest with "/", e.g. "SFX/Player"; everything feeds Master.
struct AudioBus: Codable, Equatable, Identifiable, Sendable {
    var path: String
    var volumeDb: Double = 0

    var id: String { path }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    var parentPath: String? {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
    }
    var depth: Int { path.split(separator: "/").count - 1 }
}

enum Mix {
    static let defaultBuses: [AudioBus] = [
        AudioBus(path: "Music", volumeDb: -3),
        AudioBus(path: "Ambience", volumeDb: -6),
        AudioBus(path: "SFX"),
        AudioBus(path: "SFX/Player"),
        AudioBus(path: "SFX/UI", volumeDb: -3),
        AudioBus(path: "SFX/World"),
        AudioBus(path: "Voice"),
    ]

    static let categoryFolders: Set<String> = ["sfx", "music", "ambience", "voice", "ui"]

    /// Parents come before children so engines can create them in order.
    static func sorted(_ buses: [AudioBus]) -> [AudioBus] {
        buses.sorted { a, b in
            let pa = a.path.split(separator: "/"), pb = b.path.split(separator: "/")
            for (x, y) in zip(pa, pb) where x != y { return x < y }
            return pa.count < pb.count
        }
    }

    /// Guesses a bus for a sound from its folders: music/ -> Music, sfx/ui/ -> SFX/UI, ...
    static func suggestedBus(for soundPath: String, buses: [AudioBus]) -> String {
        let folders = soundPath.lowercased().split(separator: "/").dropLast().map(String.init)
        let byName = Dictionary(buses.map { ($0.path.lowercased(), $0.path) }, uniquingKeysWith: { a, _ in a })
        for depth in stride(from: min(folders.count, 2), through: 1, by: -1) {
            let candidate = folders.prefix(depth).joined(separator: "/")
            if let bus = byName[candidate] { return bus }
            if let last = folders.prefix(depth).last, let bus = buses.first(where: { $0.name.lowercased() == last }) { return bus.path }
        }
        return buses.first { $0.path == "SFX" }?.path ?? buses.first?.path ?? "Master"
    }

    /// Event key for a variation group or sound: drops a leading category folder
    /// ("sfx/player/jump" -> "player/jump").
    static func eventKey(for soundKey: String) -> String {
        let parts = soundKey.split(separator: "/").map(String.init)
        guard parts.count > 1, categoryFolders.contains(parts[0].lowercased()) else { return soundKey }
        return parts.dropFirst().joined(separator: "/")
    }

    static func isValidEventKey(_ key: String) -> Bool {
        !key.isEmpty && key.range(of: #"^[a-z0-9_\-]+(/[a-z0-9_\-]+)*$"#, options: .regularExpression) != nil
    }

    /// Picks the next sound index the way the game will (weights, no-repeat, sequence).
    static func pick(_ sounds: [EventSound], playback: EventPlayback, last: Int?, random: Double = Double.random(in: 0..<1)) -> Int? {
        guard !sounds.isEmpty else { return nil }
        switch playback {
        case .sequence:
            return ((last ?? -1) + 1) % sounds.count
        case .random, .randomNoRepeat:
            var candidates = Array(sounds.indices)
            if playback == .randomNoRepeat, sounds.count > 1, let last { candidates.removeAll { $0 == last } }
            let total = candidates.reduce(0) { $0 + max(sounds[$1].weight, 0) }
            guard total > 0 else { return candidates.first }
            var threshold = random * total
            for index in candidates {
                threshold -= max(sounds[index].weight, 0)
                if threshold < 0 { return index }
            }
            return candidates.last
        }
    }
}
