import CryptoKit
import Darwin
import Foundation
import OpenBotsDomain

public enum ClaudeRuntimeStoreError: Error, Equatable, Sendable {
    case rootMismatch, unsafeEntry, changedIdentity, invalidArtifact, invalidState
    case staleGeneration, invalidReceipt, unavailable
}

public protocol ClaudeRuntimeStoring: Sendable {
    func load() async throws -> ClaudeRuntimeState
    func checkResult(artifactSHA256: String, contract: ClaudeRuntimeContract) async throws -> ClaudeRuntimeCheckResult?
    func importCandidate(sourceURL: URL, artifact: ClaudeRuntimeArtifact, expectedGeneration: UInt64) async throws -> ClaudeRuntimeState
    func recordResult(_ result: ClaudeRuntimeCheckResult, expectedGeneration: UInt64) async throws -> ClaudeRuntimeState
    func promote(receipt: ClaudeRuntimeCompatibilityReceipt, contract: ClaudeRuntimeContract, expectedGeneration: UInt64) async throws -> ClaudeRuntimeState
    func reject(reason: String, expectedGeneration: UInt64) async throws -> ClaudeRuntimeState
    func explicitRetry(expectedGeneration: UInt64, contract: ClaudeRuntimeContract) async throws -> ClaudeRuntimeState
    /// Removes retained copies outside the durable selection and `keeping`;
    /// returns how many entries it had to leave in place.
    func pruneRetained(keeping: Set<String>) async throws -> Int
}

