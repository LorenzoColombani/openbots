import Foundation
import XCTest
@testable import OpenBotsDomain

final class HiringDomainTests: XCTestCase {
    private let draftID = HiringDraftID(
        UUID(uuidString: "92000000-0000-0000-0000-000000000001")!
    )
    private let instant = Date(timeIntervalSince1970: 1_788_100_000)

    func testReadyDraftRequiresNameAndRoleAndRevisionMovesForward() throws {
        let collecting = try HiringDraft(
            id: draftID,
            displayName: "  Ada  ",
            createdAt: instant,
            updatedAt: instant
        )
        XCTAssertEqual(collecting.displayName, "Ada")
        XCTAssertNil(collecting.role)

        XCTAssertThrowsError(
            try HiringDraft(
                id: draftID,
                phase: .readyForReview,
                displayName: "Ada",
                createdAt: instant,
                updatedAt: instant
            )
        ) { error in
            XCTAssertEqual(error as? DomainValidationError, .empty(field: "candidate role"))
        }

        let ready = try collecting.revised(
            phase: .readyForReview,
            role: "Research lead",
            responsibilities: "Trace claims to sources.",
            updatedAt: instant.addingTimeInterval(5)
        )
        XCTAssertEqual(ready.phase, .readyForReview)
        XCTAssertEqual(ready.revision, 2)
        XCTAssertEqual(ready.displayName, "Ada")
        XCTAssertEqual(ready.role, "Research lead")
        XCTAssertThrowsError(
            try ready.revised(updatedAt: instant)
        )
    }

    func testTurnPreservesExactTextAndEnforcesBound() throws {
        let exact = "  I need a careful researcher.\n"
        let turn = try HiringTurn(
            id: HiringTurnID(UUID()),
            draftID: draftID,
            sequence: 1,
            author: .user,
            text: exact,
            createdAt: instant
        )
        XCTAssertEqual(turn.text, exact)
        XCTAssertThrowsError(
            try HiringTurn(
                id: HiringTurnID(UUID()),
                draftID: draftID,
                sequence: 0,
                author: .guide,
                text: "Question",
                createdAt: instant
            )
        )
        XCTAssertThrowsError(
            try HiringTurn(
                id: HiringTurnID(UUID()),
                draftID: draftID,
                sequence: 1,
                author: .guide,
                text: String(repeating: "x", count: HiringTurn.maximumTextLength + 1),
                createdAt: instant
            )
        )
    }

    func testSnapshotRequiresOneOrderedContiguousDraftConversation() throws {
        let draft = try HiringDraft(
            id: draftID,
            createdAt: instant,
            updatedAt: instant.addingTimeInterval(3)
        )
        let first = try turn(id: 1, draftID: draftID, sequence: 1, at: instant)
        let second = try turn(id: 2, draftID: draftID, sequence: 2, at: instant.addingTimeInterval(1))
        let snapshot = try HiringDraftSnapshot(draft: draft, turns: [first, second])
        XCTAssertEqual(snapshot.turns.map(\.sequence), [1, 2])

        XCTAssertThrowsError(try HiringDraftSnapshot(draft: draft, turns: [second, first]))
        let otherDraftTurn = try turn(
            id: 3,
            draftID: HiringDraftID(UUID()),
            sequence: 1,
            at: instant
        )
        XCTAssertThrowsError(try HiringDraftSnapshot(draft: draft, turns: [otherDraftTurn]))
    }

    private func turn(
        id: Int,
        draftID: HiringDraftID,
        sequence: Int64,
        at date: Date
    ) throws -> HiringTurn {
        try HiringTurn(
            id: HiringTurnID(UUID(uuidString: String(format: "92000000-0000-0000-0000-%012d", id))!),
            draftID: draftID,
            sequence: sequence,
            author: sequence.isMultiple(of: 2) ? .user : .guide,
            text: "Turn \(sequence)",
            createdAt: date
        )
    }
}
