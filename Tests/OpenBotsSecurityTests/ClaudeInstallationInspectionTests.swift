import CryptoKit
import Darwin
import Foundation
import MachO
import MachO.dyld.utils
import Security
import Testing
@testable import OpenBotsSecurity

private final class SignatureCheckerSpy: ClaudeStaticSignatureChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var inspectedURLs: [URL] = []
    private let result: ClaudeStaticSignatureCheck
    private let onCheck: @Sendable (URL, Int32) -> Void

    init(
        result: ClaudeStaticSignatureCheck = .verified(ClaudeStaticSignatureIdentity(
            identifier: ClaudeInstallationInspector.expectedIdentifier,
            teamIdentifier: ClaudeInstallationInspector.expectedTeamIdentifier
        )),
        onCheck: @escaping @Sendable (URL, Int32) -> Void = { _, _ in }
    ) {
        self.result = result
        self.onCheck = onCheck
    }

    func checkSignature(at executableURL: URL, openedDescriptor: Int32) -> ClaudeStaticSignatureCheck {
        lock.withLock { inspectedURLs.append(executableURL) }
        onCheck(executableURL, openedDescriptor)
        return result
    }

    var calls: [URL] { lock.withLock { inspectedURLs } }
}

private struct InstallationFixture: Sendable {
    let home: URL
    let candidate: URL
    let versions: URL
    let executable: URL
    let payload: Data

