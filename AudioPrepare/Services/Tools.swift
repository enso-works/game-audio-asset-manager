import Foundation

/// Locates the command line tools the app depends on (installed via Homebrew).
enum Tools {
    static var searchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin",
            "\(home)/.local/bin", "\(home)/.deno/bin", "\(home)/.bun/bin",
        ]
    }

    static func find(_ name: String) -> URL? {
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in searchPaths + envPaths {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    static var ffmpeg: URL? { find("ffmpeg") }
    static var ytDlp: URL? { find("yt-dlp") }

    /// Environment for child processes; GUI apps start with a minimal PATH, so yt-dlp
    /// would otherwise miss ffmpeg and the JS runtime it needs for YouTube.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        return env
    }
}

enum ToolError: LocalizedError {
    case missing(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name): "\(name) not found. Install it with: brew install \(name)"
        case .failed(let message): message
        }
    }
}

/// Splits streamed process output into lines (handles both \n and \r).
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { onLine(line) }
        }
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8), !line.isEmpty { onLine(line) }
        buffer.removeAll()
    }
}

/// Runs a child process, streaming stdout and stderr lines to a callback.
final class ProcessRunner: @unchecked Sendable {
    private let process = Process()

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func run(_ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = Tools.environment
        process.standardInput = FileHandle.nullDevice

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let outLines = LineSplitter(onLine: onLine)
        let errLines = LineSplitter(onLine: onLine)

        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { outLines.append(data) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { errLines.append(data) }
        }

        let process = self.process
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    outLines.append(out.fileHandleForReading.readDataToEndOfFile())
                    errLines.append(err.fileHandleForReading.readDataToEndOfFile())
                    outLines.flush()
                    errLines.flush()
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            self.terminate()
        }
    }
}

/// Thread-safe collector for the tail of a process log.
final class LogTail: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > 20 { lines.removeFirst() }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.suffix(3).joined(separator: "\n")
    }
}
