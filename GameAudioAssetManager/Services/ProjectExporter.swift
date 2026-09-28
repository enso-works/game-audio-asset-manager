import Foundation

/// A project sound and where it goes in the export folder.
struct ProjectExportItem: Identifiable, Sendable {
    let input: URL
    /// Path relative to the project folder, as stored in events.
    let sourcePath: String
    /// Output path relative to the export folder, mirroring the project folders.
    let relativeOutput: String
    let settings: ExportSettings
    let meta: SoundMeta
    let isStale: Bool

    var id: String { relativeOutput }
    var key: String { (relativeOutput as NSString).deletingPathExtension }
}

/// A folder packed into one audio file with an offset table, so the web loads one file instead of many.
struct SpriteExport: Identifiable, Sendable {
    struct Member: Sendable {
        let input: URL
        let sourcePath: String
        let key: String
        let meta: SoundMeta
    }

    let relativeOutput: String
    let settings: ExportSettings
    let members: [Member]
    let isStale: Bool

    var id: String { relativeOutput }
    var jsonPath: String { (relativeOutput as NSString).deletingPathExtension + ".sprite.json" }
}

struct ProjectExportPlan: Sendable {
    var items: [ProjectExportItem] = []
    var sprites: [SpriteExport] = []
    var events: [String: SoundEvent] = [:]
    var buses: [AudioBus] = Mix.defaultBuses

    var soundCount: Int { items.count + sprites.reduce(0) { $0 + $1.members.count } }
    func pendingCount(onlyChanged: Bool) -> Int {
        items.filter { !onlyChanged || $0.isStale }.count + sprites.filter { !onlyChanged || $0.isStale }.count
    }
}

struct ProjectExportReport: Sendable {
    var exported = 0
    var skipped = 0
    var failures: [ConvertFailure] = []
    var extraFiles: [URL] = []
    /// Sounds that exported successfully, with the settings used.
    var succeeded: [(URL, ExportSettings)] = []
    /// Things worth knowing that aren't failures (e.g. skipped events).
    var notes: [String] = []
}

/// Everything the manifest and generated code need to know about one exported sound.
struct ExportedSound: Sendable {
    let key: String
    let sourcePath: String
    let file: String
    let format: ExportFormat
    var duration: Double?
    let loop: LoopPoints?
    let tempo: TempoInfo?
    let source: String?
    /// Offset and length inside a sprite file, in seconds.
    var spriteStart: Double?
}

/// An event with its sounds resolved to exported files.
struct ExportedEvent: Sendable {
    let key: String
    let event: SoundEvent
    let sounds: [(sound: ExportedSound, weight: Double)]
    let missing: [String]

    /// Godot plays individual files; sounds packed into web sprites are left out.
    var godotSounds: [(sound: ExportedSound, weight: Double)] { sounds.filter { $0.sound.spriteStart == nil } }
}

/// Exports a project (or one folder of it) into the game folder, mirroring the folder structure.
enum ProjectExporter {
    static let manifestName = "audio_manifest.json"
    static let creditsName = "CREDITS.md"
    static let spriteGap = 0.1

