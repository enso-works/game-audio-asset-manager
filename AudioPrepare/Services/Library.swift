import AppKit
import Observation

struct LibraryFile: Identifiable, Hashable {
    let url: URL
    let folder: Library.Folder
    let modified: Date
    let size: Int64

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor
@Observable
final class Library {
    enum Folder: String, CaseIterable, Identifiable {
        case downloads, edited, imported

        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    static let audioExtensions: Set<String> = [
        "mp3", "wav", "ogg", "oga", "m4a", "aac", "flac", "aif", "aiff", "caf", "opus", "webm", "mp4", "mov", "mkv",
    ]

    private(set) var root: URL
    private(set) var exportFolder: URL
    private(set) var files: [LibraryFile] = []

    init() {
        let defaults = UserDefaults.standard
        let fallback = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioPrepare", isDirectory: true)
        let root = defaults.string(forKey: "libraryRoot").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? fallback
        self.root = root
        exportFolder = defaults.string(forKey: "exportFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? root.appendingPathComponent("exports", isDirectory: true)
        prepare()
        refresh()
    }

    var defaultExportFolder: URL { root.appendingPathComponent("exports", isDirectory: true) }

    func url(for folder: Folder) -> URL {
        root.appendingPathComponent(folder.rawValue, isDirectory: true)
    }

    func setRoot(_ url: URL) {
        let usedDefaultExport = exportFolder.standardizedFileURL == defaultExportFolder.standardizedFileURL
        root = url
        UserDefaults.standard.set(url.path, forKey: "libraryRoot")
        if usedDefaultExport { setExportFolder(defaultExportFolder) }
        prepare()
        refresh()
    }

    func setExportFolder(_ url: URL) {
        exportFolder = url
        UserDefaults.standard.set(url.path, forKey: "exportFolder")
    }

    func prepare() {
        for folder in Folder.allCases {
            try? FileManager.default.createDirectory(at: url(for: folder), withIntermediateDirectories: true)
        }
        try? FileManager.default.createDirectory(at: defaultExportFolder, withIntermediateDirectories: true)
    }

    func refresh() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var result: [LibraryFile] = []
        for folder in Folder.allCases {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: url(for: folder), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )) ?? []
            for url in urls where Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                let values = try? url.resourceValues(forKeys: Set(keys))
                result.append(LibraryFile(
                    url: url,
                    folder: folder,
                    modified: values?.contentModificationDate ?? .distantPast,
                    size: Int64(values?.fileSize ?? 0)
                ))
            }
        }
        files = result.sorted { $0.modified > $1.modified }
    }

    /// Copies external files into the library's "imported" folder.
    @discardableResult
    func importFiles(_ urls: [URL]) -> [URL] {
        let destinationFolder = url(for: .imported)
        var imported: [URL] = []
        for source in urls where Self.audioExtensions.contains(source.pathExtension.lowercased()) {
            if source.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) { continue }
            let destination = uniqueURL(
                in: destinationFolder,
                base: source.deletingPathExtension().lastPathComponent,
                ext: source.pathExtension
            )
            if (try? FileManager.default.copyItem(at: source, to: destination)) != nil {
                imported.append(destination)
            }
        }
        refresh()
        return imported
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

    func trash(_ file: LibraryFile) {
        try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
        refresh()
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
