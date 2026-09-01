import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence

@Suite("Durable Claude execution observations")
struct SQLiteClaudeExecutionEvidenceRepositoryTests {
    @Test("Admission binds execution selection to the exact current bot settings before creating any turn")
    func savedSelectionBinding() async throws {
        for controlled in [false, true] {
            for field in ["model", "effort", "context"] {
                let f = try ControlledTextFixture(); defer { f.remove() }
                let store = try f.open(); let p = try await f.prepare(store, controlled: controlled)
                var teammate = try #require(try await store.teammate(id: f.bot))
                switch field {
                case "model": teammate.claudeModel = "claude-haiku-4-5-20251001"
                case "effort": teammate.claudeEffort = "low"
                default: teammate.claudeContextWindow = "standard"
                }
                // Deliberately keep the revision equal: matching only that
                // number must not validate an incorrectly assembled selection.
                try await store.update(teammate, expectedProfileRevision: teammate.profile.revision)
                await #expect(throws: TextTurnRepositoryError.invalidRequest) {
                    if controlled { return try await f.begin(store, p) }
                    return try await store.beginTextTurn(request: p.request, userMessage: p.user,
                        expectedPreviousSequence: 1, ownerID: f.owner, token: f.token, now: f.at(1), leaseDuration: 60)
                }
                #expect(try await store.message(id: p.user.id) == nil)
                #expect(try await store.message(id: p.replyID) == nil)
                #expect(try await store.query(sql: "SELECT id FROM work_runs;").isEmpty)
                #expect(try await store.query(sql: "SELECT run_id FROM claude_text_execution_evidence;").isEmpty)
                #expect(try await store.query(sql: "SELECT run_id FROM controlled_memory_text_turns;").isEmpty)
            }
        }
    }

    @Test("Requested selection, startup observation and differing result remain distinct through reopen")
    func executionReopenAndRetry() async throws {
        let f = try ControlledTextFixture(); defer { f.remove() }
        let store = try f.open(); let p = try await f.prepare(store, controlled: false)
        var current = try await store.beginTextTurn(request: p.request, userMessage: p.user,
            expectedPreviousSequence: 1, ownerID: f.owner, token: f.token, now: f.at(1), leaseDuration: 60)
        #expect(try await store.textTurnExecutionEvidence(id: current.run.id)?.modelStatus == .notObserved)
        current = try await store.recordTextTurnExecutionEvidence(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, evidence: f.initialized, now: f.at(2))
        #expect(try await f.open().textTurnExecutionEvidence(id: current.run.id)?.modelStatus == .startupObserved)
        current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "", inputEvidence: .submitted, now: f.at(3))
        current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "Actual reply", inputEvidence: .acknowledged, now: f.at(4))
        let result = ClaudeExecutionEvidence(request: f.execution, initializedModel: "claude-sonnet-5", resultModel: "claude-opus-5")
        let done = try await store.finishTextTurnWithExecutionEvidence(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "Actual reply", outcome: .succeeded, diagnosticCode: nil, evidence: result, now: f.at(5))
        let reopened = try f.open()
        let evidence = try #require(try await reopened.textTurnExecutionEvidence(id: current.run.id))
        #expect(evidence == result && evidence.modelStatus == .resultDiffers)
        #expect(evidence.request.selection.model == "claude-sonnet-5")
        #expect(try await reopened.finishTextTurnWithExecutionEvidence(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "Actual reply", outcome: .succeeded, diagnosticCode: nil, evidence: result, now: f.at(90)) == done)
    }

    @Test("A result cannot be checkpointed, introduce unseen initialization, or survive a failed terminal transaction")
    func evidenceCannotPromoteEarly() async throws {
        let f = try ControlledTextFixture(); defer { f.remove() }
        let store = try f.open(); let p = try await f.prepare(store, controlled: false)
        var current = try await store.beginTextTurn(request: p.request, userMessage: p.user,
            expectedPreviousSequence: 1, ownerID: f.owner, token: f.token, now: f.at(1), leaseDuration: 60)
        await #expect(throws: TextTurnRepositoryError.invalidEvidence) {
            try await store.recordTextTurnExecutionEvidence(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, evidence: f.result, now: f.at(2))
        }
        current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "", inputEvidence: .submitted, now: f.at(2))
        current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "Real text", inputEvidence: .acknowledged, now: f.at(3))
        await #expect(throws: TextTurnRepositoryError.invalidEvidence) {
            try await store.finishTextTurnWithExecutionEvidence(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "Real text", outcome: .succeeded, diagnosticCode: nil, evidence: f.result, now: f.at(4))
        }
        current = try await store.recordTextTurnExecutionEvidence(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, evidence: f.initialized, now: f.at(4))
        _ = try await store.execute(sql: "CREATE TRIGGER reject_evidence_terminal BEFORE INSERT ON run_journal_entries WHEN NEW.state='succeeded' BEGIN SELECT RAISE(ABORT,'terminal rejected'); END;")
        await #expect(throws: SQLiteStoreError.self) {
            try await store.finishTextTurnWithExecutionEvidence(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "Real text", outcome: .succeeded, diagnosticCode: nil, evidence: f.result, now: f.at(5))
        }
        #expect(try await store.textTurnExecutionEvidence(id: current.run.id) == f.initialized)
        #expect(try await store.message(id: p.replyID)?.deliveryState == .pending)
        await #expect(throws: TextTurnRepositoryError.invalidEvidence) {
            try await store.finishTextTurnWithExecutionEvidence(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "Real text", outcome: .failed, diagnosticCode: nil, evidence: f.result, now: f.at(5))
        }
    }

    @Test("Frozen session, selection and lease fence execution evidence")
    func evidenceBinding() async throws {
        let f = try ControlledTextFixture(); defer { f.remove() }
        let store = try f.open(); let p = try await f.prepare(store, controlled: false)
        let current = try await store.beginTextTurn(request: p.request, userMessage: p.user,
            expectedPreviousSequence: 1, ownerID: f.owner, token: f.token, now: f.at(1), leaseDuration: 60)
        let changed = ClaudeExecutionRequest(sessionID: UUID(), selection: f.execution.selection, launchModel: f.execution.launchModel)
        await #expect(throws: TextTurnRepositoryError.invalidEvidence) {
            try await store.recordTextTurnExecutionEvidence(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, evidence: .init(request: changed, initializedModel: "claude-sonnet-5", resultModel: nil), now: f.at(2))
        }
        await #expect(throws: RunJournalError.leaseUnavailable) {
            try await store.recordTextTurnExecutionEvidence(id: current.run.id, expectedRevision: current.run.revision,
                token: UUID(), evidence: f.initialized, now: f.at(2))
        }
        let saved = try await store.recordTextTurnExecutionEvidence(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, evidence: f.initialized, now: f.at(2))
        await #expect(throws: RunJournalError.staleRevision) {
            try await store.recordTextTurnExecutionEvidence(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, evidence: f.initialized, now: f.at(3))
        }
        #expect(try await store.run(id: current.run.id)?.revision == saved.run.revision)
    }

    @Test("Legacy turns remain unknown after a realistic schema19 migration; no observed or result defaults are invented")
    func migrationPreservesUnknown() async throws {
        let f = try ControlledTextFixture(); defer { f.remove() }
        let store = try f.open(); let p = try await f.prepare(store, controlled: false, executionRecorded: false)
        let current = try await store.beginTextTurn(request: p.request, userMessage: p.user,
            expectedPreviousSequence: 1, ownerID: f.owner, token: f.token, now: f.at(1), leaseDuration: 60)
        _ = try await store.execute(sql: "DROP TABLE claude_text_execution_evidence;")
        _ = try await store.execute(sql: "DROP TABLE controlled_memory_text_turns;")
        _ = try await store.execute(sql: "DELETE FROM schema_migrations WHERE version=20;")
        let reopened = try f.open()
        #expect(try await reopened.textTurnExecutionEvidence(id: current.run.id) == nil)
        #expect(try await reopened.pendingTextTurns(appOwnerID: f.appOwner, limit: 10) == [current])
        #expect(try await reopened.message(id: p.user.id) == p.user)
        #expect(try await reopened.query(sql: "SELECT version FROM schema_migrations;").count == SQLiteStore.expectedMigrationCount)
        #expect(try await reopened.query(sql: "SELECT run_id FROM claude_text_execution_evidence;").isEmpty)
        #expect(try await reopened.query(sql: "SELECT run_id FROM controlled_memory_text_turns;").isEmpty)
    }
}
