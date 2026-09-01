import Darwin
import Foundation
import Testing
@testable import OpenBotsSecurity

private let policyTestProfile = URL(fileURLWithPath: "/private/tmp/not-created-policy.noindex/profile")

@Test("Policy admission checks only the fixed documented sources and never loads their contents")
func claudeTextPolicyFixedSources() {
    let receipt = PolicyPathReceipt()
    let inspector = NativeClaudeTextPolicyInspector(metadata: { url in
        receipt.append(url.path)
        return .absent
    }, preferences: { .absent })
    #expect(inspector.inspect(profileURL: policyTestProfile) == .admitted)
    #expect(receipt.paths == NativeClaudeTextPolicyInspector.managedPaths + [policyTestProfile.appendingPathComponent("remote-settings.json").path])
}

@Test("Every managed local source and cached remote policy is rejected")
func claudeTextPolicyRejectsPresence() {
    let locations = NativeClaudeTextPolicyInspector.managedPaths + [policyTestProfile.appendingPathComponent("remote-settings.json").path]
    for path in locations {
        let inspector = NativeClaudeTextPolicyInspector(metadata: { $0.path == path ? .present : .absent }, preferences: { .absent })
        #expect(inspector.inspect(profileURL: policyTestProfile) == .rejected(path.hasSuffix("remote-settings.json") ? .remotePolicyCachePresent : .managedFilePresent))
    }
    let preferences = NativeClaudeTextPolicyInspector(metadata: { _ in .absent }, preferences: { .present })
    #expect(preferences.inspect(profileURL: policyTestProfile) == .rejected(.managedPreferencesPresent))
}

@Test("Unknown path or preferences inspection never admits a launch")
func claudeTextPolicyRejectsUnknown() {
    let metadata = NativeClaudeTextPolicyInspector(metadata: { _ in .unknown }, preferences: { .absent })
    #expect(metadata.inspect(profileURL: policyTestProfile) == .rejected(.inspectionUnavailable))
    let preferences = NativeClaudeTextPolicyInspector(metadata: { _ in .absent }, preferences: { .unknown })
    #expect(preferences.inspect(profileURL: policyTestProfile) == .rejected(.inspectionUnavailable))
}

@Test("Malformed profile URLs fail before policy observation")
func claudeTextPolicyRejectsMalformedProfile() {
    let receipt = PolicyPathReceipt()
    let inspector = NativeClaudeTextPolicyInspector(metadata: { url in receipt.append(url.path); return .absent }, preferences: { .absent })
    for url in [URL(string: "file:///private/tmp/a.noindex/profile%00ignored")!,
                URL(fileURLWithPath: "/private/tmp/no-boundary"), URL(string: "https://example.invalid/profile.noindex")!] {
        #expect(inspector.inspect(profileURL: url) == .rejected(.invalidProfile))
    }
    #expect(receipt.paths.isEmpty)
}

@Test("Native metadata refuses symlink ancestors and counts unreadable files, FIFOs and empty directories as present")
func claudeTextPolicyMetadataHasNoContentReads() throws {
    let root = URL(fileURLWithPath: "/private/tmp/text-policy-fixture-\(UUID().uuidString).noindex")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(NativeClaudeTextPolicyInspector.inspectMetadata(root.appendingPathComponent("missing")) == .absent)
    let unreadable = root.appendingPathComponent("unreadable")
    try Data("not inspected".utf8).write(to: unreadable)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
    #expect(NativeClaudeTextPolicyInspector.inspectMetadata(unreadable) == .present)
    let fifo = root.appendingPathComponent("fifo")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(NativeClaudeTextPolicyInspector.inspectMetadata(fifo) == .present)
    let empty = root.appendingPathComponent("empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
    #expect(NativeClaudeTextPolicyInspector.inspectMetadata(empty) == .present)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: empty)
    #expect(NativeClaudeTextPolicyInspector.inspectMetadata(link) == .present)
    #expect(NativeClaudeTextPolicyInspector.inspectMetadata(link.appendingPathComponent("missing")) == .unknown)
    let dangling = root.appendingPathComponent("dangling")
    try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "absent")
    #expect(NativeClaudeTextPolicyInspector.inspectMetadata(dangling) == .present)
}

private final class PolicyPathReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var paths: [String] { lock.withLock { recorded } }
    func append(_ path: String) { lock.withLock { recorded.append(path) } }
}
