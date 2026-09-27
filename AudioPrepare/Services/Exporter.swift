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
    /// Target integrated loudness in LUFS; nil leaves levels alone.
    var loudness: Double?

    private static let key = "exportSettings"

    /// Short description, e.g. "WAV 16-bit · Mono · 44.1 kHz".
    var summary: String {
        let quality = switch format {
        case .wav: "\(wavBitDepth)-bit"
        case .ogg: "q\(oggQuality)"
        case .mp3: "\(mp3Bitrate) kbps"
        }
        let channelText = channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "Keep channels"
        let rateText = sampleRate == 0 ? "Keep rate" : String(format: "%g kHz", Double(sampleRate) / 1000)
        let loudnessText = loudness.map { String(format: " · %g LUFS", $0) } ?? ""
        return "\(format.label) \(quality) · \(channelText) · \(rateText)\(loudnessText)"
    }

    /// The matching preset, ignoring loudness (which is set independently).
    var preset: ExportPreset? {
        var plain = self
        plain.loudness = nil
        return ExportPreset.allCases.first { $0.settings == plain }
    }

    /// Applies a preset's format settings but keeps the loudness target.
    func applying(_ preset: ExportPreset) -> ExportSettings {
        var result = preset.settings
        result.loudness = loudness
        return result
    }

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

/// One file-to-file conversion, used by project export and batch convert.
struct ConvertTask: Sendable {
    let input: URL
    let output: URL
    let settings: ExportSettings
    var loop: LoopPoints?
}

struct ConvertFailure: Sendable, Identifiable {
    let id = UUID()
    let input: URL?
    let message: String

    var file: String { input?.lastPathComponent ?? "ffmpeg" }
}

struct ExportJob: Sendable {
    let range: Range<Int>
    let name: String
    /// Loop points in seconds relative to the start of the range.
    var loop: LoopPoints?
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

    /// Converts one file with ffmpeg: optional loudness matching, then encoding, then WAV loop points.
    static func convert(_ input: URL, to output: URL, settings: ExportSettings, loop: LoopPoints?, ffmpeg: URL) async throws {
        var filters: [String] = []
        if settings.channels > 0 {
            // Downmix before measuring so mono exports hit the loudness target too.
            filters.append("aformat=channel_layouts=\(settings.channels == 1 ? "mono" : "stereo")")
        }
        if let loop, settings.format != .wav {
            // Godot loops OGG/MP3 from the end of the file back to loop_offset, so the file must end at the loop end.
            filters.append(String(format: "atrim=end=%.6f", loop.end))
        }
        if let target = settings.loudness, let measured = await measureLoudness(input, filters: filters, ffmpeg: ffmpeg) {
            // A fixed gain keeps the sound's dynamics; the cap keeps true peaks at or below -1 dBTP.
            let gain = min(target - measured.integrated, -1 - measured.truePeak)
            filters.append(String(format: "volume=%.2fdB", gain))
        }
        let log = LogTail()
        let arguments = ["-y", "-v", "error", "-i", input.path, "-vn", "-map_metadata", "-1"]
            + (filters.isEmpty ? [] : ["-af", filters.joined(separator: ",")])
            + codecArguments(settings) + [output.path]
        let status = try await ProcessRunner().run(ffmpeg, arguments) { log.append($0) }
        guard status == 0 else {
            throw ToolError.failed("ffmpeg failed on \(output.lastPathComponent):\n\(log.text)")
        }
        if settings.format == .wav, let loop {
            try WAVLoop.embed(in: output, loop: loop)
        }
    }

    /// Integrated loudness (LUFS) and true peak (dBTP) via ffmpeg's EBU R128 meter. Sounds shorter
    /// than the meter's 400 ms window read as -inf, so those are measured looped.
    static func measureLoudness(_ input: URL, filters: [String], ffmpeg: URL) async -> (integrated: Double, truePeak: Double)? {
        for looped in [false, true] {
            var arguments = ["-hide_banner", "-nostats"]
            if looped { arguments += ["-stream_loop", "50"] }
            arguments += ["-i", input.path, "-vn", "-af", (filters + ["loudnorm=print_format=json"]).joined(separator: ",")]
            if looped { arguments += ["-t", "8"] }
            arguments += ["-f", "null", "-"]
            let log = LogTail(limit: 40)
            guard (try? await ProcessRunner().run(ffmpeg, arguments) { log.append($0) }) == 0 else { return nil }
            func value(_ key: String) -> Double? {
                guard let line = log.all.last(where: { $0.contains("\"\(key)\"") }) else { return nil }
                let parts = line.split(separator: "\"")
                return parts.count >= 4 ? Double(parts[3]) : nil
            }
            if let integrated = value("input_i"), integrated.isFinite, integrated > -70, let peak = value("input_tp") {
                return (integrated, peak)
            }
        }
        return nil
    }

    /// Runs conversions in parallel (ffmpeg is single-threaded for audio) and collects failures.
    static func convertMany(
        _ tasks: [ConvertTask],
        concurrency: Int = 4,
        progress: @escaping @MainActor (Int) -> Void
    ) async -> [ConvertFailure] {
        guard let ffmpeg = Tools.ffmpeg else {
            return [ConvertFailure(input: nil, message: ToolError.missing("ffmpeg").localizedDescription)]
        }
        var failures: [ConvertFailure] = []
        var done = 0
        await withTaskGroup(of: ConvertFailure?.self) { group in
            var next = 0
            func addNext() {
                guard next < tasks.count else { return }
                let task = tasks[next]
                next += 1
                group.addTask {
                    do {
                        try FileManager.default.createDirectory(at: task.output.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try await convert(task.input, to: task.output, settings: task.settings, loop: task.loop, ffmpeg: ffmpeg)
                        return nil
                    } catch {
                        return ConvertFailure(input: task.input, message: error.localizedDescription)
                    }
                }
            }
            for _ in 0..<concurrency { addNext() }
            for await failure in group {
                if let failure { failures.append(failure) }
                done += 1
                await progress(done)
                addNext()
            }
        }
        return failures
    }

    /// Duration in seconds via ffprobe, or nil if unavailable.
    static func duration(of url: URL) async -> Double? {
        guard let ffprobe = Tools.find("ffprobe") else { return nil }
        let log = LogTail()
        let status = try? await ProcessRunner().run(
            ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path]
        ) { log.append($0) }
        guard status == 0 else { return nil }
        return Double(log.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// How a loop will behave in the game for a given format.
    static func loopNote(for format: ExportFormat) -> String {
        switch format {
        case .wav: "Loop points are embedded in the WAV. Godot 4 loops it automatically (Loop Mode: Detect From WAV)."
        case .ogg: "OGG can't carry loop points: the file is cut at the loop end, and the generated sounds.gd (or Godot's Import dock) sets Loop and Loop Offset. For three.js, use the manifest's loopStart/loopEnd."
        case .mp3: "MP3 adds silence at the start and end, so loops click. Use OGG or WAV for loops."
        }
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
            try await convert(temp, to: output, settings: settings, loop: job.loop, ffmpeg: ffmpeg)
            results.append(output)
        }
        await progress(jobs.count, jobs.count)
        return results
    }
}
