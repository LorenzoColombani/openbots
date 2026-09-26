import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsPersistence

@Suite("Reversible teammate archive")
struct SQLiteTeammateArchiveTests {
    @Test("Archive and restore preserve every unrelated row across actual reopen", arguments: ["legacy", "guide", "photo"])
    func preservationAcrossReopen(appearance: String) async throws {
        let f = try ArchiveFixture(); defer { f.remove() }
        var original: Teammate!
        var archived: Teammate!
        var preserved: [String: [String]] = [:]
        weak var closed: SQLiteStore?
        do {
            let store = try f.open(); closed = store
            original = try await f.seed(store, appearance: appearance, includeContent: true)
            preserved = try await f.unchangedRows(store)
            let service = TeammateArchiveService(repository: store, clock: ArchiveClock(date: f.at(10)))
            archived = try await service.archiveTeammate(id: original.id, expectedProfileRevision: original.profile.revision)
            var expected = original!
            expected.profile = try expected.profile.revised()
            expected.lifecycle = .archived
            expected.updatedAt = f.at(10)
            #expect(archived == expected)
            #expect(try await store.selectedConversationID() == nil)
            #expect(try await service.archivedTeammates() == [archived])
            #expect(try await store.listTeammates(includingArchived: false).isEmpty)
            #expect(try await f.unchangedRows(store) == preserved)
        }
        #expect(closed == nil)
        let reopened = try f.open()
        #expect(try await reopened.teammate(id: f.teammateID) == archived)
        #expect(try await f.unchangedRows(reopened) == preserved)
        let restored = try await TeammateArchiveService(repository: reopened, clock: ArchiveClock(date: f.at(20)))
            .restoreTeammate(id: f.teammateID, expectedProfileRevision: archived.profile.revision)
        var expected = original!
        expected.profile = try expected.profile.revised().revised()
        expected.updatedAt = f.at(20)
        #expect(restored == expected)
        #expect(try await reopened.archivedTeammates().isEmpty)
        #expect(try await reopened.listTeammates(includingArchived: false) == [restored])
        #expect(try await reopened.selectedConversationID() == nil)
        #expect(try await f.unchangedRows(reopened) == preserved)
        #expect(try await reopened.query(sql: "SELECT COUNT(*) AS n FROM teammate_profile_revisions;").first?.integer("n") == 3)
    }