    init(createInstallation: Bool = true, payload: Data? = nil) throws {
        home = URL(fileURLWithPath: "/private/tmp/OpenBotsClaudeInspection-\(UUID().uuidString).noindex")
        candidate = home.appending(path: ".local/bin/claude")
        versions = home.appending(path: ".local/share/claude/versions")
        executable = versions.appending(path: "2.1.88-fixture")
        self.payload = payload ?? Data([0xCF, 0xFA, 0xED, 0xFE] + Array("static test bytes only".utf8))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        if createInstallation {
            for component in [".local", ".local/bin", ".local/share", ".local/share/claude", ".local/share/claude/versions"] {
                try FileManager.default.createDirectory(
                    at: home.appending(path: component),
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try self.payload.write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            try FileManager.default.createSymbolicLink(
                atPath: candidate.path,
                withDestinationPath: "../share/claude/versions/\(executable.lastPathComponent)"
            )
        }
    }

    var digest: String { SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined() }

    func inspector(checker: any ClaudeStaticSignatureChecking = SignatureCheckerSpy()) -> ClaudeInstallationInspector {
        ClaudeInstallationInspector(homeDirectory: home, signatureChecker: checker)
    }

    func replaceCandidate(with destination: String) throws {
        try FileManager.default.removeItem(at: candidate)
        try FileManager.default.createSymbolicLink(atPath: candidate.path, withDestinationPath: destination)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

@Test("Claude installation construction performs no inspection or creation")
func claudeInstallationConstructionIsInert() throws {
    let fixture = try InstallationFixture(createInstallation: false)
    defer { fixture.remove() }
    let checker = SignatureCheckerSpy()
    _ = ClaudeInstallationInspector(homeDirectory: fixture.home, signatureChecker: checker)
    #expect(checker.calls.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path).isEmpty)
}

@Test("Missing supported installation does not search or use another executable")
func claudeInstallationHasNoFallback() async throws {
    let fixture = try InstallationFixture(createInstallation: false)
    defer { fixture.remove() }
    let unrelated = fixture.home.appending(path: "claude")
    try Data("unrelated executable must not be inspected".utf8).write(to: unrelated)
    let checker = SignatureCheckerSpy()
    let result = await fixture.inspector(checker: checker).inspectInstallation()
    #expect(result.state == .missing)
    #expect(result.details.requestedPath == fixture.candidate.path)
    #expect(result.details.resolvedPath == nil)
    #expect(checker.calls.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path) == ["claude"])
}

@Test("Signer-verified bytes and static identity produce only a file inspection receipt")
func claudeInstallationInspectsOnlyVerifiedPhysicalExecutable() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    let checker = SignatureCheckerSpy()
    let before = try Data(contentsOf: fixture.executable)
    let result = await fixture.inspector(checker: checker).inspectInstallation()
    #expect(result.state == .verified)
    #expect(result.details.requestedPath == fixture.candidate.path)
    #expect(result.details.resolvedPath == fixture.executable.path)
    #expect(result.details.versionFilename == fixture.executable.lastPathComponent)
    #expect(result.details.sha256 == fixture.digest)
    #expect(result.details.signature?.identifier == ClaudeInstallationInspector.expectedIdentifier)
    #expect(result.details.signature?.teamIdentifier == ClaudeInstallationInspector.expectedTeamIdentifier)
    #expect(result.details.fileIdentity?.byteCount == Int64(fixture.payload.count))
    #expect(checker.calls == [fixture.executable])
    #expect(try Data(contentsOf: fixture.executable) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.versions.path) == [fixture.executable.lastPathComponent])
}

@Test("Distinct signer-verified CLI payloads are admitted with separate SHA receipts")
func claudeInstallationAdmitsSignerVerifiedHashRotation() async throws {
    let payloads = [
        Data([0xCF, 0xFA, 0xED, 0xFE] + Array("signed release one".utf8)),
        Data([0xCF, 0xFA, 0xED, 0xFE] + Array("signed release two".utf8))
    ]
    var receipts: [String] = []

    for payload in payloads {
        let fixture = try InstallationFixture(payload: payload)
        defer { fixture.remove() }
        let checker = SignatureCheckerSpy()
        let result = await fixture.inspector(checker: checker).inspectInstallation()

        #expect(result.state == .verified)
        #expect(result.details.sha256 == fixture.digest)
        #expect(checker.calls == [fixture.executable])
        if let sha256 = result.details.sha256 { receipts.append(sha256) }
    }

    #expect(Set(receipts).count == payloads.count)
}

@Test("Static signature failures and wrong identities remain distinct", arguments: [
    ClaudeStaticSignatureCheck.rejected,
    .verified(ClaudeStaticSignatureIdentity(identifier: "other.cli", teamIdentifier: "Q6L2SF6YDW")),
    .verified(ClaudeStaticSignatureIdentity(identifier: "com.anthropic.claude-code", teamIdentifier: "OTHERTEAM")),
    .unavailable(code: -42)
])
func claudeInstallationRejectsSignatureFailures(_ signature: ClaudeStaticSignatureCheck) async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    let checker = SignatureCheckerSpy(result: signature)
    let result = await fixture.inspector(checker: checker).inspectInstallation()
    switch signature {
    case .verified: #expect(result.state == .rejected(.unexpectedSigner))
    case .rejected: #expect(result.state == .rejected(.invalidSignature))
    case .unavailable(let code): #expect(result.state == .unavailable(.signatureCheck(code: code)))
    }
    #expect(checker.calls == [fixture.executable])
}

@Test("Only bounded links inside the exact versions directory are followed")
func claudeInstallationAcceptsSupportedLinkChain() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    let current = fixture.versions.appending(path: "current")
    try FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: fixture.executable.lastPathComponent)
    try fixture.replaceCandidate(with: current.path)
    #expect(await fixture.inspector().inspectInstallation().state == .verified)
}

@Test("Links outside the supported directory are rejected without reading the target")
func claudeInstallationRejectsLinkEscape() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    let unrelated = fixture.home.appending(path: "do-not-read")
    try Data("private unrelated contents".utf8).write(to: unrelated)
    try fixture.replaceCandidate(with: unrelated.path)
    let checker = SignatureCheckerSpy()
    let result = await fixture.inspector(checker: checker).inspectInstallation()
    #expect(result.state == .rejected(.unsupportedLocation))
    #expect(result.details.sha256 == nil)
    #expect(result.details.resolvedPath == nil)
    #expect(checker.calls.isEmpty)
}