/// One bounded snapshot and immutable copies. The lock also serializes different
/// store instances; generation checks reject stale work after every suspension.
/// Signature verification belongs to Services/Security, before gate or launch.
public actor ClaudeRuntimeStore: ClaudeRuntimeStoring {
    private let root: VerifiedOwnedRoot
    private let layout: PreviewStorageLayout
    private let beforePublication: (@Sendable () throws -> Void)?
    private let afterSourceCopy: (@Sendable () throws -> Void)?
    private let leftoverCutoff: time_t?

    public init(applicationSupportRoot: VerifiedOwnedRoot, layout: PreviewStorageLayout) {
        root = applicationSupportRoot; self.layout = layout; beforePublication = nil; afterSourceCopy = nil
        leftoverCutoff = nil
    }

    init(applicationSupportRoot: VerifiedOwnedRoot, layout: PreviewStorageLayout,
         beforePublication: (@Sendable () throws -> Void)?,
         afterSourceCopy: (@Sendable () throws -> Void)? = nil, leftoverCutoff: time_t? = nil) {
        root = applicationSupportRoot; self.layout = layout; self.beforePublication = beforePublication
        self.afterSourceCopy = afterSourceCopy; self.leftoverCutoff = leftoverCutoff
    }

    /// When this process started. Staging and snapshot leftovers older than it
    /// belong to a process that died mid-write; the lock already excludes a
    /// live writer, so this is the second fence, not the first.
    private static let processStart: time_t = {
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, info.kp_proc.p_un.__p_starttime.tv_sec > 0 else {
            return time(nil)
        }
        return info.kp_proc.p_un.__p_starttime.tv_sec
    }()

    public func load() throws -> ClaudeRuntimeState {
        let access = try RuntimeAccess(root: root, layout: layout)
        return try access.load()
    }

    public func checkResult(artifactSHA256: String, contract: ClaudeRuntimeContract) throws -> ClaudeRuntimeCheckResult? {
        try RuntimeAccess(root: root, layout: layout).checkResult(artifactSHA256: artifactSHA256, contract: contract)
    }

    public func importCandidate(sourceURL: URL, artifact: ClaudeRuntimeArtifact,
                                expectedGeneration: UInt64) throws -> ClaudeRuntimeState {
        guard artifact.isWellFormed else { throw ClaudeRuntimeStoreError.invalidArtifact }
        let access = try RuntimeAccess(root: root, layout: layout)
        let state = try access.load(expectedGeneration: expectedGeneration)
        try access.retain(sourceURL: sourceURL, artifact: artifact, afterSourceCopy: afterSourceCopy)
        if state.active == artifact || state.candidate == artifact { return state }
        let next = ClaudeRuntimeState(active: state.active, previous: state.previous,
                                     candidate: artifact, generation: try nextGeneration(state),
                                     activeReceipt: state.activeReceipt)
        try access.publish(next, beforePublication: beforePublication)
        return next
    }

    public func recordResult(_ result: ClaudeRuntimeCheckResult,
                             expectedGeneration: UInt64) throws -> ClaudeRuntimeState {
        let access = try RuntimeAccess(root: root, layout: layout)
        let state = try access.load(expectedGeneration: expectedGeneration)
        guard let candidate = state.candidate, result.artifactSHA256 == candidate.sha256,
              result.message?.utf8.count ?? 0 <= 2_048 else { throw ClaudeRuntimeStoreError.invalidState }
        if result.status == .passed {
            guard let receipt = result.receipt else { throw ClaudeRuntimeStoreError.invalidReceipt }
            try validate(receipt, contract: result.contract, state: state)
        } else if result.receipt != nil { throw ClaudeRuntimeStoreError.invalidReceipt }
        try access.recordCheckResult(result)
        let next = ClaudeRuntimeState(active: state.active, previous: state.previous, candidate: candidate,
                                     generation: try nextGeneration(state), lastResult: result,
                                     activeReceipt: state.activeReceipt)
        try access.publish(next, beforePublication: beforePublication)
        return next
    }

    public func promote(receipt: ClaudeRuntimeCompatibilityReceipt, contract: ClaudeRuntimeContract,
                        expectedGeneration: UInt64) throws -> ClaudeRuntimeState {
        let access = try RuntimeAccess(root: root, layout: layout)
        let state = try access.load(expectedGeneration: expectedGeneration)
        try validate(receipt, contract: contract, state: state)
        try access.verifyRetained(receipt.artifact)
        // Persist the receipt before the active selection. A crash between these
        // snapshots leaves a passed candidate which can be revalidated and promoted.
        let passed = ClaudeRuntimeCheckResult(artifactSHA256: receipt.artifact.sha256,
                                             contract: contract, status: .passed, receipt: receipt)
        try access.recordCheckResult(passed)
        let recorded = ClaudeRuntimeState(active: state.active, previous: state.previous,
                                          candidate: state.candidate, generation: try nextGeneration(state),
                                          lastResult: passed, activeReceipt: state.activeReceipt)
        try access.publish(recorded, beforePublication: beforePublication)
        try validate(receipt, contract: contract, state: recorded)
        try access.verifyRetained(receipt.artifact)
        let next = ClaudeRuntimeState(active: receipt.artifact, previous: state.active,
                                     generation: try nextGeneration(recorded), lastResult: passed,
                                     activeReceipt: receipt)
        try access.publish(next, beforePublication: beforePublication)
        return next
    }

    public func reject(reason: String, expectedGeneration: UInt64) throws -> ClaudeRuntimeState {
        let access = try RuntimeAccess(root: root, layout: layout)
        let state = try access.load(expectedGeneration: expectedGeneration)
        guard let candidate = state.candidate, let result = state.lastResult else {
            throw ClaudeRuntimeStoreError.invalidState
        }
        let failed = ClaudeRuntimeCheckResult(artifactSHA256: candidate.sha256, contract: result.contract,
                                             status: .failed, message: reason)
        try access.recordCheckResult(failed)
        let next = ClaudeRuntimeState(active: state.active, previous: state.previous, candidate: candidate,
                                     generation: try nextGeneration(state), lastResult: failed,
                                     activeReceipt: state.activeReceipt)
        try access.publish(next, beforePublication: beforePublication)
        return next
    }

    public func explicitRetry(expectedGeneration: UInt64, contract: ClaudeRuntimeContract) throws -> ClaudeRuntimeState {
        let access = try RuntimeAccess(root: root, layout: layout)
        let state = try access.load(expectedGeneration: expectedGeneration)
        guard let candidate = state.candidate else { throw ClaudeRuntimeStoreError.invalidState }
        try access.recordCheckResult(ClaudeRuntimeCheckResult(artifactSHA256: candidate.sha256,
                                                               contract: contract, status: .pending))
        let next = ClaudeRuntimeState(active: state.active, previous: state.previous, candidate: state.candidate,
                                     generation: try nextGeneration(state), activeReceipt: state.activeReceipt)
        try access.publish(next, beforePublication: beforePublication)
        return next
    }

    /// The selection is reread under the lock, so its active, previous and
    /// candidate survive whatever `keeping` says. Check receipts are kept: they
    /// are small, and a remembered failure is what stops a second automatic probe
    /// when an earlier failed version is installed again.
    public func pruneRetained(keeping: Set<String>) throws -> Int {
        let access = try RuntimeAccess(root: root, layout: layout)
        let state = try access.load()
        let selected = [state.active, state.previous, state.candidate].compactMap { $0?.sha256 }
        return try access.pruneRetained(keeping: keeping.union(selected), cutoff: leftoverCutoff ?? Self.processStart)
    }

    private func nextGeneration(_ state: ClaudeRuntimeState) throws -> UInt64 {
        guard state.generation < UInt64.max else { throw ClaudeRuntimeStoreError.invalidState }
        return state.generation + 1
    }

    private func validate(_ receipt: ClaudeRuntimeCompatibilityReceipt, contract: ClaudeRuntimeContract,
                          state: ClaudeRuntimeState) throws {
        let compatibility = layout.withClaudeProfilePurpose(.compatibility)
        guard receipt.artifact.isWellFormed, receipt.artifact == state.candidate,
              receipt.contract == contract, !contract.appBuild.isEmpty, contract.appBuild.utf8.count <= 256,
              contract.protocolRevision == 1,
              contract.suiteRevision == ClaudeRuntimeContract.currentSuiteRevision, contract.profileSchemaVersion == 1,
              receipt.compatibilityProfilePath == compatibility.claudeCLIProfileRoot.path,
              receipt.sourceRuntimeSHA256 == state.active?.sha256,
              receipt.passedCases == Set(ClaudeRuntimeCompatibilityCase.allCases),
              receipt.completedAt.timeIntervalSince1970.isFinite,
              receipt.completedAt.timeIntervalSince1970 > 0,
              receipt.completedAt <= Date().addingTimeInterval(60),
              try ClaudeProfileInspector().verifiedProfileIdentity(applicationSupportRoot: root, layout: compatibility)
                == contract.compatibilityProfileID else { throw ClaudeRuntimeStoreError.invalidReceipt }
    }
}

