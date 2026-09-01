import CryptoKit
import Darwin
import Foundation
import Security

public enum ClaudeInstallationRejection: String, Equatable, Sendable {
    case unsupportedLocation
    case symbolicLinkCycle
    case tooManySymbolicLinks
    case unexpectedFileType
    case unsafeOwnership
    case unsafePermissions
    case notExecutable
    case unsupportedExecutable
    case executableTooLarge
    case changedDuringInspection
    case invalidSignature
    case unexpectedSigner
}

public enum ClaudeInstallationUnavailableReason: Equatable, Sendable {
    case invalidHomeDirectory
    case invalidPolicy
    case fileSystem(code: Int32)
    case signatureCheck(code: Int32)
    case cancelled
}

public enum ClaudeInstallationState: Equatable, Sendable {
    case missing
    case verified
    case rejected(ClaudeInstallationRejection)
    case unavailable(ClaudeInstallationUnavailableReason)
}

public struct ClaudeStaticSignatureIdentity: Equatable, Sendable {
    public let identifier: String
    public let teamIdentifier: String
    /// Kernel-derived CodeDirectory hash for the same open file descriptor
    /// whose full bytes were hashed by the installation inspector.
    public let codeDirectoryHash: String?

    public init(identifier: String, teamIdentifier: String, codeDirectoryHash: String? = nil) {
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.codeDirectoryHash = codeDirectoryHash
    }
}

public struct ClaudeInstallationFileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let byteCount: Int64

    public init(device: UInt64, inode: UInt64, byteCount: Int64) {
        self.device = device
        self.inode = inode
        self.byteCount = byteCount
    }
}

/// Nonsecret observations, not a credential, subscription, or launch authorization.
public struct ClaudeInstallationDetails: Equatable, Sendable {
    public let requestedPath: String
    public var resolvedPath: String?
    /// The filename is descriptive only; it is not a verified `claude --version` result.
    public var versionFilename: String?
    public var sha256: String?
    public var signature: ClaudeStaticSignatureIdentity?
    public var fileIdentity: ClaudeInstallationFileIdentity?

    public init(
        requestedPath: String,
        resolvedPath: String? = nil,
        versionFilename: String? = nil,
        sha256: String? = nil,
        signature: ClaudeStaticSignatureIdentity? = nil,
        fileIdentity: ClaudeInstallationFileIdentity? = nil
    ) {
        self.requestedPath = requestedPath
        self.resolvedPath = resolvedPath
        self.versionFilename = versionFilename
        self.sha256 = sha256
        self.signature = signature
        self.fileIdentity = fileIdentity
    }
}

public struct ClaudeInstallationInspection: Equatable, Sendable {
    public let state: ClaudeInstallationState
    public let details: ClaudeInstallationDetails

    public init(state: ClaudeInstallationState, details: ClaudeInstallationDetails) {
        self.state = state
        self.details = details
    }
}

public protocol ClaudeInstallationInspecting: Sendable {
    func inspectInstallation() async -> ClaudeInstallationInspection
}

public enum ClaudeStaticSignatureCheck: Equatable, Sendable {
    case verified(ClaudeStaticSignatureIdentity)
    case rejected
    case unavailable(code: Int32)
}

public protocol ClaudeStaticSignatureChecking: Sendable {
    /// Inspect static code only. Implementations must bind the path-based trust
    /// result to `openedDescriptor`, which is the exact file already hashed by
    /// the caller. They must not launch code or use the network.
    func checkSignature(at executableURL: URL, openedDescriptor: Int32) -> ClaudeStaticSignatureCheck
}

public struct NativeClaudeStaticSignatureChecker: ClaudeStaticSignatureChecking {
    public init() {}

    // kSecCSNoNetworkAccess (CSCommon.h) disables online revocation/notarization
    // requests. The other flags verify all Mach-O architectures and strict seals.
    static let validationFlags = SecCSFlags(
        rawValue: (1 << 29) | kSecCSCheckAllArchitectures | kSecCSStrictValidate
    )

