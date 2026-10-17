import Darwin
import Foundation

public enum SourceAppUpdateProgress: String, Codable, Sendable { case downloading, verifying, building, validating }

public struct PreparedSourceAppUpdate: Equatable, Sendable {
    public let appURL: URL
    public let sourceCommit: String
    public let build: String
    public let version: String
    public let fingerprint: String
    public let id: UUID
    public init(appURL: URL, sourceCommit: String, build: String, version: String, fingerprint: String, id: UUID = UUID()) {
        self.appURL = appURL; self.sourceCommit = sourceCommit; self.build = build
        self.version = version; self.fingerprint = fingerprint; self.id = id
    }
}

public struct SourceAppUpdateInstallation: Equatable, Sendable {
    public let id: UUID
    public let receiptURL: URL
    public init(id: UUID, receiptURL: URL) { self.id = id; self.receiptURL = receiptURL }
}

public struct SourceAppUpdateInstallationReceipt: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case installed, rolledBack, failed, aborted }
    public let status: Status
    public let message: String
    public let build: String
    public let sourceCommit: String
    public init(status: Status, message: String, build: String = "", sourceCommit: String = "") {
        self.status = status; self.message = message; self.build = build; self.sourceCommit = sourceCommit
    }
}

public protocol SourceAppUpdateServing: Sendable {
    func check() async throws -> VerifiedSourceAppUpdate?
    func prepare(_ release: VerifiedSourceAppUpdate, progress: @escaping @Sendable (SourceAppUpdateProgress) -> Void) async throws -> PreparedSourceAppUpdate
    func cancel() async throws
    func discard(_ prepared: PreparedSourceAppUpdate) async throws
    func beginInstallation(_ prepared: PreparedSourceAppUpdate, googleConfiguration: GoogleWorkspaceUpdateConfiguration) async throws -> SourceAppUpdateInstallation
    func abortInstallation(_ installation: SourceAppUpdateInstallation) async throws
    func receipt(_ installation: SourceAppUpdateInstallation) async throws -> SourceAppUpdateInstallationReceipt?
    func latestInstallationReceipt() async throws -> SourceAppUpdateInstallationReceipt?
}

