import AppKit
import OpenBotsDomain
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class ActionProposalWorkspaceTests: XCTestCase {
    func testInertConstructionAndReadOnlyLoadNeverPrepareDecideOrExpire() async throws {
        let conversation = proposalUUID(1)
        let record = try proposalRecord(conversation: conversation)
        let service = ProposalTestService(records: [conversation: [record]])
        let model = ActionProposalWorkspaceModel(service: service)
        model.activateConversation(conversation, teammateName: "Ada")
        XCTAssertEqual(model.loadState, .idle)
        var calls = await service.calls
        XCTAssertTrue(calls.isEmpty)
        await model.load()
        XCTAssertEqual(model.selectedReview, record)
        XCTAssertEqual(model.selectedReview?.state, .pending, "Loading must not write an expiry decision")
        calls = await service.calls
        XCTAssertEqual(calls, [.load(conversation)])
    }

    func testPrepareCapturesActionBeforeAwaitAndDoesNotFollowLaterPickerChange() async throws {
        let conversation = proposalUUID(2)
        let gate = ProposalTestGate()
        let service = ProposalTestService(gates: [.prepare(conversation, .delete): gate])
        let model = ActionProposalWorkspaceModel(service: service)
        model.activateConversation(conversation)
        await model.load()
        model.selectedAction = .delete
        let task = Task { await model.prepareDemoProposal() }
        try await waitProposalGate(gate)
        model.selectedAction = .publish
        await model.prepareDemoProposal()
        await gate.release()
        await task.value
        XCTAssertEqual(model.selectedReview?.proposal.action, .delete)
        XCTAssertEqual(model.selectedAction, .publish)
        let calls = await service.calls
        XCTAssertEqual(calls, [.load(conversation), .prepare(conversation, .delete)])
    }

    func testApproveDenyAndCancelConsumeOnlyExactDisplayedFrozenReview() async throws {
        for (decision, state) in [(ActionProposalDecision.approve, ActionProposalState.approved), (.deny, .denied), (.cancel, .cancelled)] {
            let conversation = proposalUUID(3)
            let record = try proposalRecord(conversation: conversation)
            let service = ProposalTestService(records: [conversation: [record]])
            let model = ActionProposalWorkspaceModel(service: service)
            model.activateConversation(conversation)
            await model.load()
            await model.decide(record, decision: decision)
            XCTAssertEqual(model.selectedReview?.state, state)
            XCTAssertEqual(model.selectedReview?.fingerprint, record.fingerprint)
            XCTAssertEqual(model.selectedReview?.revision, record.revision + 1)
            XCTAssertFalse(model.canDecide(try XCTUnwrap(model.selectedReview)))
            let calls = await service.calls
            XCTAssertEqual(calls, [.load(conversation), .decide(record.id, record.fingerprint, record.revision, proposalDecisionName(decision))])
            XCTAssertTrue(model.statusMessage?.contains("Nothing was executed") ?? false)
        }
    }

    func testTamperedPayloadOrFingerprintCannotReachDecisionService() async throws {
        let conversation = proposalUUID(4)
        let original = try proposalRecord(conversation: conversation)
        for changed in [
            ActionProposalRecord(proposal: original.proposal, fingerprint: String(repeating: "0", count: 64), state: .pending, revision: 1, updatedAt: original.updatedAt),
            try proposalRecord(conversation: conversation, payload: "Different exact payload")
        ] {
            let service = ProposalTestService(records: [conversation: [original]])
            let model = ActionProposalWorkspaceModel(service: service)
            model.activateConversation(conversation)
            await model.load()
            await model.decide(changed, decision: .approve)
            XCTAssertTrue(model.needsRefresh)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(model.selectedReview, original)
            let calls = await service.calls
            XCTAssertEqual(calls, [.load(conversation)])
        }
    }

    func testApprovedDecisionCanBeCancelledWithoutExecutingOrChangingEnvelope() async throws {
        let conversation = proposalUUID(14)
        let pending = try proposalRecord(conversation: conversation)
        let approved = ActionProposalRecord(proposal: pending.proposal, fingerprint: pending.fingerprint, state: .approved,
                                            revision: 2, updatedAt: pending.updatedAt.addingTimeInterval(1))
        let service = ProposalTestService(records: [conversation: [approved]])
        let model = ActionProposalWorkspaceModel(service: service)
        model.activateConversation(conversation)
        await model.load()
        XCTAssertFalse(model.canDecide(approved, decision: .approve))
        XCTAssertTrue(model.canDecide(approved, decision: .cancel))
        await model.decide(approved, decision: .cancel)
        XCTAssertEqual(model.selectedReview?.state, .cancelled)
        XCTAssertEqual(model.selectedReview?.fingerprint, approved.fingerprint)
        XCTAssertEqual(model.selectedReview?.revision, 3)
        let calls = await service.calls
        XCTAssertEqual(calls, [.load(conversation), .decide(approved.id, approved.fingerprint, 2, "cancel")])
    }

    func testPastDeadlineBlocksApprovalAndOnlyExplicitExpiryChangesSavedState() async throws {
        for state in [ActionProposalState.pending, .approved] {
            let conversation = proposalUUID(15)
            let pending = try proposalRecord(conversation: conversation)
            let record = ActionProposalRecord(proposal: pending.proposal, fingerprint: pending.fingerprint, state: state,
                                              revision: state == .pending ? 1 : 2, updatedAt: pending.updatedAt)
            let time = record.proposal.expiresAt.addingTimeInterval(1)
            let service = ProposalTestService(records: [conversation: [record]])
            let model = ActionProposalWorkspaceModel(service: service, now: { time })
            model.activateConversation(conversation)
            await model.load()
            XCTAssertTrue(model.isExpired(record))
            XCTAssertFalse(model.canDecide(record, decision: .approve))
            XCTAssertTrue(model.canDecide(record, decision: .expire))
            XCTAssertEqual(model.selectedReview?.state, state)
            await model.decide(record, decision: .expire)
            XCTAssertEqual(model.selectedReview?.state, .expired)
            let calls = await service.calls
            XCTAssertEqual(calls, [.load(conversation), .decide(record.id, record.fingerprint, record.revision, "expire")])
        }
    }

    func testLateLoadCannotReplaceNewConversationOrTeammate() async throws {
        let first = proposalUUID(5), second = proposalUUID(6)
        let a = try proposalRecord(conversation: first), b = try proposalRecord(conversation: second, id: 20)
        let gate = ProposalTestGate()
        let service = ProposalTestService(records: [first: [a], second: [b]], gates: [.load(first): gate])
        let model = ActionProposalWorkspaceModel(service: service)
        model.activateConversation(first, teammateName: "Ada")
        let task = Task { await model.load() }
        try await waitProposalGate(gate)
        model.activateConversation(second, teammateName: "Mira")
        await model.load()
        await gate.release()
        await task.value
        XCTAssertEqual(model.conversationID, second)
        XCTAssertEqual(model.teammateName, "Mira")
        XCTAssertEqual(model.selectedReview, b)
        XCTAssertNil(model.errorMessage)
    }

    func testPendingDecisionSurvivesNavigationWithoutDuplicateOrStaleViewUpdate() async throws {
        let conversation = proposalUUID(7)
        let record = try proposalRecord(conversation: conversation)
        let call = ProposalTestCall.decide(record.id, record.fingerprint, 1, "approve")
        let gate = ProposalTestGate()
        let service = ProposalTestService(records: [conversation: [record]], gates: [call: gate])
        let model = ActionProposalWorkspaceModel(service: service)
        model.activateConversation(conversation)
        await model.load()
        let task = Task { await model.decide(record, decision: .approve) }
        try await waitProposalGate(gate)
        await model.decide(record, decision: .approve)
        model.activateConversation(proposalUUID(8))
        model.activateConversation(conversation)
        XCTAssertTrue(model.isBusy)
        await model.load()
        await gate.release()
        await task.value
        XCTAssertTrue(model.needsRefresh)
        XCTAssertTrue(model.records.isEmpty)
        await model.load()
        XCTAssertEqual(model.selectedReview?.state, .approved)
        let calls = await service.calls
        XCTAssertEqual(calls.filter { $0 == call }.count, 1)
    }

    func testExpiryAndContextFailuresRequireRefreshAndNeverRetryAutomatically() async throws {
        for failure in [ActionProposalError.expired, .contextChanged] {
            let conversation = proposalUUID(9)
            let record = try proposalRecord(conversation: conversation)
            let call = ProposalTestCall.decide(record.id, record.fingerprint, 1, "approve")
            let service = ProposalTestService(records: [conversation: [record]], failures: [call: failure])
            let model = ActionProposalWorkspaceModel(service: service)
            model.activateConversation(conversation)
            await model.load()
            await model.decide(record, decision: .approve)
            XCTAssertTrue(model.needsRefresh)
            XCTAssertFalse(model.canPrepare)
            XCTAssertTrue(model.errorMessage?.contains("Refresh") ?? false)
            await model.decide(record, decision: .approve)
            let calls = await service.calls
            XCTAssertEqual(calls.filter { $0 == call }.count, 1)
            XCTAssertEqual(model.selectedReview?.state, .pending)
        }
    }

    func testForeignOrInvalidReceiptCannotPopulateReview() async throws {
        let conversation = proposalUUID(10)
        let foreign = try proposalRecord(conversation: proposalUUID(11))
        let original = try proposalRecord(conversation: conversation)
        let bad = ActionProposalRecord(proposal: original.proposal, fingerprint: "invalid", state: .pending, revision: 1, updatedAt: original.updatedAt)
        for record in [foreign, bad] {
            let service = ProposalTestService(records: [conversation: [record]])
            let model = ActionProposalWorkspaceModel(service: service)
            model.activateConversation(conversation)
            await model.load()
            XCTAssertEqual(model.loadState, .failed)
            XCTAssertTrue(model.records.isEmpty)
            XCTAssertFalse(model.canPrepare)
        }
    }

    func testHistoryBoundAndSelectionDoNotPrepareOrDecide() async throws {
        let conversation = proposalUUID(12)
        let records = try (1...10).map { try proposalRecord(conversation: conversation, id: UInt64($0)) }
        let service = ProposalTestService(records: [conversation: records])
        let model = ActionProposalWorkspaceModel(service: service)
        model.activateConversation(conversation)
        await model.load()
        model.selectReview(records[4].id)
        XCTAssertEqual(model.selectedReview, records[4])
        XCTAssertEqual(model.records.count, 10)
        let calls = await service.calls
        XCTAssertEqual(calls, [.load(conversation)])
    }

    func testSavedRecordSummariesKeepDecisionsAndSeparatePassedDeadlinesWithoutDemoInstructions() throws {
        let pending = try proposalRecord(conversation: proposalUUID(15))
        for state in [ActionProposalState.pending, .approved, .denied, .cancelled, .expired] {
            let record = ActionProposalRecord(proposal: pending.proposal, fingerprint: pending.fingerprint,
                                              state: state, revision: state == .pending ? 1 : 2,
                                              updatedAt: pending.updatedAt)
            let current = ActionProposalWorkspaceView.savedRecordSummary(record, isExpired: false)
            let later = ActionProposalWorkspaceView.savedRecordSummary(record, isExpired: true)
            XCTAssertEqual(current.title, later.title, "A passed deadline must not replace the saved decision")
            XCTAssertEqual(record.state, state)
            XCTAssertTrue(later.nextStep.contains("Nothing will be executed"))
            XCTAssertEqual(later.attention?.contains("saved decision has not been changed") == true,
                           state == .pending || state == .approved)
            for text in [current.plainText, later.plainText] {
                for instruction in ["Approve, deny", "Choose Cancel", "Choose Record Expiry", "Prepare a new"] {
                    XCTAssertFalse(text.contains(instruction), "Read-only history must not direct a demo mutation")
                }
            }
        }
    }

    func testNormalSavedReviewPreservesExactPayloadAndSelectionWithoutMutationsOrDiagnostics() async throws {
        let conversation = proposalUUID(16)
        let pending = try proposalRecord(conversation: conversation, id: 30,
                                        payload: "  Exact saved text\nhttps://example.invalid/review\nDo not change these bytes.  ")
        let earlier = try proposalRecord(conversation: conversation, id: 31, action: .overwrite,
                                        payload: "A different saved payload")
        let approved = ActionProposalRecord(proposal: earlier.proposal, fingerprint: earlier.fingerprint,
                                            state: .approved, revision: 2, updatedAt: earlier.updatedAt)
        let time = earlier.proposal.expiresAt.addingTimeInterval(1)
        let service = ProposalTestService(records: [conversation: [pending, approved]])
        let model = ActionProposalWorkspaceModel(service: service, now: { time })
        model.activateConversation(conversation, teammateName: "Ada")
        await model.load()
        let controller = NSHostingController(rootView: ActionProposalWorkspaceView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        controller.view.frame = CGRect(x: 0, y: 0, width: 360, height: 1_600)
        for record in [pending, approved] {
            model.selectReview(record.id)
            for _ in 0..<4 { controller.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(5)) }
            let size = controller.sizeThatFits(in: CGSize(width: 360, height: 1_600))
            XCTAssertTrue(size.width.isFinite && size.height.isFinite)
            XCTAssertLessThanOrEqual(size.width, 360.5)
            XCTAssertGreaterThan(size.height, 0)
            XCTAssertLessThanOrEqual(size.height, 1_600)
            let views = controller.view.proposalDescendants.filter { !$0.isHiddenOrHasHiddenAncestor }
            let payload = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
            XCTAssertEqual(payload.string, record.proposal.payload)
            XCTAssertFalse(payload.isEditable)
            XCTAssertTrue(payload.isSelectable)
            XCTAssertFalse(payload.isAutomaticLinkDetectionEnabled)
            let materializedText = views.compactMap { view -> String? in
                if let field = view as? NSTextField { return field.stringValue }
                if let text = view as? NSTextView { return text.string }
                if let button = view as? NSButton { return button.title }
                return nil
            }.joined(separator: "\n")
            for diagnostic in ["Technical details", "Frozen fingerprint", record.fingerprint,
                               record.id.rawValue.uuidString, "Prepare Demo Proposal", "Approve Demo Proposal",
                               "Cancel Demo Approval", "Record Expiry"] {
                XCTAssertFalse(materializedText.contains(diagnostic))
            }
            XCTAssertEqual(model.selectedReview, record)
        }
        XCTAssertEqual(Set(model.records.map(\.id)), Set([pending.id, approved.id]))
        let calls = await service.calls
        XCTAssertTrue(calls.allSatisfy { if case .load = $0 { return true }; return false })
        // SwiftUI need not expose every label as an NSControl. This proves the
        // hosted payload, selection and inert service boundary, not live AX.
    }

    func testNativeReviewRendersAt238270360And760WithoutDecisions() async throws {
        let conversation = proposalUUID(13)
        let record = try proposalRecord(conversation: conversation)
        let service = ProposalTestService(records: [conversation: [record]])
        let model = ActionProposalWorkspaceModel(service: service)
        model.activateConversation(conversation, teammateName: "Ada")
        await model.load()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".build.noindex/shutdown-ui-tests/rendered/proposals", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
          let controller = NSHostingController(rootView: ActionProposalWorkspaceView(model: model, mode: .developmentDemo)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background).environment(\.colorScheme, scheme))
          for width: CGFloat in [238, 270, 360, 760] {
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 1_800)
            for _ in 0..<4 { controller.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(5)) }
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 1_800))
            XCTAssertTrue(size.width.isFinite && size.height.isFinite)
            XCTAssertGreaterThan(size.height, 0)
            XCTAssertLessThanOrEqual(size.width, width + 0.5)
            XCTAssertLessThanOrEqual(size.height, 1_800)
            let textViews = controller.view.proposalDescendants.compactMap { $0 as? NSTextView }
            let payload = try XCTUnwrap(textViews.first)
            XCTAssertEqual(payload.string, record.proposal.payload)
            XCTAssertFalse(payload.isEditable)
            XCTAssertTrue(payload.isSelectable)
            XCTAssertFalse(payload.isAutomaticLinkDetectionEnabled)
            let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("proposal-\(scheme == .dark ? "dark" : "light")-\(Int(width)).png"), options: .atomic)
          }
        }
        let calls = await service.calls
        XCTAssertTrue(calls.allSatisfy { if case .load = $0 { return true }; return false })
        // Offscreen layout/readonly controls only; not a live keyboard or
        // VoiceOver sign-off, nor proof that a proposed action can execute.
    }

    func testViewKeepsImmutableFieldsAndExactLocalDecisionControls() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/OpenBotsUI/ActionProposalWorkspaceView.swift"), encoding: .utf8)
        for label in ["Exact target", "Exact payload", "Consequence", "Review expires", "Frozen fingerprint", "Prepare Demo Proposal", "Approve Demo Proposal", "Deny Demo Proposal", "Cancel Demo Proposal", "Cancel Demo Approval", "Record Expiry"] {
            XCTAssertTrue(source.contains("\"\(label)\""))
        }
        XCTAssertTrue(source.contains("ConsequentialActionKind.allCases"))
        XCTAssertTrue(source.contains("model.decide(record, decision:"))
        XCTAssertTrue(source.contains(".task(id: model.conversationID) { await model.load() }"))
        for forbidden in ["TextField(", "Button(\"Execute", "Timer", "keyboardShortcut(.defaultAction)", "NSWorkspace", "URL("] {
            XCTAssertFalse(source.contains(forbidden))
        }
    }
}