    public func checkSignature(at executableURL: URL, openedDescriptor: Int32) -> ClaudeStaticSignatureCheck {
        guard let descriptorHash = Self.codeDirectoryHash(of: openedDescriptor) else {
            return .rejected
        }
        var code: SecStaticCode?
        let creation = SecStaticCodeCreateWithPath(executableURL as CFURL, [], &code)
        guard creation == errSecSuccess, let code else {
            return creation == errSecCSUnsigned ? .rejected : .unavailable(code: creation)
        }

        let expression = "anchor apple generic and identifier \"com.anthropic.claude-code\" and certificate leaf[subject.OU] = \"Q6L2SF6YDW\""
        var requirement: SecRequirement?
        let compilation = SecRequirementCreateWithString(expression as CFString, [], &requirement)
        guard compilation == errSecSuccess, let requirement else {
            return .unavailable(code: compilation)
        }
        guard SecStaticCodeCheckValidity(code, Self.validationFlags, requirement) == errSecSuccess else {
            return .rejected
        }

        var information: CFDictionary?
        let copied = SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        )
        guard copied == errSecSuccess, let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              let staticHash = values[kSecCodeInfoUnique as String] as? Data,
              staticHash.count == USER_FSIGNATURES_CDHASH_LEN else {
            return .unavailable(code: copied == errSecSuccess ? errSecInternalComponent : copied)
        }
        let staticHashText = staticHash.map { String(format: "%02x", $0) }.joined()
        guard staticHashText == descriptorHash else { return .rejected }
        return .verified(ClaudeStaticSignatureIdentity(
            identifier: identifier,
            teamIdentifier: team,
            codeDirectoryHash: descriptorHash
        ))
    }

    /// Ask the kernel for the embedded CodeDirectory identity on the already
    /// opened vnode. This does not execute the file or touch provider state.
    /// Matching it to Security.framework's validated path result prevents a
    /// swap-and-restore path from lending its signer to different open bytes.
    static func codeDirectoryHash(of descriptor: Int32) -> String? {
        var signatures = fsignatures_t()
        signatures.fs_file_start = 0
        signatures.fs_fsignatures_size = MemoryLayout<fsignatures_t>.size
        guard fcntl(descriptor, F_ADDFILESIGS_INFO, &signatures) == 0 else { return nil }
        return withUnsafeBytes(of: &signatures.fs_cdhash) { bytes in
            bytes.prefix(Int(USER_FSIGNATURES_CDHASH_LEN)).map { String(format: "%02x", $0) }.joined()
        }
    }
}

/// Reads only the supported native installation under one explicit home directory.
/// Construction performs no I/O. Every inspection is a fresh observation, never
/// permission to launch later; a later authorized operation must revalidate it.
public struct ClaudeInstallationInspector: ClaudeInstallationInspecting {
    public static let expectedIdentifier = "com.anthropic.claude-code"
    public static let expectedTeamIdentifier = "Q6L2SF6YDW"
    public static let maximumExecutableBytes: Int64 = 512 * 1_024 * 1_024
    public static let maximumSymbolicLinks = 8

    private let homeDirectory: URL
    private let signatureChecker: any ClaudeStaticSignatureChecking
    private let expectedUserID: uid_t
    private let maximumBytes: Int64

    public init(
        homeDirectory: URL,
        signatureChecker: any ClaudeStaticSignatureChecking = NativeClaudeStaticSignatureChecker()
    ) {
        self.init(
            homeDirectory: homeDirectory,
            signatureChecker: signatureChecker,
            expectedUserID: geteuid(),
            maximumBytes: Self.maximumExecutableBytes
        )
    }

    init(
        homeDirectory: URL,
        signatureChecker: any ClaudeStaticSignatureChecking,
        expectedUserID: uid_t,
        maximumBytes: Int64 = Self.maximumExecutableBytes
    ) {
        self.homeDirectory = homeDirectory
        self.signatureChecker = signatureChecker
        self.expectedUserID = expectedUserID
        self.maximumBytes = maximumBytes
    }