@Test("Self links and cycles inside versions terminate without signature work", arguments: [false, true])
func claudeInstallationRejectsLinkCycles(_ useVersionCycle: Bool) async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    if useVersionCycle {
        let first = fixture.versions.appending(path: "first")
        let second = fixture.versions.appending(path: "second")
        try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: "second")
        try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: "first")
        try fixture.replaceCandidate(with: first.path)
    } else {
        try fixture.replaceCandidate(with: "claude")
    }
    let checker = SignatureCheckerSpy()
    #expect(await fixture.inspector(checker: checker).inspectInstallation().state == .rejected(.symbolicLinkCycle))
    #expect(checker.calls.isEmpty)
}

@Test("Excessive link chains stop at the declared bound")
func claudeInstallationBoundsLinkCount() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    for index in 0...ClaudeInstallationInspector.maximumSymbolicLinks {
        let next = index == ClaudeInstallationInspector.maximumSymbolicLinks ? fixture.executable.lastPathComponent : "link-\(index + 1)"
        try FileManager.default.createSymbolicLink(
            atPath: fixture.versions.appending(path: "link-\(index)").path,
            withDestinationPath: next
        )
    }
    try fixture.replaceCandidate(with: fixture.versions.appending(path: "link-0").path)
    #expect(await fixture.inspector().inspectInstallation().state == .rejected(.tooManySymbolicLinks))
}

@Test("Installation directories cannot redirect through ancestor symlinks")
func claudeInstallationRejectsSymlinkedAncestor() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    let moved = fixture.home.appending(path: "moved-local")
    let local = fixture.home.appending(path: ".local")
    try FileManager.default.moveItem(at: local, to: moved)
    try FileManager.default.createSymbolicLink(atPath: local.path, withDestinationPath: moved.path)
    let checker = SignatureCheckerSpy()
    #expect(await fixture.inspector(checker: checker).inspectInstallation().state == .rejected(.unexpectedFileType))
    #expect(checker.calls.isEmpty)
}

@Test("Preserving the physical temporary spelling does not admit its symlink alias")
func claudeInstallationRejectsTemporaryAliasHome() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    let aliasedHome = URL(fileURLWithPath: "/tmp/" + fixture.home.lastPathComponent)
    let checker = SignatureCheckerSpy()
    let inspector = ClaudeInstallationInspector(
        homeDirectory: aliasedHome, signatureChecker: checker
    )
    #expect(await inspector.inspectInstallation().state == .rejected(.unexpectedFileType))
    #expect(checker.calls.isEmpty)
}

@Test("A directory, FIFO, script, or nonexecutable file cannot become the native CLI", arguments: ["directory", "fifo", "script", "no-execute", "direct-bin"])
func claudeInstallationRejectsUnsupportedTypes(_ kind: String) async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    if kind == "direct-bin" {
        try FileManager.default.removeItem(at: fixture.candidate)
        try fixture.payload.write(to: fixture.candidate)
    } else if kind == "no-execute" {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.executable.path)
    } else {
        try FileManager.default.removeItem(at: fixture.executable)
        switch kind {
        case "directory":
            try FileManager.default.createDirectory(at: fixture.executable, withIntermediateDirectories: false)
        case "fifo":
            #expect(mkfifo(fixture.executable.path, 0o700) == 0)
        default:
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fixture.executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.executable.path)
        }
    }
    let checker = SignatureCheckerSpy()
    let result = await fixture.inspector(checker: checker).inspectInstallation()
    let expected: ClaudeInstallationRejection = kind == "script" ? .unsupportedExecutable
        : kind == "no-execute" ? .notExecutable : .unexpectedFileType
    #expect(result.state == .rejected(expected))
    #expect(checker.calls.isEmpty)
}

@Test("Observed group/world write permissions are rejected without repair", arguments: [0o720, 0o702])
func claudeInstallationRejectsUnsafePermissions(_ permissions: Int) async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    try #require(chmod(fixture.executable.path, mode_t(permissions)) == 0)
    var before = stat()
    try #require(lstat(fixture.executable.path, &before) == 0)
    try #require(Int(before.st_mode & 0o7777) == permissions)
    let checker = SignatureCheckerSpy()
    #expect(await fixture.inspector(checker: checker).inspectInstallation().state == .rejected(.unsafePermissions))
    #expect(checker.calls.isEmpty)
    var after = stat()
    try #require(lstat(fixture.executable.path, &after) == 0)
    #expect(Int(after.st_mode & 0o7777) == permissions)
}

