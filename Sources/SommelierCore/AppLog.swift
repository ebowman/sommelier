import Foundation
import os

/// The app's one log sink (gdu.88).
///
/// `NSLog` text is redacted as `<private>` by unified logging for a notarized build launched from Finder, so nothing could be
/// attributed after the fact. Every line now goes to (1) `os.Logger` with `privacy: .public` (subsystem `ie.boboco.sommelier`, one
/// category per component), (2) a rotating file `~/Library/Logs/Sommelier/sommelier.log`, written off the calling thread, and
/// (3) stderr in the old NSLog shape, so `make app-run` (`> build/sommelier.log 2>&1`) and the soak scripts keep working.
public enum AppLog {
    public static let subsystem = "ie.boboco.sommelier"

    public enum Category: String, CaseIterable, Sendable {
        case engine, apps, poll, reveal, activator, arrange, panel, app, permissions
    }

    public static let logDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Sommelier", isDirectory: true)

    private static let loggers: [Category: Logger] = Dictionary(uniqueKeysWithValues: Category.allCases.map {
        ($0, Logger(subsystem: subsystem, category: $0.rawValue))
    })

    public static let sink = FileLogSink(directory: logDirectory, echoToStderr: true)

    /// Logs `text` under `category`. Safe from any thread.
    public static func log(_ category: Category, _ text: String) {
        loggers[category]?.log("\(text, privacy: .public)")
        sink.write(category: category, text: text)
    }

    /// A `(String) -> Void` for the engine components' `log:` parameters.
    public static func logger(_ category: Category, prefix: String) -> @Sendable (String) -> Void {
        { log(category, prefix + $0) }
    }

    /// Drains pending file writes (call on quit).
    public static func flush() { sink.flush() }
}

/// Line-oriented rotating file sink. One serial queue owns the file handle; `write` never blocks the caller.
/// Line format: `2026-11-05T14:03:22.123Z <category> <text>` (ISO-8601 UTC with milliseconds), embedded newlines become `\n` text.
public final class FileLogSink: @unchecked Sendable {
    public let directory: URL
    public let fileName: String
    public let maxBytes: Int
    public let keep: Int
    private let echoToStderr: Bool
    private let queue = DispatchQueue(label: "ie.boboco.sommelier.log")
    private var handle: FileHandle?
    private var size = 0
    private var failed = false          // unwritable: already reported once, now dropping silently
    private let fallback = Logger(subsystem: AppLog.subsystem, category: "app")

    public init(directory: URL, fileName: String = "sommelier.log", maxBytes: Int = 5 * 1024 * 1024, keep: Int = 3, echoToStderr: Bool = false) {
        self.directory = directory
        self.fileName = fileName
        self.maxBytes = maxBytes
        self.keep = keep
        self.echoToStderr = echoToStderr
    }

    public var fileURL: URL { directory.appendingPathComponent(fileName) }

    public static func format(date: Date, category: AppLog.Category, text: String) -> String {
        // +0.5 ms: the formatter truncates and a Double like ...00.123 may sit just below the millisecond.
        let stamp = date.addingTimeInterval(0.0005).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        return "\(stamp) \(category.rawValue) \(text.replacingOccurrences(of: "\n", with: "\\n"))\n"
    }

    public func write(category: AppLog.Category, text: String, date: Date = Date()) {
        let line = Self.format(date: date, category: category, text: text)
        let tid = pthread_mach_thread_np(pthread_self())
        queue.async { [self] in
            if echoToStderr { echo(text, tid: tid, date: date) }
            append(line)
        }
    }

    /// Blocks until every line written so far is on disk.
    public func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private func echo(_ text: String, tid: UInt32, date: Date) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let s = "\(f.string(from: date)) Sommelier[\(ProcessInfo.processInfo.processIdentifier):\(tid)] [Sommelier] \(text)\n"
        FileHandle.standardError.write(Data(s.utf8))
    }

    private func append(_ line: String) {
        let data = Data(line.utf8)
        do {
            if handle == nil { try open() }
            if size > 0, size + data.count > maxBytes {
                try? handle?.close()
                handle = nil
                rotate()
                try open()
            }
            try handle?.write(contentsOf: data)
            size += data.count
        } catch {
            handle = nil
            if !failed {
                failed = true
                fallback.error("log file \(self.fileURL.path, privacy: .public) is not writable (\(String(describing: error), privacy: .public)); file logging dropped")
            }
        }
    }

    private func open() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) { guard fm.createFile(atPath: fileURL.path, contents: nil) else { throw CocoaError(.fileWriteNoPermission) } }
        let h = try FileHandle(forWritingTo: fileURL)
        size = Int(try h.seekToEnd())
        handle = h
        failed = false
    }

    /// sommelier.log -> sommelier.log.1 -> ... -> sommelier.log.<keep> (the oldest is deleted).
    private func rotate() {
        let fm = FileManager.default
        func path(_ i: Int) -> String { i == 0 ? fileURL.path : fileURL.path + ".\(i)" }
        try? fm.removeItem(atPath: path(keep))
        for i in stride(from: keep - 1, through: 0, by: -1) where fm.fileExists(atPath: path(i)) {
            try? fm.moveItem(atPath: path(i), toPath: path(i + 1))
        }
        size = 0
    }
}
