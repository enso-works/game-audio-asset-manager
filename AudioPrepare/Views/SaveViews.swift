import SwiftUI

/// Picks a project folder, with an inline way to create a new one.
struct FolderPicker: View {
    @Environment(Library.self) private var library
    @Binding var folder: URL
    @State private var newFolderName = ""

    var body: some View {
        Picker("Folder", selection: $folder) {
            ForEach(library.folders, id: \.self) { url in
                Text(library.displayName(forFolder: url)).tag(url)
            }
        }
        HStack {
            TextField("New folder", text: $newFolderName, prompt: Text("new subfolder name"))
            Button("Create") {
                if let url = library.createFolder(named: newFolderName, in: folder) {
                    folder = url
                    newFolderName = ""
                }
            }
            .disabled(Library.cleanName(newFolderName).isEmpty)
        }
    }

    /// Last folder used for saving, if it still exists in the current project.
    @MainActor
    static func initialFolder(_ library: Library) -> URL {
        if let path = UserDefaults.standard.string(forKey: "lastSaveFolder"),
           let match = library.folders.first(where: { $0.path == path }) {
            return match
        }
        return library.folders.dropFirst().first ?? library.projectURL
    }

    static func remember(_ folder: URL) {
        UserDefaults.standard.set(folder.path, forKey: "lastSaveFolder")
    }
}

struct SaveAsView: View {
    @Environment(EditorModel.self) private var editor
    @Environment(Library.self) private var library
    @Environment(Navigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var folder: URL?
    @State private var removeOriginal = false
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    if let folder = Binding($folder) {
                        FolderPicker(folder: folder)
                    }
                    if let url = editor.url, library.contains(url) {
                        Toggle("Move the original to the Trash", isOn: $removeOriginal)
                    }
                } header: {
                    Text("Save as WAV into the project")
                } footer: {
                    Text("Regions, loop points and the source link are kept with the new file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || Library.cleanName(name).isEmpty || folder == nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
        .onAppear {
            name = Exporter.sanitize(editor.fileName)
            folder = FolderPicker.initialFolder(library)
            removeOriginal = editor.url.map(library.isInInbox) ?? false
        }
    }

    private func save() async {
        guard let folder else { return }
        saving = true
        defer { saving = false }
        FolderPicker.remember(folder)
        if let url = await editor.saveAs(in: folder, name: name, removeOriginal: removeOriginal) {
            navigation.selection = .file(url)
            dismiss()
        }
    }
}

struct SaveRegionsView: View {
    @Environment(EditorModel.self) private var editor
    @Environment(Library.self) private var library
    @Environment(Navigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    @State private var prefix = ""
    @State private var folder: URL?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name prefix", text: $prefix, prompt: Text("optional, e.g. hit_"))
                    if let folder = Binding($folder) {
                        FolderPicker(folder: folder)
                    }
                    LabeledContent("Files") {
                        Text(editor.regions.prefix(4).map { Library.cleanName(prefix + $0.name) + ".wav" }.joined(separator: "\n")
                             + (editor.regions.count > 4 ? "\n+ \(editor.regions.count - 4) more" : ""))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Save \(editor.regions.count) regions as separate sounds")
                }
            }
            .formStyle(.grouped)
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save \(editor.regions.count) Sounds") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || editor.regions.isEmpty || folder == nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
        .onAppear { folder = FolderPicker.initialFolder(library) }
    }

    private func save() async {
        guard let folder else { return }
        saving = true
        defer { saving = false }
        FolderPicker.remember(folder)
        let urls = await editor.saveRegionsAsSounds(in: folder, prefix: prefix)
        if !urls.isEmpty {
            dismiss()
            if !editor.isDirty { navigation.selection = .folder(folder) }
        }
    }
}

struct VariationsView: View {
    @Environment(EditorModel.self) private var editor
    @Environment(Library.self) private var library
    @Environment(Navigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    @AppStorage("variationCount") private var count = 5
    @AppStorage("variationKeepLength") private var keepLength = false
    @State private var name = ""
    @State private var folder: URL?
    @State private var saving = false

    var body: some View {
        @Bindable var editor = editor
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Stepper("Variants: \(count)", value: $count, in: 2...12)
                    Picker("Pitch spread", selection: $editor.pitchSpread) {
                        ForEach([0.5, 1, 2, 3, 5], id: \.self) { Text(String(format: "±%g semitones", $0)).tag($0) }
                    }
                    Toggle("Keep original length (time-stretch)", isOn: $keepLength)
                    LabeledContent("Pitches") {
                        Text(EditorModel.variationPitches(count: count, spread: editor.pitchSpread)
                            .map { String(format: "%+.1f", $0) }.joined(separator: "  "))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Variations of \(editor.hasSelection ? "the selection" : "the whole sound")")
                } footer: {
                    Text("Without time-stretch, higher pitches also play faster, the same as Godot's pitch_scale or three.js playbackRate. Pick a random variant at runtime to avoid repetition.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Save as WAV into") {
                    TextField("Name", text: $name)
                    if let folder = Binding($folder) {
                        FolderPicker(folder: folder)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save \(count) Variants") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || folder == nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 500)
        .onAppear {
            name = Exporter.sanitize(editor.fileName)
            folder = FolderPicker.initialFolder(library)
        }
    }

    private func save() async {
        guard let folder else { return }
        saving = true
        defer { saving = false }
        FolderPicker.remember(folder)
        let urls = await editor.saveVariations(in: folder, name: name, count: count, keepLength: keepLength)
        if !urls.isEmpty {
            dismiss()
            if !editor.isDirty { navigation.selection = .folder(folder) }
        }
    }
}
