import SwiftUI

/// Exports every sound in the project (or one folder) into the game folder, mirroring folders.
struct ProjectExportView: View {
    @Environment(Library.self) private var library
    @Environment(ExportService.self) private var service
    @Environment(\.dismiss) private var dismiss
    let scope: URL?

    @State private var plan = ProjectExportPlan()
    @State private var report: ProjectExportReport?

    private var isWholeProject: Bool { scope == nil }

    private var scopeFolders: [URL] {
        guard let scope else { return library.folders }
        return library.folders.filter { $0 == scope || $0.path.hasPrefix(scope.path + "/") }
    }

    private var options: Binding<ExportOptions> {
        Binding(get: { library.config.exportOptions }, set: { library.setExportOptions($0) })
    }

    var body: some View {
        let options = self.options
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
                            HStack {
                                if library.isSpriteFolder(folder) {
                                    Label("Sprite", systemImage: "square.stack").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.blue)
                                }
                                FolderSettingsControl(folder: folder)
                            }
                        }
                    }
                } header: {
                    Text("Format per folder")
                } footer: {
                    Text("Subfolders inherit their parent's format unless you set one. Tip: sfx as WAV, music and ambience as OGG.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Only export changed sounds", isOn: options.onlyChanged)
                    Toggle("Export automatically when a sound is saved", isOn: options.autoExport)
                } header: {
                    Text("Options")
                } footer: {
                    Text("Auto-export keeps the game folder in sync while you work, so a running game or dev server picks up changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("\(ProjectExporter.manifestName): paths, durations, loops, groups", isOn: options.writeManifest)
                    Toggle("\(ProjectExporter.creditsName): sources for attribution", isOn: options.writeCredits)
                    Toggle("\(CodeGenerator.godotName): Godot Sounds class with preloads and groups", isOn: options.generateGodot)
                    Toggle("\(CodeGenerator.typeScriptName): typed sound keys for three.js", isOn: options.generateTypeScript)
                } header: {
                    Text("Generated files")
                } footer: {
                    Text(isWholeProject ? "Written to the export folder. Names like jump_01, jump_02 become the group \"jump\"." : "Only written when exporting the whole project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!isWholeProject)

                Section("\(plan.soundCount) sounds · \(plan.pendingCount(onlyChanged: options.wrappedValue.onlyChanged)) to export") {
                    if plan.soundCount == 0 {
                        Text("No sounds yet. Save sounds into project folders first; the Inbox is not exported.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(plan.sprites) { sprite in
                        row(sprite.relativeOutput, detail: "sprite of \(sprite.members.count)", loops: false, stale: sprite.isStale)
                    }
                    ForEach(plan.items.prefix(8)) { item in
                        row(item.relativeOutput, detail: nil, loops: item.meta.loop != nil, stale: item.isStale)
                    }
                    if plan.items.count > 8 {
                        Text("+ \(plan.items.count - 8) more").foregroundStyle(.secondary)
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
                    if service.isRunning {
                        ProgressView(value: Double(service.progress.done), total: Double(max(service.progress.total, 1)))
                            .frame(width: 180)
                        Text("\(service.progress.done) of \(service.progress.total)").foregroundStyle(.secondary)
                    } else if let report {
                        Label("Exported \(report.exported), skipped \(report.skipped) unchanged", systemImage: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(report.failures.isEmpty ? .green : .orange)
                        Button("Show in Finder") { library.reveal([library.exportFolder]) }
                    }
                    Spacer()
                    Button(report == nil ? "Cancel" : "Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Export \(plan.pendingCount(onlyChanged: options.wrappedValue.onlyChanged))") {
                        Task {
                            report = await service.export(scope: scope)
                            replan()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(service.isRunning || plan.soundCount == 0)
                }
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 700, height: 680)
        .onAppear(perform: replan)
        .onChange(of: library.config.folderSettings) { replan() }
        .onChange(of: library.config.defaultSettings) { replan() }
        .onChange(of: library.config.spriteFolders) { replan() }
    }

    private func row(_ path: String, detail: String?, loops: Bool, stale: Bool) -> some View {
        HStack {
            Text(path).font(.callout.monospaced())
            if let detail { Text(detail).font(.caption).foregroundStyle(.blue) }
            if loops { Image(systemName: "repeat").foregroundStyle(.green).help("Loops") }
            Spacer()
            Text(stale ? "changed" : "up to date")
                .font(.caption)
                .foregroundStyle(stale ? .orange : .secondary)
        }
    }

    private func replan() {
        plan = ProjectExporter.plan(library: library, scope: scope, destination: library.exportFolder)
    }
}