    public func inspectInstallation() async -> ClaudeInstallationInspection {
        let requested = homeDirectory.appending(path: ".local/bin/claude")
        var details = ClaudeInstallationDetails(requestedPath: requested.path)
        do {
            try Task.checkCancellation()
            guard homeDirectory.isFileURL,
                  homeDirectory.path.hasPrefix("/"),
                  homeDirectory.path != "/",
                  Self.lexicalURL(homeDirectory).path == homeDirectory.path else {
                throw InspectionFailure.unavailable(.invalidHomeDirectory)
            }
            guard maximumBytes >= 4 else {
                throw InspectionFailure.unavailable(.invalidPolicy)
            }
            let session = InspectionSession(expectedUserID: expectedUserID)
            let homeFD = try session.openHome(homeDirectory)
            let localFD = try session.openChild(".local", beneath: homeFD, at: homeDirectory)
            let localURL = homeDirectory.appending(path: ".local")
            let binFD = try session.openChild("bin", beneath: localFD, at: localURL)

            let initialLink = try session.readLink("claude", beneath: binFD)
            let versionsURL = localURL.appending(path: "share/claude/versions")
            var target = try Self.target(of: initialLink, relativeTo: requested, within: versionsURL)
            var visited: Set<String> = [requested.path]
            if visited.contains(target.path) { throw InspectionFailure.rejected(.symbolicLinkCycle) }

            let shareFD = try session.openChild("share", beneath: localFD, at: localURL)
            let claudeFD = try session.openChild("claude", beneath: shareFD, at: localURL.appending(path: "share"))
            let versionsFD = try session.openChild("versions", beneath: claudeFD, at: localURL.appending(path: "share/claude"))
            var linkCount = 1
            while true {
                try Task.checkCancellation()
                guard visited.insert(target.path).inserted else {
                    throw InspectionFailure.rejected(.symbolicLinkCycle)
                }
                let metadata = try session.metadata(target.lastPathComponent, beneath: versionsFD)
                guard metadata.st_mode & S_IFMT == S_IFLNK else { break }
                guard linkCount < Self.maximumSymbolicLinks else {
                    throw InspectionFailure.rejected(.tooManySymbolicLinks)
                }
                let link = try session.readLink(target.lastPathComponent, beneath: versionsFD)
                target = try Self.target(of: link, relativeTo: target, within: versionsURL)
                linkCount += 1
            }

            details.resolvedPath = target.path
            details.versionFilename = target.lastPathComponent
            let executableFD = try session.openExecutable(target.lastPathComponent, beneath: versionsFD)
            let before = try session.executableMetadata(executableFD, maximumBytes: maximumBytes)
            details.fileIdentity = ClaudeInstallationFileIdentity(
                device: UInt64(before.st_dev), inode: UInt64(before.st_ino), byteCount: before.st_size
            )
            details.sha256 = try Self.hashExecutable(executableFD, maximumBytes: maximumBytes)
            try session.revalidate()
            try session.requireUnchanged(executableFD, name: target.lastPathComponent, beneath: versionsFD, previous: before)
            try Task.checkCancellation()
            switch signatureChecker.checkSignature(at: target, openedDescriptor: executableFD) {
            case .verified(let signature):
                details.signature = signature
                guard signature.identifier == Self.expectedIdentifier,
                      signature.teamIdentifier == Self.expectedTeamIdentifier else {
                    throw InspectionFailure.rejected(.unexpectedSigner)
                }
            case .rejected:
                throw InspectionFailure.rejected(.invalidSignature)
            case .unavailable(let code):
                throw InspectionFailure.unavailable(.signatureCheck(code: code))
            }
            try Task.checkCancellation()
            try session.revalidate()
            try session.requireUnchanged(executableFD, name: target.lastPathComponent, beneath: versionsFD, previous: before)
            return ClaudeInstallationInspection(state: .verified, details: details)
        } catch InspectionFailure.missing {
            return ClaudeInstallationInspection(state: .missing, details: details)
        } catch InspectionFailure.rejected(let issue) {
            return ClaudeInstallationInspection(state: .rejected(issue), details: details)
        } catch InspectionFailure.unavailable(let issue) {
            return ClaudeInstallationInspection(state: .unavailable(issue), details: details)
        } catch is CancellationError {
            return ClaudeInstallationInspection(state: .unavailable(.cancelled), details: details)
        } catch {
            return ClaudeInstallationInspection(state: .unavailable(.fileSystem(code: EIO)), details: details)
        }
    }

    private static func target(of link: String, relativeTo source: URL, within versions: URL) throws -> URL {
        let target = link.hasPrefix("/")
            ? URL(fileURLWithPath: link)
            : source.deletingLastPathComponent().appending(path: link)
        let normalized = lexicalURL(target)
        if normalized.path == source.path { throw InspectionFailure.rejected(.symbolicLinkCycle) }
        guard normalized.deletingLastPathComponent().path == versions.path,
              !normalized.lastPathComponent.isEmpty else {
            throw InspectionFailure.rejected(.unsupportedLocation)
        }
        return normalized
    }

