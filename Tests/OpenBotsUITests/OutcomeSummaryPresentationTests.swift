import AppKit
import OpenBotsDomain
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class OutcomeSummaryPresentationTests: XCTestCase {
    func testRunDefaultsNeverExposeRecordIdentityPrivateInputOrTechnicalMetadata() throws {
        for state in outcomeRunStates {
            let review = try outcomeRun(state: state, input: .outcomeUnknown)
            let text = OutcomeSummaryPresentation.run(review, now: review.record.updatedAt).plainText
            for sentinel in [review.id.rawValue.uuidString, review.record.request.teammateID.rawValue.uuidString,
                             review.record.request.conversationID.rawValue.uuidString, "PRIVATE-INPUT-SENTINEL",
                             "987654321", "lease", "revision", "outcomeUnknown", "stateChanged"] {
                XCTAssertFalse(text.contains(sentinel), "Default \(state) summary exposed \(sentinel)")
            }
            XCTAssertFalse(text.isEmpty)
        }
    }

    func testAcknowledgementDoesNotClaimFinishedWork() throws {
        let review = try outcomeRun(state: .running, input: .acknowledged)
        let summary = OutcomeSummaryPresentation.run(review, now: review.record.updatedAt)
        XCTAssertEqual(summary.title, "Message received in demo")
        XCTAssertTrue(summary.result.contains("does not mean the work is finished"))
        XCTAssertTrue(summary.nextStep.contains("Finish Demo"))
        XCTAssertFalse(summary.title.contains("finished"))
    }

    func testInterruptedAndFailedRunsKeepUnknownOutcomeAndNoAutomaticReplayVisible() throws {
        for state in [WorkRunState.failed, .interrupted] {
            let review = try outcomeRun(state: state, input: .outcomeUnknown)
            let summary = OutcomeSummaryPresentation.run(review, now: review.record.updatedAt)
            XCTAssertTrue(summary.attention?.contains("outcome is unknown") ?? false)
            XCTAssertTrue(summary.attention?.contains("Nothing will be resent automatically") ?? false)
            XCTAssertTrue(summary.nextStep.contains("Nothing restarts automatically"))
            XCTAssertTrue(summary.result.contains(state == .failed ? "No successful work" : "not successful work"))
        }
    }

    func testStopRequestIsNotPresentedAsFinishedOrARealProcessStop() throws {
        let review = try outcomeRun(state: .stopping, input: .submitted)
        let summary = OutcomeSummaryPresentation.run(review, now: review.record.updatedAt)
        XCTAssertEqual(summary.title, "Demo stop requested")
        XCTAssertTrue(summary.result.contains("not a real process"))
        XCTAssertTrue(summary.nextStep.contains("Finish Demo Stop"))
        XCTAssertTrue(summary.nextStep.contains("without completing"))
        XCTAssertTrue(summary.attention?.contains("not been confirmed") ?? false)
    }

    func testExpiredAndIncompleteDemosNameTheAvailableRecoveryActionWithoutTechnicalTerms() throws {
        let expired = try outcomeRun(state: .running, input: .submitted, expired: true)
        let summary = OutcomeSummaryPresentation.run(expired, now: expired.record.updatedAt)
        XCTAssertEqual(summary.title, "This demo needs recovery")
        XCTAssertTrue(summary.nextStep.contains("Recover Expired Demos"))
        XCTAssertFalse(summary.plainText.contains("lease"))
        let queued = try outcomeRun(state: .queued, input: .queued, hasLease: false)
        let incomplete = OutcomeSummaryPresentation.run(queued, now: queued.record.updatedAt)
        XCTAssertTrue(incomplete.nextStep.contains("Fail Demo"))
        XCTAssertEqual(queued.record.state, .queued, "Presentation must not change the saved state")
    }

    func testEveryRunStateExplainsResultAndNextStep() throws {
        for state in outcomeRunStates {
            let review = try outcomeRun(state: state, input: .acknowledged)
            let summary = OutcomeSummaryPresentation.run(review, now: review.record.updatedAt)
            XCTAssertFalse(summary.result.isEmpty)
            XCTAssertFalse(summary.nextStep.isEmpty)
            XCTAssertFalse(summary.symbol.isEmpty)
        }
    }

    func testProposalDefaultsOmitIDsAndFingerprintButRetainExactApprovalContent() throws {
        for state in outcomeProposalStates {
            let record = try outcomeProposal(state: state)
            let summary = OutcomeSummaryPresentation.proposal(record, isExpired: false)
            for sentinel in [record.id.rawValue.uuidString, record.proposal.teammateID.rawValue.uuidString,
                             record.proposal.conversationID.rawValue.uuidString, record.fingerprint,
                             "987654321", "fingerprint", "revision"] {
                XCTAssertFalse(summary.plainText.contains(sentinel))
            }
            let content = ApprovalReviewContent(record)
            XCTAssertTrue(content.target.utf8.elementsEqual(record.proposal.target.utf8))
            XCTAssertTrue(content.payload.utf8.elementsEqual(record.proposal.payload.utf8))
            XCTAssertTrue(content.consequence.utf8.elementsEqual(record.proposal.consequence.utf8))
            XCTAssertEqual(content.expiresAt, record.proposal.expiresAt)
            XCTAssertFalse(summary.nextStep.isEmpty)
        }
    }

    func testApprovedProposalExplainsRevocationAndNeverImpliesExecution() throws {
        let record = try outcomeProposal(state: .approved)
        let summary = OutcomeSummaryPresentation.proposal(record, isExpired: false)
        XCTAssertTrue(summary.title.contains("nothing executed"))
        XCTAssertTrue(summary.result.contains("No access was granted"))
        XCTAssertTrue(summary.nextStep.contains("Cancel Demo Approval"))
    }

    func testExpiredPendingOrApprovedProposalNeedsExplicitNewReview() throws {
        for state in [ActionProposalState.pending, .approved] {
            let record = try outcomeProposal(state: state)
            let summary = OutcomeSummaryPresentation.proposal(record, isExpired: true)
            XCTAssertEqual(summary.title, "This review has expired")
            XCTAssertTrue(summary.nextStep.contains("Record Expiry"))
            XCTAssertTrue(summary.nextStep.contains("new proposal"))
            XCTAssertEqual(record.state, state, "Showing expiry must not write an expiry decision")
        }
    }

    func testViewsKeepApprovalContentBeforeCollapsedTechnicalDetails() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let run = try String(contentsOf: root.appendingPathComponent("Sources/OpenBotsUI/RunRecoveryWorkspaceView.swift"), encoding: .utf8)
        let proposal = try String(contentsOf: root.appendingPathComponent("Sources/OpenBotsUI/ActionProposalWorkspaceView.swift"), encoding: .utf8)
        for source in [run, proposal] {
            let beforeDetails = try XCTUnwrap(source.components(separatedBy: "DisclosureGroup(\"Technical details\")").first)
            XCTAssertTrue(source.contains("DisclosureGroup(\"Technical details\")"))
            XCTAssertTrue(beforeDetails.contains("OutcomeSummaryView(summary: summary)"))
            for technicalDisplay in ["Text(\"Revision", ".uuidString", "field(\"Frozen fingerprint", "Text(\"Local demo lease expires"] {
                XCTAssertFalse(beforeDetails.contains(technicalDisplay), "Default view exposes technical display \(technicalDisplay)")
            }
        }
        let defaultProposal = proposal.components(separatedBy: "DisclosureGroup(\"Technical details\")")[0]
        for required in ["field(\"Exact target\", content.target)", "AttachmentPreviewPlainText(text: content.payload)",
                         "field(\"Consequence\", content.consequence)", "Text(content.expiresAt, style: .date)",
                         "Text(content.expiresAt, style: .time)", "model.decide(record, decision:"] {
            XCTAssertTrue(defaultProposal.contains(required), "Approval-relevant content or action moved behind disclosure")
        }
    }

    func testWindowlessDefaultViewsRemainBoundedAndDoNotMaterializeTechnicalIdentityFields() async throws {
        let review = try outcomeRun(state: .interrupted, input: .outcomeUnknown)
        let record = try outcomeProposal(state: .approved)
        let service = OutcomeReadOnlyFixture(run: review, proposal: record)
        let runModel = RunRecoveryWorkspaceModel(service: service)
        runModel.activateConversation(review.record.request.conversationID.rawValue)
        await runModel.load()
        let proposalModel = ActionProposalWorkspaceModel(service: service)
        proposalModel.activateConversation(record.proposal.conversationID.rawValue, teammateName: "Ada")
        await proposalModel.load()
        for scheme in [ColorScheme.light, .dark] {
            let root = VStack(alignment: .leading, spacing: 16) {
                RunRecoveryWorkspaceView(model: runModel)
                ActionProposalWorkspaceView(model: proposalModel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background).environment(\.colorScheme, scheme)
            let host = NSHostingController(rootView: root)
            host.view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            for width: CGFloat in [238, 760] {
                host.view.frame = CGRect(x: 0, y: 0, width: width, height: 2_000)
                for _ in 0..<3 { host.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(5)) }
                let size = host.sizeThatFits(in: CGSize(width: width, height: 2_000))
                XCTAssertTrue(size.width.isFinite && size.height.isFinite)
                XCTAssertGreaterThan(size.height, 0)
                XCTAssertLessThanOrEqual(size.width, width + 0.5)
                XCTAssertLessThanOrEqual(size.height, 2_000)
                let fields = host.view.outcomeDescendants.compactMap { $0 as? NSTextField }
                    .filter { !$0.isHiddenOrHasHiddenAncestor }
                let strings = fields.map(\.stringValue).joined(separator: "\n")
                for sentinel in [review.id.rawValue.uuidString, record.id.rawValue.uuidString, record.fingerprint] {
                    XCTAssertFalse(strings.contains(sentinel), "Collapsed technical field is present in native controls")
                }
                let payloads = host.view.outcomeDescendants.compactMap { $0 as? NSTextView }
                let payload = try XCTUnwrap(payloads.first { $0.string == record.proposal.payload })
                XCTAssertFalse(payload.isEditable)
                XCTAssertTrue(payload.isSelectable)
                try captureOutcome(host.view, name: "outcomes-\(scheme == .dark ? "dark" : "light")-\(Int(width))")
            }
        }
        let mutations = await service.mutationCount
        XCTAssertEqual(mutations, 0)
        // Native, windowless rendering only; no live keyboard/VoiceOver claim.
    }

    private func captureOutcome(_ host: NSView, name: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".build.noindex/shutdown-ui-tests/rendered/outcomes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
}

