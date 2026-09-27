import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case downloader
    case batch
    case folder(URL)
    case file(URL)
}

@MainActor
@Observable
final class Navigation {
    var selection: SidebarItem? = .downloader
    var exportScope: URL?
    var showProjectExport = false

    func exportProject(_ folder: URL? = nil) {
        exportScope = folder
        showProjectExport = true
    }
}

/// A request to type a name (new folder, rename, new project).
struct NamePrompt: Identifiable {
    let id = UUID()
    let title: String
    let initial: String
    let action: (String) -> Void
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(EditorModel.self) private var editor
    @Environment(Navigation.self) private var navigation

    private enum Pending {
        case navigate(SidebarItem?)
        case switchProject(String)
    }

    @State private var pending: Pending?

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            SidebarView(selection: guardedSelection, switchProject: requestProjectSwitch)
                .navigationSplitViewColumnWidth(min: 230, ideal: 280)
        } detail: {
            switch navigation.selection {
            case .file(let url):
                EditorView()
                    .task(id: url) { await editor.open(url) }
            case .folder(let url):
                FolderView(folder: url)
            case .batch:
                BatchConvertView()
            case .downloader, .none:
                DownloaderView { select(.file($0)) }
            }
        }
        .sheet(isPresented: $navigation.showProjectExport) {
            ProjectExportView(scope: navigation.exportScope)
        }
        .alert("Unsaved edits", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Save") {
                let action = pending
                Task {
                    switch await editor.save() {
                    case .saved: perform(action)
                    case .needsSaveAs: editor.showSaveAs = true
                    case .failed: break
                    }
                }
            }
            Button("Discard", role: .destructive) {
                editor.discardChanges()
                perform(pending)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(editor.fileName)\" has edits that are not saved yet.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            library.refresh()
        }
    }

    private var guardedSelection: Binding<SidebarItem?> {
        Binding(get: { navigation.selection }, set: { select($0) })
    }

    private func select(_ item: SidebarItem?) {
        guard item != navigation.selection else { return }
        if editor.isDirty, case .file = navigation.selection, item != nil {
            pending = .navigate(item)
        } else {
            navigation.selection = item
        }
    }

    private func requestProjectSwitch(_ name: String) {
        if editor.isDirty {
            pending = .switchProject(name)
        } else {
            perform(.switchProject(name))
        }
    }

    private func perform(_ action: Pending?) {
        switch action {
        case .navigate(let item):
            navigation.selection = item
        case .switchProject(let name):
            if case .file = navigation.selection { navigation.selection = .downloader }
            if case .folder = navigation.selection { navigation.selection = .downloader }
            editor.close()
            library.switchProject(name)
        case nil:
            break
        }
    }
}

private struct SidebarView: View {
    @Environment(Library.self) private var library
    @Environment(DownloadQueue.self) private var queue
    @Environment(EditorModel.self) private var editor
    @Environment(Navigation.self) private var navigation
    @Environment(ExportService.self) private var exportService
    @Binding var selection: SidebarItem?
    var switchProject: (String) -> Void

    @State private var importing = false
    @State private var prompt: NamePrompt?
    @State private var promptText = ""

