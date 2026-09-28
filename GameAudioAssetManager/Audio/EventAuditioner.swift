import Foundation
import Observation

/// Plays sound events the way the game will: picks variants with the event's playback mode and
/// weights, and applies its random pitch and volume.
@MainActor
@Observable
final class EventAuditioner {
    private(set) var loading = false
    var errorMessage: String?

    @ObservationIgnored weak var player: Player?
    @ObservationIgnored private var clips: [URL: AudioClip] = [:]
    @ObservationIgnored private var lastIndex: [String: Int] = [:]

    func audition(_ key: String, _ event: SoundEvent, library: Library, hits: Int = 1) async {
        guard let player else { return }
        var picks: [(EventSound, Double, Double)] = []
        for _ in 0..<hits {
            guard let index = Mix.pick(event.sounds, playback: event.playback, last: lastIndex[key]) else { break }
            lastIndex[key] = index
            let pitch = event.pitchSemitones > 0 ? Double.random(in: -event.pitchSemitones...event.pitchSemitones) : 0
            let volume = event.volumeDb - Double.random(in: 0...max(event.volumeRandomDb, 0))
            picks.append((event.sounds[index], pitch, volume))
        }
        guard !picks.isEmpty else {
            errorMessage = "Add a sound to this event first."
            return
        }
        loading = true
        defer { loading = false }
        var result: [Player.Hit] = []
        for (sound, pitch, volume) in picks {
            let url = library.projectURL.appendingPathComponent(sound.path)
            if clips[url] == nil {
                do {
                    clips[url] = try await AudioDecoder.load(url)
                } catch {
                    errorMessage = "Couldn't load \(sound.path): \(error.localizedDescription)"
                    return
                }
            }
            if let clip = clips[url] { result.append(Player.Hit(clip: clip, semitones: pitch, volumeDb: volume)) }
        }
        errorMessage = nil
        player.playHits(result, gap: 0.2)
    }

    /// Forgets cached audio, e.g. after sounds were edited.
    func clearCache() {
        clips.removeAll()
    }
}
