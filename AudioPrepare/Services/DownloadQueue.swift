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
    /// Optional time range like "1:30-2:00"; only that part is downloaded.
    let range: String?
    var title: String?
    var channel: String?
    var pageURL: String?
    var state: State = .queued
    var progress: Double = 0
    var fileURL: URL?
    @ObservationIgnored var runner: ProcessRunner?
    @ObservationIgnored var lastError: String?

    init(link: String, range: String? = nil) {
        self.link = link
        self.range = range
    }
}

/// A link to download, optionally limited to a time range.
struct LinkRequest: Equatable {
    let url: String
    var range: String?
}

struct SearchResult: Identifiable, Equatable {
    let id: String
    let title: String
    let channel: String
    let duration: Double?
    let url: String

    var thumbnail: URL? { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") }
    var durationText: String { duration.map { formatTime($0, decimals: 0) } ?? "" }
}

/// Downloads links as MP3 through yt-dlp, a few at a time.
@MainActor
@Observable
final class DownloadQueue {
    var items: [DownloadItem] = []
    var draft = ""
    var maxConcurrent = 3
    var searchQuery = ""
    private(set) var searchResults: [SearchResult] = []
    private(set) var isSearching = false
    private(set) var searchError: String?
    @ObservationIgnored weak var library: Library?

    var pendingCount: Int { items.filter { $0.state == .queued || $0.state.isActive }.count }

    /// Parses links, one per line. A time range after a link ("URL 1:30-2:00") limits the download.
    static func parseLinks(_ text: String) -> [LinkRequest] {
        var seen = Set<String>()
        var requests: [LinkRequest] = []
        for line in text.components(separatedBy: .newlines) {
            let tokens = line
                .replacingOccurrences(of: "–", with: "-")
                .components(separatedBy: .whitespaces)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'(),")) }
                .filter { !$0.isEmpty }
            for (index, token) in tokens.enumerated() where token.hasPrefix("https://") || token.hasPrefix("http://") {
                let next = index + 1 < tokens.count ? tokens[index + 1] : nil
                let range = next.flatMap { isTimeRange($0) ? $0 : nil }
                let request = LinkRequest(url: token, range: range)
                if seen.insert(token + (range ?? "")).inserted { requests.append(request) }
            }
        }
        return requests
    }

    static func isTimeRange(_ text: String) -> Bool {
        text.range(of: #"^\d{1,2}(:\d{1,2}){0,2}(\.\d+)?-\d{1,2}(:\d{1,2}){0,2}(\.\d+)?$"#, options: .regularExpression) != nil
    }

    func enqueue(_ requests: [LinkRequest]) {
        items.append(contentsOf: requests.map { DownloadItem(link: $0.url, range: $0.range) })
        pump()
    }

    /// Searches YouTube through yt-dlp (no API key needed).
    func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let ytDlp = Tools.ytDlp else { return }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        let lines = LogTail(limit: 100)
        let status = try? await ProcessRunner().run(
            ytDlp, ["--flat-playlist", "--dump-json", "--no-warnings", "ytsearch20:\(query)"]
        ) { lines.append($0) }
        guard status == 0 else {
            searchError = "Search failed. Check your connection or run: brew upgrade yt-dlp"
            return
        }
        searchResults = lines.all.compactMap { line in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String
            else { return nil }
            return SearchResult(
                id: id,
                title: json["title"] as? String ?? id,
                channel: (json["channel"] as? String) ?? (json["uploader"] as? String) ?? "",
                duration: json["duration"] as? Double,
                url: (json["url"] as? String) ?? "https://www.youtube.com/watch?v=\(id)"
            )
        }
    }

    func clearSearch() {
        searchResults = []
        searchError = nil
    }

    /// Adds a link line to the paste box so a time range can be typed after it.
    func addToDraft(_ url: String) {
        if !draft.isEmpty && !draft.hasSuffix("\n") { draft += "\n" }
        draft += url + "\n"
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
            "--print", "after_move:SRC:%(webpage_url)s\t%(channel,uploader|)s",
            "--paths", library.inboxURL.path,
        ]
        if let range = item.range {
            let label = range.replacingOccurrences(of: ":", with: ".")
            arguments += [
                "--download-sections", "*\(range)", "--force-keyframes-at-cuts",
                "--output", "%(title).150B [%(id)s] \(label).%(ext)s",
            ]
        } else {
            arguments += ["--output", "%(title).150B [%(id)s].%(ext)s"]
        }
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
            if let file = item.fileURL {
                library.updateMeta(for: file) { meta in
                    meta.sourceURL = item.pageURL ?? item.link
                    meta.sourceTitle = item.title
                    meta.sourceChannel = item.channel
                    meta.sourceRange = item.range
                }
            }
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
        } else if line.hasPrefix("SRC:") {
            let parts = line.dropFirst(4).split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            item.pageURL = parts.first.flatMap { $0.isEmpty || $0 == "NA" ? nil : $0 }
            item.channel = parts.count > 1 && !parts[1].isEmpty && parts[1] != "NA" ? parts[1] : nil
        } else if line.hasPrefix("FILE:") {
            item.fileURL = URL(fileURLWithPath: String(line.dropFirst(5)))
        } else if line.hasPrefix("ERROR:") {
            item.lastError = line.replacingOccurrences(of: "ERROR: ", with: "")
        }
    }
}
