import AppKit
import SwiftUI

struct ExportView: View {
    @Environment(EditorModel.self) private var editor
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    enum Scope: String, CaseIterable, Identifiable {
        case whole, selection, regions
        var id: Self { self }
    }

    @State private var scope: Scope = .whole
    @State private var baseName = ""
    @State private var prefix = ""
    @State private var settings = ExportSettings.load()
    @State private var overwrite = false
    @State private var isExporting = false
    @State private var progressText = ""
    @State private var exported: [URL] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("What to export") {
                    Picker("Export", selection: $scope) {
                        Text("Whole File").tag(Scope.whole)
                        Text("Selection").tag(Scope.selection).disabled(!editor.hasSelection)
                        Text("Regions (\(editor.regions.count))").tag(Scope.regions).disabled(editor.regions.isEmpty)
                    }
                    .pickerStyle(.segmented)

                    if scope == .regions {
                        TextField("Prefix", text: $prefix, prompt: Text("optional, e.g. sfx_"))
                    } else {
                        TextField("File name", text: $baseName)
                    }
                    LabeledContent("Files") {
                        Text(previewNames)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Format") {
                    ExportSettingsEditor(settings: $settings)
                    if jobs.contains(where: { $0.loop != nil }) {
                        Label(Exporter.loopNote(for: settings.format), systemImage: "repeat")
                            .font(.caption)
                            .foregroundStyle(settings.format == .mp3 ? .orange : .green)
                    }
                }

                Section("Destination") {
                    LabeledContent("Folder") {
                        HStack {
                            Text(library.exportFolder.path(percentEncoded: false))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Choose...", action: chooseFolder)
                        }
                    }
                    Toggle("Overwrite files with the same name", isOn: $overwrite)
                }
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 8) {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                }
                HStack {
                    if isExporting {
                        ProgressView().controlSize(.small)
                        Text(progressText).foregroundStyle(.secondary)
                    } else if !exported.isEmpty {
                        Label("Exported \(exported.count) file\(exported.count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Show in Finder") { library.reveal(exported) }
                    }
                    Spacer()
                    Button(exported.isEmpty ? "Cancel" : "Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Export") { Task { await export() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isExporting || jobs.isEmpty)
                }
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 620)
        .onAppear {
            baseName = Exporter.sanitize(editor.fileName)
            scope = !editor.regions.isEmpty ? .regions : editor.hasSelection ? .selection : .whole
        }
        .onChange(of: settings) { _, value in value.save() }
    }

    private var jobs: [ExportJob] {
        switch scope {
        case .whole:
            let range = 0..<editor.frameCount
            return [ExportJob(range: range, name: baseName, loop: loopPoints(within: range))]
        case .selection:
            guard let selection = editor.selection, !selection.isEmpty else { return [] }
            return [ExportJob(range: selection, name: baseName, loop: loopPoints(within: selection))]
        case .regions:
            return editor.regions.map { ExportJob(range: $0.range, name: prefix + $0.name, loop: loopPoints(within: $0.range)) }
        }
    }

    /// The loop, relative to the range, if it lies fully inside it.
    private func loopPoints(within range: Range<Int>) -> LoopPoints? {
        guard let loop = editor.loop, loop.lowerBound >= range.lowerBound, loop.upperBound <= range.upperBound else { return nil }
        let rate = editor.sampleRate
        return LoopPoints(
            start: Double(loop.lowerBound - range.lowerBound) / rate,
            end: Double(loop.upperBound - range.lowerBound) / rate
        )
    }

    private var previewNames: String {
        let names = jobs.map { Exporter.sanitize($0.name) + "." + settings.format.rawValue }
        guard names.count > 3 else { return names.joined(separator: "\n") }
        return names.prefix(2).joined(separator: "\n") + "\n+ \(names.count - 2) more"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = library.exportFolder
        panel.prompt = "Use Folder"
        panel.message = "Choose where exported sounds go, e.g. your game's assets/sounds folder."
        if panel.runModal() == .OK, let url = panel.url {
            library.setExportFolder(url)
        }
    }

    private func export() async {
        guard let clip = editor.clip else { return }
        isExporting = true
        errorMessage = nil
        exported = []
        defer { isExporting = false }
        do {
            exported = try await Exporter.export(
                clip: clip,
                jobs: jobs,
                settings: settings,
                folder: library.exportFolder,
                overwrite: overwrite
            ) { done, total in
                progressText = "Exporting \(min(done + 1, total)) of \(total)..."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