private final class RuntimeAccess {
    private struct Directory {
        let fd: Int32; let parent: Int32?; let name: String?; let metadata: stat
    }
    private var directories: [Directory] = []
    private var lockFD: Int32 = -1
    private var marker: (fd: Int32, parent: Int32, metadata: stat, data: Data)?
    private let maximumBytes: Int64 = 512 * 1_024 * 1_024
    private let compatibilityProfilePath: String
    private var claudeFD: Int32 { directories.last!.fd }

    init(root: VerifiedOwnedRoot, layout: PreviewStorageLayout) throws {
        compatibilityProfilePath = layout.withClaudeProfilePurpose(.compatibility).claudeCLIProfileRoot.path
        guard root.kind == .applicationSupport, root.url == layout.applicationSupportRoot.url,
              root.url.isFileURL, root.url.pathComponents.count <= 128 else {
            throw ClaudeRuntimeStoreError.rootMismatch
        }
        do {
            let first = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard first >= 0 else { throw ClaudeRuntimeStoreError.unavailable }
            directories.append(Directory(fd: first, parent: nil, name: nil, metadata: try Self.metadata(first)))
            let components = Array(root.url.pathComponents.dropFirst())
            for (index, name) in components.enumerated() {
                try append(name, protected: index == components.count - 1)
            }
            let rootFD = claudeFD
            let openedMarker = try openFile(".openbots-root.json", parent: rootFD, mode: 0o600, maximum: 4_096)
            let data = try read(openedMarker.fd, maximum: 4_096)
            marker = (openedMarker.fd, rootFD, openedMarker.metadata, data)
            let expected = OwnedRootMarker(installationID: root.installationID, rootID: root.rootID, kind: .applicationSupport)
            guard try JSONDecoder().decode(OwnedRootMarker.self, from: data) == expected else {
                throw ClaudeRuntimeStoreError.rootMismatch
            }
            for name in ["HighChurn.noindex", "Runtime", "Claude"] { try append(name, protected: true) }
            lockFD = openat(claudeFD, ".runtime-state.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard lockFD >= 0 else { throw ClaudeRuntimeStoreError.unsafeEntry }
            try Self.validateFile(try Self.metadata(lockFD), mode: 0o600, maximum: 0)
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw ClaudeRuntimeStoreError.unavailable }
            try revalidate()
        } catch { cleanup(); throw error }
    }

    deinit { cleanup() }
    private func cleanup() {
        if lockFD >= 0 { close(lockFD); lockFD = -1 }
        if let marker { close(marker.fd); self.marker = nil }
        for directory in directories.reversed() { close(directory.fd) }
        directories.removeAll()
    }