@Test("Injected set-user/group-ID metadata is rejected by the production file policy", arguments: [0o4700, 0o2700])
func claudeInstallationRejectsPrivilegeBitMetadata(_ permissions: Int) {
    // This execution host strips these bits even after successful direct fchmod:
    // immediate fstat reports 0700 for requested 04700/02700. Retain both policy
    // cases with synthetic metadata; do not claim a physical privileged fixture.
    let rejection = ClaudeInstallationInspector.metadataRejection(
        owner: geteuid(), mode: mode_t(S_IFREG) | mode_t(permissions), expectedUserID: geteuid()
    )
    #expect(rejection == .unsafePermissions)
}

@Test("Unsafe installation directory permissions and unexpected ownership fail closed")
func claudeInstallationRejectsUnsafeDirectoryOrOwner() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    let checker = SignatureCheckerSpy()
    let wrongOwner = ClaudeInstallationInspector(
        homeDirectory: fixture.home, signatureChecker: checker,
        expectedUserID: geteuid() == 0 ? 1 : 0
    )
    #expect(await wrongOwner.inspectInstallation().state == .rejected(.unsafeOwnership))
    try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: fixture.versions.path)
    #expect(await fixture.inspector(checker: checker).inspectInstallation().state == .rejected(.unsafePermissions))
    #expect(checker.calls.isEmpty)
}

@Test("Maximum executable size is checked before hashing or native signature inspection")
func claudeInstallationBoundsExecutableSize() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    let checker = SignatureCheckerSpy()
    let inspector = ClaudeInstallationInspector(
        homeDirectory: fixture.home, signatureChecker: checker,
        expectedUserID: geteuid(), maximumBytes: 4
    )
    let result = await inspector.inspectInstallation()
    #expect(result.state == .rejected(.executableTooLarge))
    #expect(result.details.sha256 == nil)
    #expect(checker.calls.isEmpty)
}

@Test("Hashing streams content larger than one buffer")
func claudeInstallationStreamsHash() async throws {
    let payload = Data([0xCF, 0xFA, 0xED, 0xFE]) + Data(repeating: 0x5A, count: 1_024 * 1_024 + 37)
    let fixture = try InstallationFixture(payload: payload)
    defer { fixture.remove() }
    let result = await fixture.inspector().inspectInstallation()
    #expect(result.state == .verified)
    #expect(result.details.sha256 == fixture.digest)
    #expect(result.details.fileIdentity?.byteCount == Int64(payload.count))
}

@Test("An executable replaced during static validation cannot retain a verified result")
func claudeInstallationDetectsExecutableReplacement() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    let replacement = fixture.versions.appending(path: "replacement")
    try fixture.payload.write(to: replacement)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: replacement.path)
    let checker = SignatureCheckerSpy { target, _ in
        #expect(rename(replacement.path, target.path) == 0)
    }
    let result = await fixture.inspector(checker: checker).inspectInstallation()
    #expect(result.state == .rejected(.changedDuringInspection))
    #expect(checker.calls.count == 1)
}

/// A send was once refused "Claude setup needs attention" and went
/// through on a retry. Run many times against a real home folder, this check
/// sometimes refused as changed during inspection: the home folder's own times move whenever a
/// file is written into it, and Claude Code rewrites `~/.claude.json` there.
@Test("A file written into the home folder during the check does not refuse a verified installation")
func claudeInstallationIgnoresUnrelatedHomeWrites() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    let checker = SignatureCheckerSpy { _, _ in
        let temporary = fixture.home.appending(path: ".claude.json.tmp.1.fixture")
        #expect(FileManager.default.createFile(atPath: temporary.path, contents: Data("{}".utf8)))
        #expect(rename(temporary.path, fixture.home.appending(path: ".claude.json").path) == 0)
    }
    #expect(await fixture.inspector(checker: checker).inspectInstallation().state == .verified)
}

