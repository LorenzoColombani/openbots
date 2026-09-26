import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
@testable import OpenBotsServices
import Testing

@Suite("Launch sweep: the sole running copy closes turns a dead process left busy")
struct SoleInstanceTextTurnProcessAbsenceTests {
    @Test("A pending turn from another process is interrupted once, keeping its partial text")
    func soleInstanceInterruptsOrphan() async throws {
        let f = try TextRecoveryFixture(); defer { f.remove() }
        let store = try f.open()
        let partial = "Half an answer."
        let pending = try await f.seedPending(store, hasSession: true, partial: partial)
        let prover = SoleInstanceTextTurnProcessAbsence(
            ownersHeldByThisProcess: { [UUID()] }, isSoleRunningInstance: { true })
        let service = TextTurnRecoveryService(repository: store, appOwnerID: f.appOwner,
            absenceProver: prover, clock: { f.at(120) })

        let report = await service.recover()

        #expect(report.status == .completed && report.interruptedCount == 1 && !report.needsAttention)
        #expect(report.entries.map(\.disposition) == [.interrupted])
        let saved = try #require(try await store.run(id: pending.run.id))
        #expect(saved.state == .interrupted && saved.lease == nil)
        let rows = try await store.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements
        #expect(rows.count == 2)
        #expect(rows[0].deliveryState == .failed && rows[1].deliveryState == .outcomeUnknown)
        guard case let .text(savedPartial) = rows[1].parts[0].content else {
            Issue.record("The sweep replaced the saved partial text."); return
        }
        #expect(savedPartial == partial)
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).isEmpty)
        // A second pass finds nothing and changes nothing.
        let again = await service.recover()
        #expect(again.status == .completed && again.entries.isEmpty)
    }

    @Test("Another running copy of the app proves nothing")
    func anotherInstanceLeavesTheTurn() async throws {
        let f = try TextRecoveryFixture(); defer { f.remove() }
        let store = try f.open()
        let pending = try await f.seedPending(store, hasSession: true, partial: "Kept.")
        let prover = SoleInstanceTextTurnProcessAbsence(
            ownersHeldByThisProcess: { [] }, isSoleRunningInstance: { false })
        let service = TextTurnRecoveryService(repository: store, appOwnerID: f.appOwner,
            absenceProver: prover, clock: { f.at(120) })

        let report = await service.recover()

        #expect(report.status == .completed && report.interruptedCount == 0)
        #expect(report.entries.map(\.disposition) == [.absenceUnproven])
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10) == [pending])
    }

    @Test("A turn leased by this process's own reply service is live, not orphaned")
    func ownLeaseIsNeverInterrupted() async throws {
        let f = try TextRecoveryFixture(); defer { f.remove() }
        let store = try f.open()
        let pending = try await f.seedPending(store, hasSession: true, partial: "Still running.")
        let prover = SoleInstanceTextTurnProcessAbsence(
            ownersHeldByThisProcess: { [f.processOwner] }, isSoleRunningInstance: { true })
        let service = TextTurnRecoveryService(repository: store, appOwnerID: f.appOwner,
            absenceProver: prover, clock: { f.at(120) })

        let report = await service.recover()

        #expect(report.entries.map(\.disposition) == [.absenceUnproven])
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10) == [pending])
    }
}
