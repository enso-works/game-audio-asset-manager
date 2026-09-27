import SwiftUI

@main
struct AudioPrepareApp: App {
    @State private var library = Library()
    @State private var downloads = DownloadQueue()
    @State private var editor = EditorModel()
    @State private var navigation = Navigation()
    @State private var exportService = ExportService()

    var body: some Scene {
        Window("Audio Prepare", id: "main") {
            ContentView()
                .environment(library)
                .environment(downloads)
                .environment(editor)
                .environment(navigation)
                .environment(exportService)
                .frame(minWidth: 1100, minHeight: 680)
                .onAppear {
                    downloads.library = library
                    editor.library = library
                    editor.exportService = exportService
                    exportService.library = library
                    library.onMove = { old, new in
                        editor.fileMoved(from: old, to: new)
                        if navigation.selection == .file(old) { navigation.selection = .file(new) }
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    Task {
                        switch await editor.save() {
                        case .saved(let url): navigation.selection = .file(url)
                        case .needsSaveAs: editor.showSaveAs = true
                        case .failed: break
                        }
                    }
                }
                .keyboardShortcut("s")
                .disabled(editor.clip == nil)

                Button("Save As...") { editor.showSaveAs = true }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(editor.clip == nil)

                Button("Save Regions as Sounds...") { editor.showSaveRegions = true }
                    .disabled(editor.regions.isEmpty)

                Divider()

                Button("Export...") { editor.showExport = true }
                    .keyboardShortcut("e")
                    .disabled(editor.clip == nil)

                Button("Export Project...") { navigation.exportProject() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Audio") {
                Button("Play / Stop") { editor.togglePlay() }
                Button("Trim to Selection") { editor.trimToSelection() }
                    .keyboardShortcut("t")
                Button("Add Region from Selection") { editor.addRegion() }
                    .keyboardShortcut("r")
                Divider()
                Button("Zoom In") { editor.zoomIn() }
                    .keyboardShortcut("=")
                Button("Zoom Out") { editor.zoomOut() }
                    .keyboardShortcut("-")
                Button("Zoom to Fit") { editor.zoomToFit() }
                    .keyboardShortcut("0")
                Button("Zoom to Selection") { editor.zoomToSelection() }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { editor.showShortcuts = true }
                    .keyboardShortcut("/")
                    .disabled(editor.clip == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(library)
        }
    }
}

struct SettingsView: View {
    @Environment(Library.self) private var library

    var body: some View {
        Form {
            LabeledContent("Library folder") {
                HStack {
                    Text(library.root.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { library.setRoot(url) }
                    }
                    Button("Open") { NSWorkspace.shared.open(library.projectsFolder) }
                }
            }
            LabeledContent("Export folder (\(library.currentProject))") {
                HStack {
                    Text(library.exportFolder.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Reset") { library.setExportFolder(nil) }
                }
            }
            LabeledContent("yt-dlp") { Text(Tools.ytDlp?.path ?? "Not found (brew install yt-dlp)") }
            LabeledContent("ffmpeg") { Text(Tools.ffmpeg?.path ?? "Not found (brew install ffmpeg)") }
        }
        .formStyle(.grouped)
        .frame(width: 560)
    }
}