@Test("A .local folder swapped out and restored during the check is still refused")
func claudeInstallationDetectsSwappedAndRestoredLocal() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    let local = fixture.home.appending(path: ".local")
    let parked = fixture.home.appending(path: ".local-parked")
    let checker = SignatureCheckerSpy { _, _ in
        #expect(rename(local.path, parked.path) == 0)
        #expect(rename(parked.path, local.path) == 0)
    }
    #expect(await fixture.inspector(checker: checker).inspectInstallation().state == .rejected(.changedDuringInspection))
}

@Test("A retargeted entry link invalidates an otherwise approved static signature")
func claudeInstallationDetectsEntryRetargeting() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    let checker = SignatureCheckerSpy { _, _ in
        #expect(unlink(fixture.candidate.path) == 0)
        #expect(symlink("../share/claude/versions/missing", fixture.candidate.path) == 0)
    }
    #expect(await fixture.inspector(checker: checker).inspectInstallation().state == .rejected(.changedDuringInspection))
}

@Test("Native static verification explicitly disables network access")
func claudeNativeSignatureValidationIsOffline() {
    #expect(NativeClaudeStaticSignatureChecker.validationFlags.rawValue & (1 << 29) != 0)
    #expect(NativeClaudeStaticSignatureChecker.validationFlags.rawValue & (1 << 16) == 0)
}

@Test("Static signature validation receives the exact open bytes across a path swap and restore")
func claudeInstallationBindsSignatureCheckToHashedDescriptor() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    let parked = fixture.versions.appending(path: "original-parked")
    let decoy = fixture.versions.appending(path: "signed-path-decoy")
    let decoyPayload = Data([0xCF, 0xFA, 0xED, 0xFE] + Array("different path bytes".utf8))
    try decoyPayload.write(to: decoy)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: decoy.path)

    let checker = SignatureCheckerSpy { target, descriptor in
        #expect(rename(target.path, parked.path) == 0)
        #expect(rename(decoy.path, target.path) == 0)
        let currentPathBytes = try? Data(contentsOf: target)
        #expect(currentPathBytes == decoyPayload)

        var buffer = Data(count: fixture.payload.count)
        let readCount = buffer.withUnsafeMutableBytes { bytes in
            pread(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        #expect(readCount == fixture.payload.count)
        #expect(buffer == fixture.payload)

        #expect(rename(target.path, decoy.path) == 0)
        #expect(rename(parked.path, target.path) == 0)
    }

    let result = await fixture.inspector(checker: checker).inspectInstallation()
    #expect(result.state == .rejected(.changedDuringInspection))
    #expect(result.details.sha256 == fixture.digest)
    #expect(checker.calls == [fixture.executable])
}

@Test("An already-cancelled check reads no installation or signature")
func claudeInstallationRespectsCancellationBeforeInspection() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    let checker = SignatureCheckerSpy()
    let inspector = fixture.inspector(checker: checker)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await inspector.inspectInstallation()
    }
    let result = await task.value
    #expect(result.state == .unavailable(.cancelled))
    #expect(result.details.resolvedPath == nil)
    #expect(result.details.sha256 == nil)
    #expect(checker.calls.isEmpty)
}

@Test("An invalid executable size policy fails closed before filesystem inspection")
func claudeInstallationRejectsInvalidPolicy() async throws {
    let fixture = try InstallationFixture(createInstallation: false)
    defer { fixture.remove() }
    let checker = SignatureCheckerSpy()
    let inspector = ClaudeInstallationInspector(
        homeDirectory: fixture.home, signatureChecker: checker,
        expectedUserID: geteuid(), maximumBytes: 3
    )
    #expect(await inspector.inspectInstallation().state == .unavailable(.invalidPolicy))
    #expect(checker.calls.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path).isEmpty)
}

@Test("The production native checker cannot accept synthetic Mach-O fixture bytes")
func claudeNativeSignatureRejectsSyntheticCode() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    let inspector = ClaudeInstallationInspector(homeDirectory: fixture.home)
    let result = await inspector.inspectInstallation()
    #expect(result.state != .verified)
    #expect(result.details.sha256 == fixture.digest)
    #expect(result.details.signature == nil)
}

