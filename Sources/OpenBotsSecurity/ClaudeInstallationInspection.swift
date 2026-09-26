import CryptoKit
import Darwin
import Foundation
import MachO
import MachO.dyld.utils
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
        guard let location = ClaudeMachOSignatureParser.location(in: openedDescriptor),
              let descriptorHash = Self.codeDirectoryHash(of: openedDescriptor, location: location) else {
            return .rejected
        }
        var code: SecStaticCode?
        // Select the same slice for path validation and descriptor identity.
        // Strict validation below still checks every architecture's seal.
        let attributes = [
            kSecCodeAttributeArchitecture as String: NSNumber(value: location.cpuType),
            kSecCodeAttributeSubarchitecture as String: NSNumber(value: location.cpuSubtype)
        ] as CFDictionary
        let creation = SecStaticCodeCreateWithPathAndAttributes(executableURL as CFURL, [], attributes, &code)
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
        guard let location = ClaudeMachOSignatureParser.location(in: descriptor) else { return nil }
        return codeDirectoryHash(of: descriptor, location: location)
    }

    private static func codeDirectoryHash(of descriptor: Int32, location: ClaudeMachOSignatureLocation) -> String? {
        var signatures = fsignatures_t()
        signatures.fs_file_start = off_t(location.sliceOffset)
        // F_ADDFILESIGS_INFO interprets this pointer value as a file offset,
        // relative to fs_file_start, not as an address to userspace bytes.
        signatures.fs_blob_start = UnsafeMutableRawPointer(bitPattern: location.dataOffset)
        signatures.fs_blob_size = location.dataSize
        signatures.fs_fsignatures_size = MemoryLayout<fsignatures_t>.size
        guard fcntl(descriptor, F_ADDFILESIGS_INFO, &signatures) == 0 else { return nil }
        return withUnsafeBytes(of: &signatures.fs_cdhash) { bytes in
            let hash = bytes.prefix(Int(USER_FSIGNATURES_CDHASH_LEN))
            guard hash.contains(where: { $0 != 0 }) else { return nil }
            return hash.map { String(format: "%02x", $0) }.joined()
        }
    }
}

struct ClaudeMachOSignatureLocation: Equatable {
    let sliceOffset: Int
    let dataOffset: Int
    let dataSize: Int
    let cpuType: Int32
    let cpuSubtype: Int32
}

/// Reads bounded headers from the already-hashed descriptor using pread; the
/// caller's EOF position is unchanged. The kernel verifies the signature blob.
/// Offsets alone never establish trust, and no path is reopened by this parser.
enum ClaudeMachOSignatureParser {
    private struct Slice {
        let offset: Int
        let size: Int
        let cpuType: Int32?
        let cpuSubtype: Int32?
    }

    static func location(in descriptor: Int32) -> ClaudeMachOSignatureLocation? {
        location(in: descriptor, selectingSliceAt: nil)
    }

