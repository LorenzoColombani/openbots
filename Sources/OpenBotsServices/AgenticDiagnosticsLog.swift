import Foundation
import os

/// Bounded, secret-free diagnostics for the agentic job path. Lines go to the
/// unified log and, because `log show` is not always readable, to
/// one small app-owned file under the high-churn Logs folder. Callers pass
/// error enum descriptions and counts only, never provider text or paths of
/// user documents. The file is capped; when full, nothing more is written.
public enum AgenticDiagnosticsLog {
    private static let logger = Logger(subsystem: "com.lorenzocolombani.openbotsnext.preview", category: "agentic")
    private static let queue = DispatchQueue(label: "openbots.agentic.diagnostics")
    private static let maximumBytes = 1_048_576

    public static func note(_ category: String, _ message: String) {
        logger.notice("\(category, privacy: .public): \(message, privacy: .public)")
        append("\(category) \(message)")
    }

    public static func error(_ category: String, _ message: String) {
        logger.error("\(category, privacy: .public): \(message, privacy: .public)")
        append("\(category) ERROR \(message)")
    }

    private static func append(_ line: String) {
        guard let file = fileURL else { return }
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line.prefix(600))\n"
        queue.async {
            let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
                  info.st_size < maximumBytes else { return }
            let bytes = Array(stamped.utf8)
            _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        }
    }

    private static let fileURL: URL? = {
        guard let bundleID = Bundle.main.bundleIdentifier, bundleID.hasPrefix("com.lorenzocolombani.openbotsnext"),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let logs = support.appending(path: bundleID).appending(path: "HighChurn.noindex").appending(path: "Logs")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: logs.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return logs.appending(path: "agentic-diagnostics.log")
    }()
}
