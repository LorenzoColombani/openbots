import Foundation
import XCTest
@testable import OpenBotsDomain

final class DomainModelTests: XCTestCase {
    private let teammateID = TeammateID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    private let projectID = ProjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    private let conversationID = ConversationID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    private let messageID = MessageID(UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
    private let instant = Date(timeIntervalSince1970: 1_750_000_000)

    func testTypedIdentityCodableIsStableAndTypeSafe() throws {
        let data = try JSONEncoder().encode(teammateID)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"00000000-0000-0000-0000-000000000001\"")
        XCTAssertEqual(try JSONDecoder().decode(TeammateID.self, from: data), teammateID)
    }

    func testCapabilityScopeHasVersionedStableEncoding() throws {
        let scope = CapabilityScope.userSelectedRead(reference: "bookmark-ref-7")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(scope)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "{\"kind\":\"userSelectedRead\",\"reference\":\"bookmark-ref-7\",\"version\":1}"
        )
        XCTAssertEqual(try JSONDecoder().decode(CapabilityScope.self, from: data), scope)
    }

    func testProfileValidationAndRevision() throws {
        let original = try TeammateProfile(displayName: "  Nova ", role: " Research ")
        XCTAssertEqual(original.displayName, "Nova")
        XCTAssertEqual(original.role, "Research")
        let revised = try original.revised(role: "Research and synthesis")
        XCTAssertEqual(revised.revision, 2)
        XCTAssertThrowsError(try TeammateProfile(displayName: "  ", role: "Research"))
    }

    func testTeammateArchiveWaitsForActiveRunAndIsReversible() throws {
        var state = TeammateLifecycle.active
        state = try state.applying(.requestArchive(hasActiveRun: true))
        XCTAssertEqual(state, .archivePendingRunResolution)
        state = try state.applying(.activeRunResolved)
        XCTAssertEqual(state, .archived)
        state = try state.applying(.restore)
        XCTAssertEqual(state, .active)
        XCTAssertThrowsError(try state.applying(.restore))
    }

    func testTeamLeadMustRemainAnActiveMember() throws {
        let other = TeammateID(UUID(uuidString: "00000000-0000-0000-0000-000000000009")!)
        var team = try Team(
            id: TeamID(UUID()),
            name: "Studio",
            leadID: teammateID,
            memberIDs: [teammateID, other],
            createdAt: instant,
            updatedAt: instant
        )
        XCTAssertThrowsError(try team.removeMember(teammateID))
        try team.assignLead(other)
        try team.removeMember(teammateID)
        XCTAssertEqual(team.memberIDs, [other])
    }

    func testDeliveryAcknowledgementIsDistinctFromSubmission() throws {
        var state = MessageDeliveryState.pending
        state = try state.applying(.submit)
        XCTAssertEqual(state, .submitted)
        state = try state.applying(.acknowledge)
        XCTAssertEqual(state, .acknowledged)
        state = try state.applying(.markOutcomeUnknown)
        XCTAssertEqual(state, .outcomeUnknown)
        XCTAssertThrowsError(try MessageDeliveryState.pending.applying(.acknowledge))
    }

    func testWorkRequestBindsRunToInitiatingMessage() throws {
        let input = try WorkInput(messageID: messageID, sequence: 1, text: "Research this")
        XCTAssertNoThrow(
            try WorkRequest(
                runID: RunID(UUID()), teammateID: teammateID, conversationID: conversationID,
                initiatingMessageID: messageID, selectedProjectID: projectID,
                profileRevision: 1, initialInput: input, submittedAt: instant
            )
        )
        XCTAssertThrowsError(
            try WorkRequest(
                runID: RunID(UUID()), teammateID: teammateID, conversationID: conversationID,
                initiatingMessageID: MessageID(UUID()), profileRevision: 1,
                initialInput: input, submittedAt: instant
            )
        )
    }

    func testMemoryScopeNeverCreatesImplicitTeamScope() {
        XCTAssertTrue(
            MemoryScope.user.isReadable(
                by: teammateID,
                selectedProjectID: nil,
                activeProjectMemberships: []
            )
        )
        XCTAssertTrue(
            MemoryScope.project(projectID).isReadable(
                by: teammateID,
                selectedProjectID: projectID,
                activeProjectMemberships: [projectID]
            )
        )
        XCTAssertFalse(
            MemoryScope.project(projectID).isReadable(
                by: teammateID,
                selectedProjectID: nil,
                activeProjectMemberships: [projectID]
            )
        )
    }

    func testApprovalCannotExecuteBeforeExactUserDecision() throws {
        var approval = try ApprovalRequest(
            id: ApprovalID(UUID()), teammateID: teammateID, conversationID: conversationID,
            action: .overwrite, exactTargetSummary: "/chosen/report.pdf",
            consequenceSummary: "Replace the existing file; macOS sync may propagate this change.",
            fingerprint: ApprovalFingerprint("sha256:test-target-and-operation"), requestedAt: instant
        )
        XCTAssertThrowsError(try approval.apply(.beginExecution, at: instant))
        try approval.apply(.resolve(.approve), at: instant)
        try approval.apply(.beginExecution, at: instant)
        try approval.apply(.executionSucceeded, at: instant)
        XCTAssertEqual(approval.state, .succeeded)
    }
}