/// Each operation owns one private directory and one bundled worker. No source
/// process is started until the complete signed inventory has been checked.
public actor SourceAppUpdateService: SourceAppUpdateServing {
    private let configuration: SourceAppUpdateConfiguration
    private let installedApplicationURL: URL
    private let currentBuild: String
    private let googleConfiguration: GoogleWorkspaceUpdateConfiguration
    private let stagingRoot: URL
    private var download: Task<Data, any Error>?
    private var worker: SourceAppUpdateWorker?
    private var prepared: PreparedSourceAppUpdate?
    private var preparedStage: URL?
    private var installation: SourceAppUpdateInstallation?
    private var operationActive = false
    private var cancelling = false
    private var generation: UInt64 = 0
    private var sweptStages = false

    public init(configuration: SourceAppUpdateConfiguration, installedApplicationURL: URL,
                currentBuild: String, googleConfiguration: GoogleWorkspaceUpdateConfiguration,
                stagingRoot: URL? = nil) {
        self.configuration = configuration; self.installedApplicationURL = installedApplicationURL
        self.currentBuild = currentBuild; self.googleConfiguration = googleConfiguration
        self.stagingRoot = stagingRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.lorenzocolombani.openbotsnext.preview/HighChurn.noindex/SourceUpdates")
    }

    public func check() async throws -> VerifiedSourceAppUpdate? {
        guard !operationActive, !cancelling, worker == nil else { throw SourceAppUpdateError.busy }
        try SourceAppUpdateManifest.validate(configuration)
        // The first check after launch, which follows an install's relaunch, is
        // where the previous run's stages are emptied. Not in init: the app
        // builds this service on the main actor and a sweep can take seconds.
        if !sweptStages {
            sweptStages = true
            sweepSourceUpdateStages(in: stagingRoot, keeping: preparedStage)
        }
        operationActive = true
        let operationGeneration = generation
        defer { operationActive = false; download = nil }
        let url = configuration.feedURL
        let task = Task { try await AnonymousApplicationUpdateDownload.bytes(from: url, maximumBytes: SourceAppUpdateManifest.maximumEnvelopeBytes) }
        download = task
        let bytes = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard operationGeneration == generation else { throw SourceAppUpdateError.cancelled }
        try Task.checkCancellation()
        let release = try SourceAppUpdateManifest.verify(bytes, configuration: configuration)
        return try SourceAppUpdateManifest.isNewer(release.build, than: currentBuild) ? release : nil
    }

    public func prepare(_ release: VerifiedSourceAppUpdate,
                        progress: @escaping @Sendable (SourceAppUpdateProgress) -> Void) async throws -> PreparedSourceAppUpdate {
        guard !operationActive, !cancelling, worker == nil, installation == nil else { throw SourceAppUpdateError.busy }
        let verified = try SourceAppUpdateManifest.verify(release.signedEnvelope, configuration: configuration)
        guard verified == release, try SourceAppUpdateManifest.isNewer(verified.build, than: currentBuild) else {
            throw SourceAppUpdateError.invalidPreparation
        }
        if let old = prepared { try discardStorage(old) }
        sweptStages = true
        sweepSourceUpdateStages(in: stagingRoot, keeping: preparedStage)
        try privateDirectory(stagingRoot)
        let id = UUID()
        let stage = stagingRoot.appending(path: id.uuidString)
        try privateDirectory(stage)
        operationActive = true
        let operationGeneration = generation
        preparedStage = stage
        defer { operationActive = false }
        do {
            let job: [String: Any] = [
                "schema": 1, "repository": configuration.repository,
                "archiveURL": try SourceAppUpdateManifest.archiveURL(for: verified, configuration: configuration).absoluteString,
                "sourceCommit": verified.sourceCommit, "build": verified.build, "version": verified.version,
                "files": verified.files.map { ["path": $0.path, "sha256": $0.sha256, "mode": $0.mode] },
                "installedApplication": installedApplicationURL.path, "currentBuild": currentBuild,
                "googleClientID": googleConfiguration.clientID ?? "", "durableGoogleClientID": googleConfiguration.durableClientID ?? "",
                "parentPID": Int(getpid())
            ]
            try writeJSON(job, to: stage.appending(path: "job.json"))
            let runner = try SourceAppUpdateWorker(stage: stage, operation: "prepare")
            worker = runner
            try await withTaskCancellationHandler {
                try await runner.wait(progress: progress)
            } onCancel: { runner.requestCancellation() }
            guard operationGeneration == generation else { throw SourceAppUpdateError.cancelled }
            worker = nil
            let result = try readObject(stage.appending(path: "result.json"))
            guard let path = result["appURL"] as? String,
                  let fingerprint = result["fingerprint"] as? String, SourceAppUpdateManifest.hex(fingerprint, count: 64),
                  path == stage.appending(path: "source/.build.noindex/source-update/Build/Products/Release/OpenBots Next.app").path else {
                throw SourceAppUpdateError.invalidPreparation
            }
            try Task.checkCancellation()
            let value = PreparedSourceAppUpdate(appURL: URL(fileURLWithPath: path), sourceCommit: verified.sourceCommit,
                                              build: verified.build, version: verified.version, fingerprint: fingerprint, id: id)
            prepared = value
            return value
        } catch {
            if worker?.isRunning == true || (error as? SourceAppUpdateError) == .cancellationIncomplete {
                // Do not forget a still-running child or remove its staging.
                throw SourceAppUpdateError.cancellationIncomplete
            }
            worker = nil
            try? FileManager.default.removeItem(at: stage)
            preparedStage = nil
            throw error
        }
    }

    public func cancel() async throws {
        guard !cancelling else { throw SourceAppUpdateError.busy }
        cancelling = true
        defer { cancelling = false }
        generation &+= 1
        if let download { download.cancel(); _ = await download.result }
        if let runner = worker {
            runner.requestCancellation()
            try await runner.waitForStop()
            worker = nil
        }
        installation = nil
        if let stage = preparedStage, FileManager.default.fileExists(atPath: stage.path) {
            try FileManager.default.removeItem(at: stage)
        }
        prepared = nil; preparedStage = nil
    }

    public func discard(_ value: PreparedSourceAppUpdate) async throws {
        try discardStorage(value)
    }

    private func discardStorage(_ value: PreparedSourceAppUpdate) throws {
        guard !operationActive, !cancelling, worker == nil, installation == nil, value == prepared, let stage = preparedStage else {
            throw SourceAppUpdateError.invalidPreparation
        }
        try FileManager.default.removeItem(at: stage)
        prepared = nil; preparedStage = nil
    }

    public func beginInstallation(_ value: PreparedSourceAppUpdate,
                                  googleConfiguration fresh: GoogleWorkspaceUpdateConfiguration) async throws -> SourceAppUpdateInstallation {
        guard !operationActive, !cancelling, worker == nil, installation == nil, value == prepared, let stage = preparedStage,
              fresh == googleConfiguration else { throw SourceAppUpdateError.invalidPreparation }
        operationActive = true
        let operationGeneration = generation
        defer { operationActive = false }
        // A fresh helper performs every bundle/signature/configuration check
        // again and records both full fingerprints before acknowledging.
        try? FileManager.default.removeItem(at: stage.appending(path: "cancel"))
        try? FileManager.default.removeItem(at: stage.appending(path: "ready.json"))
        let runner = try SourceAppUpdateWorker(stage: stage, operation: "install")
        worker = runner
        do {
            try await withTaskCancellationHandler { try await runner.waitUntilReady() }
                onCancel: { runner.requestCancellation() }
            guard operationGeneration == generation else { throw SourceAppUpdateError.cancelled }
            let ticket = SourceAppUpdateInstallation(id: value.id, receiptURL: stage.appending(path: "receipt.json"))
            installation = ticket
            return ticket
        } catch {
            runner.requestCancellation()
            try await runner.waitForStop()
            worker = nil
            throw error
        }
    }

    public func abortInstallation(_ ticket: SourceAppUpdateInstallation) async throws {
        guard ticket == installation, let runner = worker else { throw SourceAppUpdateError.invalidPreparation }
        runner.requestCancellation()
        try await runner.waitForStop()
        worker = nil; installation = nil
    }

    public func receipt(_ ticket: SourceAppUpdateInstallation) async throws -> SourceAppUpdateInstallationReceipt? {
        guard ticket == installation || ticket.id == prepared?.id,
              ticket.receiptURL == preparedStage?.appending(path: "receipt.json") else { throw SourceAppUpdateError.invalidPreparation }
        return try readReceipt(ticket.receiptURL)
    }

    public func latestInstallationReceipt() async throws -> SourceAppUpdateInstallationReceipt? {
        try readReceipt(stagingRoot.appending(path: "last-installation.json"))
    }

    private func readReceipt(_ url: URL) throws -> SourceAppUpdateInstallationReceipt? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try privateRegularFile(url, maximumBytes: 8_192)
        return try JSONDecoder().decode(SourceAppUpdateInstallationReceipt.self, from: Data(contentsOf: url))
    }
}