    @MainActor
    static func plan(library: Library, scope: URL?, destination: URL) -> ProjectExportPlan {
        var plan = ProjectExportPlan()
        plan.events = library.events
        plan.buses = Mix.sorted(library.config.mixBuses)
        var used = Set<String>()
        var spriteMembers: [String: [SpriteExport.Member]] = [:]
        var spriteStale: [String: Bool] = [:]
        let spriteFolders = library.config.spriteFolders ?? []

        func outputPath(_ folder: String, _ name: String, _ ext: String) -> String {
            let folders = folder.split(separator: "/").map { Exporter.sanitize(String($0)) }
            let base = (folders + [Exporter.sanitize(name)]).joined(separator: "/")
            var output = base + "." + ext
            var suffix = 2
            while used.contains(output) {
                output = "\(base)_\(suffix).\(ext)"
                suffix += 1
            }
            used.insert(output)
            return output
        }

        for file in library.soundFiles(in: scope ?? library.projectURL) {
            guard let relative = library.relativePath(file) else { continue }
            let folder = (relative as NSString).deletingLastPathComponent
            let settings = library.config.settings(forFolder: folder)
            let meta = library.meta(for: file)
            let sourceDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            let settingsChanged = library.lastExportSettings(for: file) != settings

            if let sprite = spriteFolders.filter({ folder == $0 || folder.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
                let inner = String(relative.dropFirst(sprite.count + 1))
                let key = ((sprite.split(separator: "/").map { Exporter.sanitize(String($0)) })
                    + (inner as NSString).deletingPathExtension.split(separator: "/").map { Exporter.sanitize(String($0)) })
                    .joined(separator: "/")
                spriteMembers[sprite, default: []].append(SpriteExport.Member(input: file, sourcePath: relative, key: key, meta: meta))
                spriteStale[sprite] = (spriteStale[sprite] ?? false) || settingsChanged || (meta.modified ?? .distantPast) > sourceDate
                    || library.lastExportSettings(for: file) == nil
                continue
            }

            let output = outputPath(folder, file.deletingPathExtension().lastPathComponent, settings.format.rawValue)
            let target = destination.appendingPathComponent(output)
            let outputDate = (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let stale = settingsChanged || (outputDate.map { $0 < sourceDate || $0 < (meta.modified ?? .distantPast) } ?? true)
            plan.items.append(ProjectExportItem(input: file, sourcePath: relative, relativeOutput: output, settings: settings, meta: meta, isStale: stale))
        }

        for (folder, members) in spriteMembers.sorted(by: { $0.key < $1.key }) {
            let settings = library.config.settings(forFolder: folder)
            let parent = (folder as NSString).deletingLastPathComponent
            let output = outputPath(parent, (folder as NSString).lastPathComponent, settings.format.rawValue)
            let target = destination.appendingPathComponent(output)
            let sprite = SpriteExport(relativeOutput: output, settings: settings, members: members, isStale: false)
            let layoutMatches = readSpriteLayout(destination.appendingPathComponent(sprite.jsonPath)).map { Set($0.keys) == Set(members.map(\.key)) } ?? false
            let outputDate = (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let newest = members.compactMap { (try? $0.input.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }.max() ?? .distantFuture
            let stale = (spriteStale[folder] ?? true) || !layoutMatches || (outputDate.map { $0 < newest } ?? true)
            plan.sprites.append(SpriteExport(relativeOutput: output, settings: settings, members: members, isStale: stale))
        }
        return plan
    }

    static func run(
        _ plan: ProjectExportPlan,
        to destination: URL,
        projectName: String,
        options: ExportOptions,
        wholeProject: Bool,
        progress: @escaping @MainActor (Int, Int) -> Void
    ) async -> ProjectExportReport {
        var report = ProjectExportReport()
        let items = plan.items.filter { !options.onlyChanged || $0.isStale }
        let sprites = plan.sprites.filter { !options.onlyChanged || $0.isStale }
        report.skipped = plan.pendingCount(onlyChanged: false) - items.count - sprites.count
        let total = items.count + sprites.count
        let tasks = items.map {
            ConvertTask(input: $0.input, output: destination.appendingPathComponent($0.relativeOutput), settings: $0.settings, loop: $0.meta.loop)
        }
        await progress(0, total)
        report.failures = await Exporter.convertMany(tasks) { done in progress(done, total) }
        let failed = Set(report.failures.compactMap(\.input))
        report.succeeded = items.filter { !failed.contains($0.input) }.map { ($0.input, $0.settings) }

        for (index, sprite) in sprites.enumerated() {
            do {
                try await buildSprite(sprite, destination: destination)
                report.succeeded += sprite.members.map { ($0.input, sprite.settings) }
            } catch {
                report.failures.append(ConvertFailure(input: sprite.members.first?.input, message: "Sprite \(sprite.relativeOutput): \(error.localizedDescription)"))
            }
            await progress(items.count + index + 1, total)
        }
        report.exported = total - report.failures.count

        guard wholeProject else { return report }
        let sounds = await describe(plan, destination: destination)
        let events = exportedEvents(plan, sounds: sounds)
        for event in events where !event.missing.isEmpty {
            report.notes.append("Event \(event.key): \(event.missing.count) sound(s) not in a project folder were skipped (\(event.missing.joined(separator: ", "))).")
        }
        var generated: [(Bool, String, () -> String)] = [
            (options.writeManifest, manifestName, { manifest(sounds, events: events, buses: plan.buses, projectName: projectName) }),
            (options.writeCredits, creditsName, { credits(plan, projectName: projectName) ?? "" }),
            (options.generateGodot, CodeGenerator.godotName, { CodeGenerator.godot(sounds, events: events, buses: plan.buses, projectName: projectName, exportFolder: destination) }),
            (options.generateTypeScript, CodeGenerator.typeScriptName, { CodeGenerator.typeScript(sounds, projectName: projectName) }),
            (options.generateTypeScript, WebAudioGenerator.fileName, { WebAudioGenerator.engine(events: events, buses: plan.buses, projectName: projectName) }),
        ]
        if options.generateGodot {
            let base = CodeGenerator.godotResourcePath(for: destination)
            if base.isEmpty, !events.isEmpty {
                report.notes.append("Godot event resources need the export folder inside a Godot project (next to or below project.godot); they were skipped.")
            } else {
                generated.append((true, CodeGenerator.godotBusLayoutName, { CodeGenerator.godotBusLayout(plan.buses) }))
                for event in events where !event.godotSounds.isEmpty {
                    generated.append((true, CodeGenerator.godotEventPath(event.key), { CodeGenerator.godotEvent(event, resourceBase: base) }))
                }
            }
        }
        for (enabled, name, text) in generated where enabled {
            let content = text()
            guard !content.isEmpty else { continue }
            let url = destination.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? content.write(to: url, atomically: true, encoding: .utf8)) != nil {
                report.extraFiles.append(url)
            }
        }
        return report
    }

    // MARK: - Sprites

    /// Decodes the members, joins them with short gaps at one rate and channel count, then encodes once.
    private static func buildSprite(_ sprite: SpriteExport, destination: URL) async throws {
        guard let ffmpeg = Tools.ffmpeg else { throw ToolError.missing("ffmpeg") }
        var clips: [AudioClip] = []
        for member in sprite.members {
            clips.append(try await AudioDecoder.load(member.input))
        }
        let rate = sprite.settings.sampleRate > 0 ? Double(sprite.settings.sampleRate) : clips.map(\.sampleRate).max() ?? 44_100
        let channels = sprite.settings.channels > 0 ? sprite.settings.channels : min(clips.map(\.channelCount).max() ?? 1, 2)
        let gap = [Float](repeating: 0, count: Int(spriteGap * rate))
        var joined = [[Float]](repeating: gap, count: channels)
        var layout: [String: [Double]] = [:]
        for (member, clip) in zip(sprite.members, clips) {
            let conformed = clip.conformed(sampleRate: rate, channelCount: channels)
            let start = Double(joined[0].count) / rate
            for c in 0..<channels { joined[c] += conformed.channels[min(c, conformed.channelCount - 1)] + gap }
            layout[member.key] = [start, conformed.duration]
        }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: temp) }
        let clip = AudioClip(channels: joined, sampleRate: rate)
        try clip.writeWAV(to: temp, range: 0..<clip.frameCount)
        let output = destination.appendingPathComponent(sprite.relativeOutput)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        var settings = sprite.settings
        settings.loudness = nil
        // Loudness is matched per sound before joining so each sound hits the target.
        if let target = sprite.settings.loudness {
            try await matchLoudness(&joined, layout: layout, rate: rate, target: target, ffmpeg: ffmpeg)
            try AudioClip(channels: joined, sampleRate: rate).writeWAV(to: temp, range: 0..<joined[0].count)
        }
        try await Exporter.convert(temp, to: output, settings: settings, loop: nil, ffmpeg: ffmpeg)

        // Howler.js format (milliseconds), plus seconds for three.js.
        let json: [String: Any] = [
            "src": [output.lastPathComponent],
            "sprite": layout.mapValues { [Int(($0[0] * 1000).rounded()), Int(($0[1] * 1000).rounded())] },
            "sounds": layout.mapValues { ["start": decimal($0[0]), "duration": decimal($0[1])] },
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: destination.appendingPathComponent(sprite.jsonPath), options: .atomic)
    }

    private static func matchLoudness(_ channels: inout [[Float]], layout: [String: [Double]], rate: Double, target: Double, ffmpeg: URL) async throws {
        for (_, span) in layout {
            let range = Int(span[0] * rate)..<min(Int((span[0] + span[1]) * rate), channels[0].count)
            let part = AudioClip(channels: channels.map { Array($0[range]) }, sampleRate: rate)
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
            defer { try? FileManager.default.removeItem(at: temp) }
            try part.writeWAV(to: temp, range: 0..<part.frameCount)
            guard let measured = await Exporter.measureLoudness(temp, filters: [], ffmpeg: ffmpeg) else { continue }
            let gain = Float(pow(10, min(target - measured.integrated, -1 - measured.truePeak) / 20))
            for c in channels.indices {
                for i in range { channels[c][i] *= gain }
            }
        }
    }

    static func readSpriteLayout(_ url: URL) -> [String: (start: Double, duration: Double)]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sounds = json["sounds"] as? [String: [String: Double]]
        else { return nil }
        return sounds.compactMapValues { entry in
            guard let start = entry["start"], let duration = entry["duration"] else { return nil }
            return (start, duration)
        }
    }

