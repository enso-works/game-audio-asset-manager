import AppKit
import SwiftUI

struct DownloaderView: View {
    @Environment(DownloadQueue.self) private var queue
    @Environment(Library.self) private var library
    var open: (URL) -> Void

    @State private var missingTools: [String] = []

    var body: some View {
        @Bindable var queue = queue
        let links = DownloadQueue.parseLinks(queue.draft)
        VStack(alignment: .leading, spacing: 12) {
            if !missingTools.isEmpty {
                Label("Missing tools. Install with: brew install \(missingTools.joined(separator: " "))", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            Text("Paste links, one per line").font(.headline)
            TextEditor(text: $queue.draft)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .overlay(alignment: .topLeading) {
                    if queue.draft.isEmpty {
                        Text(verbatim: "https://www.youtube.com/watch?v=...\nhttps://youtu.be/...")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(11)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 150)

            HStack {
                Text(links.isEmpty ? "No links" : "\(links.count) link\(links.count == 1 ? "" : "s")")
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
                    description: Text("MP3s go into the Inbox of \(library.currentProject) and show up in the sidebar.")
                )
            } else {
                List(queue.items) { item in
                    DownloadRow(item: item, open: open)
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .navigationTitle("YouTube to MP3")
        .onChange(of: queue.maxConcurrent) { queue.pump() }
        .onAppear {
            missingTools = [("yt-dlp", Tools.ytDlp), ("ffmpeg", Tools.ffmpeg)].filter { $0.1 == nil }.map(\.0)
        }
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
                Text(item.title ?? item.link).lineLimit(1)
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
