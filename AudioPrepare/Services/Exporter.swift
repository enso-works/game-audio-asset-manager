import Foundation

enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case wav, ogg, mp3

    var id: Self { self }
    var label: String { rawValue.uppercased() }
}

struct ExportSettings: Equatable, Codable {
    var format: ExportFormat = .ogg
    var channels = 0        // 0 keeps the source channel count
    var sampleRate = 44100  // 0 keeps the source rate
    var wavBitDepth = 16
    var oggQuality = 6
    var mp3Bitrate = 192

    private static let key = "exportSettings"

    static func load() -> ExportSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(ExportSettings.self, from: data)
        else { return ExportPreset.godotSFX.settings }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

enum ExportPreset: String, CaseIterable, Identifiable {
    case godotSFX, godotMusic, webSFX, webMusic

    var id: Self { self }

    var title: String {
        switch self {
        case .godotSFX: "Godot SFX"
        case .godotMusic: "Godot Music"
        case .webSFX: "three.js SFX"
        case .webMusic: "three.js Music"
        }
    }

    var settings: ExportSettings {
        switch self {
        case .godotSFX: ExportSettings(format: .wav, channels: 1, sampleRate: 44100, wavBitDepth: 16)
        case .godotMusic: ExportSettings(format: .ogg, channels: 2, sampleRate: 44100, oggQuality: 6)
        case .webSFX: ExportSettings(format: .mp3, channels: 1, sampleRate: 44100, mp3Bitrate: 128)
        case .webMusic: ExportSettings(format: .mp3, channels: 2, sampleRate: 44100, mp3Bitrate: 192)
        }
    }

    var note: String {
        switch self {
        case .godotSFX:
            "16-bit mono WAV. Cheapest to play in Godot, best for short sounds that fire often."
        case .godotMusic:
            "OGG Vorbis stereo. Small and streams well. Enable Loop in Godot's Import dock for music."
        case .webSFX:
            "MP3 mono. Decodes in every browser through THREE.AudioLoader."
        case .webMusic:
            "MP3 stereo. Widest browser support. MP3 adds a few ms of padding, so avoid it for seamless loops."
        }
    }
}

struct ExportJob: Sendable {
    let range: Range<Int>
    let name: String
}

enum Exporter {
    /// Game-asset friendly file name: lowercase ASCII, underscores, no spaces.
    static func sanitize(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        var out = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-") {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty && !out.hasSuffix("_") {
                out.append("_")
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        return out.isEmpty ? "sound" : String(out.prefix(80))
    }

    static func codecArguments(_ settings: ExportSettings) -> [String] {
        var args: [String] = []
        if settings.channels > 0 { args += ["-ac", "\(settings.channels)"] }
        if settings.sampleRate > 0 { args += ["-ar", "\(settings.sampleRate)"] }
        switch settings.format {
        case .wav: args += ["-c:a", settings.wavBitDepth == 24 ? "pcm_s24le" : "pcm_s16le"]
        case .ogg: args += ["-c:a", "libvorbis", "-q:a", "\(settings.oggQuality)"]
        case .mp3: args += ["-c:a", "libmp3lame", "-b:a", "\(settings.mp3Bitrate)k"]
        }
        return args
    }

    static func export(
        clip: AudioClip,
        jobs: [ExportJob],
        settings: ExportSettings,
        folder: URL,
        overwrite: Bool,
        progress: @escaping @MainActor (Int, Int) -> Void
    ) async throws -> [URL] {
        guard let ffmpeg = Tools.ffmpeg else { throw ToolError.missing("ffmpeg") }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var results: [URL] = []
        var used = Set<String>()
        for (index, job) in jobs.enumerated() {
            await progress(index, jobs.count)
            let ext = settings.format.rawValue
            let base = sanitize(job.name)
            var output = folder.appendingPathComponent(base).appendingPathExtension(ext)
            var suffix = 2
            while used.contains(output.lastPathComponent) || (!overwrite && fm.fileExists(atPath: output.path)) {
                output = folder.appendingPathComponent("\(base)_\(suffix)").appendingPathExtension(ext)
                suffix += 1
            }
            used.insert(output.lastPathComponent)

            let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
            defer { try? fm.removeItem(at: temp) }
            try clip.writeWAV(to: temp, range: job.range)

            let log = LogTail()
            let arguments = ["-y", "-v", "error", "-i", temp.path, "-map_metadata", "-1"]
                + codecArguments(settings) + [output.path]
            let status = try await ProcessRunner().run(ffmpeg, arguments) { log.append($0) }
            guard status == 0 else {
                throw ToolError.failed("ffmpeg failed on \(output.lastPathComponent):\n\(log.text)")
            }
            results.append(output)
        }
        await progress(jobs.count, jobs.count)
        return results
    }
}
