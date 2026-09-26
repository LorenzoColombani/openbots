import Foundation
import Testing
@testable import OpenBotsExecutionRules

// The clearest allow and deny rows of OpenBotsExecutionRules' three decision
// surfaces: a first file rather than full coverage.

private let bot = TeammateID(UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
private let otherBot = TeammateID(UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!)
private let run = RunID(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
private let policy = ShellPolicyVersion(rawValue: "test-policy-1")

// MARK: - BrokerPolicy

struct BrokerPolicyDecisionTableTests {
    private let digest = PayloadDigest.sha256(of: Data("payload".utf8))

    private func file(_ path: String, _ location: LocationClassification = .userOwnedLocal,
                      scope: TargetScope = .exactItem, providerRoot: Bool = false) throws -> CanonicalTarget {
        try CanonicalTarget(kind: .filesystem, canonicalIdentifier: path, location: location,
                            scope: scope, isProviderRoot: providerRoot)
    }

    private func proposal(_ operation: OperationClass, _ targets: [CanonicalTarget],
                          traversal: TraversalScope = .exactTargets) -> ActionProposal {
        ActionProposal(actionID: ActionID(UUID()), teammateID: bot, runID: run, operation: operation,
                       targets: targets, payloadDigest: digest, traversal: traversal)
    }

    @Test("Only a read-only external access escapes a fresh, exact, single-use approval")
    func approvalRequirementByOperation() throws {
        for operation in OperationClass.allCases {
            let target: CanonicalTarget
            switch operation {
            case .readOnlyExternalAccess:
                target = try CanonicalTarget(kind: .externalResource, canonicalIdentifier: "https://example.com/a",
                                             location: .notApplicable, scope: .exactItem)
            case .containedWorkspaceCommand:
                target = try file("/private/tmp/bot.noindex/work", .appOwned, scope: .narrowFolder)
            default:
                target = try file("/Users/someone/Documents/a.txt")
            }
            let frozen = try BrokerPolicy.freeze(proposal(operation, [target]))
            let expected: ApprovalRequirement = operation == .readOnlyExternalAccess
                ? .explicitReadCapability : .freshExactSingleUseApproval
            #expect(BrokerPolicy.approvalRequirement(for: frozen) == expected, "\(operation)")
        }
    }

    @Test("Malformed targets and shapes are refused before anything is frozen")
    func refusedShapes() throws {
        #expect(throws: BrokerPolicyError.self) { try file("relative/path") }
        #expect(throws: BrokerPolicyError.self) { try file("/Users/someone/../etc/passwd") }
        #expect(throws: BrokerPolicyError.self) {
            try CanonicalTarget(kind: .externalResource, canonicalIdentifier: "https://example.com",
                                location: .userOwnedLocal, scope: .exactItem)
        }
        #expect(throws: BrokerPolicyError.invalidTarget("action requires at least one exact target")) {
            try BrokerPolicy.freeze(proposal(.overwrite, []))
        }
        let a = try file("/Users/someone/a.txt")
        #expect(throws: BrokerPolicyError.duplicateTarget("filesystem:/Users/someone/a.txt:exactItem")) {
            try BrokerPolicy.freeze(proposal(.overwrite, [a, a]))
        }
        #expect(throws: BrokerPolicyError.exclusiveCreateRequiresOneExactItem) {
            try BrokerPolicy.freeze(proposal(.exclusiveCreateNewArtifactDelivery, [a, try file("/Users/someone/b.txt")]))
        }
        let providerRoot = try file("/Users/someone/Library/CloudStorage/Drive", .providerManaged,
                                    scope: .narrowFolder, providerRoot: true)
        #expect(throws: BrokerPolicyError.providerRootRecursiveMutationForbidden) {
            try BrokerPolicy.freeze(proposal(.destructiveFilesystemChange, [providerRoot],
                                             traversal: .boundedDescendants(maximumDepth: 3)))
        }
        #expect(throws: BrokerPolicyError.self) {
            try BrokerPolicy.freeze(proposal(.containedWorkspaceCommand, [a]))
        }
    }

    @Test("A receipt authorizes its own action once, inside its window, and nothing else")
    func receiptLifecycle() throws {
        let target = try file("/Users/someone/a.txt")
        let action = try BrokerPolicy.freeze(proposal(.overwrite, [target]))
        let other = try BrokerPolicy.freeze(proposal(.overwrite, [target]))
        let ledger = ApprovalLedger()
        let issued = Date(timeIntervalSince1970: 1_000)
        let receipt = try ledger.issue(receiptID: ApprovalReceiptID(UUID()), for: action,
                                       issuedAt: issued, expiresAt: issued.addingTimeInterval(60))

        #expect(throws: BrokerPolicyError.receiptBindingMismatch) {
            try ledger.consume(receipt, for: other, at: issued.addingTimeInterval(1))
        }
        #expect(throws: BrokerPolicyError.receiptNotYetValid) {
            try ledger.consume(receipt, for: action, at: issued.addingTimeInterval(-1))
        }
        #expect(throws: BrokerPolicyError.receiptExpired) {
            try ledger.consume(receipt, for: action, at: issued.addingTimeInterval(60))
        }
        let authorization = try ledger.consume(receipt, for: action, at: issued.addingTimeInterval(1))
        #expect(authorization.actionFingerprint == action.fingerprint)
        #expect(throws: BrokerPolicyError.receiptAlreadyConsumed) {
            try ledger.consume(receipt, for: action, at: issued.addingTimeInterval(2))
        }
        #expect(throws: BrokerPolicyError.unknownReceipt) {
            try ApprovalLedger().consume(receipt, for: action, at: issued.addingTimeInterval(1))
        }
        #expect(throws: BrokerPolicyError.invalidApprovalWindow) {
            try ledger.issue(receiptID: ApprovalReceiptID(UUID()), for: action, issuedAt: issued, expiresAt: issued)
        }
    }
}