private func privateDirectory(_ url: URL) throws {
    let manager = FileManager.default
    let standard = url.standardizedFileURL
    // The caller chooses the root, but no existing component may redirect it.
    var cursor = URL(fileURLWithPath: "/", isDirectory: true)
    for component in standard.pathComponents.dropFirst() {
        cursor.append(path: component)
        var status = stat()
        if lstat(cursor.path, &status) == 0 {
            guard status.st_mode & S_IFMT == S_IFDIR else { throw SourceAppUpdateError.invalidPreparation }
        } else {
            guard errno == ENOENT else { throw SourceAppUpdateError.invalidPreparation }
            try manager.createDirectory(at: cursor, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }
    var status = stat()
    guard lstat(standard.path, &status) == 0, status.st_uid == getuid(), status.st_mode & 0o077 == 0 else {
        throw SourceAppUpdateError.invalidPreparation
    }
}

/// A stage holds the source tree, DerivedData and the built app, gigabytes in
/// all, and nothing removed it after a successful install, because the
/// relaunched app never knew the stage. A sweep empties every stage that no
/// live job owns down to its small receipts
/// and keeps only the newest stages. Only UUID-named stage folders under the
/// app-owned root are touched (never Rollback/ or last-installation.json), and
/// no link is followed: removing a link removes the link.
func sweepSourceUpdateStages(in root: URL, keeping live: URL?) {
    let manager = FileManager.default
    var rootStatus = stat()
    guard lstat(root.path, &rootStatus) == 0, rootStatus.st_mode & S_IFMT == S_IFDIR, rootStatus.st_uid == getuid(),
          let names = try? manager.contentsOfDirectory(atPath: root.path) else { return }
    var swept: [(stage: URL, born: Double)] = []
    for name in names where UUID(uuidString: name) != nil {
        let stage = root.appending(path: name)
        var status = stat()
        guard lstat(stage.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR, status.st_uid == getuid(),
              stage.standardizedFileURL != live?.standardizedFileURL, !stageMayBeLive(stage) else { continue }
        for child in (try? manager.contentsOfDirectory(atPath: stage.path)) ?? [] {
            let item = stage.appending(path: child)
            var info = stat()
            if retainedStageReceipts.contains(child), lstat(item.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG { continue }
            try? manager.removeItem(at: item)
        }
        // Birth time, because emptying a folder changes its modification time.
        swept.append((stage, Double(status.st_birthtimespec.tv_sec) + Double(status.st_birthtimespec.tv_nsec) / 1e9))
    }
    for old in swept.sorted(by: { $0.born > $1.born }).dropFirst(retainedStageCount) {
        try? manager.removeItem(at: old.stage)
    }
}

private let retainedStageCount = 10
private let retainedStageReceipts: Set<String> = [
    "started.json", "admitted.json", "worker-stopped.json", "stopped.json", "ready.json", "result.json",
    "receipt.json", "error.json", "launch.json", "progress.json", "build.log"
]

/// A stage whose job never launched, or whose controller wrote its final
/// stopped receipt or is gone, is not live. The app relaunched by an install
/// starts while that install's controller is still finishing, so its stage
/// waits for the next sweep. An unreadable launch receipt counts as live.
private func stageMayBeLive(_ stage: URL) -> Bool {
    var status = stat()
    guard lstat(stage.appending(path: "launch.json").path, &status) == 0 else { return errno != ENOENT }
    if let stopped = try? readObject(stage.appending(path: "stopped.json")), stopped["stopped"] as? Bool == true { return false }
    guard let launch = try? readObject(stage.appending(path: "launch.json")),
          let controller = launch["controllerIdentity"] as? [String: Any],
          let pid = controller["pid"] as? Int, pid > 1, pid <= Int(Int32.max) else { return true }
    return kill(pid_t(pid), 0) == 0 || errno == EPERM
}

private func privateRegularFile(_ url: URL, maximumBytes: Int) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
          status.st_uid == getuid(), status.st_nlink == 1, status.st_mode & 0o077 == 0,
          status.st_size >= 0, status.st_size <= maximumBytes else { throw SourceAppUpdateError.invalidPreparation }
}

private func writeJSON(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
        throw SourceAppUpdateError.invalidPreparation
    }
}

private func readObject(_ url: URL) throws -> [String: Any] {
    try privateRegularFile(url, maximumBytes: 16_384)
    guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
        throw SourceAppUpdateError.invalidPreparation
    }
    return result
}

/// Uses a cancellation file rather than killing the helper out from under its
/// child cleanup. A nonce-bound transient job owns one kernel resource coalition.
private final class SourceAppUpdateWorker: @unchecked Sendable {
    private var processStorage: Process
    private let stage: URL
    private let script: URL
    private let nonce: String
    private let log: FileHandle
    private let cancellationLock = NSLock()
    private var cancellationRequested = false
    private var cleanupAcknowledged = false

    init(stage: URL, operation: String) throws {
        guard let script = ServicesResourceBundle.url(forResource: "source-app-update", withExtension: "py"),
              let ownership = ServicesResourceBundle.url(forResource: "source-app-update-processes", withExtension: "py"),
              ownership.deletingLastPathComponent() == script.deletingLastPathComponent(),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw SourceAppUpdateError.workerUnavailable }
        self.stage = stage
        self.script = script
        let runNonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        self.nonce = runNonce
        for name in ["stopped.json", "error.json", "receipt.json", "started.json", "admitted.json", "worker-stopped.json", "ready.json"] {
            let path = stage.appending(path: name)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
        let logURL = stage.appending(path: "worker.log")
        FileManager.default.createFile(atPath: logURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        let outputLog = try FileHandle(forWritingTo: logURL)
        log = outputLog
        processStorage = Self.controller(stage: stage, script: script, operation: operation, nonce: runNonce, log: outputLog)
        do { try processStorage.run() } catch { try? log.close(); throw SourceAppUpdateError.workerUnavailable }
    }

    private static func controller(stage: URL, script: URL, operation: String, nonce: String, log: FileHandle) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-B", "-S", script.path, operation, stage.path, nonce]
        process.currentDirectoryURL = stage
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "LANG": "en_US.UTF-8", "TMPDIR": stage.path, "PYTHONDONTWRITEBYTECODE": "1"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log; process.standardError = log
        return process
    }

    deinit { try? log.close() }
    private var process: Process {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        return processStorage
    }
    var isRunning: Bool { process.isRunning }

    func requestCancellation() {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        cancellationRequested = true
        FileManager.default.createFile(atPath: stage.appending(path: "cancel").path, contents: Data(), attributes: [.posixPermissions: 0o600])
        // A failed job-removal attempt remains retryable without starting any
        // source/build step. Ownership stays bound to this run's private ledger.
        if !processStorage.isRunning, !cleanupAcknowledged,
           FileManager.default.fileExists(atPath: stage.appending(path: "launch.json").path),
           !validCleanupReceipt() {
            let recovery = Self.controller(stage: stage, script: script, operation: "cleanup", nonce: nonce, log: log)
            do { try recovery.run(); processStorage = recovery } catch { /* waitForStop keeps the admission closed */ }
        }
    }

    private var wasCancelled: Bool {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        return cancellationRequested
    }

    func wait(progress: @Sendable (SourceAppUpdateProgress) -> Void) async throws {
        var last: SourceAppUpdateProgress?
        let deadline = Date().addingTimeInterval(45 * 60)
        while process.isRunning {
            if Task.isCancelled || Date() >= deadline { requestCancellation() }
            if wasCancelled { try await waitForStop(); throw SourceAppUpdateError.cancelled }
            if let object = try? readObject(stage.appending(path: "progress.json")), let raw = object["stage"] as? String,
               let value = SourceAppUpdateProgress(rawValue: raw), value != last { last = value; progress(value) }
            await Self.pause()
        }
        try finish()
    }

    func waitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning && Date() < deadline {
            if Task.isCancelled || wasCancelled { requestCancellation(); try await waitForStop(); throw SourceAppUpdateError.cancelled }
            if let ready = try? readObject(stage.appending(path: "ready.json")), ready["ready"] as? Bool == true,
               ready["nonce"] as? String == nonce, ready["population"] as? Int == 1 { return }
            await Self.pause()
        }
        if process.isRunning { throw SourceAppUpdateError.operationFailed("The installer did not become ready in time. The current app is unchanged.") }
        try finish()
        throw SourceAppUpdateError.invalidPreparation
    }

    func waitForStop() async throws {
        let deadline = Date().addingTimeInterval(40)
        while process.isRunning && Date() < deadline { await Self.pause() }
        guard !process.isRunning else { throw SourceAppUpdateError.cancellationIncomplete }
        // Process disappearance alone is insufficient: a crashed helper may
        // have left a build child. Require its explicit cleanup acknowledgment.
        guard acknowledgeCleanup() else {
            throw SourceAppUpdateError.cancellationIncomplete
        }
    }

    private func finish() throws {
        guard acknowledgeCleanup() else {
            throw SourceAppUpdateError.cancellationIncomplete
        }
        if wasCancelled { throw SourceAppUpdateError.cancelled }
        guard process.terminationStatus == 0 else {
            let result = try? readObject(stage.appending(path: "error.json"))
            let message = result?["message"] as? String ?? "The source update could not finish. The current app is unchanged."
            throw SourceAppUpdateError.operationFailed(String(message.prefix(1_024)))
        }
    }

    private func acknowledgeCleanup() -> Bool {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        if cleanupAcknowledged { return true }
        guard validCleanupReceipt() else { return false }
        cleanupAcknowledged = true
        return true
    }

    private func validCleanupReceipt() -> Bool {
        guard let stopped = try? readObject(stage.appending(path: "stopped.json")) else { return false }
        return stopped["nonce"] as? String == nonce && stopped["stopped"] as? Bool == true
            && stopped["jobRemoved"] as? Bool == true && stopped["resourceCoalitionEmpty"] as? Bool == true
    }

    private static func pause() async {
        // Cleanup must keep yielding even when the caller's task is cancelled.
        await Task.detached(priority: .utility) { try? await Task.sleep(for: .milliseconds(100)) }.value
    }
}
