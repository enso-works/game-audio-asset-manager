import Foundation

/// Loop points in seconds, so they survive resampling on export.
struct LoopPoints: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
}

/// Per-sound data stored in the project file, keyed by path relative to the project folder.
struct SoundMeta: Codable, Equatable {
    var regions: [Region]?
    var loop: LoopPoints?
    var tempo: TempoInfo?
    var sourceURL: String?
    var sourceTitle: String?
    var sourceChannel: String?
    var sourceRange: String?
    var modified: Date?

    var hasSource: Bool { sourceURL != nil }

    /// Source attribution without edit data, for copies derived from this sound.
    var sourceOnly: SoundMeta {
        SoundMeta(sourceURL: sourceURL, sourceTitle: sourceTitle, sourceChannel: sourceChannel, sourceRange: sourceRange)
    }
}

/// Contents of `<project>/.game-audio-asset-manager/project.json`.
struct ProjectConfig: Codable {
    var exportFolder: String?
    var defaultSettings = ExportPreset.godotSFX.settings
    /// Export settings per folder path relative to the project; subfolders inherit.
    var folderSettings: [String: ExportSettings] = [:]
    var sounds: [String: SoundMeta] = [:]
    /// Settings each sound was last exported with, so format or loudness changes count as changed.
    var lastExport: [String: ExportSettings]?
    /// Folders packed into one audio sprite file for the web (relative paths).
    var spriteFolders: [String]?
    /// Export options, stored per project so auto-export behaves like a manual export.
    var options: ExportOptions?

    var exportOptions: ExportOptions { options ?? ExportOptions() }

    static let folderName = ".game-audio-asset-manager"
    static let fileName = "project.json"

    static func url(for project: URL) -> URL {
        project.appendingPathComponent(folderName).appendingPathComponent(fileName)
    }

    enum LoadResult {
        case loaded(ProjectConfig)
        case missing
        /// The file couldn't be read; it was moved aside so a fresh config doesn't overwrite it.
        case corrupt(backup: URL)
    }

    static func load(from project: URL) -> ProjectConfig {
        if case .loaded(let config) = read(from: project) { return config }
        return ProjectConfig()
    }

    static func read(from project: URL) -> LoadResult {
        LegacyMigration.migrateProjectFolder(in: project, to: folderName)
        let file = url(for: project)
        guard let data = try? Data(contentsOf: file) else { return .missing }
        if let config = try? JSONDecoder.project.decode(ProjectConfig.self, from: data) { return .loaded(config) }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = file.deletingLastPathComponent().appendingPathComponent("project.broken-\(stamp).json")
        try? FileManager.default.moveItem(at: file, to: backup)
        return .corrupt(backup: backup)
    }

    /// Writes atomically; returns the error instead of throwing so callers can report it.
    @discardableResult
    func save(to project: URL) -> Error? {
        let url = Self.url(for: project)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.project.encode(self).write(to: url, options: .atomic)
            return nil
        } catch {
            return error
        }
    }

    /// Effective settings for a folder: its own, else the nearest parent's, else the project default.
    func settings(forFolder relativePath: String) -> ExportSettings {
        var path = relativePath
        while true {
            if let settings = folderSettings[path] { return settings }
            if path.isEmpty { return defaultSettings }
            path = (path as NSString).deletingLastPathComponent
        }
    }
}

struct ExportOptions: Codable, Equatable, Sendable {
    var onlyChanged = true
    var writeManifest = true
    var writeCredits = true
    var generateGodot = false
    var generateTypeScript = false
    /// Export the project automatically whenever a sound is saved.
    var autoExport = false
}

extension JSONEncoder {
    static var project: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var project: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// A folder or sound file in the project tree.
struct LibraryNode: Identifiable, Hashable {
    enum Kind { case folder, file }

    let url: URL
    let kind: Kind
    var children: [LibraryNode]?
    var size: Int64 = 0

    var id: URL { url }
    var name: String { kind == .file ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent }
    var isFolder: Bool { kind == .folder }
}
