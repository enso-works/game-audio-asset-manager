import Foundation
import Observation

@MainActor
@Observable
final class DownloadItem: Identifiable {
    enum State: Equatable {
        case queued, downloading, converting, done, cancelled
        case failed(String)

        var isActive: Bool { self == .downloading || self == .converting }
        var isFinished: Bool {
            switch self {
            case .done, .cancelled, .failed: true
            default: false
            }
        }
    }

    let id = UUID()
    let link: String
    var title: String?
    var state: State = .queued
    var progress: Double = 0
    var fileURL: URL?
    @ObservationIgnored var runner: ProcessRunner?
    @ObservationIgnored var lastError: String?

    init(link: String) {
        self.link = link
    }
}

/// Downloads links as MP3 through yt-dlp, a few at a time.
@MainActor
@Observable
final class DownloadQueue {
    var items: [DownloadItem] = []
    var draft = ""
    var maxConcurrent = 3
    @ObservationIgnored weak var library: Library?

    var pendingCount: Int { items.filter { $0.state == .queued || $0.state.isActive }.count }

    static func parseLinks(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'(),")) }
            .filter { ($0.hasPrefix("https://") || $0.hasPrefix("http://")) && seen.insert($0).inserted }
    }

    func enqueue(_ links: [String]) {
        items.append(contentsOf: links.map(DownloadItem.init))
        pump()
    }

    func cancel(_ item: DownloadItem) {
        item.state = .cancelled
        item.runner?.terminate()
        pump()
    }

    func retry(_ item: DownloadItem) {
        item.state = .queued
        item.progress = 0
        item.lastError = nil
        pump()
    }

    func remove(_ item: DownloadItem) {
        if item.state.isActive { item.runner?.terminate() }
        items.removeAll { $0.id == item.id }
        pump()
    }

    func clearFinished() {
        items.removeAll { $0.state.isFinished }
    }

    func pump() {
        var running = items.filter { $0.state.isActive }.count
        for item in items where item.state == .queued && running < maxConcurrent {
            item.state = .downloading
            running += 1
            Task { await run(item) }
        }
    }

    private func run(_ item: DownloadItem) async {
        defer { pump() }
        guard let ytDlp = Tools.ytDlp else {
            item.state = .failed("yt-dlp not found. Install it with: brew install yt-dlp")
            return
        }
        guard let library else { return }

        var arguments = [
            "--extract-audio", "--audio-format", "mp3", "--audio-quality", "0",
            "--no-playlist", "--no-simulate", "--newline", "--progress", "--color", "never",
            "--progress-template", "download:PROGRESS:%(progress._percent_str)s",
            "--print", "before_dl:TITLE:%(title)s",
            "--print", "after_move:FILE:%(filepath)s",
            "--paths", library.url(for: .downloads).path,
            "--output", "%(title).150B [%(id)s].%(ext)s",
        ]
        if let ffmpeg = Tools.ffmpeg { arguments += ["--ffmpeg-location", ffmpeg.path] }
        arguments.append(item.link)

        let runner = ProcessRunner()
        item.runner = runner
        let status: Int32
        do {
            status = try await runner.run(ytDlp, arguments) { line in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { Self.handle(line, for: item) }
                }
            }
        } catch {
            item.state = .failed(error.localizedDescription)
            return
        }

        // Let queued line callbacks land before reading the final state.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        item.runner = nil
        guard item.state != .cancelled else { return }

        if status == 0 {
            item.state = .done
            item.progress = 1
            library.refresh()
        } else {
            let hint = "If YouTube downloads keep failing, run: brew upgrade yt-dlp"
            item.state = .failed((item.lastError ?? "yt-dlp exited with code \(status)") + "\n" + hint)
        }
    }

    private static func handle(_ line: String, for item: DownloadItem) {
        guard item.state != .cancelled else { return }
        if line.hasPrefix("TITLE:") {
            item.title = String(line.dropFirst(6))
        } else if line.hasPrefix("PROGRESS:") {
            let text = line.dropFirst(9).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
            if let value = Double(text) {
                item.progress = value / 100
                if value >= 100, item.state == .downloading { item.state = .converting }
            }
        } else if line.hasPrefix("FILE:") {
            item.fileURL = URL(fileURLWithPath: String(line.dropFirst(5)))
        } else if line.hasPrefix("ERROR:") {
            item.lastError = line.replacingOccurrences(of: "ERROR: ", with: "")
        }
    }
}