    @Test("Every nonterminal durable run blocks archive, without cancelling or marking pending",
          arguments: ["queued", "starting", "running", "waitingForUser", "stopping"])
    func unresolvedRuns(state: String) async throws {
        let f = try ArchiveFixture(); defer { f.remove() }
        let store = try f.open(); let original = try await f.seed(store)
        let message = try f.message(sequence: 1)
        try await store.append(message, expectedPreviousSequence: 0)
        let run = try await store.enqueueRun(f.request(message), origin: .localFixture)
        _ = try await store.execute(sql: "UPDATE work_runs SET state=? WHERE id=?;", bindings: [.text(state), .text(run.id.persistedValue)])
        let before = try await f.unchangedRows(store)
        await #expect(throws: TeammateArchiveError.unresolvedWork) {
            try await store.archiveTeammate(id: f.teammateID, expectedProfileRevision: 1, now: f.at(10))
        }
        #expect(try await store.teammate(id: f.teammateID) == original)
        #expect(try await store.selectedConversationID() == f.conversationID)
        #expect(try await f.unchangedRows(store) == before)
    }

    @Test("Pending and approved proposals block archive until explicitly resolved", arguments: [false, true])
    func unresolvedProposals(approve: Bool) async throws {
        let f = try ArchiveFixture(); defer { f.remove() }
        let store = try f.open(); let original = try await f.seed(store)
        var proposal = try await store.insertProposal(f.proposal())
        if approve { proposal = try await store.decideProposal(proposal, decision: .approve, now: f.at(1)) }
        await #expect(throws: TeammateArchiveError.unresolvedWork) {
            try await store.archiveTeammate(id: f.teammateID, expectedProfileRevision: 1, now: f.at(10))
        }
        #expect(try await store.teammate(id: f.teammateID) == original)
        #expect(try await store.proposals(conversationID: f.conversationID, limit: 10) == [proposal])
        let cancelled = try await store.decideProposal(proposal, decision: .cancel, now: f.at(11))
        _ = try await store.archiveTeammate(id: f.teammateID, expectedProfileRevision: 1, now: f.at(12))
        #expect(try await store.proposals(conversationID: f.conversationID, limit: 10) == [cancelled])
    }

    /// Found in use: nothing moves a card's row past
    /// `approved`, and a quit leaves `pending`, so every bot that had ever been
    /// asked could never be archived. A card lives only inside its turn, which
    /// the run check above already covers.
    @Test("A card left behind by a turn that has ended does not block archive",
          arguments: ["pending", "approved", "executing"])
    func approvalsOfAnEndedTurn(state: String) async throws {
        let f = try ArchiveFixture(); defer { f.remove() }
        let store = try f.open(); _ = try await f.seed(store)
        let message = try f.message(sequence: 1)
        try await store.append(message, expectedPreviousSequence: 0)
        let run = try await store.enqueueRun(f.request(message), origin: .localFixture)
        let approval = try f.approval()
        try await store.insert(approval)
        _ = try await store.execute(sql: """
            UPDATE approvals SET state=?1, resolved_at=CASE WHEN ?1='pending' THEN NULL ELSE requested_at END WHERE id=?2;
            """, bindings: [.text(state), .text(approval.id.persistedValue)])
        _ = try await store.execute(sql: "UPDATE work_runs SET state='interrupted' WHERE id=?;", bindings: [.text(run.id.persistedValue)])
        let archived = try await store.archiveTeammate(id: f.teammateID, expectedProfileRevision: 1, now: f.at(10))
        #expect(archived.lifecycle == .archived)
        #expect(try await store.approvals(conversationID: f.conversationID, limit: 10).map(\.state.rawValue) == [state])
    }

    @Test("Profile edits, duplicate transitions, invalid dates and revision exhaustion fail without archival")
    func revisionAndValidation() async throws {
        let f = try ArchiveFixture(); defer { f.remove() }
        let first = try f.open(); var edited = try await f.seed(first); let second = try f.open()
        edited.profile = try edited.profile.revised(displayName: "Renamed")
        try await second.update(edited, expectedProfileRevision: 1)
        await #expect(throws: TeammateArchiveError.staleRevision) {
            try await first.archiveTeammate(id: f.teammateID, expectedProfileRevision: 1, now: f.at(1))
        }
        await #expect(throws: TeammateArchiveError.invalidTransition) {
            try await first.restoreTeammate(id: f.teammateID, expectedProfileRevision: 2, now: f.at(1))
        }
        await #expect(throws: TeammateArchiveError.invalidDate) {
            try await first.archiveTeammate(id: f.teammateID, expectedProfileRevision: 2, now: Date(timeIntervalSince1970: .infinity))
        }
        #expect(try await first.teammate(id: f.teammateID) == edited)
        let archived = try await first.archiveTeammate(id: f.teammateID, expectedProfileRevision: 2, now: f.at(2))
        await #expect(throws: RepositoryError.optimisticLockFailed(entity: "teammate", id: f.teammateID.persistedValue)) {
            try await second.update(edited, expectedProfileRevision: 2)
        }
        await #expect(throws: TeammateArchiveError.invalidTransition) {
            try await first.archiveTeammate(id: f.teammateID, expectedProfileRevision: archived.profile.revision, now: f.at(3))
        }
        await #expect(throws: TeammateArchiveError.staleRevision) {
            try await first.restoreTeammate(id: f.teammateID, expectedProfileRevision: 2, now: f.at(3))
        }
        _ = try await first.execute(sql: "UPDATE teammates SET profile_revision=?;", bindings: [.integer(Int64.max)])
        await #expect(throws: TeammateArchiveError.revisionExhausted) {
            try await first.restoreTeammate(id: f.teammateID, expectedProfileRevision: UInt64(Int64.max), now: f.at(3))
        }
        await #expect(throws: TeammateArchiveError.notFound) {
            try await first.archiveTeammate(id: TeammateID(UUID()), expectedProfileRevision: 1, now: f.at(3))
        }
    }

    @Test("Archive and enqueue on independent connections cannot both succeed")
    func competingRunAndArchive() async throws {
        let f = try ArchiveFixture(); defer { f.remove() }
        let first = try f.open(); _ = try await f.seed(first); let second = try f.open()
        let message = try f.message(sequence: 1)
        try await first.append(message, expectedPreviousSequence: 0)
        let request = try f.request(message)
        async let archived = try? first.archiveTeammate(id: f.teammateID, expectedProfileRevision: 1, now: f.at(1))
        async let enqueued = try? second.enqueueRun(request, origin: .localFixture)
        let outcomes = await (archived, enqueued)
        #expect((outcomes.0 != nil) != (outcomes.1 != nil))
        let saved = try #require(try await first.teammate(id: f.teammateID))
        let runs = try await first.runs(conversationID: f.conversationID, limit: 10)
        #expect(saved.lifecycle == .archived ? runs.isEmpty : runs.count == 1)
    }

    @Test("Archived identity refuses stale sends, selection, new work and approvals; restore never replays")
    func postArchiveGuardsAndRestore() async throws {
        let f = try ArchiveFixture(); defer { f.remove() }
        let store = try f.open(); _ = try await f.seed(store)
        let prior = try f.message(sequence: 1)
        try await store.append(prior, expectedPreviousSequence: 0)
        let request = try f.request(prior)
        let run = try await store.enqueueRun(request, origin: .localFixture)
        _ = try await store.failUnclaimedLocalFixture(id: run.id, expectedRevision: 1, now: f.at(1))
        let history = try await f.unchangedRows(store)
        let archived = try await store.archiveTeammate(id: f.teammateID, expectedProfileRevision: 1, now: f.at(2))
        let staleMessage = try f.message(sequence: 2)
        await #expect(throws: TeammateArchiveError.invalidTransition) {
            try await store.append(staleMessage, expectedPreviousSequence: 1)
        }
        await #expect(throws: AttachmentRepositoryError.self) {
            try await store.commitLocalMessage(userMessage: staleMessage, expectedPreviousSequence: 1, attachmentIDs: [])
        }
        await #expect(throws: TeammateArchiveError.invalidTransition) {
            try await store.setSelectedConversationID(f.conversationID)
        }
        await #expect(throws: RunJournalError.invalidRequest) {
            try await store.enqueueRun(f.request(prior), origin: .localFixture)
        }
        await #expect(throws: ActionProposalError.contextChanged) { try await store.insertProposal(f.proposal()) }
        await #expect(throws: TeammateArchiveError.invalidTransition) { try await store.insert(f.approval()) }
        _ = try await store.restoreTeammate(id: f.teammateID, expectedProfileRevision: archived.profile.revision, now: f.at(3))
        #expect(try await f.unchangedRows(store) == history)
        await #expect(throws: RunJournalError.invalidRequest) {
            try await store.enqueueRun(f.request(prior), origin: .localFixture)
        }
        #expect(try await store.run(id: run.id)?.state == .failed)
        #expect(try await store.selectedConversationID() == nil)
        try await store.append(staleMessage, expectedPreviousSequence: 1)
    }

    @Test("Restoring is refused while another bot carries the archived bot's name, compared without case")
    func restoreRefusedWhileNameTaken() async throws {
        let f = try ArchiveFixture(); defer { f.remove() }
        let store = try f.open(); let original = try await f.seed(store)
        let archived = try await store.archiveTeammate(id: f.teammateID, expectedProfileRevision: original.profile.revision, now: f.at(1))
        let successor = try Teammate(id: TeammateID(UUID()),
            profile: TeammateProfile(displayName: "archive FIXTURE", role: "Took the name over"),
            appearance: original.appearance, createdAt: f.at(2), updatedAt: f.at(2))
        try await store.insert(successor)

        await #expect(throws: TeammateNameTakenError(existingName: "archive FIXTURE")) {
            try await store.restoreTeammate(id: f.teammateID, expectedProfileRevision: archived.profile.revision, now: f.at(3))
        }
        #expect(try await store.teammate(id: f.teammateID) == archived, "A refused restore changes nothing")
        #expect(try await store.archivedTeammates() == [archived])

        var renamed = successor
        renamed.profile = try successor.profile.revised(displayName: "Successor")
        try await store.update(renamed, expectedProfileRevision: successor.profile.revision)
        let restored = try await store.restoreTeammate(id: f.teammateID, expectedProfileRevision: archived.profile.revision, now: f.at(4))
        #expect(restored.lifecycle == .active)
        #expect(try await store.listTeammates(includingArchived: false).map(\.profile.displayName).sorted() == ["Archive Fixture", "Successor"])
    }

    /// A service reads the roster and then awaits before it writes, so another
    /// path's bot can take the name in between.
    /// The store is the authority: each write checks inside its own transaction.
    @Test("Creation and rename are refused inside the write when an active bot carries the name, even after a roster read from before that bot existed")
    func theNameRuleHoldsInsideTheWrite() async throws {
        let f = try ArchiveFixture(); defer { f.remove() }
        let store = try f.open(); let holder = try await f.seed(store)
        let stale = StaleRosterRepository(store: store)
        let taken = TeammateNameTakenError(existingName: "Archive Fixture")
        func bot(_ name: String) throws -> Teammate {
            try Teammate(id: TeammateID(UUID()), profile: TeammateProfile(displayName: name, role: "Wants the name"),
                appearance: holder.appearance, createdAt: f.at(1), updatedAt: f.at(1))
        }
        // The New Bot sheet's and a hire's path: the chat service's own check reads the stale roster.
        let chats = DurableTeammateChatService(teammateRepository: stale, conversationRepository: store,
            messageRepository: store, provisioningRepository: store, selectionRepository: store)
        await #expect(throws: taken) {
            try await chats.createTeammateAndDirectChat(DurableTeammateDraft(teammateID: TeammateID(UUID()),
                displayName: " archive FIXTURE ", role: "Wants the name", appearance: holder.appearance), selectConversation: false)
        }
        await #expect(throws: taken) {
            try await TeammateProfileService(repository: stale).createQuickTeammate(QuickTeammateDraft(displayName: "ARCHIVE fixture", role: "x"))
        }
        await #expect(throws: taken) { try await store.insert(try bot("Archive Fixture")) }
        #expect(try await store.listTeammates(includingArchived: true).map(\.id) == [holder.id], "a refused name creates nothing")

        // A rename into the name, through the profile service on the stale roster.
        let other = try bot("Other")
        try await store.insert(other)
        await #expect(throws: taken) {
            try await TeammateProfileService(repository: stale).saveProfile(teammateID: other.id, expectedRevision: 1,
                draft: TeammateProfileEditDraft(displayName: "archive fixture", role: "Wants the name"))
        }
        #expect(try await store.teammate(id: other.id) == other, "a refused rename writes nothing")
    }

    @Test("A write that keeps a bot's own name passes while a bot saved before the rule shares it; an archived bot's name is free, and a plain update cannot bring its bot back into a taken name")
    func keepingANameIsNotTakingIt() async throws {
        let f = try ArchiveFixture(); defer { f.remove() }
        let store = try f.open(); let holder = try await f.seed(store)
        // A twin saved before the rule existed: only a raw write can make one now.
        let first = try Teammate(id: TeammateID(UUID()), profile: TeammateProfile(displayName: "Twin", role: "Saved before the rule"),
            appearance: holder.appearance, createdAt: f.at(1), updatedAt: f.at(1))
        try await store.insert(first)
        _ = try await store.execute(sql: "UPDATE teammates SET display_name='Archive Fixture' WHERE id=?;",
                                    bindings: [.text(first.id.persistedValue)])
        var twin = try #require(try await store.teammate(id: first.id))
        twin.isPinned = true
        try await store.update(twin, expectedProfileRevision: 1)
        var shouted = twin
        shouted.profile = try twin.profile.revised(displayName: "ARCHIVE FIXTURE")
        try await store.update(shouted, expectedProfileRevision: 1)
        #expect(try await store.teammate(id: twin.id)?.profile.displayName == "ARCHIVE FIXTURE", "its own name in another case")

        // Both archived: the name is free to take.
        let archivedHolder = try await store.archiveTeammate(id: holder.id, expectedProfileRevision: 1, now: f.at(2))
        _ = try await store.archiveTeammate(id: twin.id, expectedProfileRevision: 2, now: f.at(2))
        let successor = try Teammate(id: TeammateID(UUID()), profile: TeammateProfile(displayName: "archive fixture", role: "Took it over"),
            appearance: holder.appearance, createdAt: f.at(3), updatedAt: f.at(3))
        try await store.insert(successor)

        // Brought back by a plain update rather than restore: refused like restore.
        var back = archivedHolder
        back.lifecycle = .active
        await #expect(throws: TeammateNameTakenError(existingName: "archive fixture")) {
            try await store.update(back, expectedProfileRevision: archivedHolder.profile.revision)
        }
        #expect(try await store.teammate(id: holder.id)?.lifecycle == .archived)
    }

    @Test("Late history failure rolls back lifecycle, revision and selected chat together")
    func rollback() async throws {
        let f = try ArchiveFixture(); defer { f.remove() }
        let store = try f.open(); let original = try await f.seed(store)
        _ = try await store.execute(sql: "CREATE TRIGGER reject_archive_revision BEFORE INSERT ON teammate_profile_revisions BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;")
        await #expect(throws: SQLiteStoreError.self) {
            try await store.archiveTeammate(id: f.teammateID, expectedProfileRevision: 1, now: f.at(1))
        }
        #expect(try await store.teammate(id: f.teammateID) == original)
        #expect(try await store.selectedConversationID() == f.conversationID)
        #expect(try await store.archivedTeammates().isEmpty)
    }

    @Test("Archiving a different bot does not clear the current conversation")
    func preserveOtherSelection() async throws {
        let f = try ArchiveFixture(); defer { f.remove() }
        let other = try ArchiveFixture(); defer { other.remove() }
        let store = try f.open(); _ = try await f.seed(store); _ = try await other.seed(store, name: "Other Archive Fixture")
        _ = try await store.archiveTeammate(id: f.teammateID, expectedProfileRevision: 1, now: f.at(1))
        #expect(try await store.selectedConversationID() == other.conversationID)
        #expect(try await store.teammate(id: other.teammateID)?.lifecycle == .active)
    }
}