private let outcomeRunStates: [WorkRunState] = [.queued, .starting, .running, .waitingForUser, .stopping, .succeeded, .failed, .interrupted]
private let outcomeProposalStates: [ActionProposalState] = [.pending, .approved, .denied, .cancelled, .expired]
private let outcomeConversation = UUID(uuidString: "CCCCCCCC-1111-2222-3333-444444444444")!
private let outcomeTeammate = UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444")!

private func outcomeRun(state: WorkRunState, input: RunInputState, expired: Bool = false, hasLease: Bool = true) throws -> RunRecoveryReview {
    let date = Date()
    let message = MessageID(UUID(uuidString: "BBBBBBBB-1111-2222-3333-444444444444")!)
    let request = try WorkRequest(runID: RunID(UUID(uuidString: "DDDDDDDD-1111-2222-3333-444444444444")!),
                                  teammateID: TeammateID(outcomeTeammate), conversationID: ConversationID(outcomeConversation),
                                  initiatingMessageID: message, profileRevision: 987654321,
                                  initialInput: WorkInput(messageID: message, sequence: 1, text: "PRIVATE-INPUT-SENTINEL"), submittedAt: date)
    let lease = hasLease ? RunLease(ownerID: UUID(), token: UUID(), generation: 987654321,
                                   expiresAt: date.addingTimeInterval(expired ? -1 : 3_600)) : nil
    return .init(record: .init(request: request, origin: .localFixture, state: state, revision: 987654321, lease: lease, updatedAt: date),
                 inputs: [.init(runID: request.runID, messageID: message, sequence: 1, state: input, updatedAt: date)],
                 entries: [.init(runID: request.runID, sequence: 1, kind: .stateChanged, state: state, inputMessageID: message, recordedAt: date)])
}

