import CryptoKit
import Darwin
import Foundation
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