    // Explicit selection is an internal parser-fixture seam. Production uses
    // Apple's native fd-based selector for universal binaries.
    static func location(in descriptor: Int32, selectingSliceAt selectedOffset: Int?) -> ClaudeMachOSignatureLocation? {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 4, metadata.st_size <= ClaudeInstallationInspector.maximumExecutableBytes,
              let prefix = read(descriptor, offset: 0, count: 4) else { return nil }
        let fileSize = Int(metadata.st_size)
        let magic = uint32(prefix, 0, littleEndian: false)
        let slice: Slice
        if [UInt32(0xcafebabe), 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) {
            let little = magic == 0xbebafeca || magic == 0xbfbafeca
            let wide = magic == 0xcafebabf || magic == 0xbfbafeca
            guard let header = read(descriptor, offset: 0, count: 8) else { return nil }
            let count = Int(uint32(header, 4, littleEndian: little)), entrySize = wide ? 32 : 20
            guard count > 0, count <= 64 else { return nil }
            let tableEnd = 8 + count * entrySize
            guard tableEnd <= fileSize, let table = read(descriptor, offset: 8, count: count * entrySize) else { return nil }
            var slices: [Slice] = []
            for index in 0..<count {
                let position = index * entrySize
                let offset = wide ? uint64(table, position + 8, littleEndian: little)
                    : UInt64(uint32(table, position + 8, littleEndian: little))
                let size = wide ? uint64(table, position + 16, littleEndian: little)
                    : UInt64(uint32(table, position + 12, littleEndian: little))
                let alignment = uint32(table, position + (wide ? 24 : 16), littleEndian: little)
                guard offset >= UInt64(tableEnd), size >= 28, offset <= UInt64(fileSize),
                      size <= UInt64(fileSize) - offset, alignment <= 30,
                      offset % (UInt64(1) << alignment) == 0,
                      !wide || uint32(table, position + 28, littleEndian: little) == 0 else { return nil }
                let candidate = Slice(offset: Int(offset), size: Int(size),
                    cpuType: Int32(bitPattern: uint32(table, position, littleEndian: little)),
                    cpuSubtype: Int32(bitPattern: uint32(table, position + 4, littleEndian: little)))
                guard !slices.contains(where: {
                    ($0.cpuType == candidate.cpuType && $0.cpuSubtype == candidate.cpuSubtype)
                        || (candidate.offset < $0.offset + $0.size && $0.offset < candidate.offset + candidate.size)
                }) else { return nil }
                slices.append(candidate)
            }
            if let selectedOffset {
                guard let selected = slices.first(where: { $0.offset == selectedOffset }) else { return nil }
                slice = selected
            } else {
                var nativeOffset: UInt64?, nativeSize: Int?
                guard macho_best_slice_in_fd(descriptor, { _, offset, size in
                    nativeOffset = offset
                    nativeSize = size
                }) == 0, let nativeOffset, let nativeSize,
                      let selected = slices.first(where: { UInt64($0.offset) == nativeOffset && $0.size == nativeSize }) else { return nil }
                slice = selected
            }
        } else {
            guard selectedOffset == nil || selectedOffset == 0 else { return nil }
            slice = Slice(offset: 0, size: fileSize, cpuType: nil, cpuSubtype: nil)
        }
        return thinLocation(in: descriptor, slice: slice)
    }

    private static func thinLocation(in descriptor: Int32, slice: Slice) -> ClaudeMachOSignatureLocation? {
        guard let prefix = read(descriptor, offset: slice.offset, count: 4) else { return nil }
        let magic = uint32(prefix, 0, littleEndian: false)
        guard [UInt32(0xfeedface), 0xcefaedfe, 0xfeedfacf, 0xcffaedfe].contains(magic) else { return nil }
        let little = magic == 0xcefaedfe || magic == 0xcffaedfe
        let wide = magic == 0xfeedfacf || magic == 0xcffaedfe
        let headerSize = wide ? 32 : 28
        guard slice.size >= headerSize, let header = read(descriptor, offset: slice.offset, count: headerSize) else { return nil }
        let cpuType = Int32(bitPattern: uint32(header, 4, littleEndian: little))
        let cpuSubtype = Int32(bitPattern: uint32(header, 8, littleEndian: little))
        guard (slice.cpuType == nil || slice.cpuType == cpuType),
              (slice.cpuSubtype == nil || slice.cpuSubtype == cpuSubtype) else { return nil }
        let count = Int(uint32(header, 16, littleEndian: little))
        let size = Int(uint32(header, 20, littleEndian: little))
        guard count > 0, count <= 4_096, size >= count * 8, size <= 1_024 * 1_024,
              size <= slice.size - headerSize,
              let commands = read(descriptor, offset: slice.offset + headerSize, count: size) else { return nil }
        var cursor = 0
        var result: ClaudeMachOSignatureLocation?
        for _ in 0..<count {
            guard cursor <= size - 8 else { return nil }
            let command = uint32(commands, cursor, littleEndian: little)
            let commandSize = Int(uint32(commands, cursor + 4, littleEndian: little))
            guard commandSize >= 8, commandSize % (wide ? 8 : 4) == 0, commandSize <= size - cursor else { return nil }
            if command == UInt32(LC_CODE_SIGNATURE) {
                guard result == nil, commandSize == 16 else { return nil }
                let offset = Int(uint32(commands, cursor + 8, littleEndian: little))
                let signatureSize = Int(uint32(commands, cursor + 12, littleEndian: little))
                guard offset >= headerSize + size, signatureSize >= 8, signatureSize <= 40 * 1_024 * 1_024,
                      offset <= slice.size, signatureSize <= slice.size - offset else { return nil }
                result = ClaudeMachOSignatureLocation(sliceOffset: slice.offset, dataOffset: offset,
                    dataSize: signatureSize, cpuType: cpuType, cpuSubtype: cpuSubtype)
            }
            cursor += commandSize
        }
        return cursor == size ? result : nil
    }