private func outcomeProposal(state: ActionProposalState) throws -> ActionProposalRecord {
    let date = Date()
    let proposal = try ActionProposal(id: ApprovalID(UUID(uuidString: "EEEEEEEE-1111-2222-3333-444444444444")!),
                                       teammateID: TeammateID(outcomeTeammate), conversationID: ConversationID(outcomeConversation),
                                       profileRevision: 987654321, contextRevision: 987654321, action: .send,
                                       target: "Synthetic account / exact recipient",
                                       payload: "Exact content: cafe\u{301}\nNo real message will be sent.",
                                       consequence: "Only a local decision is saved; no message is sent.",
                                       createdAt: date, expiresAt: date.addingTimeInterval(300))
    return .init(proposal: proposal, fingerprint: try proposal.fingerprint(), state: state, revision: 987654321, updatedAt: date)
}

private actor OutcomeReadOnlyFixture: RunRecoveryFixtureServing, ActionProposalFixtureServing {
    let run: RunRecoveryReview
    let proposal: ActionProposalRecord
    private(set) var mutationCount = 0
    init(run: RunRecoveryReview, proposal: ActionProposalRecord) { self.run = run; self.proposal = proposal }
    func reviews(conversationID: ConversationID) async throws -> [RunRecoveryReview] { [run] }
    func proposals(conversationID: ConversationID) async throws -> [ActionProposalRecord] { [proposal] }
    func startDemo(conversationID: ConversationID) async throws -> RunRecoveryReview { try reject() }
    func acknowledgeDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview { try reject() }
    func finishDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview { try reject() }
    func interruptDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview { try reject() }
    func recoverExpiredDemos(conversationID: ConversationID) async throws -> [RunRecoveryReview] { try reject() }
    func prepare(conversationID: ConversationID, action: ConsequentialActionKind) async throws -> ActionProposalRecord { try reject() }
    func decide(_ review: ActionProposalRecord, decision: ActionProposalDecision) async throws -> ActionProposalRecord { try reject() }
    private func reject<T>() throws -> T { mutationCount += 1; throw ActionProposalError.unavailable }
}

private extension NSView { var outcomeDescendants: [NSView] { subviews + subviews.flatMap(\.outcomeDescendants) } }