@Test("Signature load commands are read from the descriptor at EOF in either thin byte order", arguments: [false, true])
func claudeSignatureParsesThinAtEOF(_ littleEndian: Bool) throws {
    for wide in [false, true] {
        let payload = signatureThinFixture(wide: wide, littleEndian: littleEndian)
        try withSignatureDescriptor(payload) { descriptor in
            let eof = lseek(descriptor, 0, SEEK_END)
            let result = try #require(ClaudeMachOSignatureParser.location(in: descriptor))
            #expect(result.sliceOffset == 0)
            #expect(result.dataOffset == 64)
            #expect(result.dataSize == 16)
            #expect(result.cpuType == (wide ? 0x0100000c : 12))
            #expect(lseek(descriptor, 0, SEEK_CUR) == eof)
        }
    }
}

@Test("Universal table offsets stay relative to the selected slice in both table widths and byte orders", arguments: [false, true])
func claudeSignatureParsesUniversalOffsets(_ littleEndian: Bool) throws {
    for wide in [false, true] {
        let payload = signatureFatFixture(wide: wide, littleEndian: littleEndian)
        try withSignatureDescriptor(payload) { descriptor in
            let first = try #require(ClaudeMachOSignatureParser.location(in: descriptor, selectingSliceAt: 256))
            let second = try #require(ClaudeMachOSignatureParser.location(in: descriptor, selectingSliceAt: 512))
            #expect(first.sliceOffset == 256 && second.sliceOffset == 512)
            #expect(first.dataOffset == 64 && second.dataOffset == 64)
            #expect(first.cpuType == 0x0100000c && second.cpuType == 0x01000007)
            #expect(ClaudeMachOSignatureParser.location(in: descriptor, selectingSliceAt: 128) == nil)
        }
    }
}

@Test("Malformed signature command lengths, counts, duplicate signatures and ranges are rejected", arguments: [
    "truncated-header", "too-many-commands", "huge-command-region", "short-command", "unaligned-command",
    "command-past-region", "signature-in-header", "signature-past-slice", "signature-overflow", "empty-signature",
    "missing-signature", "duplicate-signature", "unconsumed-command-bytes"
])
func claudeSignatureRejectsMalformedCommands(_ variant: String) throws {
    var bytes = signatureThinFixture()
    switch variant {
    case "truncated-header": bytes = bytes.prefix(20)
    case "too-many-commands": signaturePut32(4_097, in: &bytes, at: 16)
    case "huge-command-region": signaturePut32(1_048_577, in: &bytes, at: 20)
    case "short-command": signaturePut32(4, in: &bytes, at: 36)
    case "unaligned-command": signaturePut32(12, in: &bytes, at: 36)
    case "command-past-region": signaturePut32(24, in: &bytes, at: 36)
    case "signature-in-header": signaturePut32(32, in: &bytes, at: 40)
    case "signature-past-slice": signaturePut32(72, in: &bytes, at: 40)
    case "signature-overflow": signaturePut32(UInt32.max, in: &bytes, at: 40)
    case "empty-signature": signaturePut32(0, in: &bytes, at: 44)
    case "missing-signature": signaturePut32(0, in: &bytes, at: 32)
    case "duplicate-signature":
        signaturePut32(2, in: &bytes, at: 16)
        signaturePut32(32, in: &bytes, at: 20)
        bytes.replaceSubrange(48..<64, with: bytes[32..<48])
    default:
        signaturePut32(24, in: &bytes, at: 20)
    }
    try withSignatureDescriptor(bytes) { descriptor in
        #expect(ClaudeMachOSignatureParser.location(in: descriptor) == nil)
    }
}