    var body: some View {
        List(selection: $selection) {
            Section("Tools") {
                Label("YouTube to MP3", systemImage: "arrow.down.circle")
                    .badge(queue.pendingCount)
                    .tag(SidebarItem.downloader)
                Label("Batch Convert", systemImage: "arrow.triangle.2.circlepath")
                    .tag(SidebarItem.batch)
            }
            Section(library.currentProject) {
                OutlineGroup(library.tree, children: \.children) { node in
                    row(node)
                        .tag(node.isFolder ? SidebarItem.folder(node.url) : SidebarItem.file(node.url))
                        .contextMenu { menu(for: node) }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let imported = library.importFiles(urls)
            if let first = imported.first { selection = .file(first) }
            return !imported.isEmpty
        }
        .safeAreaInset(edge: .top, spacing: 0) { projectSwitcher }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, let first = library.move(urls, into: targetFolder(allowInbox: true)).first {
                selection = .file(first)
            }
        }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("Name", text: $promptText)
            Button("OK") { prompt?.action(promptText) }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func row(_ node: LibraryNode) -> some View {
        let isInbox = node.url.standardizedFileURL == library.inboxURL.standardizedFileURL
        if node.isFolder {
            Label(node.name, systemImage: isInbox ? "tray" : "folder")
                .dropDestination(for: URL.self) { urls, _ in
                    !library.move(urls, into: node.url).isEmpty
                }
        } else {
            FileRow(node: node, hasEdits: editor.url == node.url && editor.isDirty)
                .draggable(node.url)
        }
    }

    @ViewBuilder
    private func menu(for node: LibraryNode) -> some View {
        let isInbox = node.url.standardizedFileURL == library.inboxURL.standardizedFileURL
        if node.isFolder {
            Button("New Folder Inside...") { newFolder(in: node.url) }
            if !isInbox {
                Button("Export Folder...") { navigation.exportProject(node.url) }
            }
        }
        Button("Show in Finder") { library.reveal([node.url]) }
        if !isInbox {
            Button("Rename...") {
                ask("Rename", initial: node.isFolder ? node.name : node.url.deletingPathExtension().lastPathComponent) { name in
                    if let new = library.rename(node.url, to: name), selection == .folder(node.url) {
                        selection = .folder(new)
                    }
                }
            }
            Divider()
            Button("Move to Trash", role: .destructive) { trash(node.url) }
        }
    }

    private var projectSwitcher: some View {
        Menu {
            ForEach(library.projects, id: \.self) { name in
                Button {
                    switchProject(name)
                } label: {
                    if name == library.currentProject {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
            Divider()
            Button("New Project...") {
                ask("New Project", initial: "") { name in
                    if library.createProject(name) { selection = .downloader }
                }
            }
            Button("Rename Project...") {
                ask("Rename Project", initial: library.currentProject) { library.renameProject(to: $0) }
            }
            Button("Show Project in Finder") { NSWorkspace.shared.open(library.projectURL) }
        } label: {
            Label(library.currentProject, systemImage: "shippingbox")
                .font(.headline)
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help("Switch project")
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            exportStatus
            bottomButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var exportStatus: some View {
        if exportService.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Exporting \(exportService.progress.done)/\(exportService.progress.total)...")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let date = exportService.lastExportDate, let report = exportService.lastReport {
            Label(report.failures.isEmpty ? "Exported \(date.formatted(date: .omitted, time: .shortened))" : "\(report.failures.count) export errors",
                  systemImage: report.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(report.failures.isEmpty ? Color.secondary : Color.orange)
                .help(report.failures.map { "\($0.file): \($0.message)" }.joined(separator: "\n"))
        } else if library.config.exportOptions.autoExport {
            Label("Auto-export on", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var bottomButtons: some View {
        HStack(spacing: 12) {
            Button("New Folder", systemImage: "folder.badge.plus") { newFolder(in: targetFolder(allowInbox: false)) }
                .help("New folder")
            Button("Import Audio", systemImage: "square.and.arrow.down") { importing = true }
                .help("Import audio files (or drag them onto the sidebar or a folder)")
            Spacer()
            Button("Export Project", systemImage: "square.and.arrow.up.on.square") { navigation.exportProject() }
                .help("Export every sound in the project to the game folder (Shift Cmd E)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    /// Folder for new items: the selected folder, the selected file's folder, or the project root.
    private func targetFolder(allowInbox: Bool) -> URL {
        var folder: URL
        switch selection {
        case .folder(let url): folder = url
        case .file(let url): folder = url.deletingLastPathComponent()
        default: folder = allowInbox ? library.inboxURL : library.projectURL
        }
        if !allowInbox && library.isInInbox(folder) { folder = library.projectURL }
        return folder
    }

    private func newFolder(in parent: URL) {
        ask("New Folder", initial: "") { name in
            if let url = library.createFolder(named: name, in: parent) { selection = .folder(url) }
        }
    }

    private func ask(_ title: String, initial: String, action: @escaping (String) -> Void) {
        promptText = initial
        prompt = NamePrompt(title: title, initial: initial, action: action)
    }

    private func trash(_ url: URL) {
        if let open = editor.url, open == url || open.path.hasPrefix(url.path + "/") {
            navigation.selection = .downloader
            editor.close()
        }
        if selection == .folder(url) { selection = .downloader }
        library.trash(url)
    }
}

private struct FileRow: View {
    let node: LibraryNode
    let hasEdits: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform").foregroundStyle(.secondary)
            Text(node.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if hasEdits {
                Circle().fill(.orange).frame(width: 6, height: 6).help("Unsaved edits")
            }
            Text(node.url.pathExtension.uppercased())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .help("\(node.url.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file))")
    }
}