// MARK: - TrustModel

struct TrustModelDecisionTableTests {
    private func receipt(_ mode: ShellMode = .contained, teammate: TeammateID = bot,
                         version: ShellPolicyVersion = policy, accepted: Bool = true,
                         id: UUID = UUID()) -> ShellWarningReceipt {
        ShellWarningReceipt(id: id, teammateID: teammate, policyVersion: version,
                            requestedMode: mode, wasAffirmativelyAccepted: accepted)
    }

    private func enable(_ record: inout TeammateShellTrustRecord, _ mode: ShellMode = .contained,
                        _ receipt: ShellWarningReceipt) -> ShellTrustEffect {
        record.handle(ShellTrustCommand(operationID: UUID(), expectedRevision: record.revision,
            action: .enable(mode: mode, warningReceipt: receipt, authorization: .boundedPhysicalMacProbe))).effect
    }

    @Test("Every way a bot comes into being starts with its shell off, and off denies a new call")
    func startsOff() {
        for route in TeammateMaterialization.allCases {
            let record = TeammateShellTrustRecord(teammateID: bot, policyVersion: policy, materializedBy: route)
            #expect(record.mode == .off)
            #expect(record.authorizeNewShellCall(runID: run) == .deniedShellOff)
        }
    }

    @Test("Contained is the only mode the current authorization can switch on")
    func whatCanBeEnabled() {
        #expect(ShellEnablementAuthorization.boundedPhysicalMacProbe.permits(.contained))
        #expect(!ShellEnablementAuthorization.boundedPhysicalMacProbe.permits(.higherTrust))
        #expect(!ShellEnablementAuthorization.boundedPhysicalMacProbe.permits(.off))

        var record = TeammateShellTrustRecord(teammateID: bot, policyVersion: policy, materializedBy: .creation)
        #expect(enable(&record, .higherTrust, receipt(.higherTrust)) == .rejected(.modeNotAuthorizedByCurrentProbe(.higherTrust)))
        #expect(enable(&record, .off, receipt(.off)) == .rejected(.modeCannotBeEnabled(.off)))
        #expect(enable(&record, .contained, receipt()) == .enabled(.contained))
        guard case .granted(let authorization) = record.authorizeNewShellCall(runID: run) else {
            Issue.record("a contained bot was refused a new shell call"); return
        }
        #expect(authorization.modeAtStart == .contained && authorization.teammateID == bot)
    }

