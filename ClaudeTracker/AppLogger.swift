import Foundation
import os

/// Lightweight logger: writes to os.log (visible in Console.app) and to a
/// rolling file in ~/Library/Logs/ClaudeTracker/ (or the sandboxed container
/// equivalent). Max file size 512 KB; one rotation kept as claudetracker.1.log.
final class AppLogger: Sendable {
    static let shared = AppLogger()

    private let osLog = Logger(subsystem: "com.claudetracker.app", category: "app")
    private let queue = DispatchQueue(label: "com.claudetracker.app.logger", qos: .utility)
    private let maxFileBytes = 512 * 1024

    let logFileURL: URL?

    private init() {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        if let dir = lib?.appendingPathComponent("Logs/ClaudeTracker") {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            logFileURL = dir.appendingPathComponent("claudetracker.log")
        } else {
            logFileURL = nil
        }
    }

    func info(_ msg: String)  { write(msg, level: "INFO");  osLog.info("\(msg, privacy: .public)") }
    func error(_ msg: String) { write(msg, level: "ERROR"); osLog.error("\(msg, privacy: .public)") }

    /// Returns the last `maxBytes` of the log file as a string. Reads on the logger
    /// queue so it can't observe a mid-append or mid-rotation file.
    func tail(maxBytes: Int = 32_768) -> String {
        guard let url = logFileURL else { return "(no log file)" }
        return queue.sync {
            guard let data = try? Data(contentsOf: url) else { return "(no log file)" }
            // Lossy decode ON PURPOSE: the byte cut can land mid-multibyte-character
            // (the log has non-ASCII, e.g. "…"), and the failable String(data:encoding:)
            // the lint rule prefers would return nil for the WHOLE tail instead of
            // mangling one character.
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: data.suffix(maxBytes), as: UTF8.self)
        }
    }

    private func write(_ msg: String, level: String) {
        let line = "[\(timestamp())] [\(level)] \(msg)\n"
        queue.async { [weak self] in self?.append(line) }
    }

    private func append(_ line: String) {
        guard let url = logFileURL, let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > maxFileBytes {
            let rotated = url.deletingLastPathComponent().appendingPathComponent("claudetracker.1.log")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }
        if fm.fileExists(atPath: url.path) {
            guard let fh = try? FileHandle(forWritingTo: url) else { return }
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// `ISO8601DateFormatter` is documented thread-safe (hence `nonisolated(unsafe)` —
    /// the type just lacks a Sendable annotation); one shared instance avoids allocating
    /// a formatter on the caller's thread for every log line (polls log every 1–10 s).
    private nonisolated(unsafe) static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func timestamp() -> String {
        Self.timestampFormatter.string(from: Date())
    }
}