private struct ArchiveClock: OpenBotsClock {
    let date: Date
    func now() -> Date { date }
}

/// The roster as a service read it before another path's bot was saved:
/// empty. Everything else is the real store.
private struct StaleRosterRepository: TeammateRepository {
    let store: SQLiteStore
    func teammate(id: TeammateID) async throws -> Teammate? { try await store.teammate(id: id) }
    func listTeammates(includingArchived: Bool) async throws -> [Teammate] { [] }
    func insert(_ teammate: Teammate) async throws { try await store.insert(teammate) }
    func update(_ teammate: Teammate, expectedProfileRevision: UInt64) async throws {
        try await store.update(teammate, expectedProfileRevision: expectedProfileRevision)
    }
}

private struct ArchiveFixture: Sendable {
    let root: URL
    let receipt: ProtectionDecisionReceipt
    let teammateID = TeammateID(UUID())
    let conversationID = ConversationID(UUID())
    let date = Date(timeIntervalSince1970: 10_000)

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsArchiveTests-\(UUID()).noindex")
        receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(timeIntervalSince1970: 10_000), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: root.appendingPathComponent("control.sqlite"), protection: .ordinarySQLite(decision: receipt)))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func at(_ seconds: TimeInterval) -> Date { date.addingTimeInterval(seconds) }

    func seed(_ store: SQLiteStore, appearance: String = "guide", includeContent: Bool = false,
              name: String = "Archive Fixture") async throws -> Teammate {
        var teammate = try Teammate(id: teammateID,
            profile: TeammateProfile(displayName: name, title: "Researcher", role: "Local synthetic work", detailedInstructions: "Keep every saved field."),
            appearance: AgentAppearance(mode: appearance == "photo" ? .photo : .creature, grammarVersion: 3,
                deterministicSeed: UInt64.max - 5, silhouette: "cloud", paletteToken: "violet", eyeDialect: "calm",
                nonColorIdentityCue: "soft crown", accessibleIdentityDescription: "Original saved identity",
                profileAssetID: appearance == "photo" ? ProfileAssetID(UUID()) : nil,
                builtInAvatarID: appearance == "guide" ? "guide" : nil, revision: 7),
            isPinned: true, notificationPreference: .disabled, createdAt: date, updatedAt: date)
        try await store.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: conversationID, kind: .direct(teammateID: teammateID), title: "Saved chat", createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: true)
        if includeContent {
            try await store.append(message(sequence: 1), expectedPreviousSequence: 0)
            _ = try await store.saveDraft(conversationID: conversationID, text: "Unsent draft\nwith exact whitespace  ", expectedRevision: 0, updatedAt: date)
            _ = try await store.stage(AttachmentAsset(id: AttachmentID(UUID()), conversationID: conversationID,
                displayName: "fixture.txt", typeIdentifier: "public.plain-text", byteCount: 6,
                sha256: String(repeating: "a", count: 64), createdAt: date))
            let projectID = UUID().uuidString.lowercased(), teamID = UUID().uuidString.lowercased()
            _ = try await store.execute(sql: "INSERT INTO projects(id,name,summary,lifecycle,created_at,updated_at) VALUES (?,'Project','Keep membership','active',10000,10000);", bindings: [.text(projectID)])
            _ = try await store.execute(sql: "INSERT INTO project_memberships(project_id,teammate_id,joined_at) VALUES (?,?,10000);", bindings: [.text(projectID), .text(teammateID.persistedValue)])
            _ = try await store.execute(sql: "INSERT INTO teams(id,name,summary,lead_teammate_id,lifecycle,created_at,updated_at) VALUES (?,'Team','Keep lead',?,'active',10000,10000);", bindings: [.text(teamID), .text(teammateID.persistedValue)])
            _ = try await store.execute(sql: "INSERT INTO team_memberships(team_id,teammate_id,joined_at) VALUES (?,?,10000);", bindings: [.text(teamID), .text(teammateID.persistedValue)])
            _ = try await store.execute(sql: "INSERT INTO memory_documents(id,scope_kind,scope_id,author_kind,title,relative_path,revision,content_digest,created_at,updated_at) VALUES (?,'teammate',?,'user','Memory','fixture-memory.md',1,'saved',10000,10000);", bindings: [.text(UUID().uuidString), .text(teammateID.persistedValue)])
            _ = try await store.execute(sql: "INSERT INTO capability_grants(id,teammate_id,capability,scope_json,status,granted_at) VALUES (?,?,'synthetic','{}','active',10000);", bindings: [.text(UUID().uuidString), .text(teammateID.persistedValue)])
        }
        if appearance == "photo" {
            teammate.isHidden = true
            try await store.update(teammate, expectedProfileRevision: teammate.profile.revision)
        }
        return teammate
    }

    func message(sequence: Int64) throws -> Message {
        try Message(id: MessageID(UUID()), conversationID: conversationID, sequence: sequence, author: .user,
            deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text("Saved fixture message"))], createdAt: date, updatedAt: date)
    }

    func request(_ message: Message) throws -> WorkRequest {
        try WorkRequest(runID: RunID(UUID()), teammateID: teammateID, conversationID: conversationID,
            initiatingMessageID: message.id, profileRevision: 1,
            initialInput: WorkInput(messageID: message.id, sequence: 1, text: "Saved fixture message"), submittedAt: date)
    }

    func proposal() throws -> ActionProposal {
        try ActionProposal(id: ApprovalID(UUID()), teammateID: teammateID, conversationID: conversationID,
            profileRevision: 1, contextRevision: 0, action: .send, target: "Synthetic target", payload: "Synthetic payload",
            consequence: "No external action", createdAt: date, expiresAt: at(60))
    }

    func approval() throws -> ApprovalRequest {
        try ApprovalRequest(id: ApprovalID(UUID()), teammateID: teammateID, conversationID: conversationID,
            action: .send, exactTargetSummary: "Synthetic target", consequenceSummary: "No external action",
            fingerprint: ApprovalFingerprint("fixture"), requestedAt: date)
    }

    /// Compare every row in every unaffected table, including binary-sensitive
    /// draft/message text, assets, memberships, memory, grants and journals.
    func unchangedRows(_ store: SQLiteStore) async throws -> [String: [String]] {
        let excluded: Set<String> = ["teammates", "teammate_profile_revisions", "chat_navigation_state", "bot_sidebar_order", "bot_sidebar_order_state"]
        let tables = try await store.query(sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;")
        var result: [String: [String]] = [:]
        for table in tables {
            let name = try table.text("name")
            guard !excluded.contains(name) else { continue }
            let columns = try await store.query(sql: "PRAGMA table_info(\"\(name)\");")
            let projection = try columns.map { "quote(\"\(try $0.text("name"))\")" }.joined(separator: " || '|' || ")
            result[name] = try await store.query(sql: "SELECT \(projection) AS saved FROM \"\(name)\" ORDER BY saved;").map { try $0.text("saved") }
        }
        return result
    }
}