    /// Foundation standardization can rewrite `/private/tmp` through `/tmp`.
    /// Collapse only lexical dot components here; the descriptor walk below is
    /// solely responsible for rejecting filesystem symlinks and unsafe owners.
    private static func lexicalURL(_ url: URL) -> URL {
        var components: [String] = []
        for component in url.pathComponents {
            switch component {
            case "/", ".", "": continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: url.hasDirectoryPath)
    }

    // The same predicate accepts observed POSIX metadata in production and
    // synthetic metadata in tests on hosts that strip set-user/group-ID bits.
    static func metadataRejection(owner: uid_t, mode: mode_t, expectedUserID: uid_t) -> ClaudeInstallationRejection? {
        guard owner == expectedUserID else { return .unsafeOwnership }
        guard mode & 0o022 == 0, mode & (S_ISUID | S_ISGID) == 0 else { return .unsafePermissions }
        return nil
    }

    private static func hashExecutable(_ descriptor: Int32, maximumBytes: Int64) throws -> String {
        var header = [UInt8](repeating: 0, count: 4)
        let headerCount = header.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, 4, 0) }
        guard headerCount == 4 else { throw InspectionFailure.rejected(.unsupportedExecutable) }
        let machOMagic: [[UInt8]] = [
            [0xCE, 0xFA, 0xED, 0xFE], [0xCF, 0xFA, 0xED, 0xFE],
            [0xFE, 0xED, 0xFA, 0xCE], [0xFE, 0xED, 0xFA, 0xCF],
            [0xCA, 0xFE, 0xBA, 0xBE], [0xCA, 0xFE, 0xBA, 0xBF],
            [0xBE, 0xBA, 0xFE, 0xCA], [0xBF, 0xBA, 0xFE, 0xCA]
        ]
        guard machOMagic.contains(header) else { throw InspectionFailure.rejected(.unsupportedExecutable) }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw InspectionFailure.unavailable(.fileSystem(code: errno))
            }
            guard Int64(count) <= maximumBytes - total else {
                throw InspectionFailure.rejected(.executableTooLarge)
            }
            hasher.update(data: Data(buffer.prefix(count)))
            total += Int64(count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private enum InspectionFailure: Error {
    case missing
    case rejected(ClaudeInstallationRejection)
    case unavailable(ClaudeInstallationUnavailableReason)
}

private struct FileObservation: Equatable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let mode: mode_t
    let size: off_t
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        owner = value.st_uid
        mode = value.st_mode
        size = value.st_size
        modificationSeconds = value.st_mtimespec.tv_sec
        modificationNanoseconds = value.st_mtimespec.tv_nsec
        changeSeconds = value.st_ctimespec.tv_sec
        changeNanoseconds = value.st_ctimespec.tv_nsec
    }
}

/// Per-call descriptors prevent reads through replaced symlinks. Path observations
/// are checked again around Security's path-based static-code API, whose validated
/// CodeDirectory hash is also matched to the exact open executable descriptor.
private final class InspectionSession {
    let expectedUserID: uid_t
    private var descriptors: [Int32] = []
    private var directories: [(URL, FileObservation)] = []
    private var links: [(Int32, String, FileObservation)] = []

    init(expectedUserID: uid_t) { self.expectedUserID = expectedUserID }
    deinit { for descriptor in descriptors { close(descriptor) } }

    func openHome(_ url: URL) throws -> Int32 {
        let descriptor = try openAbsoluteDirectory(url)
        descriptors.append(descriptor)
        try recordDirectory(descriptor, at: url)
        return descriptor
    }

