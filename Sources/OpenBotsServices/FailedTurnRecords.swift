import Foundation
import OpenBotsRuntime

/// What the reply service tells the keeper when a turn settles.
public protocol ClaudeTextFailedTurnKeeping: Sendable {
    /// `keep` is true for a failed turn that used no secret; anything else
    /// lets go of what was held for it.
    func finished(runID: UUID, profileURL: URL, sessionID: UUID, keep: Bool)
}

/// Retain the bounded stream frames of a refused reply and its CLI transcript before session
/// deletion. Keep only `keptFailures` failures under `HighChurn.noindex/Logs/failed-turns`,
/// each in a separate folder readable only by the user.
public final class FailedTurnRecords: ClaudeTextFailedTurnKeeping, @unchecked Sendable {
    public static let keptFailures = 5
    /// The largest transcript kept whole; a larger one is left out.
    public static let maximumTranscriptBytes = 8 * 1_048_576

    private let root: URL
    private let lock = NSLock()
    private var held: [(runID: UUID, frames: [Data])] = []

    public init(root: URL) { self.root = root }

    /// The app's own folder, when the app's Logs folder is there.
    public static func inApplicationSupport() -> FailedTurnRecords? {
        guard let bundleID = Bundle.main.bundleIdentifier, bundleID.hasPrefix("com.lorenzocolombani.openbotsnext"),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let logs = support.appending(path: bundleID).appending(path: "HighChurn.noindex").appending(path: "Logs")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: logs.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return FailedTurnRecords(root: logs.appending(path: "failed-turns", directoryHint: .isDirectory))
    }

    /// Starts taking the frames every refused turn hands over. Called once
    /// at launch by the app, with the same records given to the reply service.
    public func holdRefusedFrames() {
        ClaudeTextOnlyRefusalLog.observeFrames { [weak self] runID, frames in self?.hold(runID: runID, frames: frames) }
    }

    /// Frames a refused turn handed over; held until the service says whether
    /// the turn is kept. Only the latest few runs are held.
    public func hold(runID: UUID, frames: [Data]) {
        lock.withLock {
            held.removeAll { $0.runID == runID }
            held.append((runID, frames))
            if held.count > Self.keptFailures { held.removeFirst(held.count - Self.keptFailures) }
        }
    }

    var heldRunCount: Int { lock.withLock { held.count } }

    public func finished(runID: UUID, profileURL: URL, sessionID: UUID, keep: Bool) {
        finished(runID: runID, profileURL: profileURL, sessionID: sessionID, keep: keep, now: Date())
    }

    func finished(runID: UUID, profileURL: URL, sessionID: UUID, keep: Bool, now: Date) {
        let frames = lock.withLock { () -> [Data]? in
            guard let index = held.firstIndex(where: { $0.runID == runID }) else { return nil }
            return held.remove(at: index).frames
        }
        guard keep else { return }
        let transcript = ClaudeSessionTranscriptLocator.read(profileURL: profileURL, sessionID: sessionID,
                                                             maximumBytes: Self.maximumTranscriptBytes)
        guard frames != nil || transcript != nil else { return }
        lock.withLock {
            do {
                let folder = try makeFolder(runID: runID, now: now)
                if let frames {
                    var body = Data()
                    for frame in frames { body.append(frame); if frame.last != 0x0a { body.append(0x0a) } }
                    try write(body, to: folder.appendingPathComponent("frames.jsonl"))
                }
                if let transcript { try write(transcript, to: folder.appendingPathComponent("transcript.jsonl")) }
                try prune()
                AgenticDiagnosticsLog.note("text-turn", "kept failed turn \(folder.lastPathComponent)")
            } catch {
                AgenticDiagnosticsLog.error("text-turn", "failed turn not kept: \(String(describing: error).prefix(160))")
            }
        }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private func makeFolder(runID: UUID, now: Date) throws -> URL {
        try Self.makePrivateFolder(root)
        let folder = root.appendingPathComponent("\(Self.stamp.string(from: now))-\(runID.uuidString.lowercased())",
                                                 isDirectory: true)
        try Self.makePrivateFolder(folder)
        return folder
    }

    /// A real folder, 0700; a link or a file in its place is refused.
    private static func makePrivateFolder(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid() else {
            throw POSIXError(.ENOTDIR)
        }
        _ = chmod(url.path, 0o700)
    }

    private func write(_ data: Data, to url: URL) throws {
        let file = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(file) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var done = 0
            while done < buffer.count {
                let wrote = Darwin.write(file, base + done, buffer.count - done)
                guard wrote > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                done += wrote
            }
        }
    }

    /// The oldest folders go once there are more than `keptFailures`; names
    /// start with their UTC time, so their order is their age.
    private func prune() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }.sorted()
        for name in names.dropLast(Self.keptFailures) {
            try FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }
}
