import Foundation

/// A project sound and where it goes in the export folder.
struct ProjectExportItem: Identifiable, Sendable {
    let input: URL
    /// Output path relative to the export folder, mirroring the project folders.
    let relativeOutput: String
    let settings: ExportSettings
    let meta: SoundMeta
    let isStale: Bool

    var id: String { relativeOutput }
    var key: String { (relativeOutput as NSString).deletingPathExtension }
}

struct ProjectExportReport: Sendable {
    var exported = 0
    var skipped = 0
    var failures: [ConvertFailure] = []
    var extraFiles: [URL] = []
    /// Sounds that exported successfully, with the settings used.
    var succeeded: [(URL, ExportSettings)] = []
}

/// Exports a project (or one folder of it) into the game folder, mirroring the folder structure.
enum ProjectExporter {
    static let manifestName = "audio_manifest.json"
    static let creditsName = "CREDITS.md"

    @MainActor
    static func plan(library: Library, scope: URL?, destination: URL) -> [ProjectExportItem] {
        var used = Set<String>()
        var items: [ProjectExportItem] = []
        for file in library.soundFiles(in: scope ?? library.projectURL) {
            guard let relative = library.relativePath(file) else { continue }
            let folder = (relative as NSString).deletingLastPathComponent
            let settings = library.config.settings(forFolder: folder)
            let folders = folder.split(separator: "/").map { Exporter.sanitize(String($0)) }
            let base = (folders + [Exporter.sanitize(file.deletingPathExtension().lastPathComponent)]).joined(separator: "/")
            var output = base + "." + settings.format.rawValue
            var suffix = 2
            while used.contains(output) {
                output = "\(base)_\(suffix).\(settings.format.rawValue)"
                suffix += 1
            }
            used.insert(output)

            let meta = library.meta(for: file)
            let target = destination.appendingPathComponent(output)
            let outputDate = (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let sourceDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            let settingsChanged = library.lastExportSettings(for: file) != settings
            let stale = settingsChanged || (outputDate.map { $0 < sourceDate || $0 < (meta.modified ?? .distantPast) } ?? true)
            items.append(ProjectExportItem(input: file, relativeOutput: output, settings: settings, meta: meta, isStale: stale))
        }
        return items
    }

    static func run(
        _ items: [ProjectExportItem],
        to destination: URL,
        projectName: String,
        onlyChanged: Bool,
        writeManifest: Bool,
        writeCredits: Bool,
        progress: @escaping @MainActor (Int, Int) -> Void
    ) async -> ProjectExportReport {
        var report = ProjectExportReport()
        let selected = items.filter { !onlyChanged || $0.isStale }
        report.skipped = items.count - selected.count
        let tasks = selected.map {
            ConvertTask(input: $0.input, output: destination.appendingPathComponent($0.relativeOutput), settings: $0.settings, loop: $0.meta.loop)
        }
        await progress(0, tasks.count)
        report.failures = await Exporter.convertMany(tasks) { done in progress(done, tasks.count) }
        report.exported = tasks.count - report.failures.count
        let failed = Set(report.failures.compactMap(\.input))
        report.succeeded = selected.filter { !failed.contains($0.input) }.map { ($0.input, $0.settings) }

        if writeManifest {
            let url = destination.appendingPathComponent(manifestName)
            if (try? await manifest(items, destination: destination, projectName: projectName).write(to: url, options: .atomic)) != nil {
                report.extraFiles.append(url)
            }
        }
        if writeCredits, let text = credits(items, projectName: projectName) {
            let url = destination.appendingPathComponent(creditsName)
            if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil {
                report.extraFiles.append(url)
            }
        }
        return report
    }

    /// JSON for three.js (or any engine): sound key -> file, duration and loop points.
    static func manifest(_ items: [ProjectExportItem], destination: URL, projectName: String) async -> Data {
        var sounds: [String: [String: Any]] = [:]
        for item in items {
            var entry: [String: Any] = ["file": item.relativeOutput, "format": item.settings.format.rawValue]
            if let duration = await Exporter.duration(of: destination.appendingPathComponent(item.relativeOutput)) {
                entry["duration"] = seconds(duration)
            }
            if let loop = item.meta.loop {
                entry["loop"] = true
                entry["loopStart"] = seconds(loop.start)
                entry["loopEnd"] = seconds(loop.end)
            } else {
                entry["loop"] = false
            }
            if let tempo = item.meta.tempo {
                entry["bpm"] = tempo.bpm
                entry["beatsPerBar"] = tempo.beatsPerBar
            }
            if let source = item.meta.sourceURL { entry["source"] = source }
            sounds[item.key] = entry
        }
        let root: [String: Any] = [
            "project": projectName,
            "generated": ISO8601DateFormatter().string(from: Date()),
            "sounds": sounds,
        ]
        var data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Millisecond precision without binary float noise in the JSON (3.751, not 3.7509999).
    private static func seconds(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.3f", value))
    }

    /// Attribution list for sounds that came from YouTube (or any tracked source).
    static func credits(_ items: [ProjectExportItem], projectName: String) -> String? {
        let sourced = items.filter { $0.meta.hasSource }
        guard !sourced.isEmpty else { return nil }
        var lines = ["# Audio credits: \(projectName)", "", "Check each source's license before shipping.", ""]
        for item in sourced {
            let meta = item.meta
            var line = "- `\(item.relativeOutput)`"
            if let title = meta.sourceTitle { line += ": \"\(title)\"" }
            if let channel = meta.sourceChannel, !channel.isEmpty { line += " by \(channel)" }
            if let range = meta.sourceRange { line += " (\(range))" }
            if let url = meta.sourceURL { line += " <\(url)>" }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