    func openChild(_ name: String, beneath parent: Int32, at parentURL: URL) throws -> Int32 {
        let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw failureForErrno() }
        descriptors.append(descriptor)
        try recordDirectory(descriptor, at: parentURL.appending(path: name))
        return descriptor
    }

    func metadata(_ name: String, beneath parent: Int32) throws -> stat {
        var value = stat()
        guard name.withCString({ fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw failureForErrno()
        }
        return value
    }

    func readLink(_ name: String, beneath parent: Int32) throws -> String {
        let before = try metadata(name, beneath: parent)
        guard before.st_mode & S_IFMT == S_IFLNK else { throw InspectionFailure.rejected(.unexpectedFileType) }
        guard before.st_uid == expectedUserID else { throw InspectionFailure.rejected(.unsafeOwnership) }
        var buffer = [UInt8](repeating: 0, count: 4_097)
        let count = name.withCString { name in
            buffer.withUnsafeMutableBytes {
                readlinkat(parent, name, $0.bindMemory(to: CChar.self).baseAddress, $0.count)
            }
        }
        guard count > 0, count <= 4_096,
              let target = String(bytes: buffer.prefix(count), encoding: .utf8),
              !target.contains("\0") else { throw InspectionFailure.rejected(.unsupportedLocation) }
        guard FileObservation(before) == FileObservation(try metadata(name, beneath: parent)) else {
            throw InspectionFailure.rejected(.changedDuringInspection)
        }
        links.append((parent, name, FileObservation(before)))
        return target
    }

    func openExecutable(_ name: String, beneath parent: Int32) throws -> Int32 {
        let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard descriptor >= 0 else { throw failureForErrno() }
        descriptors.append(descriptor)
        return descriptor
    }

    func executableMetadata(_ descriptor: Int32, maximumBytes: Int64) throws -> stat {
        let value = try inspect(descriptor)
        guard value.st_mode & S_IFMT == S_IFREG else { throw InspectionFailure.rejected(.unexpectedFileType) }
        try validateOwnerAndPermissions(value)
        guard value.st_mode & S_IXUSR != 0 else { throw InspectionFailure.rejected(.notExecutable) }
        guard value.st_size >= 4 else { throw InspectionFailure.rejected(.unsupportedExecutable) }
        guard value.st_size <= maximumBytes else { throw InspectionFailure.rejected(.executableTooLarge) }
        return value
    }

    func requireUnchanged(_ descriptor: Int32, name: String, beneath parent: Int32, previous: stat) throws {
        guard FileObservation(previous) == FileObservation(try inspect(descriptor)),
              FileObservation(previous) == FileObservation(try metadata(name, beneath: parent)) else {
            throw InspectionFailure.rejected(.changedDuringInspection)
        }
    }

    func revalidate() throws {
        for (url, previous) in directories {
            try Task.checkCancellation()
            let descriptor: Int32
            do { descriptor = try openAbsoluteDirectory(url) }
            catch { throw InspectionFailure.rejected(.changedDuringInspection) }
            defer { close(descriptor) }
            guard previous == FileObservation(try inspect(descriptor)) else {
                throw InspectionFailure.rejected(.changedDuringInspection)
            }
        }
        for (parent, name, previous) in links {
            guard previous == FileObservation(try metadata(name, beneath: parent)) else {
                throw InspectionFailure.rejected(.changedDuringInspection)
            }
        }
    }

    private func recordDirectory(_ descriptor: Int32, at url: URL) throws {
        let value = try inspect(descriptor)
        guard value.st_mode & S_IFMT == S_IFDIR else { throw InspectionFailure.rejected(.unexpectedFileType) }
        try validateOwnerAndPermissions(value)
        directories.append((url, FileObservation(value)))
    }

    private func validateOwnerAndPermissions(_ value: stat) throws {
        if let rejection = ClaudeInstallationInspector.metadataRejection(
            owner: value.st_uid, mode: value.st_mode, expectedUserID: expectedUserID
        ) {
            throw InspectionFailure.rejected(rejection)
        }
    }

    private func inspect(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw failureForErrno() }
        return value
    }

    private func openAbsoluteDirectory(_ url: URL) throws -> Int32 {
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw failureForErrno() }
        do {
            for component in url.pathComponents.dropFirst() {
                guard !component.isEmpty, component != ".", component != ".." else {
                    throw InspectionFailure.unavailable(.invalidHomeDirectory)
                }
                let next = component.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                guard next >= 0 else { throw failureForErrno() }
                close(current)
                current = next
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    private func failureForErrno() -> InspectionFailure {
        switch errno {
        case ENOENT: .missing
        case ELOOP, ENOTDIR: .rejected(.unexpectedFileType)
        default: .unavailable(.fileSystem(code: errno))
        }
    }
}
