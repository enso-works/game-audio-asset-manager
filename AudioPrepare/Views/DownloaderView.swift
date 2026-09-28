import AppKit
import SwiftUI

struct DownloaderView: View {
    @Environment(DownloadQueue.self) private var queue
    @Environment(Library.self) private var library
    var open: (URL) -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case links = "Paste Links"
        case search = "Search YouTube"
        var id: Self { self }
    }

    @State private var missingTools: [String] = []
    @AppStorage("downloaderMode") private var mode: Mode = .links

    var body: some View {
        @Bindable var queue = queue
        VStack(alignment: .leading, spacing: 12) {
            if !missingTools.isEmpty {
                Label("Missing tools. Install with: brew install \(missingTools.joined(separator: " "))", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            Picker("Input", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            switch mode {
            case .links: linksInput
            case .search: SearchPanel { mode = .links }
            }

            Divider()

            HStack {
                Text("Queue").font(.headline)
                if queue.pendingCount > 0 {
                    Text("\(queue.pendingCount) in progress").foregroundStyle(.secondary)
                }
                Spacer()
                Stepper("Parallel downloads: \(queue.maxConcurrent)", value: $queue.maxConcurrent, in: 1...6)
                    .fixedSize()
                Button("Clear Finished") { queue.clearFinished() }
                    .disabled(!queue.items.contains { $0.state.isFinished })
            }

            if queue.items.isEmpty {
                ContentUnavailableView(
                    "Nothing downloading",
                    systemImage: "arrow.down.circle",
                    description: Text("MP3s go into the Inbox of \(library.currentProject) and show up in the sidebar. The source link is saved for credits.")
                )
            } else {
                List(queue.items) { item in
                    DownloadRow(item: item, open: open)
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationTitle("YouTube to MP3")
        .onChange(of: queue.maxConcurrent) { queue.pump() }
        .onAppear {
            missingTools = [("yt-dlp", Tools.ytDlp), ("ffmpeg", Tools.ffmpeg)].filter { $0.1 == nil }.map(\.0)
        }
    }

    @ViewBuilder private var linksInput: some View {
        @Bindable var queue = queue
        let links = DownloadQueue.parseLinks(queue.draft)
        let ranged = links.filter { $0.range != nil }.count
        TextEditor(text: $queue.draft)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            .overlay(alignment: .topLeading) {
                if queue.draft.isEmpty {
                    Text(verbatim: "https://www.youtube.com/watch?v=...\nhttps://youtu.be/... 1:30-2:05   (only that part)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(11)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 150)

        HStack {
            Text(links.isEmpty ? "One link per line. Add a time range after a link to download only that part." : "\(links.count) link\(links.count == 1 ? "" : "s")\(ranged > 0 ? ", \(ranged) with time range" : "")")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Paste") {
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                queue.draft += (queue.draft.isEmpty || queue.draft.hasSuffix("\n") ? "" : "\n") + text
            }
            Button("Clear") { queue.draft = "" }
                .disabled(queue.draft.isEmpty)
            Button("Download \(links.count) as MP3") {
                queue.enqueue(links)
                queue.draft = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(links.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}

private struct SearchPanel: View {
    @Environment(DownloadQueue.self) private var queue
    var showLinks: () -> Void

    var body: some View {
        @Bindable var queue = queue
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search", text: $queue.searchQuery, prompt: Text("e.g. 8 bit jump sound effect, rain ambience loop"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await queue.search() } }
                Button("Search") { Task { await queue.search() } }
                    .disabled(queue.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty || queue.isSearching)
                if queue.isSearching { ProgressView().controlSize(.small) }
            }
            if let error = queue.searchError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if !queue.searchResults.isEmpty {
                HStack {
                    Text("\(queue.searchResults.count) results").foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Results") { queue.clearSearch() }
                        .controlSize(.small)
                }
                List(queue.searchResults) { result in
                    SearchResultRow(result: result, showLinks: showLinks)
                }
                .listStyle(.inset)
                .frame(minHeight: 180, maxHeight: 260)
            }
        }
    }
}

private struct SearchResultRow: View {
    @Environment(DownloadQueue.self) private var queue
    let result: SearchResult
    var showLinks: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: result.thumbnail) { image in
                image.resizable().aspectRatio(16 / 9, contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 80, height: 45)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).lineLimit(1)
                Text([result.channel, result.durationText].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Button("Open in Browser", systemImage: "safari") {
                    if let url = URL(string: result.url) { NSWorkspace.shared.open(url) }
                }
                Button("Add to Links (to set a time range)", systemImage: "text.badge.plus") {
                    queue.addToDraft(result.url)
                    showLinks()
                }
                Button("Download", systemImage: "arrow.down.circle.fill") {
                    queue.enqueue([LinkRequest(url: result.url)])
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .imageScale(.large)
        }
        .padding(.vertical, 2)
    }
}

private struct DownloadRow: View {
    @Environment(DownloadQueue.self) private var queue
    @Environment(Library.self) private var library
    let item: DownloadItem
    var open: (URL) -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title ?? item.link).lineLimit(1)
                    if let range = item.range {
                        Text(range)
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 5)
                            .background(.blue.opacity(0.2), in: Capsule())
                    }
                }
                status
            }
            Spacer()
            actions
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .downloading, .converting: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .queued:
            Text("Waiting").font(.caption).foregroundStyle(.secondary)
        case .downloading:
            HStack {
                ProgressView(value: item.progress).frame(maxWidth: 240)
                Text("\(Int(item.progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .converting:
            Text("Converting to MP3...").font(.caption).foregroundStyle(.secondary)
        case .done:
            Text(item.fileURL?.lastPathComponent ?? "Done").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            switch item.state {
            case .queued, .downloading, .converting:
                Button("Cancel", systemImage: "xmark") { queue.cancel(item) }
            case .done:
                if let url = item.fileURL {
                    Button("Edit", systemImage: "waveform") { open(url) }
                    Button("Show in Finder", systemImage: "folder") { library.reveal([url]) }
                }
            case .failed, .cancelled:
                Button("Retry", systemImage: "arrow.clockwise") { queue.retry(item) }
                Button("Remove", systemImage: "trash") { queue.remove(item) }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}
