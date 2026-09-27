import SwiftUI

/// Converts every audio file in any folder with one preset, keeping subfolders.
struct BatchConvertView: View {
    @Environment(Library.self) private var library
    @AppStorage("batchSource") private var sourcePath = ""
    @AppStorage("batchDestination") private var destinationPath = ""
    @AppStorage("batchRecursive") private var recursive = true
    @AppStorage("batchKeepFolders") private var keepFolders = true
    @AppStorage("batchSnakeCase") private var snakeCase = true
    @State private var settings = ExportPreset.godotMusic.settings
    @State private var files: [URL] = []
    @State private var running = false
    @State private var progress = (done: 0, total: 0)
    @State private var failures: [ConvertFailure] = []
    @State private var finished = false

    private var source: URL? { sourcePath.isEmpty ? nil : URL(fileURLWithPath: sourcePath, isDirectory: true) }
    private var destination: URL? { destinationPath.isEmpty ? nil : URL(fileURLWithPath: destinationPath, isDirectory: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    FolderField(url: source, placeholder: "Choose a folder of audio files") { url in
                        sourcePath = url.path
                        scan()
                    }
                    Toggle("Include subfolders", isOn: $recursive)
                    Text(source == nil ? "No folder selected" : "\(files.count) audio file\(files.count == 1 ? "" : "s") found")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Source")
                }

                Section("Convert to") {
                    ExportSettingsEditor(settings: $settings)
                }

                Section("Destination") {
                    FolderField(url: destination, placeholder: "Choose where converted files go") { destinationPath = $0.path }
                    Toggle("Keep subfolder structure", isOn: $keepFolders)
                    Toggle("Rename to snake_case (game-friendly)", isOn: $snakeCase)
                }
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 8) {
                if !failures.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(failures) { Text("\($0.file): \($0.message)").font(.caption).foregroundStyle(.red) }
                        }
                    }
                    .frame(maxHeight: 80)
                }
                HStack {
                    if running {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 200)
                        Text("\(progress.done) of \(progress.total)").foregroundStyle(.secondary)
                    } else if finished {
                        Label("Converted \(progress.total - failures.count) of \(progress.total)", systemImage: failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(failures.isEmpty ? .green : .orange)
                        if let destination { Button("Show in Finder") { library.reveal([destination]) } }
                    }
                    Spacer()
                    Button("Convert \(files.count) Files") { Task { await convert() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || files.isEmpty || destination == nil)
                }
            }
            .padding(16)
        }
        .navigationTitle("Batch Convert")
        .onAppear(perform: scan)
        .onChange(of: recursive) { scan() }
    }

    private func scan() {
        finished = false
        guard let source else {
            files = []
            return
        }
        let options: FileManager.DirectoryEnumerationOptions = recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil, options: options)
        var found: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if let destination, url.standardizedFileURL.path.hasPrefix(destination.standardizedFileURL.path + "/") { continue }
            if Library.audioExtensions.contains(url.pathExtension.lowercased()) { found.append(url) }
        }
        files = found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func outputURL(for file: URL, source: URL, destination: URL, used: inout Set<String>) -> URL {
        let name = file.deletingPathExtension().lastPathComponent
        var folders: [String] = []
        if keepFolders {
            let relative = file.deletingLastPathComponent().standardizedFileURL.path.dropFirst(source.standardizedFileURL.path.count)
            folders = relative.split(separator: "/").map { snakeCase ? Exporter.sanitize(String($0)) : String($0) }
        }
        let base = (folders + [snakeCase ? Exporter.sanitize(name) : name]).joined(separator: "/")
        var path = base + "." + settings.format.rawValue
        var suffix = 2
        while used.contains(path) {
            path = "\(base)_\(suffix).\(settings.format.rawValue)"
            suffix += 1
        }
        used.insert(path)
        return destination.appendingPathComponent(path)
    }

    private func convert() async {
        guard let source, let destination else { return }
        scan()
        var used = Set<String>()
        let tasks = files.map { ConvertTask(input: $0, output: outputURL(for: $0, source: source, destination: destination, used: &used), settings: settings) }
        running = true
        finished = false
        failures = []
        progress = (0, tasks.count)
        failures = await Exporter.convertMany(tasks) { done in progress = (done, tasks.count) }
        running = false
        finished = true
    }
}
