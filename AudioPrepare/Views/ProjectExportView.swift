import SwiftUI

/// Exports every sound in the project (or one folder) into the game folder, mirroring folders.
struct ProjectExportView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let scope: URL?

    @AppStorage("exportOnlyChanged") private var onlyChanged = true
    @AppStorage("exportManifest") private var writeManifest = true
    @AppStorage("exportCredits") private var writeCredits = true
    @State private var items: [ProjectExportItem] = []
    @State private var running = false
    @State private var progress = (done: 0, total: 0)
    @State private var report: ProjectExportReport?

    private var isWholeProject: Bool { scope == nil }
    private var toExport: [ProjectExportItem] { items.filter { !onlyChanged || $0.isStale } }

    private var scopeFolders: [URL] {
        guard let scope else { return library.folders }
        return library.folders.filter { $0 == scope || $0.path.hasPrefix(scope.path + "/") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    FolderField(url: library.exportFolder) { url in
                        library.setExportFolder(url)
                        replan()
                    }
                } header: {
                    Text(isWholeProject ? "Export \(library.currentProject) to" : "Export \(library.displayName(forFolder: scope!)) to")
                } footer: {
                    Text("Pick your game's sound folder, e.g. res://audio in Godot or public/audio in a three.js app. Project folders are recreated inside it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(scopeFolders, id: \.self) { folder in
                        LabeledContent(library.displayName(forFolder: folder)) {
                            FolderSettingsControl(folder: folder)
                        }
                    }
                } header: {
                    Text("Format per folder")
                } footer: {
                    Text("Subfolders inherit their parent's format unless you set one. Tip: sfx as WAV, music and ambience as OGG.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Options") {
                    Toggle("Only export changed sounds", isOn: $onlyChanged)
                    Toggle("Write \(ProjectExporter.manifestName) (paths, durations, loop points for three.js)", isOn: $writeManifest)
                        .disabled(!isWholeProject)
                    Toggle("Write \(ProjectExporter.creditsName) (sources for attribution)", isOn: $writeCredits)
                        .disabled(!isWholeProject)
                }

                Section("\(items.count) sounds · \(toExport.count) to export") {
                    if items.isEmpty {
                        Text("No sounds yet. Save sounds into project folders first; the Inbox is not exported.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items.prefix(8)) { item in
                        HStack {
                            Text(item.relativeOutput).font(.callout.monospaced())
                            if item.meta.loop != nil {
                                Image(systemName: "repeat").foregroundStyle(.green).help("Loops")
                            }
                            Spacer()
                            Text(item.isStale ? "changed" : "up to date")
                                .font(.caption)
                                .foregroundStyle(item.isStale ? .orange : .secondary)
                        }
                    }
                    if items.count > 8 {
                        Text("+ \(items.count - 8) more").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 8) {
                if let report, !report.failures.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(report.failures) { failure in
                                Text("\(failure.file): \(failure.message)").font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    .frame(maxHeight: 80)
                }
                HStack {
                    if running {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                            .frame(width: 180)
                        Text("\(progress.done) of \(progress.total)").foregroundStyle(.secondary)
                    } else if let report {
                        Label("Exported \(report.exported), skipped \(report.skipped) unchanged", systemImage: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(report.failures.isEmpty ? .green : .orange)
                        Button("Show in Finder") { library.reveal([library.exportFolder]) }
                    }
                    Spacer()
                    Button(report == nil ? "Cancel" : "Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Export \(toExport.count)") { Task { await export() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || (toExport.isEmpty && !writeManifest))
                }
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 680, height: 640)
        .onAppear(perform: replan)
        .onChange(of: library.config.folderSettings) { replan() }
        .onChange(of: library.config.defaultSettings) { replan() }
    }

    private func replan() {
        items = ProjectExporter.plan(library: library, scope: scope, destination: library.exportFolder)
    }

    private func export() async {
        running = true
        report = nil
        let result = await ProjectExporter.run(
            items,
            to: library.exportFolder,
            projectName: library.currentProject,
            onlyChanged: onlyChanged,
            writeManifest: isWholeProject && writeManifest,
            writeCredits: isWholeProject && writeCredits
        ) { done, total in
            progress = (done, total)
        }
        report = result
        library.recordExport(result.succeeded)
        running = false
        replan()
    }
}
