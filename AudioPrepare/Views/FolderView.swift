import SwiftUI

/// Detail pane for a project folder: its sounds and subfolders.
struct FolderView: View {
    @Environment(Library.self) private var library
    @Environment(Navigation.self) private var navigation
    let folder: URL

    var body: some View {
        let node = findNode(library.tree)
        let children = node?.children ?? []
        let isInbox = library.isInInbox(folder)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(library.displayName(forFolder: folder), systemImage: isInbox ? "tray" : "folder")
                    .font(.title2.bold())
                Spacer()
                Button("Show in Finder") { library.reveal([folder]) }
            }
            if isInbox {
                Text("Raw downloads and imports land here. The Inbox is never exported: open a sound, edit it, and use Save As (Shift Cmd S) to put it into a project folder.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Sounds in this folder export to the same folder path inside the game's export folder.")
                    .foregroundStyle(.secondary)
            }
            if children.isEmpty {
                ContentUnavailableView("Empty folder", systemImage: "folder", description: Text("Drag sounds here from the sidebar or Finder."))
            } else {
                List(children) { child in
                    Button {
                        navigation.selection = child.isFolder ? .folder(child.url) : .file(child.url)
                    } label: {
                        HStack {
                            Image(systemName: child.isFolder ? "folder" : "waveform")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(child.isFolder ? child.name : child.url.lastPathComponent)
                            Spacer()
                            if !child.isFolder {
                                if library.meta(for: child.url).loop != nil {
                                    Image(systemName: "repeat").foregroundStyle(.green).help("Has loop points")
                                }
                                Text(ByteCountFormatter.string(fromByteCount: child.size, countStyle: .file))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .navigationTitle(folder.lastPathComponent)
    }

    private func findNode(_ nodes: [LibraryNode]) -> LibraryNode? {
        if folder.standardizedFileURL == library.projectURL.standardizedFileURL {
            return LibraryNode(url: folder, kind: .folder, children: nodes)
        }
        for node in nodes where node.isFolder {
            if node.url.standardizedFileURL == folder.standardizedFileURL { return node }
            if let found = findNode(node.children ?? []) { return found }
        }
        return nil
    }
}