    private static func read(_ descriptor: Int32, offset: Int, count: Int) -> Data? {
        guard offset >= 0, count > 0, count <= 1_024 * 1_024 else { return nil }
        var data = Data(count: count)
        let complete = data.withUnsafeMutableBytes { buffer -> Bool in
            var consumed = 0
            while consumed < count {
                let result = pread(descriptor, buffer.baseAddress!.advanced(by: consumed), count - consumed, off_t(offset + consumed))
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { return false }
                consumed += result
            }
            return true
        }
        return complete ? data : nil
    }

    private static func uint32(_ data: Data, _ offset: Int, littleEndian: Bool) -> UInt32 {
        (0..<4).reduce(0) { $0 | (UInt32(data[offset + $1]) << ((littleEndian ? $1 : 3 - $1) * 8)) }
    }

    private static func uint64(_ data: Data, _ offset: Int, littleEndian: Bool) -> UInt64 {
        (0..<8).reduce(0) { $0 | (UInt64(data[offset + $1]) << ((littleEndian ? $1 : 7 - $1) * 8)) }
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

    /// The same filesystem object with the same owner and mode, whatever it
    /// holds. For a folder whose other entries belong to other programs.
    func sameObject(as other: FileObservation) -> Bool {
        device == other.device && inode == other.inode && owner == other.owner && mode == other.mode
    }

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
    /// Each opened directory, and whether only its identity is checked again.
    private var directories: [(URL, FileObservation, identityOnly: Bool)] = []
    private var links: [(Int32, String, FileObservation)] = []

    init(expectedUserID: uid_t) { self.expectedUserID = expectedUserID }
    deinit { for descriptor in descriptors { close(descriptor) } }

    /// The home folder is checked again by identity only. Its size and times
    /// move whenever anything writes a file into it, and Claude Code rewrites
    /// `~/.claude.json` there: compared whole, a check straddling such a write
    /// was occasionally refused as changed, and a send failed with "Claude
    /// setup needs attention". Swapping
    /// `.local` out and back still changes `.local`'s own change time, which is
    /// compared whole.
    func openHome(_ url: URL) throws -> Int32 {
        let descriptor = try openAbsoluteDirectory(url)
        descriptors.append(descriptor)
        try recordDirectory(descriptor, at: url, identityOnly: true)
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
        for (url, previous, identityOnly) in directories {
            try Task.checkCancellation()
            let descriptor: Int32
            do { descriptor = try openAbsoluteDirectory(url) }
            catch { throw InspectionFailure.rejected(.changedDuringInspection) }
            defer { close(descriptor) }
            let current = FileObservation(try inspect(descriptor))
            guard identityOnly ? previous.sameObject(as: current) : previous == current else {
                throw InspectionFailure.rejected(.changedDuringInspection)
            }
        }
        for (parent, name, previous) in links {
            guard previous == FileObservation(try metadata(name, beneath: parent)) else {
                throw InspectionFailure.rejected(.changedDuringInspection)
            }
        }
    }

    private func recordDirectory(_ descriptor: Int32, at url: URL, identityOnly: Bool = false) throws {
        let value = try inspect(descriptor)
        guard value.st_mode & S_IFMT == S_IFDIR else { throw InspectionFailure.rejected(.unexpectedFileType) }
        try validateOwnerAndPermissions(value)
        directories.append((url, FileObservation(value), identityOnly: identityOnly))
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