    @Test("A warning receipt counts only if accepted, for this bot, this policy and this mode, once")
    func warningReceiptBinding() {
        var record = TeammateShellTrustRecord(teammateID: bot, policyVersion: policy, materializedBy: .creation)
        #expect(enable(&record, .contained, receipt(accepted: false)) == .rejected(.warningNotAffirmativelyAccepted))
        #expect(enable(&record, .contained, receipt(teammate: otherBot)) == .rejected(.warningBoundToDifferentTeammate))
        #expect(enable(&record, .contained, receipt(version: ShellPolicyVersion(rawValue: "old")))
            == .rejected(.warningBoundToDifferentPolicy))
        #expect(enable(&record, .contained, receipt(.higherTrust)) == .rejected(.warningBoundToDifferentMode))
        #expect(record.mode == .off)

        let once = receipt()
        #expect(enable(&record, .contained, once) == .enabled(.contained))
        let off = record.handle(ShellTrustCommand(operationID: UUID(), expectedRevision: record.revision,
                                                  action: .disable(reason: .revoke)))
        #expect(off.effect == .disabled(previousMode: .contained, reason: .revoke))
        #expect(off.existingRunDisposition == .unaffectedRequiresExplicitStop)
        #expect(enable(&record, .contained, once) == .rejected(.warningReceiptAlreadyUsed))
        #expect(record.mode == .off)
    }

    @Test("A stale revision is refused, a replay repeats its answer, and a reused id with new content conflicts")
    func revisionsAndReplays() {
        var record = TeammateShellTrustRecord(teammateID: bot, policyVersion: policy, materializedBy: .creation)
        let stale = record.handle(ShellTrustCommand(operationID: UUID(), expectedRevision: 7,
            action: .enable(mode: .contained, warningReceipt: receipt(), authorization: .boundedPhysicalMacProbe)))
        #expect(stale.effect == .rejected(.staleRevision(expected: 7, actual: 0)))

        let operation = UUID()
        let command = ShellTrustCommand(operationID: operation, expectedRevision: 0,
            action: .enable(mode: .contained, warningReceipt: receipt(), authorization: .boundedPhysicalMacProbe))
        let first = record.handle(command)
        let again = record.handle(command)
        #expect(first.effect == .enabled(.contained) && !first.isIdempotentReplay)
        #expect(again.effect == .enabled(.contained) && again.isIdempotentReplay && again.revision == first.revision)
        let conflict = record.handle(ShellTrustCommand(operationID: operation, expectedRevision: record.revision,
                                                       action: .disable(reason: .reset)))
        #expect(conflict.effect == .rejected(.operationIdentifierConflict))
        #expect(record.mode == .contained)

        let membership = record.handle(ShellTrustCommand(operationID: UUID(), expectedRevision: record.revision,
            action: .observeMembership(CollaborationMembership(teamIDs: [UUID()], projectIDs: []))))
        #expect(membership.effect == .membershipObservedWithoutTrustChange && membership.mode == .contained)
    }
}

// MARK: - ContainedBoundaryPolicy

struct ContainedBoundaryPolicyDecisionTableTests {
    private func paths(root: String = "/private/tmp/openbots-rules.noindex/run") throws -> AgenticProbePaths {
        try AgenticProbePaths(root: URL(fileURLWithPath: root),
                              configurationDirectory: URL(fileURLWithPath: "/private/tmp/openbots-rules.noindex/config"),
                              homeDirectory: URL(fileURLWithPath: "/private/tmp/openbots-rules.noindex/home"),
                              claudeExecutable: URL(fileURLWithPath: "/opt/claude/bin/claude"))
    }

