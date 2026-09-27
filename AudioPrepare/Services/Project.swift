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

/// Contents of `<project>/.audioprepare/project.json`.
struct ProjectConfig: Codable {
    var exportFolder: String?
    var defaultSettings = ExportPreset.godotSFX.settings
    /// Export settings per folder path relative to the project; subfolders inherit.
    var folderSettings: [String: ExportSettings] = [:]
    var sounds: [String: SoundMeta] = [:]
    /// Settings each sound was last exported with, so format or loudness changes count as changed.
    var lastExport: [String: ExportSettings]?

    static let folderName = ".audioprepare"
    static let fileName = "project.json"

    static func url(for project: URL) -> URL {
        project.appendingPathComponent(folderName).appendingPathComponent(fileName)
    }

    static func load(from project: URL) -> ProjectConfig {
        guard let data = try? Data(contentsOf: url(for: project)),
              let config = try? JSONDecoder.project.decode(ProjectConfig.self, from: data)
        else { return ProjectConfig() }
        return config
    }

    func save(to project: URL) {
        let url = Self.url(for: project)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.project.encode(self) {
            try? data.write(to: url, options: .atomic)
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
