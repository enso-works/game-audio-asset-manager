import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case downloader
    case file(URL)
}

@MainActor
@Observable
final class Navigation {
    var selection: SidebarItem? = .downloader
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(EditorModel.self) private var editor
    @Environment(Navigation.self) private var navigation
    @State private var pending: SidebarItem?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: guardedSelection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 270)
        } detail: {
            switch navigation.selection {
            case .file(let url):
                EditorView()
                    .task(id: url) { await editor.open(url) }
            case .downloader, .none:
                DownloaderView { select(.file($0)) }
            }
        }
        .alert(
            "Unsaved edits",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { item in
            Button("Save Copy") {
                Task {
                    if await editor.saveToLibrary(library) != nil { navigation.selection = item }
                }
            }
            Button("Discard", role: .destructive) {
                editor.discardChanges()
                navigation.selection = item
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Edits to \"\(editor.fileName)\" only exist in memory. Save a WAV copy to the library first?")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            library.refresh()
        }
    }

    /// Asks before leaving a file with unsaved edits.
    private var guardedSelection: Binding<SidebarItem?> {
        Binding(get: { navigation.selection }, set: { select($0) })
    }

    private func select(_ item: SidebarItem?) {
        guard item != navigation.selection else { return }
        if editor.isDirty, case .file = navigation.selection, item != nil {
            pending = item
        } else {
            navigation.selection = item
        }
    }
}

private struct SidebarView: View {
    @Environment(Library.self) private var library
    @Environment(DownloadQueue.self) private var queue
    @Environment(EditorModel.self) private var editor
    @Environment(Navigation.self) private var navigation
    @Binding var selection: SidebarItem?
    @State private var importing = false

    var body: some View {
        List(selection: $selection) {
            Section("Tools") {
                Label("YouTube to MP3", systemImage: "arrow.down.circle")
                    .badge(queue.pendingCount)
                    .tag(SidebarItem.downloader)
            }
            ForEach(Library.Folder.allCases) { folder in
                let files = library.files.filter { $0.folder == folder }
                if !files.isEmpty {
                    Section(folder.title) {
                        ForEach(files) { file in
                            FileRow(file: file, isOpen: editor.url == file.url && editor.isDirty)
                                .tag(SidebarItem.file(file.url))
                                .contextMenu {
                                    Button("Show in Finder") { library.reveal([file.url]) }
                                    Divider()
                                    Button("Move to Trash", role: .destructive) { trash(file) }
                                }
                        }
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let imported = library.importFiles(urls)
            if let first = imported.first { selection = .file(first) }
            return !imported.isEmpty
        }
        .toolbar {
            ToolbarItem {
                Button("Import Audio", systemImage: "plus") { importing = true }
                    .help("Import audio files into the library (or drag them onto the sidebar)")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, let first = library.importFiles(urls).first {
                selection = .file(first)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if library.files.isEmpty {
                Text("Drop audio files here or download from YouTube.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }

    private func trash(_ file: LibraryFile) {
        if editor.url == file.url {
            navigation.selection = .downloader
            editor.close()
        }
        library.trash(file)
    }
}

private struct FileRow: View {
    let file: LibraryFile
    let isOpen: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Text("\(file.url.pathExtension.uppercased()) · \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if isOpen {
                Spacer()
                Circle().fill(.orange).frame(width: 6, height: 6).help("Unsaved edits")
            }
        }
        .help(file.url.lastPathComponent)
    }
}
