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
                    HStack {
                        ForEach(ExportPreset.allCases) { preset in
                            Button(preset.title) { settings = preset.settings }
                                .buttonStyle(.bordered)
                                .tint(activePreset == preset ? .accentColor : nil)
                        }
                    }
                    Picker("Format", selection: $settings.format) {
                        ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Channels", selection: $settings.channels) {
                        Text("Keep").tag(0)
                        Text("Mono").tag(1)
                        Text("Stereo").tag(2)
                    }
                    .pickerStyle(.segmented)
                    Picker("Sample rate", selection: $settings.sampleRate) {
                        Text("Keep").tag(0)
                        Text("22.05 kHz").tag(22050)
                        Text("44.1 kHz").tag(44100)
                        Text("48 kHz").tag(48000)
                    }
                    switch settings.format {
                    case .wav:
                        Picker("Bit depth", selection: $settings.wavBitDepth) {
                            Text("16-bit").tag(16)
                            Text("24-bit").tag(24)
                        }
                    case .ogg:
                        Picker("Quality", selection: $settings.oggQuality) {
                            ForEach([3, 4, 5, 6, 7, 8, 10], id: \.self) { Text("q\($0) (~\(oggKbps($0)) kbps)").tag($0) }
                        }
                    case .mp3:
                        Picker("Bitrate", selection: $settings.mp3Bitrate) {
                            ForEach([96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                        }
                    }
                    Text(activePreset?.note ?? "Custom settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private var activePreset: ExportPreset? {
        ExportPreset.allCases.first { $0.settings == settings }
    }

    private var jobs: [ExportJob] {
        switch scope {
        case .whole:
            return [ExportJob(range: 0..<editor.frameCount, name: baseName)]
        case .selection:
            guard let selection = editor.selection, !selection.isEmpty else { return [] }
            return [ExportJob(range: selection, name: baseName)]
        case .regions:
            return editor.regions.map { ExportJob(range: $0.range, name: prefix + $0.name) }
        }
    }

    private var previewNames: String {
        let names = jobs.map { Exporter.sanitize($0.name) + "." + settings.format.rawValue }
        guard names.count > 3 else { return names.joined(separator: "\n") }
        return names.prefix(2).joined(separator: "\n") + "\n+ \(names.count - 2) more"
    }

    private func oggKbps(_ quality: Int) -> Int {
        [3: 112, 4: 128, 5: 160, 6: 192, 7: 224, 8: 256, 10: 500][quality] ?? 0
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