    @Test("A probe root outside /private/tmp or a .noindex folder, or not canonical, is refused")
    func probeRoots() throws {
        #expect(throws: ContainedBoundaryPolicyError.self) { try paths(root: "/Users/someone/run.noindex") }
        #expect(throws: ContainedBoundaryPolicyError.self) { try paths(root: "/private/tmp/plain/run") }
        #expect(throws: ContainedBoundaryPolicyError.self) { try paths(root: "/private/tmp/x.noindex/../escape") }
        _ = try paths()
    }

    @Test("Shell off launches with no tools; contained with Bash only; any other mode is refused")
    func toolsByAuthorization() throws {
        let off = try ContainedBoundaryPolicy.makePlan(paths: try paths(),
            authorization: .shellOff(teammateID: bot, runID: run),
            persistence: .ephemeral(sessionID: UUID()), userName: "someone")
        #expect(off.arguments.firstIndex(of: "--tools").map { off.arguments[$0 + 1] } == "")

        let contained = ShellRunAuthorization(runID: run, teammateID: bot, modeAtStart: .contained, trustRevisionAtStart: 1)
        let plan = try ContainedBoundaryPolicy.makePlan(paths: try paths(), authorization: .contained(contained),
            persistence: .ephemeral(sessionID: UUID()), userName: "someone")
        #expect(plan.arguments.firstIndex(of: "--tools").map { plan.arguments[$0 + 1] } == "Bash")
        #expect(plan.arguments.contains("--no-session-persistence"))
        #expect(plan.arguments.firstIndex(of: "--permission-mode").map { plan.arguments[$0 + 1] } == "dontAsk")

        let higher = ShellRunAuthorization(runID: run, teammateID: bot, modeAtStart: .higherTrust, trustRevisionAtStart: 1)
        #expect(throws: ContainedBoundaryPolicyError.modeNotAuthorized(.higherTrust)) {
            try ContainedBoundaryPolicy.makePlan(paths: try paths(), authorization: .contained(higher),
                persistence: .ephemeral(sessionID: UUID()), userName: "someone")
        }
        #expect(throws: ContainedBoundaryPolicyError.invalidIdentity) {
            try ContainedBoundaryPolicy.makePlan(paths: try paths(), authorization: .shellOff(teammateID: bot, runID: run),
                persistence: .ephemeral(sessionID: UUID()), userName: "")
        }
    }

    @Test("The launch settings deny the sandbox escape, the network and the credential variables")
    func settingsDenyRows() throws {
        let plan = try ContainedBoundaryPolicy.makePlan(paths: try paths(),
            authorization: .shellOff(teammateID: bot, runID: run),
            persistence: .ephemeral(sessionID: UUID()), userName: "someone")
        let settings = try #require(try JSONSerialization.jsonObject(with: plan.settingsJSON) as? [String: Any])
        let permissions = try #require(settings["permissions"] as? [String: Any])
        let sandbox = try #require(settings["sandbox"] as? [String: Any])
        let network = try #require(sandbox["network"] as? [String: Any])
        let credentials = try #require(sandbox["credentials"] as? [String: Any])
        let deniedVariables = try #require(credentials["envVars"] as? [[String: Any]])
        #expect((permissions["deny"] as? [String])?.contains("Bash(dangerouslyDisableSandbox:true)") == true)
        #expect(sandbox["allowUnsandboxedCommands"] as? Bool == false)
        #expect(sandbox["failIfUnavailable"] as? Bool == true)
        #expect(network["deniedDomains"] as? [String] == ["*"])
        for name in ContainedBoundaryPolicy.deniedCredentialEnvironmentNames {
            #expect(deniedVariables.contains { $0["name"] as? String == name && $0["mode"] as? String == "deny" },
                    "\(name) is not denied")
            #expect(plan.environment[name] == nil, "\(name) reaches the launch environment")
        }
    }
}
