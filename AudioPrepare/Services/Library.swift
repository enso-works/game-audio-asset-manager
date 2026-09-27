import AppKit
import Observation

/// Projects on disk. Each project is a folder with an Inbox for raw downloads plus user folders
/// that mirror the game's sound folders on export.
@MainActor
@Observable
final class Library {
    static let audioExtensions: Set<String> = [
        "mp3", "wav", "ogg", "oga", "m4a", "aac", "flac", "aif", "aiff", "caf", "opus", "webm", "mp4", "mov", "mkv",
    ]
    static let inboxName = "Inbox"

    private(set) var root: URL
    private(set) var projects: [String] = []
    private(set) var currentProject: String
    private(set) var config = ProjectConfig()
    private(set) var tree: [LibraryNode] = []
    /// Called after files move or get renamed, so open editors can follow them.
    @ObservationIgnored var onMove: ((URL, URL) -> Void)?

    init() {
        let defaults = UserDefaults.standard
        let fallback = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioPrepare", isDirectory: true)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            // Unit tests host the app; keep them away from the real library.
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AudioPrepareTests-\(UUID().uuidString)", isDirectory: true)
        } else {
            root = defaults.string(forKey: "libraryRoot").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? fallback
        }
        currentProject = defaults.string(forKey: "currentProject") ?? "Default"
        loadProjects()
    }

    // MARK: - Paths

    var projectsFolder: URL { root.appendingPathComponent("projects", isDirectory: true) }
    var projectURL: URL { projectsFolder.appendingPathComponent(currentProject, isDirectory: true) }
    var inboxURL: URL { projectURL.appendingPathComponent(Self.inboxName, isDirectory: true) }
    var defaultExportFolder: URL {
        root.appendingPathComponent("exports", isDirectory: true).appendingPathComponent(currentProject, isDirectory: true)
    }
    var exportFolder: URL {
        config.exportFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultExportFolder
    }

    func relativePath(_ url: URL) -> String? {
        let base = projectURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == base || path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func contains(_ url: URL) -> Bool { relativePath(url) != nil }

    func isInInbox(_ url: URL) -> Bool {
        guard let path = relativePath(url) else { return false }
        return path == Self.inboxName || path.hasPrefix(Self.inboxName + "/")
    }

    /// All folders in the project except the Inbox, for pickers.
    var folders: [URL] {
        var result = [projectURL]
        func walk(_ nodes: [LibraryNode]) {
            for node in nodes where node.isFolder {
                if node.url.standardizedFileURL == inboxURL.standardizedFileURL { continue }
                result.append(node.url)
                walk(node.children ?? [])
            }
        }
        walk(tree)
        return result
    }

    func displayName(forFolder url: URL) -> String {
        let path = relativePath(url) ?? url.lastPathComponent
        return path.isEmpty ? "\(currentProject) (project root)" : path
    }

    // MARK: - Projects

    private func loadProjects() {
        let fm = FileManager.default
        try? fm.createDirectory(at: projectsFolder, withIntermediateDirectories: true)
        migrateLegacyLayout()
        projects = ((try? fm.contentsOfDirectory(at: projectsFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if projects.isEmpty {
            projects = ["Default"]
        }
        if !projects.contains(currentProject) { currentProject = projects[0] }
        openCurrentProject()
    }

    private func openCurrentProject() {
        UserDefaults.standard.set(currentProject, forKey: "currentProject")
        try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        config = ProjectConfig.load(from: projectURL)
        refresh()
    }

    func switchProject(_ name: String) {
        guard name != currentProject, projects.contains(name) else { return }
        currentProject = name
        openCurrentProject()
    }

    @discardableResult
    func createProject(_ rawName: String) -> Bool {
        let name = Self.cleanName(rawName)
        guard !name.isEmpty, !projects.contains(name) else { return false }
        try? FileManager.default.createDirectory(
            at: projectsFolder.appendingPathComponent(name).appendingPathComponent(Self.inboxName),
            withIntermediateDirectories: true
        )
        projects.append(name)
        projects.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        currentProject = name
        openCurrentProject()
        return true
    }

    @discardableResult
    func renameProject(to rawName: String) -> Bool {
        let name = Self.cleanName(rawName)
        guard !name.isEmpty, !projects.contains(name) else { return false }
        let old = projectURL
        let new = projectsFolder.appendingPathComponent(name, isDirectory: true)
        guard (try? FileManager.default.moveItem(at: old, to: new)) != nil else { return false }
        let oldExport = defaultExportFolder
        projects = projects.map { $0 == currentProject ? name : $0 }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        currentProject = name
        if config.exportFolder == nil, FileManager.default.fileExists(atPath: oldExport.path) {
            try? FileManager.default.moveItem(at: oldExport, to: defaultExportFolder)
        }
        openCurrentProject()
        return true
    }

    func setRoot(_ url: URL) {
        root = url
        UserDefaults.standard.set(url.path, forKey: "libraryRoot")
        loadProjects()
    }

    /// Moves files from the single-library layout (downloads/edited/imported) into a Default project.
    private func migrateLegacyLayout() {
        let fm = FileManager.default
        let target = projectsFolder.appendingPathComponent("Default", isDirectory: true)
        let moves: [(String, URL)] = [
            ("downloads", target.appendingPathComponent(Self.inboxName)),
            ("imported", target.appendingPathComponent(Self.inboxName)),
            ("edited", target.appendingPathComponent("edited")),
        ]
        for (legacy, destination) in moves {
            let folder = root.appendingPathComponent(legacy, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in files {
                try? fm.moveItem(at: file, to: uniqueURL(in: destination, base: file.deletingPathExtension().lastPathComponent, ext: file.pathExtension))
            }
            if (try? fm.contentsOfDirectory(atPath: folder.path))?.filter({ !$0.hasPrefix(".") }).isEmpty == true {
                try? fm.removeItem(at: folder)
            }
        }
        if let legacyExport = UserDefaults.standard.string(forKey: "exportFolder") {
            var config = ProjectConfig.load(from: target)
            if config.exportFolder == nil {
                config.exportFolder = legacyExport
                config.save(to: target)
            }
            UserDefaults.standard.removeObject(forKey: "exportFolder")
        }
    }

    // MARK: - Tree

    func refresh() {
        tree = scan(projectURL)
    }

    private func scan(_ folder: URL) -> [LibraryNode] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]
        )) ?? []
        var folders: [LibraryNode] = []
        var files: [LibraryNode] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                let children = scan(url)
                folders.append(LibraryNode(url: url, kind: .folder, children: children.isEmpty ? nil : children))
            } else if Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                files.append(LibraryNode(url: url, kind: .file, size: Int64(values?.fileSize ?? 0)))
            }
        }
        let byName: (LibraryNode, LibraryNode) -> Bool = { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        folders.sort { a, b in
            if a.name == Self.inboxName { return true }
            if b.name == Self.inboxName { return false }
            return byName(a, b)
        }
        return folders + files.sorted(by: byName)
    }

    /// Sound files under a folder, skipping the Inbox. Used by project export.
    func soundFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if url.standardizedFileURL == inboxURL.standardizedFileURL {
                enumerator.skipDescendants()
                continue
            }
            if Self.audioExtensions.contains(url.pathExtension.lowercased()) { result.append(url) }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - Metadata

    func meta(for url: URL) -> SoundMeta {
        relativePath(url).flatMap { config.sounds[$0] } ?? SoundMeta()
    }

    /// Updates a sound's metadata. Works for files in other projects too (e.g. a download that
    /// finished after switching projects).
    func updateMeta(for url: URL, _ change: (inout SoundMeta) -> Void) {
        if let path = relativePath(url) {
            var meta = config.sounds[path] ?? SoundMeta()
            change(&meta)
            meta.modified = Date()
            config.sounds[path] = meta
            saveConfig()
            return
        }
        let base = projectsFolder.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return }
        let parts = String(path.dropFirst(base.count)).split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let project = projectsFolder.appendingPathComponent(parts[0], isDirectory: true)
        var other = ProjectConfig.load(from: project)
        var meta = other.sounds[parts[1]] ?? SoundMeta()
        change(&meta)
        meta.modified = Date()
        other.sounds[parts[1]] = meta
        other.save(to: project)
    }

    func removeMeta(for url: URL) {
        guard let path = relativePath(url) else { return }
        let removed: (String) -> Bool = { $0 == path || $0.hasPrefix(path + "/") }
        config.sounds = config.sounds.filter { !removed($0.key) }
        config.lastExport = config.lastExport?.filter { !removed($0.key) }
        saveConfig()
    }

    private func moveMeta(from old: URL, to new: URL) {
        guard let oldPath = relativePath(old), let newPath = relativePath(new) else { return }
        var moved: [String: SoundMeta] = [:]
        for (key, value) in config.sounds {
            if key == oldPath {
                moved[newPath] = value
            } else if key.hasPrefix(oldPath + "/") {
                moved[newPath + key.dropFirst(oldPath.count)] = value
            } else {
                moved[key] = value
            }
        }
        config.sounds = moved
        var settings: [String: ExportSettings] = [:]
        for (key, value) in config.folderSettings {
            if key == oldPath {
                settings[newPath] = value
            } else if key.hasPrefix(oldPath + "/") {
                settings[newPath + key.dropFirst(oldPath.count)] = value
            } else {
                settings[key] = value
            }
        }
        config.folderSettings = settings
        saveConfig()
    }

    // MARK: - Export settings

    func settings(forFolder url: URL) -> ExportSettings {
        config.settings(forFolder: relativePath(url) ?? "")
    }

    /// Explicit settings for this folder, or nil when it inherits.
    func ownSettings(forFolder url: URL) -> ExportSettings? {
        guard let path = relativePath(url) else { return nil }
        return path.isEmpty ? config.defaultSettings : config.folderSettings[path]
    }

    func setSettings(_ settings: ExportSettings?, forFolder url: URL) {
        guard let path = relativePath(url) else { return }
        if path.isEmpty {
            config.defaultSettings = settings ?? ExportPreset.godotSFX.settings
        } else {
            config.folderSettings[path] = settings
        }
        saveConfig()
    }

    func lastExportSettings(for url: URL) -> ExportSettings? {
        relativePath(url).flatMap { config.lastExport?[$0] }
    }

    func recordExport(_ exported: [(URL, ExportSettings)]) {
        var record = config.lastExport ?? [:]
        for (url, settings) in exported {
            if let path = relativePath(url) { record[path] = settings }
        }
        config.lastExport = record
        saveConfig()
    }

    func setExportFolder(_ url: URL?) {
        config.exportFolder = url?.path
        saveConfig()
    }

    private func saveConfig() {
        config.save(to: projectURL)
    }

    // MARK: - File operations

    @discardableResult
    func createFolder(named rawName: String, in parent: URL) -> URL? {
        let name = Self.cleanName(rawName)
        guard !name.isEmpty else { return nil }
        let url = parent.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path),
              (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil
        else { return nil }
        refresh()
        return url
    }

    @discardableResult
    func rename(_ url: URL, to rawName: String) -> URL? {
        let name = Self.cleanName(rawName)
        guard !name.isEmpty else { return nil }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let destination = url.deletingLastPathComponent().appendingPathComponent(isFolder ? name : name + "." + url.pathExtension)
        guard destination != url, !FileManager.default.fileExists(atPath: destination.path),
              (try? FileManager.default.moveItem(at: url, to: destination)) != nil
        else { return nil }
        moveMeta(from: url, to: destination)
        refresh()
        onMove?(url, destination)
        return destination
    }

    /// Moves project files into a folder, or copies external files in.
    @discardableResult
    func move(_ urls: [URL], into folder: URL) -> [URL] {
        var results: [URL] = []
        for url in urls {
            if contains(url) {
                guard url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL,
                      !folder.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/")
                else { continue }
                let destination = uniqueURL(in: folder, base: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension)
                if (try? FileManager.default.moveItem(at: url, to: destination)) != nil {
                    moveMeta(from: url, to: destination)
                    onMove?(url, destination)
                    results.append(destination)
                }
            } else if Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                let destination = uniqueURL(in: folder, base: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension)
                if (try? FileManager.default.copyItem(at: url, to: destination)) != nil { results.append(destination) }
            }
        }
        refresh()
        return results
    }

    @discardableResult
    func importFiles(_ urls: [URL]) -> [URL] {
        move(urls.filter { !contains($0) }, into: inboxURL)
    }

    func trash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        removeMeta(for: url)
        refresh()
    }

    func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(index)").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func cleanName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