@Test("Malformed universal tables cannot lend another slice or overflow file bounds", arguments: [
    "too-many-slices", "truncated-table", "slice-overlaps-table", "overlapping-slices", "duplicate-architecture",
    "slice-overflow", "size-overflow", "invalid-alignment", "misaligned-offset", "mismatched-inner-cpu", "reserved"
])
func claudeSignatureRejectsMalformedUniversal(_ variant: String) throws {
    var bytes = signatureFatFixture(wide: true, littleEndian: false)
    switch variant {
    case "too-many-slices": signaturePut32(65, in: &bytes, at: 4, littleEndian: false)
    case "truncated-table": bytes = bytes.prefix(50)
    case "slice-overlaps-table": signaturePut64(32, in: &bytes, at: 16, littleEndian: false)
    case "overlapping-slices": signaturePut64(256, in: &bytes, at: 48, littleEndian: false)
    case "duplicate-architecture": signaturePut32(0x0100000c, in: &bytes, at: 40, littleEndian: false)
    case "slice-overflow": signaturePut64(UInt64.max, in: &bytes, at: 16, littleEndian: false)
    case "size-overflow": signaturePut64(UInt64.max, in: &bytes, at: 24, littleEndian: false)
    case "invalid-alignment": signaturePut32(63, in: &bytes, at: 32, littleEndian: false)
    case "misaligned-offset": signaturePut64(257, in: &bytes, at: 16, littleEndian: false)
    case "mismatched-inner-cpu": signaturePut32(0x01000007, in: &bytes, at: 260)
    default: signaturePut32(1, in: &bytes, at: 36, littleEndian: false)
    }
    try withSignatureDescriptor(bytes) { descriptor in
        #expect(ClaudeMachOSignatureParser.location(in: descriptor, selectingSliceAt: 256) == nil)
    }
}

@Test("A cold ad-hoc signed vnode yields the same CodeDirectory hash as static Security validation")
func claudeSignatureReadsColdNativeFixtureAndRejectsMismatchedDescriptor() throws {
    let root = URL(fileURLWithPath: "/private/tmp/OpenBotsColdSignature-\(UUID().uuidString).noindex")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let systemBytes = try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
    var coldFiles: [URL] = [], hashes: [String] = []
    for index in 0..<2 {
        let signingInput = root.appending(path: "signing-input-\(index)")
        try systemBytes.write(to: signingInput)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: signingInput.path)
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", "--identifier", "com.openbotsnext.cold-signature-\(index)",
            "--timestamp=none", signingInput.path]
        signer.environment = [:]
        signer.standardInput = FileHandle.nullDevice
        signer.standardOutput = FileHandle.nullDevice
        signer.standardError = FileHandle.nullDevice
        try signer.run()
        signer.waitUntilExit()
        try #require(signer.terminationStatus == 0)
        // Copy bytes into a newly created vnode after signing; this file has
        // never been executed or passed to codesign/Security before the fd call.
        let cold = root.appending(path: "cold-\(index)")
        try Data(contentsOf: signingInput).write(to: cold)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cold.path)
        let descriptor = open(cold.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        let end = lseek(descriptor, 0, SEEK_END)
        let hash = try #require(NativeClaudeStaticSignatureChecker.codeDirectoryHash(of: descriptor))
        #expect(hash.count == 40)
        #expect(lseek(descriptor, 0, SEEK_CUR) == end)
        // Pin Security to the slice this Mac's loader runs. Unpinned, Security on
        // macOS 27 picks the arm64e.x1 slice /usr/bin/true gained, while the loader
        // and the product pick arm64e, so the two hashes describe different slices.
        var loaderSliceOffset: UInt64?
        #expect(macho_best_slice_in_fd(descriptor) { _, offset, _ in loaderSliceOffset = offset } == 0)
        let location = try #require(ClaudeMachOSignatureParser.location(in: descriptor))
        #expect(UInt64(location.sliceOffset) == loaderSliceOffset)
        let loaderSlice = [
            kSecCodeAttributeArchitecture as String: NSNumber(value: location.cpuType),
            kSecCodeAttributeSubarchitecture as String: NSNumber(value: location.cpuSubtype)
        ] as CFDictionary
        var code: SecStaticCode?
        try #require(SecStaticCodeCreateWithPathAndAttributes(cold as CFURL, [], loaderSlice, &code) == errSecSuccess)
        let staticCode = try #require(code)
        try #require(SecStaticCodeCheckValidity(staticCode, NativeClaudeStaticSignatureChecker.validationFlags, nil) == errSecSuccess)
        var information: CFDictionary?
        try #require(SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess)
        let dictionary = try #require(information as? [String: Any])
        let staticHash = try #require(dictionary[kSecCodeInfoUnique as String] as? Data)
        #expect(hash == staticHash.map { String(format: "%02x", $0) }.joined())
        // Ad-hoc signing provides a kernel fixture, never Anthropic admission.
        #expect(NativeClaudeStaticSignatureChecker().checkSignature(at: cold, openedDescriptor: descriptor) == .rejected)
        hashes.append(hash)
        coldFiles.append(cold)
    }
    #expect(hashes[0] != hashes[1])
    let secondDescriptor = open(coldFiles[1].path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    try #require(secondDescriptor >= 0)
    defer { close(secondDescriptor) }
    #expect(NativeClaudeStaticSignatureChecker.codeDirectoryHash(of: secondDescriptor) == hashes[1])
    #expect(NativeClaudeStaticSignatureChecker().checkSignature(at: coldFiles[0], openedDescriptor: secondDescriptor) == .rejected)
}