    func load(expectedGeneration: UInt64? = nil) throws -> ClaudeRuntimeState {
        try revalidate()
        let state: ClaudeRuntimeState
        var entry = stat()
        if fstatat(claudeFD, "runtime-state.json", &entry, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ClaudeRuntimeStoreError.unavailable }
            state = ClaudeRuntimeState()
        } else {
            let file = try openFile("runtime-state.json", parent: claudeFD, mode: 0o600, maximum: 65_536)
            defer { close(file.fd) }
            let bytes = try read(file.fd, maximum: 65_536)
            try unchanged(file.fd, parent: claudeFD, name: "runtime-state.json", before: file.metadata)
            guard let decoded = try? JSONDecoder().decode(ClaudeRuntimeState.self, from: bytes),
                  [decoded.active, decoded.previous, decoded.candidate].compactMap({ $0 }).allSatisfy(\.isWellFormed),
                  decoded.lastResult?.message?.utf8.count ?? 0 <= 2_048 else {
                throw ClaudeRuntimeStoreError.invalidState
            }
            state = decoded
        }
        try validateSelection(state)
        try revalidate()
        if let expectedGeneration, state.generation != expectedGeneration { throw ClaudeRuntimeStoreError.staleGeneration }
        return state
    }

    private func validateSelection(_ state: ClaudeRuntimeState) throws {
        guard let active = state.active else {
            guard state.activeReceipt == nil, state.previous == nil else { throw ClaudeRuntimeStoreError.invalidState }
            return
        }
        guard let receipt = state.activeReceipt, receipt.artifact == active,
              receipt.sourceRuntimeSHA256 == state.previous?.sha256,
              receipt.compatibilityProfilePath == compatibilityProfilePath,
              receipt.passedCases == Set(ClaudeRuntimeCompatibilityCase.allCases),
              !receipt.contract.appBuild.isEmpty, receipt.contract.appBuild.utf8.count <= 256,
              receipt.contract.protocolRevision == 1,
              [1, ClaudeRuntimeContract.currentSuiteRevision].contains(receipt.contract.suiteRevision),
              receipt.contract.profileSchemaVersion == 1,
              receipt.completedAt.timeIntervalSince1970.isFinite,
              receipt.completedAt.timeIntervalSince1970 > 0 else { throw ClaudeRuntimeStoreError.invalidState }
    }

    func publish(_ state: ClaudeRuntimeState, beforePublication: (@Sendable () throws -> Void)?) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= 65_536 else { throw ClaudeRuntimeStoreError.invalidState }
        try writeAtomic(data, parent: claudeFD, finalName: "runtime-state.json", beforePublication: beforePublication)
    }

    func checkResult(artifactSHA256: String, contract: ClaudeRuntimeContract) throws -> ClaudeRuntimeCheckResult? {
        let filename = try checkFilename(artifactSHA256: artifactSHA256, contract: contract)
        return try withCheckDirectory(artifactSHA256: artifactSHA256, create: false) { parent in
            var entry = stat()
            if fstatat(parent, filename, &entry, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw ClaudeRuntimeStoreError.unavailable }
                return nil
            }
            let file = try openFile(filename, parent: parent, mode: 0o600, maximum: 8_192)
            defer { close(file.fd) }
            let data = try read(file.fd, maximum: 8_192)
            try unchanged(file.fd, parent: parent, name: filename, before: file.metadata)
            guard let result = try? JSONDecoder().decode(ClaudeRuntimeCheckResult.self, from: data),
                  result.artifactSHA256 == artifactSHA256, result.contract == contract,
                  (result.message?.utf8.count ?? 0) <= 2_048 else { throw ClaudeRuntimeStoreError.invalidState }
            return result
        } ?? nil
    }

    func recordCheckResult(_ result: ClaudeRuntimeCheckResult) throws {
        let filename = try checkFilename(artifactSHA256: result.artifactSHA256, contract: result.contract)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        guard data.count <= 8_192 else { throw ClaudeRuntimeStoreError.invalidState }
        _ = try withCheckDirectory(artifactSHA256: result.artifactSHA256, create: true) { parent in
            try writeAtomic(data, parent: parent, finalName: filename, beforePublication: nil)
        }
    }

    private func checkFilename(artifactSHA256: String, contract: ClaudeRuntimeContract) throws -> String {
        guard artifactSHA256.count == 64, artifactSHA256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw ClaudeRuntimeStoreError.invalidArtifact
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(contract)
        guard encoded.count <= 4_096 else { throw ClaudeRuntimeStoreError.invalidState }
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private func withCheckDirectory<T>(artifactSHA256: String, create: Bool,
                                       operation: (Int32) throws -> T) throws -> T? {
        var opened: [(fd: Int32, parent: Int32, name: String)] = []
        defer { for directory in opened.reversed() { close(directory.fd) } }
        var parent = claudeFD
        for name in ["Retained", "Checks", artifactSHA256] {
            if create {
                if mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { throw ClaudeRuntimeStoreError.unavailable }
                guard fsync(parent) == 0 else { throw ClaudeRuntimeStoreError.unavailable }
            }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 {
                if !create && errno == ENOENT { return nil }
                throw ClaudeRuntimeStoreError.unsafeEntry
            }
            opened.append((fd, parent, name))
            try verifyDirectory(fd, parent: parent, name: name)
            parent = fd
        }
        try revalidate()
        let result = try operation(parent)
        for directory in opened { try verifyDirectory(directory.fd, parent: directory.parent, name: directory.name) }
        try revalidate()
        return result
    }

    private func writeAtomic(_ data: Data, parent: Int32, finalName: String,
                             beforePublication: (@Sendable () throws -> Void)?) throws {
        var existingMetadata = stat()
        let existing: (fd: Int32, metadata: stat)?
        if fstatat(parent, finalName, &existingMetadata, AT_SYMLINK_NOFOLLOW) == 0 {
            existing = try openFile(finalName, parent: parent, mode: 0o600, maximum: 65_536)
        } else {
            guard errno == ENOENT else { throw ClaudeRuntimeStoreError.unavailable }
            existing = nil
        }
        defer { if let existing { close(existing.fd) } }
        let name = ".runtime-state-\(UUID().uuidString).tmp"
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ClaudeRuntimeStoreError.unavailable }
        defer {
            if let opened = try? Self.metadata(fd), let named = try? Self.entry(parent, name),
               Self.sameObject(opened, named) { _ = unlinkat(parent, name, 0) }
            close(fd)
        }
        guard fchmod(fd, 0o600) == 0 else { throw ClaudeRuntimeStoreError.unavailable }
        try write(data, fd: fd)
        guard fsync(fd) == 0 else { throw ClaudeRuntimeStoreError.unavailable }
        let before = try Self.metadata(fd)
        try beforePublication?()
        try unchanged(fd, parent: parent, name: name, before: before)
        try revalidate()
        if let existing {
            try unchanged(existing.fd, parent: parent, name: finalName, before: existing.metadata)
        } else {
            var absent = stat()
            guard fstatat(parent, finalName, &absent, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                throw ClaudeRuntimeStoreError.changedIdentity
            }
        }
        try Task.checkCancellation()
        guard renameat(parent, name, parent, finalName) == 0,
              fsync(parent) == 0 else { throw ClaudeRuntimeStoreError.unavailable }
        try unchanged(fd, parent: parent, name: finalName, before: before, allowChangeTime: true)
        try revalidate()
    }

    func retain(sourceURL: URL, artifact: ClaudeRuntimeArtifact,
                afterSourceCopy: (@Sendable () throws -> Void)?) throws {
        guard sourceURL.isFileURL, !sourceURL.path.contains("\0"), !sourceURL.pathComponents.contains("..") else {
            throw ClaudeRuntimeStoreError.unsafeEntry
        }
        let sourceParent = try openAbsoluteDirectory(sourceURL.deletingLastPathComponent())
        defer { close(sourceParent) }
        let source = try openFile(sourceURL.lastPathComponent, parent: sourceParent, mode: nil, maximum: maximumBytes)
        defer { close(source.fd) }
        guard try hash(source.fd) == artifact.sha256 else { throw ClaudeRuntimeStoreError.invalidArtifact }
        try unchanged(source.fd, parent: sourceParent, name: sourceURL.lastPathComponent, before: source.metadata)
        let retained = try retainedDirectory(create: true)
        defer { close(retained) }
        let staging = ".stage-\(UUID().uuidString)"
        guard mkdirat(retained, staging, 0o700) == 0 else { throw ClaudeRuntimeStoreError.unavailable }
        let stageFD = openat(retained, staging, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stageFD >= 0 else { throw ClaudeRuntimeStoreError.unavailable }
        defer { close(stageFD) }
        let stageIdentity = try Self.metadata(stageFD)
        var published = false
        var copiedIdentity: stat?
        defer {
            if !published, let namedStage = try? Self.entry(retained, staging),
               Self.sameObject(stageIdentity, namedStage) {
                if let copiedIdentity, let namedCopy = try? Self.entry(stageFD, "claude"),
                   Self.sameObject(copiedIdentity, namedCopy) { _ = unlinkat(stageFD, "claude", 0) }
                _ = unlinkat(retained, staging, AT_REMOVEDIR)
            }
        }
        let copied = openat(stageFD, "claude", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard copied >= 0 else { throw ClaudeRuntimeStoreError.unavailable }
        defer { close(copied) }
        copiedIdentity = try Self.metadata(copied)
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        while offset < source.metadata.st_size {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { pread(source.fd, $0.baseAddress, min($0.count, Int(source.metadata.st_size - offset)), off_t(offset)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ClaudeRuntimeStoreError.changedIdentity }
            try write(Data(buffer.prefix(count)), fd: copied)
            offset += Int64(count)
        }
        try afterSourceCopy?()
        guard try hash(source.fd) == artifact.sha256, try hash(copied) == artifact.sha256 else {
            throw ClaudeRuntimeStoreError.changedIdentity
        }
        try unchanged(source.fd, parent: sourceParent, name: sourceURL.lastPathComponent, before: source.metadata)
        let freshSourceParent = try openAbsoluteDirectory(sourceURL.deletingLastPathComponent())
        defer { close(freshSourceParent) }
        guard Self.sameObject(try Self.metadata(sourceParent), try Self.metadata(freshSourceParent)) else {
            throw ClaudeRuntimeStoreError.changedIdentity
        }
        guard fchmod(copied, 0o700) == 0, fsync(copied) == 0, fsync(stageFD) == 0 else {
            throw ClaudeRuntimeStoreError.unavailable
        }
        copiedIdentity = try Self.metadata(copied)
        try revalidate()
        try verifyDirectory(retained, parent: claudeFD, name: "Retained")
        try verifyDirectory(stageFD, parent: retained, name: staging)
        if renameatx_np(retained, staging, retained, artifact.sha256, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST else { throw ClaudeRuntimeStoreError.unavailable }
            try verifyRetained(artifact)
            return
        }
        published = true
        guard fsync(retained) == 0 else { throw ClaudeRuntimeStoreError.unavailable }
        try verifyRetained(artifact)
    }

    func verifyRetained(_ artifact: ClaudeRuntimeArtifact) throws {
        let retained = try retainedDirectory(create: false)
        defer { close(retained) }
        let directory = openat(retained, artifact.sha256, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ClaudeRuntimeStoreError.unsafeEntry }
        defer { close(directory) }
        try verifyDirectory(directory, parent: retained, name: artifact.sha256)
        let file = try openFile("claude", parent: directory, mode: 0o700, maximum: maximumBytes)
        defer { close(file.fd) }
        guard try hash(file.fd) == artifact.sha256 else { throw ClaudeRuntimeStoreError.invalidArtifact }
        try unchanged(file.fd, parent: directory, name: "claude", before: file.metadata)
        try verifyDirectory(directory, parent: retained, name: artifact.sha256)
        try verifyDirectory(retained, parent: claudeFD, name: "Retained")
        try revalidate()
    }

    /// Retained copies go only by their exact digest name; a link, file or
    /// foreign mode in that place is left alone. Every refusal is counted.
    func pruneRetained(keeping: Set<String>, cutoff: time_t) throws -> Int {
        try revalidate()
        var left = sweepSnapshotTemporaries(in: claudeFD, cutoff: cutoff)
        let retained = openat(claudeFD, "Retained", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard retained >= 0 else {
            guard errno == ENOENT else { throw ClaudeRuntimeStoreError.unsafeEntry }
            return left
        }
        defer { close(retained) }
        try verifyDirectory(retained, parent: claudeFD, name: "Retained")
        for name in try entryNames(in: retained) {
            if Self.isDigest(name) {
                if !keeping.contains(name) && !removeRetainedCopy(name, parent: retained) { left += 1 }
            } else if name.hasPrefix(".stage-"), UUID(uuidString: String(name.dropFirst(7))) != nil {
                guard let value = try? Self.entry(retained, name), value.st_mode & S_IFMT == S_IFDIR,
                      Self.isLeftover(value, cutoff: cutoff) else { continue }
                if !removeRetainedCopy(name, parent: retained) { left += 1 }
            } else if name == "Checks" {
                left += sweepChecks(in: retained, cutoff: cutoff)
            }
        }
        _ = fsync(retained)
        try verifyDirectory(retained, parent: claudeFD, name: "Retained")
        try revalidate()
        return left
    }

    /// The descriptor pins the directory, so a rename cannot redirect the
    /// unlink. Only a directory holding nothing but its `claude` file goes;
    /// anything else inside leaves it whole, because a copy without its binary
    /// would block that version's import for good. No recursion.
    private func removeRetainedCopy(_ name: String, parent: Int32) -> Bool {
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return false }
        defer { close(directory) }
        do {
            try verifyDirectory(directory, parent: parent, name: name)
            let contents = try entryNames(in: directory)
            guard contents.allSatisfy({ $0 == "claude" }) else { return false }
            if !contents.isEmpty {
                guard try Self.entry(directory, "claude").st_mode & S_IFMT == S_IFREG,
                      unlinkat(directory, "claude", 0) == 0 else { return false }
            }
            try verifyDirectory(directory, parent: parent, name: name)
            return unlinkat(parent, name, AT_REMOVEDIR) == 0
        } catch { return false }
    }

    /// Receipts stay; only snapshot temporaries a crash left inside them go.
    private func sweepChecks(in retained: Int32, cutoff: time_t) -> Int {
        let checks = openat(retained, "Checks", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard checks >= 0 else { return 1 }
        defer { close(checks) }
        let names: [String]
        do {
            try verifyDirectory(checks, parent: retained, name: "Checks")
            names = try entryNames(in: checks)
        } catch { return 1 }
        var left = 0
        for name in names where Self.isDigest(name) {
            let directory = openat(checks, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { left += 1; continue }
            defer { close(directory) }
            do { try verifyDirectory(directory, parent: checks, name: name) } catch { left += 1; continue }
            left += sweepSnapshotTemporaries(in: directory, cutoff: cutoff)
        }
        return left
    }

    /// Only regular files named exactly as `writeAtomic` names its temporaries.
    private func sweepSnapshotTemporaries(in directory: Int32, cutoff: time_t) -> Int {
        guard let names = try? entryNames(in: directory) else { return 1 }
        var left = 0
        for name in names where name.hasPrefix(".runtime-state-") && name.hasSuffix(".tmp")
            && UUID(uuidString: String(name.dropFirst(15).dropLast(4))) != nil {
            guard let value = try? Self.entry(directory, name), value.st_mode & S_IFMT == S_IFREG,
                  Self.isLeftover(value, cutoff: cutoff) else { continue }
            if unlinkat(directory, name, 0) != 0 { left += 1 }
        }
        return left
    }

    private func entryNames(in directory: Int32) throws -> [String] {
        let copy = dup(directory)
        guard copy >= 0 else { throw ClaudeRuntimeStoreError.unavailable }
        guard let stream = fdopendir(copy) else { close(copy); throw ClaudeRuntimeStoreError.unavailable }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    private static func isDigest(_ name: String) -> Bool {
        name.count == 64 && name.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func isLeftover(_ value: stat, cutoff: time_t) -> Bool {
        max(value.st_birthtimespec.tv_sec, value.st_mtimespec.tv_sec) < cutoff
    }

    private func retainedDirectory(create: Bool) throws -> Int32 {
        if create {
            if mkdirat(claudeFD, "Retained", 0o700) != 0 && errno != EEXIST { throw ClaudeRuntimeStoreError.unavailable }
            guard fsync(claudeFD) == 0 else { throw ClaudeRuntimeStoreError.unavailable }
        }
        let fd = openat(claudeFD, "Retained", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ClaudeRuntimeStoreError.unsafeEntry }
        do { try verifyDirectory(fd, parent: claudeFD, name: "Retained"); return fd }
        catch { close(fd); throw error }
    }

    private func append(_ name: String, protected: Bool) throws {
        guard name != ".", name != "..", !name.isEmpty else { throw ClaudeRuntimeStoreError.unsafeEntry }
        let parent = claudeFD
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ClaudeRuntimeStoreError.unsafeEntry }
        do {
            let value = try Self.metadata(fd)
            if protected { try Self.validateDirectory(value) }
            guard Self.sameObject(value, try Self.entry(parent, name)) else { throw ClaudeRuntimeStoreError.changedIdentity }
            directories.append(Directory(fd: fd, parent: parent, name: name, metadata: value))
        } catch { close(fd); throw error }
    }

    private func revalidate() throws {
        for directory in directories {
            guard Self.sameObject(directory.metadata, try Self.metadata(directory.fd)) else { throw ClaudeRuntimeStoreError.changedIdentity }
            if let parent = directory.parent, let name = directory.name,
               !Self.sameObject(directory.metadata, try Self.entry(parent, name)) { throw ClaudeRuntimeStoreError.changedIdentity }
        }
        guard let marker else { throw ClaudeRuntimeStoreError.rootMismatch }
        try unchanged(marker.fd, parent: marker.parent, name: ".openbots-root.json", before: marker.metadata)
        guard try read(marker.fd, maximum: 4_096) == marker.data else { throw ClaudeRuntimeStoreError.rootMismatch }
        guard Self.sameObject(try Self.metadata(lockFD), try Self.entry(claudeFD, ".runtime-state.lock")) else {
            throw ClaudeRuntimeStoreError.changedIdentity
        }
    }

    private func verifyDirectory(_ fd: Int32, parent: Int32, name: String) throws {
        let value = try Self.metadata(fd)
        try Self.validateDirectory(value)
        guard Self.sameObject(value, try Self.entry(parent, name)) else { throw ClaudeRuntimeStoreError.changedIdentity }
    }

    private static func validateDirectory(_ value: stat) throws {
        guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == geteuid(), value.st_mode & 0o7777 == 0o700 else {
            throw ClaudeRuntimeStoreError.unsafeEntry
        }
    }

    private static func validateFile(_ value: stat, mode: mode_t?, maximum: Int64) throws {
        guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(), value.st_nlink == 1,
              value.st_mode & (0o022 | S_ISUID | S_ISGID) == 0,
              value.st_size >= 0, value.st_size <= maximum,
              mode == nil || value.st_mode & 0o7777 == mode else { throw ClaudeRuntimeStoreError.unsafeEntry }
    }

    private func openFile(_ name: String, parent: Int32, mode: mode_t?, maximum: Int64) throws -> (fd: Int32, metadata: stat) {
        let before = try Self.entry(parent, name)
        try Self.validateFile(before, mode: mode, maximum: maximum)
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ClaudeRuntimeStoreError.unsafeEntry }
        do {
            try unchanged(fd, parent: parent, name: name, before: before)
            return (fd, before)
        } catch { close(fd); throw error }
    }

    private func unchanged(_ fd: Int32, parent: Int32, name: String, before: stat, allowChangeTime: Bool = false) throws {
        for after in [try Self.metadata(fd), try Self.entry(parent, name)] {
            guard Self.sameObject(before, after), before.st_size == after.st_size, before.st_nlink == after.st_nlink,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  allowChangeTime || (before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
                    && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec) else {
                throw ClaudeRuntimeStoreError.changedIdentity
            }
        }
    }

    private static func sameObject(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_mode == b.st_mode
    }

    private static func metadata(_ fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw ClaudeRuntimeStoreError.unavailable }
        return value
    }

    private static func entry(_ parent: Int32, _ name: String) throws -> stat {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw ClaudeRuntimeStoreError.unavailable }
        return value
    }

    private func openAbsoluteDirectory(_ url: URL) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ClaudeRuntimeStoreError.unavailable }
        do {
            for name in url.pathComponents.dropFirst() {
                guard name != ".", name != ".." else { throw ClaudeRuntimeStoreError.unsafeEntry }
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ClaudeRuntimeStoreError.unsafeEntry }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }

    private func read(_ fd: Int32, maximum: Int) throws -> Data {
        let count = try Self.metadata(fd).st_size
        guard count >= 0, count <= maximum else { throw ClaudeRuntimeStoreError.unsafeEntry }
        var data = Data(count: Int(count)); var offset = 0
        while offset < data.count {
            let result = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset, off_t(offset)) }
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw ClaudeRuntimeStoreError.changedIdentity }
            offset += result
        }
        return data
    }

    private func hash(_ fd: Int32) throws -> String {
        var hasher = SHA256(); var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(offset)) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ClaudeRuntimeStoreError.unavailable }
            if count == 0 { break }
            guard Int64(count) <= maximumBytes - offset else { throw ClaudeRuntimeStoreError.invalidArtifact }
            hasher.update(data: Data(buffer.prefix(count))); offset += Int64(count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func write(_ data: Data, fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ClaudeRuntimeStoreError.unavailable }
            offset += count
        }
    }
}