    // MARK: - Manifest, credits

    /// Collects durations (ffprobe) and sprite offsets for every sound in the plan.
    static func describe(_ plan: ProjectExportPlan, destination: URL) async -> [ExportedSound] {
        var sounds: [ExportedSound] = []
        for item in plan.items {
            sounds.append(ExportedSound(
                key: item.key, sourcePath: item.sourcePath, file: item.relativeOutput, format: item.settings.format,
                duration: await Exporter.duration(of: destination.appendingPathComponent(item.relativeOutput)),
                loop: item.meta.loop, tempo: item.meta.tempo, source: item.meta.sourceURL
            ))
        }
        for sprite in plan.sprites {
            let layout = readSpriteLayout(destination.appendingPathComponent(sprite.jsonPath)) ?? [:]
            for member in sprite.members {
                let span = layout[member.key]
                sounds.append(ExportedSound(
                    key: member.key, sourcePath: member.sourcePath, file: sprite.relativeOutput, format: sprite.settings.format,
                    duration: span?.duration, loop: nil, tempo: member.meta.tempo, source: member.meta.sourceURL,
                    spriteStart: span?.start
                ))
            }
        }
        return sounds.sorted { $0.key < $1.key }
    }

    /// Sounds named like `jump_01`, `jump_02` form the group `jump` when there are at least two.
    static func groups(_ keys: [String]) -> [String: [String]] {
        var groups: [String: [String]] = [:]
        for key in keys {
            guard let match = key.range(of: #"_\d{1,3}$"#, options: .regularExpression) else { continue }
            groups[String(key[..<match.lowerBound]), default: []].append(key)
        }
        return groups.filter { $0.value.count >= 2 }.mapValues { $0.sorted() }
    }

    /// Events resolved to exported sounds; sounds outside project folders (e.g. the Inbox) are listed as missing.
    static func exportedEvents(_ plan: ProjectExportPlan, sounds: [ExportedSound]) -> [ExportedEvent] {
        let bySource = Dictionary(sounds.map { ($0.sourcePath, $0) }, uniquingKeysWith: { a, _ in a })
        return plan.events.keys.sorted().compactMap { key in
            let event = plan.events[key]!
            var members: [(sound: ExportedSound, weight: Double)] = []
            var missing: [String] = []
            for sound in event.sounds {
                if let exported = bySource[sound.path] { members.append((exported, sound.weight)) } else { missing.append(sound.path) }
            }
            return ExportedEvent(key: key, event: event, sounds: members, missing: missing)
        }
    }

    /// JSON for three.js (or any engine): sound key -> file, duration, loop points, tempo, sprite offsets.
    static func manifest(_ sounds: [ExportedSound], events: [ExportedEvent] = [], buses: [AudioBus] = [], projectName: String) -> String {
        var entries: [String: [String: Any]] = [:]
        for sound in sounds {
            var entry: [String: Any] = ["file": sound.file, "format": sound.format.rawValue, "loop": sound.loop != nil]
            if let duration = sound.duration { entry["duration"] = decimal(duration) }
            if let loop = sound.loop {
                entry["loopStart"] = decimal(loop.start)
                entry["loopEnd"] = decimal(loop.end)
            }
            if let tempo = sound.tempo {
                entry["bpm"] = tempo.bpm
                entry["beatsPerBar"] = tempo.beatsPerBar
            }
            if let start = sound.spriteStart { entry["spriteStart"] = decimal(start) }
            if let source = sound.source { entry["source"] = source }
            entries[sound.key] = entry
        }
        let root: [String: Any] = [
            "project": projectName,
            "generated": ISO8601DateFormatter().string(from: Date()),
            "sounds": entries,
            "groups": groups(sounds.map(\.key)),
            "events": Dictionary(uniqueKeysWithValues: events.map { event -> (String, [String: Any]) in
                var entry: [String: Any] = [
                    "sounds": event.sounds.map { ["sound": $0.sound.key, "weight": $0.weight] },
                    "playback": event.event.playback.rawValue,
                    "pitchSemitones": event.event.pitchSemitones,
                    "volumeDb": event.event.volumeDb,
                    "volumeRandomDb": event.event.volumeRandomDb,
                    "bus": event.event.bus,
                    "maxInstances": event.event.maxInstances,
                    "cooldownMs": event.event.cooldownMs,
                ]
                if let spatial = event.event.spatial {
                    entry["spatial"] = ["attenuation": spatial.attenuation.rawValue, "unitSize": spatial.unitSize, "maxDistance": spatial.maxDistance]
                }
                return (event.key, entry)
            }),
            "buses": buses.map { ["path": $0.path, "volumeDb": $0.volumeDb] },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    /// Attribution list for sounds that came from YouTube (or any tracked source).
    static func credits(_ plan: ProjectExportPlan, projectName: String) -> String? {
        let entries = plan.items.map { ($0.relativeOutput, $0.meta) }
            + plan.sprites.flatMap { sprite in sprite.members.map { ("\(sprite.relativeOutput) (\($0.key))", $0.meta) } }
        let sourced = entries.filter { $0.1.hasSource }
        guard !sourced.isEmpty else { return nil }
        var lines = ["# Audio credits: \(projectName)", "", "Check each source's license before shipping.", ""]
        for (file, meta) in sourced {
            var line = "- `\(file)`"
            if let title = meta.sourceTitle { line += ": \"\(title)\"" }
            if let channel = meta.sourceChannel, !channel.isEmpty { line += " by \(channel)" }
            if let range = meta.sourceRange { line += " (\(range))" }
            if let url = meta.sourceURL { line += " <\(url)>" }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Millisecond precision without binary float noise in the JSON (3.751, not 3.7509999).
    static func decimal(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.3f", value))
    }
}