private enum ProposalTestCall: Hashable, Sendable {
    case load(UUID), prepare(UUID, ConsequentialActionKind), decide(ApprovalID, String, Int64, String)
}
private actor ProposalTestService: ActionProposalFixtureServing {
    private var records: [UUID: [ActionProposalRecord]]
    private let gates: [ProposalTestCall: ProposalTestGate]
    private let failures: [ProposalTestCall: ActionProposalError]
    private(set) var calls: [ProposalTestCall] = []
    init(records: [UUID: [ActionProposalRecord]] = [:], gates: [ProposalTestCall: ProposalTestGate] = [:],
         failures: [ProposalTestCall: ActionProposalError] = [:]) {
        self.records = records; self.gates = gates; self.failures = failures
    }
    func proposals(conversationID: ConversationID) async throws -> [ActionProposalRecord] {
        let values = records[conversationID.rawValue] ?? []
        try await before(.load(conversationID.rawValue))
        return values
    }
    func prepare(conversationID: ConversationID, action: ConsequentialActionKind) async throws -> ActionProposalRecord {
        try await before(.prepare(conversationID.rawValue, action))
        let value = try proposalRecord(conversation: conversationID.rawValue, id: UInt64(100 + calls.count), action: action)
        records[conversationID.rawValue] = Array(([value] + (records[conversationID.rawValue] ?? [])).prefix(10))
        return value
    }
    func decide(_ review: ActionProposalRecord, decision: ActionProposalDecision) async throws -> ActionProposalRecord {
        try await before(.decide(review.id, review.fingerprint, review.revision, proposalDecisionName(decision)))
        let state: ActionProposalState
        switch decision { case .approve: state = .approved; case .deny: state = .denied; case .cancel: state = .cancelled; case .expire: state = .expired }
        let result = ActionProposalRecord(proposal: review.proposal, fingerprint: review.fingerprint, state: state,
                                          revision: review.revision + 1, updatedAt: review.updatedAt.addingTimeInterval(1))
        records[review.proposal.conversationID.rawValue] = (records[review.proposal.conversationID.rawValue] ?? []).map { $0.id == review.id ? result : $0 }
        return result
    }
    private func before(_ call: ProposalTestCall) async throws {
        calls.append(call)
        if let gate = gates[call] { await gate.wait() }
        if let error = failures[call] { throw error }
    }
}
private actor ProposalTestGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private func waitProposalGate(_ gate: ProposalTestGate) async throws {
    for _ in 0..<500 { if await gate.started { return }; try await Task.sleep(for: .milliseconds(2)) }
    throw ProposalTestTimeout()
}
private struct ProposalTestTimeout: Error {}
private func proposalUUID(_ value: UInt64) -> UUID { UUID(uuidString: String(format: "%08llx-AD08-0000-0000-000000000001", value))! }
private func proposalDecisionName(_ decision: ActionProposalDecision) -> String {
    switch decision { case .approve: "approve"; case .deny: "deny"; case .cancel: "cancel"; case .expire: "expire" }
}
private func proposalRecord(conversation: UUID, id: UInt64 = 10, action: ConsequentialActionKind = .send,
                            payload: String = "Exact synthetic message body. No real recipient or service.") throws -> ActionProposalRecord {
    let date = Date().addingTimeInterval(-60 + Double(id % 10))
    let proposal = try ActionProposal(id: ApprovalID(proposalUUID(id)), teammateID: TeammateID(proposalUUID(900)),
                                       conversationID: ConversationID(conversation), profileRevision: 1, contextRevision: 0,
                                       action: action, target: "Synthetic demo account / exact demo recipient", payload: payload,
                                       consequence: "Only a local decision is recorded; no message is sent and no access is granted.",
                                       createdAt: date, expiresAt: date.addingTimeInterval(300))
    return ActionProposalRecord(proposal: proposal, fingerprint: try proposal.fingerprint(), state: .pending, revision: 1, updatedAt: date)
}
private extension NSView { var proposalDescendants: [NSView] { subviews + subviews.flatMap(\.proposalDescendants) } }