private func withSignatureDescriptor(_ payload: Data, body: (Int32) throws -> Void) throws {
    let fixture = try InstallationFixture(payload: payload)
    defer { fixture.remove() }
    let descriptor = open(fixture.executable.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    try body(descriptor)
}

private func signatureThinFixture(wide: Bool = true, littleEndian: Bool = true, cpu: UInt32 = 0x0100000c) -> Data {
    var bytes = Data(repeating: 0, count: 80)
    let headerSize = wide ? 32 : 28
    signaturePut32(wide ? 0xfeedfacf : 0xfeedface, in: &bytes, at: 0, littleEndian: littleEndian)
    signaturePut32(wide ? cpu : 12, in: &bytes, at: 4, littleEndian: littleEndian)
    signaturePut32(0, in: &bytes, at: 8, littleEndian: littleEndian)
    signaturePut32(2, in: &bytes, at: 12, littleEndian: littleEndian)
    signaturePut32(1, in: &bytes, at: 16, littleEndian: littleEndian)
    signaturePut32(16, in: &bytes, at: 20, littleEndian: littleEndian)
    signaturePut32(0x1d, in: &bytes, at: headerSize, littleEndian: littleEndian)
    signaturePut32(16, in: &bytes, at: headerSize + 4, littleEndian: littleEndian)
    signaturePut32(64, in: &bytes, at: headerSize + 8, littleEndian: littleEndian)
    signaturePut32(16, in: &bytes, at: headerSize + 12, littleEndian: littleEndian)
    return bytes
}

private func signatureFatFixture(wide: Bool, littleEndian: Bool) -> Data {
    var bytes = Data(repeating: 0, count: 592)
    signaturePut32(wide ? 0xcafebabf : 0xcafebabe, in: &bytes, at: 0, littleEndian: littleEndian)
    signaturePut32(2, in: &bytes, at: 4, littleEndian: littleEndian)
    for index in 0..<2 {
        let entry = 8 + index * (wide ? 32 : 20), offset = 256 + index * 256
        let cpu: UInt32 = index == 0 ? 0x0100000c : 0x01000007
        signaturePut32(cpu, in: &bytes, at: entry, littleEndian: littleEndian)
        if wide {
            signaturePut64(UInt64(offset), in: &bytes, at: entry + 8, littleEndian: littleEndian)
            signaturePut64(80, in: &bytes, at: entry + 16, littleEndian: littleEndian)
        } else {
            signaturePut32(UInt32(offset), in: &bytes, at: entry + 8, littleEndian: littleEndian)
            signaturePut32(80, in: &bytes, at: entry + 12, littleEndian: littleEndian)
        }
        signaturePut32(8, in: &bytes, at: entry + (wide ? 24 : 16), littleEndian: littleEndian)
        bytes.replaceSubrange(offset..<(offset + 80), with: signatureThinFixture(cpu: cpu))
    }
    return bytes
}

private func signaturePut32(_ value: UInt32, in bytes: inout Data, at offset: Int, littleEndian: Bool = true) {
    for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> ((littleEndian ? index : 3 - index) * 8)) }
}

private func signaturePut64(_ value: UInt64, in bytes: inout Data, at offset: Int, littleEndian: Bool) {
    for index in 0..<8 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> ((littleEndian ? index : 7 - index) * 8)) }
}
