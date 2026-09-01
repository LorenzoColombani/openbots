import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsPersistence
import Testing
@testable import OpenBotsServices

@Suite("Local conversational memory correction with real persistence")
struct MemoryLocalCorrectionIntegrationTests {
    @Test("Initial capture saves exact terminal user text, committed uncertain memory and a fixed system acknowledgement")
    func captureAndReopenRetry() async throws {
        let f = try LocalCorrectionFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let authority = try await f.authority()
        let service = f.service(db, authority: authority)
        let submission = f.submission("Remember that I prefer quiet places, except on Fridays.")
        let result = await service.sendText(submission) { _ in }
        #expect(result.outcome == .completed)
        #expect(result.savedUserMessage?.author == .user)
        #expect(result.savedUserMessage?.deliveryState == .completed)
        #expect(result.savedUserMessage?.parts.first?.content == .text(submission.text))
        #expect(result.savedReplyMessage?.author == .system)
        #expect(result.savedReplyMessage?.parts.first?.content == .text(MemoryLocalCorrectionAcknowledgement.text))
        let record = try #require(try await db.memoryLocalCorrection(userMessageID: submission.userMessageID))
        #expect(record.state == .acknowledged)
        #expect(try await db.memoryPublication(id: record.request.operationID)?.state == .committed)
        let artifact = try await f.artifact(db, id: record.request.documentID, authority: authority)
        #expect(artifact.claims.count == 1)
        #expect(artifact.claims[0].body == "I prefer quiet places, except on Fridays.")
        #expect(artifact.claims[0].assessment.level == .uncertain)
        #expect(try await db.runs(conversationID: f.chat, limit: 10).isEmpty)
        #expect(try await service.messageProvenance(conversationID: f.chat,
            messageIDs: [record.request.acknowledgementMessageID]).isEmpty)
        let reopened = try f.open()
        let retry = await f.service(reopened, authority: authority).sendText(submission) { _ in }
        #expect(retry == result)
        #expect(try await reopened.page(conversationID: f.chat, request: PageRequest(limit: 20)).elements.count == 2)
        let conflicting = f.submission("Remember that different text.", id: submission.userMessageID)
        #expect(await service.sendText(conflicting) { _ in }.outcome == .failed(.invalidInput))
    }

    @Test("Legacy bytes do not block initial capture or packing, but cannot be ignored to assert unique correction targets")
    func legacyCaptureAndFailClosedCorrection() async throws {
        let f = try LocalCorrectionFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let authority = try await f.authority()
        let legacy = try await f.legacy(db, authority: authority)
        let legacyBytes = try Data(contentsOf: authority.url.appending(path: legacy.relativePath))
        let service = f.service(db, authority: authority)
        let first = f.submission("Remember that I prefer quiet places.")
        #expect(await service.sendText(first) { _ in }.outcome == .completed)
        let firstRecord = try #require(try await db.memoryLocalCorrection(userMessageID: first.userMessageID))
        let prior = try await f.artifact(db, id: firstRecord.request.documentID, authority: authority)
        let second = f.submission("Remember that I prefer tea after lunch.")
        #expect(await service.sendText(second) { _ in }.outcome == .completed)
        let secondRecord = try #require(try await db.memoryLocalCorrection(userMessageID: second.userMessageID))
        let packed = try await f.artifact(db, id: secondRecord.request.documentID, authority: authority)
        #expect(packed.claims.count == 2)
        #expect(try MemoryClaimDigests.canonicalData(packed.claims[0]) == MemoryClaimDigests.canonicalData(prior.claims[0]))
        #expect(try await db.document(id: secondRecord.request.documentID)?.supersedes == firstRecord.request.documentID)
        let correction = f.submission("Forget that I prefer quiet places.")
        let refused = await service.sendText(correction) { _ in }
        try await expectLocalTargetClarification(refused, database: db)
        #expect(refused.savedUserMessage?.parts.first?.content == .text(correction.text))
        #expect(try await db.allDocuments().count == 3)
        #expect(try Data(contentsOf: authority.url.appending(path: legacy.relativePath)) == legacyBytes)
    }

    @Test("A real qualified overview anchors exact Forget beside legacy without claiming the whole inventory is parsed")
    func legacyCorrectionFromDisplayedClaim() async throws {
        let f = try LocalCorrectionFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let authority = try await f.authority()
        let legacy = try await f.legacy(db, authority: authority)
        let legacyBytes = try Data(contentsOf: authority.url.appending(path: legacy.relativePath))
        let fallback = LocalCorrectionInertFallback()
        let correction = f.service(db, authority: authority, publications: db)
        let service = f.conversationService(db, authority: authority, fallback: fallback, corrections: correction)
        let capture = f.submission("Remember that I prefer quiet libraries.")
        let captured = await service.sendText(capture) { _ in }
        #expect(captured.outcome == .completed)
        let captureRecord = try #require(try await db.memoryLocalCorrection(userMessageID: capture.userMessageID))
        let before = try await f.artifact(db, id: captureRecord.request.documentID, authority: authority)
        let priorClaim = try #require(before.claims.first)
        let overview = await service.sendText(f.submission("What do you remember about me?")) { _ in }
        #expect(overview.outcome == .completed)
        let displayed = try #require(overview.savedReplyMessage)
        guard case let .text(displayedText) = displayed.parts.first?.content else {
            Issue.record("The real local overview did not provide a complete text reply"); return
        }
        #expect(displayed.author == .system)
        #expect(displayedText.contains(priorClaim.body))
        let projection = try #require(try await db.memoryConversationPublication(messageID: displayed.id, conversationID: f.chat))
        #expect(projection.publication.receipt.dependencies.contains { $0.reference.claimID == priorClaim.id })
        let command = f.submission("Forget that I prefer quiet libraries.")
        let result = await service.sendText(command) { _ in }
        #expect(result.outcome == .completed)
        #expect(result.savedReplyMessage?.author == .system)
        #expect(result.savedReplyMessage?.parts.first?.content == .text(MemoryLocalCorrectionAcknowledgement.text))
        let record = try #require(try await db.memoryLocalCorrection(userMessageID: command.userMessageID))
        #expect(record.request.targetAnchor != nil)
        #expect(!record.request.inventoryComplete && !record.request.captureNewClaim)
        #expect(record.state == .acknowledged)
        let revised = try await f.artifact(db, id: record.request.documentID, authority: authority)
        #expect(revised.claims.count == 1)
        #expect(revised.claims[0].id == priorClaim.id && revised.claims[0].body == priorClaim.body)
        #expect(revised.claims[0].validity == .withdrawn)
        #expect(revised.claims[0].changes.first?.previous.documentID == before.documentID)
        #expect(try await db.document(id: record.request.documentID)?.supersedes == before.documentID)
        #expect(try await db.allDocuments().count == 3)
        #expect(try Data(contentsOf: authority.url.appending(path: legacy.relativePath)) == legacyBytes)
        #expect(await fallback.calls == 0)
        #expect(try await db.runs(conversationID: f.chat, limit: 10).isEmpty)
    }

    @Test("A newer unqualified system reply prevents silently reusing an older overview as the correction target")
    func newerReplyInvalidatesOverviewAnchor() async throws {
        let f = try LocalCorrectionFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let authority = try await f.authority()
        let legacy = try await f.legacy(db, authority: authority)
        let legacyBytes = try Data(contentsOf: authority.url.appending(path: legacy.relativePath))
        let fallback = LocalCorrectionInertFallback()
        let correction = f.service(db, authority: authority, publications: db)
        let service = f.conversationService(db, authority: authority, fallback: fallback, corrections: correction)
        let captured = await service.sendText(f.submission("Remember that I prefer quiet libraries.")) { _ in }
        #expect(captured.outcome == .completed)
        let overview = await service.sendText(f.submission("What do you remember about me?")) { _ in }
        #expect(overview.outcome == .completed)
        let displayed = try #require(overview.savedReplyMessage)
        let newer = try Message(id: MessageID(UUID()), conversationID: f.chat, sequence: displayed.sequence + 1,
            author: .system, deliveryState: .completed,
            parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text("A separate local status reply."))],
            createdAt: f.date, updatedAt: f.date)
        try await db.append(newer, expectedPreviousSequence: displayed.sequence)
        let before = try await db.allDocuments()
        let command = f.submission("Forget that I prefer quiet libraries.")
        let refused = await service.sendText(command) { _ in }
        try await expectLocalTargetClarification(refused, database: db)
        #expect(refused.savedUserMessage?.parts.first?.content == .text(command.text))
        let record = try #require(try await db.memoryLocalCorrection(userMessageID: command.userMessageID))
        #expect(record.request.targetAnchor == nil && record.state == .failed)
        #expect(try await db.allDocuments() == before)
        #expect(try Data(contentsOf: authority.url.appending(path: legacy.relativePath)) == legacyBytes)
        #expect(await fallback.calls == 0)
        #expect(try await db.runs(conversationID: f.chat, limit: 10).isEmpty)
    }

    @Test("Explicit first-hand promotion, demotion and withdrawal revise the same unique claim")
    func assessmentAndWithdrawal() async throws {
        let f = try LocalCorrectionFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let authority = try await f.authority()
        let service = f.service(db, authority: authority)
        var previousID: MemoryClaimID?
        for (text, level, validity) in [
            ("Remember that I live in Berlin.", MemoryClaimAssessmentLevel.uncertain, MemoryClaimValidity.active),
            ("I confirm from first-hand knowledge: I live in Berlin.", .confirmed, .active),
            ("Remember as uncertain: I live in Berlin.", .uncertain, .active),
            ("I no longer live in Berlin.", .uncertain, .withdrawn)
        ] {
            let submission = f.submission(text)
            let result = await service.sendText(submission) { _ in }
            #expect(result.outcome == .completed)
            let record = try #require(try await db.memoryLocalCorrection(userMessageID: submission.userMessageID))
            let artifact = try await f.artifact(db, id: record.request.documentID, authority: authority)
            let claim = try #require(artifact.claims.first)
            #expect(claim.body == "I live in Berlin.")
            #expect(claim.assessment.level == level)
            #expect(claim.validity == validity)
            if let previousID { #expect(claim.id == previousID); #expect(claim.changes.count == 1) }
            previousID = claim.id
        }
        #expect(try await db.allDocuments().count == 4)
    }

    @Test("An unrelated replacement atomically withdraws the old identity, adds a related successor and survives exact retry")
    func unrelatedReplacementHasDistinctIdentity() async throws {
        let f = try LocalCorrectionFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let authority = try await f.authority()
        let service = f.service(db, authority: authority)
        let initial = f.submission("Remember that I live in Berlin.")
        let firstResult = await service.sendText(initial) { _ in }
        #expect(firstResult.outcome == .completed)
        let firstRecord = try #require(try await db.memoryLocalCorrection(userMessageID: initial.userMessageID))
        let firstArtifact = try await f.artifact(db, id: firstRecord.request.documentID, authority: authority)
        let original = try #require(firstArtifact.claims.first)
        let firstDocument = try #require(try await db.document(id: firstRecord.request.documentID))
        let historicalBytes = try Data(contentsOf: authority.url.appending(path: firstDocument.relativePath))

        let correction = f.submission("Correct from first-hand knowledge to: My preferred work soundtrack is rain.")
        let corrected = await service.sendText(correction) { _ in }
        #expect(corrected.outcome == .completed)
        #expect(corrected.savedReplyMessage?.parts.first?.content == .text(MemoryLocalCorrectionAcknowledgement.text))
        let record = try #require(try await db.memoryLocalCorrection(userMessageID: correction.userMessageID))
        let next = try await f.artifact(db, id: record.request.documentID, authority: authority)
        #expect(next.claims.count == 2 && next.revision == firstArtifact.revision + 1)
        let old = try #require(next.claims.first { $0.id == original.id })
        let successor = try #require(next.claims.first { $0.id != original.id })
        #expect(old.body.utf8.elementsEqual(original.body.utf8) && old.observedAt == original.observedAt)
        #expect(old.validity == .withdrawn && old.changes.first?.kind == .withdrawal)
        #expect(successor.body == "My preferred work soundtrack is rain.")
        #expect(successor.validity == .active && successor.assessment.level == .confirmed)
        #expect(successor.changes.first?.kind == .supersession)
        #expect(successor.changes.first?.previous.claimID == original.id)
        #expect(successor.changes.first?.previous.documentID == firstArtifact.documentID)
        #expect(try successor.changes.first?.previous.claimDigest == MemoryClaimDigests.claim(original))
        #expect(try await db.withdrawnMemoryClaimIDs(documentID: next.documentID).contains(original.id.rawValue))
        #expect(try Data(contentsOf: authority.url.appending(path: firstDocument.relativePath)) == historicalBytes)
        let reopened = try f.open()
        let retry = await f.service(reopened, authority: authority).sendText(correction) { _ in }
        #expect(retry == corrected)
        #expect(try await reopened.allDocuments().count == 2)
        #expect(try await reopened.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements.count == 4)
        #expect(try await reopened.runs(conversationID: f.chat, limit: 10).isEmpty)

        // A later reassessment of the successor preserves both its new identity
        // and the immutable withdrawal of the old proposition.
        let reassessment = f.submission("Remember as uncertain: My preferred work soundtrack is rain.")
        let reassessed = await f.service(reopened, authority: authority).sendText(reassessment) { _ in }
        #expect(reassessed.outcome == .completed)
        let reassessedRecord = try #require(try await reopened.memoryLocalCorrection(userMessageID: reassessment.userMessageID))
        let latest = try await f.artifact(reopened, id: reassessedRecord.request.documentID, authority: authority)
        #expect(latest.claims.count == 2)
        #expect(latest.claims.first { $0.id == successor.id }?.assessment.level == .uncertain)
        #expect(try MemoryClaimDigests.canonicalData(try #require(latest.claims.first { $0.id == old.id }))
            == MemoryClaimDigests.canonicalData(old))

        // Withdrawn history alone does not make the next explicit correction
        // ambiguous: exactly one active proposition remains in this inventory.
        let following = f.submission("Correct from first-hand knowledge to: My preferred work soundtrack is ocean waves.")
        let followed = await f.service(reopened, authority: authority).sendText(following) { _ in }
        #expect(followed.outcome == .completed)
        let followingRecord = try #require(try await reopened.memoryLocalCorrection(userMessageID: following.userMessageID))
        let final = try await f.artifact(reopened, id: followingRecord.request.documentID, authority: authority)
        #expect(final.claims.count == 3)
        let active = final.claims.filter { $0.validity == .active }
        #expect(active.count == 1)
        #expect(active.first?.id != original.id && active.first?.id != successor.id)
        #expect(active.first?.body == "My preferred work soundtrack is ocean waves.")
        #expect(active.first?.changes.first?.previous.claimID == successor.id)
        #expect(final.claims.first { $0.id == original.id }?.validity == .withdrawn)
        #expect(final.claims.first { $0.id == successor.id }?.validity == .withdrawn)
        #expect(try await reopened.withdrawnMemoryClaimIDs(documentID: final.documentID).count == 2)
    }

    @Test("A to B to A to C can reassess the distinct active A while retaining its withdrawn namesake")
    func repeatedBodyDoesNotConfuseHistoryWithCurrentTarget() async throws {
        let f = try LocalCorrectionFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let authority = try await f.authority()
        let service = f.service(db, authority: authority)
        func apply(_ text: String) async throws -> MemoryClaimArtifact {
            let submission = f.submission(text)
            let result = await service.sendText(submission) { _ in }
            #expect(result.outcome == .completed)
            #expect(result.savedReplyMessage?.parts.first?.content == .text(MemoryLocalCorrectionAcknowledgement.text))
            let record = try #require(try await db.memoryLocalCorrection(userMessageID: submission.userMessageID))
            #expect(record.state == .acknowledged)
            return try await f.artifact(db, id: record.request.documentID, authority: authority)
        }
        let first = try await apply("Remember that I prefer tea.")
        let originalA = try #require(first.claims.first)
        let second = try await apply("Correct from first-hand knowledge to: I prefer coffee.")
        let b = try #require(second.claims.first { $0.validity == .active })
        #expect(b.id != originalA.id)
        let third = try await apply("Correct from first-hand knowledge to: I prefer tea.")
        let currentA = try #require(third.claims.first { $0.validity == .active })
        let withdrawnA = try #require(third.claims.first { $0.id == originalA.id })
        #expect(currentA.body == originalA.body && currentA.id != originalA.id)
        #expect(currentA.id != b.id && withdrawnA.validity == .withdrawn)
        #expect(third.claims.filter { $0.body == originalA.body }.count == 2)

        let confirmed = try await apply("I confirm from first-hand knowledge: I prefer tea.")
        let confirmedA = try #require(confirmed.claims.first { $0.validity == .active })
        #expect(confirmedA.id == currentA.id && confirmedA.assessment.level == .confirmed)
        let demoted = try await apply("Remember as uncertain: I prefer tea.")
        let demotedA = try #require(demoted.claims.first { $0.validity == .active })
        #expect(demotedA.id == currentA.id && demotedA.assessment.level == .uncertain)
        let final = try await apply("Correct from first-hand knowledge to: I prefer cocoa.")
        let c = try #require(final.claims.first { $0.validity == .active })
        #expect(c.body == "I prefer cocoa.")
        #expect(![originalA.id, b.id, currentA.id].contains(c.id))
        #expect(final.claims.count == 4)
        #expect(final.claims.filter { $0.validity == .withdrawn }.count == 3)
        #expect(c.changes.first?.previous.claimID == currentA.id)
        #expect(try MemoryClaimDigests.canonicalData(try #require(final.claims.first { $0.id == originalA.id }))
            == MemoryClaimDigests.canonicalData(withdrawnA))
        #expect(try await db.withdrawnMemoryClaimIDs(documentID: final.documentID).count == 3)

        // With only withdrawn A records left, these commands must not silently
        // revive an old ID or invent a new identity from absence of active A.
        for text in ["I confirm from first-hand knowledge: I prefer tea.", "Remember as uncertain: I prefer tea."] {
            #expect(MemoryEvidenceVerifier.userTarget(text: text, claims: final.claims) == .ambiguous)
            let before = try await db.allDocuments()
            let refused = await service.sendText(f.submission(text)) { _ in }
            try await expectLocalTargetClarification(refused, database: db)
            #expect(try await db.allDocuments() == before)
        }
        #expect(try await db.runs(conversationID: f.chat, limit: 10).isEmpty)
    }

    @Test("Duplicate exact bodies cannot select a target by array order")
    func ambiguousTargetDoesNotMutate() async throws {
        let f = try LocalCorrectionFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let authority = try await f.authority()
        let service = f.service(db, authority: authority)
        for _ in 0..<2 { #expect(await service.sendText(f.submission("Remember that I like tea.")) { _ in }.outcome == .completed) }
        let before = try await db.allDocuments()
        let result = await service.sendText(f.submission("Forget that I like tea.")) { _ in }
        try await expectLocalTargetClarification(result, database: db)
        #expect(try await db.allDocuments() == before)
    }

    @Test("Ambiguous adoption asks a closed question, then exact named quotation resolves the target without promoting certainty")
    func clarificationThenNamedAdoptedReplacement() async throws {
        let f = try LocalCorrectionFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let authority = try await f.authority()
        let service = f.service(db, authority: authority)
        #expect(await service.sendText(f.submission("Remember that I prefer tea.")) { _ in }.outcome == .completed)
        let otherSubmission = f.submission("Remember that I prefer trains.")
        #expect(await service.sendText(otherSubmission) { _ in }.outcome == .completed)
        let otherRecord = try #require(try await db.memoryLocalCorrection(userMessageID: otherSubmission.userMessageID))
        let before = try await f.artifact(db, id: otherRecord.request.documentID, authority: authority)
        let old = try #require(before.claims.first { $0.body == "I prefer tea." })
        let other = try #require(before.claims.first { $0.body == "I prefer trains." })
        let documents = try await db.allDocuments()
        let ambiguous = f.submission("Replace it with this: \"I might prefer cocoa, if available.\"")
        let question = await service.sendText(ambiguous) { _ in }
        try await expectLocalTargetClarification(question, database: db)
        #expect(question.savedUserMessage?.parts.first?.content == .text(ambiguous.text))
        #expect(try await db.allDocuments() == documents)
        let reopened = try f.open()
        let retry = await f.service(reopened, authority: authority).sendText(ambiguous) { _ in }
        #expect(retry == question)
        #expect(try await reopened.page(conversationID: f.chat, request: PageRequest(limit: 20)).elements.count == 6)
        let exactBody = "  I might prefer cocoa, if available.  "
        let command = f.submission("Replace \"I prefer tea.\" with \"" + exactBody + "\"")
        let corrected = await f.service(reopened, authority: authority).sendText(command) { _ in }
        #expect(corrected.outcome == .completed)
        #expect(corrected.savedUserMessage?.parts.first?.content == .text(command.text))
        #expect(corrected.savedReplyMessage?.parts.first?.content == .text(MemoryLocalCorrectionAcknowledgement.text))
        let record = try #require(try await reopened.memoryLocalCorrection(userMessageID: command.userMessageID))
        #expect(record.state == .acknowledged && record.clarification == nil)
        #expect(try await reopened.memoryPublication(id: record.request.operationID)?.state == .committed)
        let artifact = try await f.artifact(reopened, id: record.request.documentID, authority: authority)
        #expect(artifact.claims.count == 3)
        #expect(artifact.claims.first { $0.id == old.id }?.validity == .withdrawn)
        let successor = try #require(artifact.claims.first { $0.id != old.id && $0.id != other.id })
        #expect(successor.body.utf8.elementsEqual(exactBody.utf8))
        #expect(successor.assessment.level == .uncertain && successor.validity == .active)
        #expect(successor.changes.first?.kind == .supersession && successor.changes.first?.previous.claimID == old.id)
        #expect(successor.assessment.evidence.first?.source.sourceID == command.userMessageID.persistedValue)
        #expect(try MemoryClaimDigests.canonicalData(try #require(artifact.claims.first { $0.id == other.id }))
            == MemoryClaimDigests.canonicalData(other))
        #expect(try await reopened.runs(conversationID: f.chat, limit: 10).isEmpty)
    }

    @Test("No committed intent means no acknowledgement; stale admission rolls back the entire user-marker pair")
    func acknowledgementAndSequenceGuards() async throws {
        let f = try LocalCorrectionFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let first = try await f.request(db, text: "Remember that a bounded fixture.")
        let record = try await db.admitMemoryLocalCorrection(first, text: "Remember that a bounded fixture.")
        do {
            _ = try await db.acknowledgeMemoryLocalCorrection(userMessageID: first.userMessageID, expectedRevision: 1, now: f.date)
            Issue.record("An uncommitted memory operation was acknowledged")
        } catch let error as MemoryLocalCorrectionError { #expect(error == .publicationNotCommitted) }
        #expect(try await db.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements == [record.userMessage])
        let stale = try await f.request(db, text: "Remember that another fixture.")
        do {
            _ = try await db.admitMemoryLocalCorrection(stale, text: "Remember that another fixture.")
            Issue.record("A stale expected conversation sequence was admitted")
        } catch { }
        #expect(try await db.memoryLocalCorrection(userMessageID: stale.userMessageID) == nil)
        #expect(try await db.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements.count == 1)
    }

    @Test("A durable active run prevents a local user command from being saved")
    func activeRunRefused() async throws {
        let f = try LocalCorrectionFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let authority = try await f.authority()
        let message = MessageID(UUID())
        try await db.append(Message(id: message, conversationID: f.chat, sequence: 1, author: .user,
            deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0,
                content: .text("Synthetic local fixture"))], createdAt: f.date, updatedAt: f.date), expectedPreviousSequence: 0)
        let work = try WorkRequest(runID: RunID(UUID()), teammateID: f.bot, conversationID: f.chat,
            initiatingMessageID: message, profileRevision: 1,
            initialInput: WorkInput(messageID: message, sequence: 1, text: "Synthetic local fixture"), submittedAt: f.date)
        _ = try await db.enqueueRun(work, origin: .localFixture)
        let submission = f.submission("Remember that I prefer quiet places.")
        let result = await f.service(db, authority: authority).sendText(submission) { _ in }
        #expect(result.outcome == .failed(.busy))
        #expect(result.savedUserMessage == nil && result.savedReplyMessage == nil)
        #expect(try await db.memoryLocalCorrection(userMessageID: submission.userMessageID) == nil)
    }

    @Test("Cancellation after saved user but before publication is terminal and cannot later acknowledge")
    func cancellationBeforePublication() async throws {
        let f = try LocalCorrectionFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let authority = try await f.authority()
        let service = f.service(db, authority: authority)
        let submission = f.submission("Remember that I prefer quiet places.")
        let task = Task {
            await service.sendText(submission) { progress in
                if case .userMessageSaved = progress { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let result = await task.value
        #expect(result.outcome == .stopped)
        #expect(result.savedUserMessage?.deliveryState == .completed && result.savedReplyMessage == nil)
        let record = try #require(try await db.memoryLocalCorrection(userMessageID: submission.userMessageID))
        #expect(record.state == .failed && record.failure == .cancelled)
        #expect(try await db.allDocuments().isEmpty)
        #expect(await service.sendText(submission) { _ in } == result)
        do {
            _ = try await db.acknowledgeMemoryLocalCorrection(userMessageID: submission.userMessageID,
                expectedRevision: record.revision, now: f.date)
            Issue.record("Cancelled action gained a later success acknowledgement")
        } catch let error as MemoryLocalCorrectionError { #expect(error == .invalidState) }
    }

    @Test("Commit-winning cancellation settles a freshly validated fixed acknowledgement")
    func cancellationAfterCommit() async throws {
        let f = try LocalCorrectionFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let authority = try await f.authority()
        let intentWrapper = LocalCorrectionCommitCancellation(base: db)
        let service = f.service(db, authority: authority, intents: intentWrapper)
        let submission = f.submission("Remember that I prefer quiet places.")
        let task = Task { await service.sendText(submission) { _ in } }
        let result = await task.value
        #expect(result.outcome == .completed)
        #expect(result.savedReplyMessage?.author == .system)
        let record = try #require(try await db.memoryLocalCorrection(userMessageID: submission.userMessageID))
        #expect(record.state == .acknowledged && record.failure == nil)
        #expect(try await db.memoryPublication(id: record.request.operationID)?.state == .committed)
    }

    @Test("A committed change whose acknowledgement lost the conversation race is durably reported as saved, not cancelled")
    func committedWithoutAcknowledgement() async throws {
        let f = try LocalCorrectionFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let authority = try await f.authority()
        let newer = try Message(id: MessageID(UUID()), conversationID: f.chat, sequence: 2, author: .user,
            deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0,
                content: .text("A separate newer user turn."))], createdAt: f.date, updatedAt: f.date)
        let service = f.service(db, authority: authority,
            intents: LocalCorrectionCommitCancellation(base: db, afterCommitMessage: newer))
        let submission = f.submission("Remember that I prefer quiet places.")
        let task = Task { await service.sendText(submission) { _ in } }
        let result = await task.value
        #expect(result.outcome == .failed(.memoryAcknowledgementPending))
        #expect(result.savedUserMessage != nil && result.savedReplyMessage == nil)
        let reopened = try f.open()
        let record = try #require(try await reopened.memoryLocalCorrection(userMessageID: submission.userMessageID))
        #expect(record.state == .committedUnacknowledged && record.failure == nil)
        #expect(try await reopened.memoryPublication(id: record.request.operationID)?.state == .committed)
        #expect(try await reopened.allDocuments().count == 1)
        let retried = await f.service(reopened, authority: authority).sendText(submission) { _ in }
        #expect(retried.outcome == .failed(.memoryAcknowledgementPending))
        #expect(retried.savedReplyMessage == nil)
    }

    @Test("Exact retry after reopen recovers a staging-only publication and adds one acknowledgement")
    func stagingRetry() async throws {
        let f = try LocalCorrectionFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let authority = try await f.authority()
        let text = "Remember that I prefer quiet places."
        let request = try await f.request(db, text: text)
        _ = try await db.admitMemoryLocalCorrection(request, text: text)
        let verifier = MemoryEvidenceVerifier(messages: db, teammates: db, contexts: db)
        let claim = try await verifier.userProposal(messageID: request.userMessageID, claimID: request.claimID,
            scope: .teammate(f.bot), authority: request.authority, at: f.date)
        let artifact = MemoryClaimArtifact(documentID: request.documentID, revision: 1, scope: .teammate(f.bot), claims: [claim])
        let bytes = try MemoryClaimCodec().encode(artifact)
        let document = try MemoryDocument(id: request.documentID, scope: artifact.scope, author: .user, title: "Remembered notes",
            relativePath: AuthoritativeMarkdownPath.relativePath(documentID: artifact.documentID, scope: artifact.scope, revision: 1),
            revision: 1, contentDigest: MemoryClaimDigests.bytes(bytes), createdAt: f.date, updatedAt: f.date)
        let evidence = try await verifier.verify(artifact: artifact, predecessor: nil, actor: .user(messageID: request.userMessageID),
            authority: request.authority, at: f.date)
        let intent = try MemoryPublicationIntent(id: request.operationID, document: document, expectedPredecessor: nil,
            authority: request.authority, actor: .user(messageID: request.userMessageID), evidenceDigest: evidence.digest(),
            policyDigest: MemoryClaimAdmissionService.policyDigest, byteCount: bytes.count,
            userMessageEvidence: evidence.userMessages, createdAt: f.date)
        _ = try await db.prepareMemoryPublication(intent)
        let publication = try await AuthoritativeMarkdownStore().publish(AuthoritativeMarkdownPublicationRequest(documentID: artifact.documentID,
            scope: artifact.scope, revision: 1, markdown: String(decoding: bytes, as: UTF8.self), authority: authority, operationID: intent.id))
        try FileManager.default.moveItem(at: publication.exactFileURL, to: authority.url.appending(path: intent.stagingRelativePath))
        let reopened = try f.open()
        let result = await f.service(reopened, authority: authority).sendText(f.submission(text, id: request.userMessageID)) { _ in }
        #expect(result.outcome == .completed && result.savedReplyMessage?.author == .system)
        #expect(try await reopened.memoryPublication(id: intent.id)?.state == .committed)
        #expect(try await reopened.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements.count == 2)
        #expect(!FileManager.default.fileExists(atPath: authority.url.appending(path: intent.stagingRelativePath).path))
    }
}

private func expectLocalTargetClarification(_ result: ClaudeTextTurnResult, database: SQLiteStore) async throws {
    #expect(result.outcome == .completed)
    let user = try #require(result.savedUserMessage)
    let reply = try #require(result.savedReplyMessage)
    #expect(user.author == .user && reply.author == .system)
    #expect(reply.parts.first?.content == .text(MemoryLocalCorrectionClarificationKind.targetRequired.text))
    #expect(reply.parts.first?.content != .text(MemoryLocalCorrectionAcknowledgement.text))
    let record = try #require(try await database.memoryLocalCorrection(userMessageID: user.id))
    #expect(record.state == .failed && record.failure == .contextUnavailable)
    #expect(record.clarification == reply && record.acknowledgement == nil)
    #expect(try await database.memoryPublication(id: record.request.operationID) == nil)
    #expect(try await database.document(id: record.request.documentID) == nil)
}

private struct LocalCorrectionLocation: MacOSLocationAdmissionChecking {
    func observation(for url: URL) async throws -> LocationObservation {
        .init(isLocalVolume: true, isReadOnlyVolume: false, isUbiquitousItem: false,
              fileProviderStatus: .notManaged, volumeIdentifier: "synthetic-local-memory-volume")
    }
}

private struct LocalCorrectionFixture: Sendable {
    let root: URL
    let layout: PreviewStorageLayout
    let plan: PreviewRootCreationPlan
    let protection: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 1_760_000_000)
    let bot = TeammateID(UUID()), chat = ConversationID(UUID())

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextLocalMemory-\(UUID()).noindex", isDirectory: true)
        let home = root.appending(path: "Home", directoryHint: .isDirectory)
        let temporary = root.appending(path: "SystemTemporary", directoryHint: .isDirectory)
        for directory in [home.appending(path: "Library/Application Support", directoryHint: .isDirectory),
                          home.appending(path: "Library/Caches", directoryHint: .isDirectory), temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        layout = PreviewStorageLayout(homeDirectory: home, systemTemporaryDirectory: temporary)
        plan = try PreviewRootCreationPlan(layout: layout, installationID: UUID(),
            rootIDs: [.applicationSupport: UUID(), .caches: UUID(), .temporary: UUID()])
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: date, rationaleVersion: 2)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: root.appending(path: "control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
    }
    func authority() async throws -> VerifiedAuthoritativeMarkdownRoot {
        let receipt = try await StorageBootstrapService(layout: layout, locationAdmission: LocalCorrectionLocation()).bootstrap(using: plan)
        let verified = try #require(receipt.verifiedRoots.first { $0.kind == .applicationSupport })
        return try AuthoritativeMarkdownRootVerifier().verify(layout.internalMemoryRoot, inside: verified)
    }
    func seed(_ database: SQLiteStore) async throws {
        let teammate = try Teammate(id: bot, profile: TeammateProfile(displayName: "Memory Fixture", role: "Synthetic QA"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature"),
            createdAt: date, updatedAt: date)
        try await database.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: chat, kind: .direct(teammateID: bot), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false)
    }
    func service(_ db: SQLiteStore, authority: VerifiedAuthoritativeMarkdownRoot,
                 intents: (any MemoryPublicationIntentRepository)? = nil,
                 publications: (any MemoryConversationPublicationRepository)? = nil) -> MemoryLocalCorrectionService {
        let time = date
        return MemoryLocalCorrectionService(corrections: db, memory: db, intents: intents ?? db, contexts: db,
            conversationContexts: db, teammates: db, messages: db, authority: authority,
            publications: publications, clock: { time })
    }
    func conversationService(_ db: SQLiteStore, authority: VerifiedAuthoritativeMarkdownRoot,
                             fallback: LocalCorrectionInertFallback,
                             corrections: MemoryLocalCorrectionService) -> MemoryLocalConversationService {
        let time = date
        return MemoryLocalConversationService(fallback: fallback, corrections: corrections,
            memory: db, intents: db, contexts: db, selections: db, messages: db,
            teammates: db, publications: db, authority: authority, clock: { time })
    }
    func submission(_ text: String, id: MessageID = MessageID(UUID())) -> ClaudeTextTurnSubmission {
        .init(conversationID: chat, teammateID: bot, userMessageID: id, text: text)
    }
    func artifact(_ db: SQLiteStore, id: MemoryDocumentID,
                  authority: VerifiedAuthoritativeMarkdownRoot) async throws -> MemoryClaimArtifact {
        let document = try #require(try await db.document(id: id))
        let read = try await AuthoritativeMarkdownStore().read(AuthoritativeMarkdownReference(document: document), inside: authority)
        return try #require(MemoryClaimCodec().decode(Data(read.markdown.utf8), expecting: document).artifact)
    }
    func request(_ db: SQLiteStore, text: String) async throws -> MemoryLocalCorrectionRequest {
        let selection = try await db.loadContext(conversationID: chat)
        let snapshot = try await db.loadReadContextCandidates(ReadContextRequest(conversationID: chat, teammateID: bot,
            profileRevision: 1, selection: selection, beforeSequence: Int64.max))
        let receipt = try snapshot.receipt.selecting(messageIDs: [], memoryDocumentIDs: [])
        return try MemoryLocalCorrectionRequest(operationID: UUID(), userMessageID: MessageID(UUID()), userPartID: MessagePartID(UUID()),
            acknowledgementMessageID: MessageID(UUID()), acknowledgementPartID: MessagePartID(UUID()),
            documentID: MemoryDocumentID(UUID()), claimID: MemoryClaimID(UUID()), authority: receipt,
            expectedPreviousSequence: 0, commandDigest: MemoryClaimDigests.bytes(Data(text.utf8)),
            inventoryComplete: true, captureNewClaim: true, createdAt: date)
    }
    func legacy(_ db: SQLiteStore, authority: VerifiedAuthoritativeMarkdownRoot) async throws -> MemoryDocument {
        let id = MemoryDocumentID(UUID()), scope = MemoryScope.teammate(bot)
        let body = "# Retained legacy fixture\n\nThis exact document is unassessed.\n"
        let publication = try await AuthoritativeMarkdownStore().publish(AuthoritativeMarkdownPublicationRequest(
            documentID: id, scope: scope, revision: 1, markdown: body, authority: authority))
        let document = try MemoryDocument(id: id, scope: scope, author: .user, title: "Legacy fixture",
            relativePath: publication.reference.relativePath, revision: 1,
            contentDigest: MemoryClaimDigests.bytes(Data(body.utf8)), createdAt: date, updatedAt: date)
        try await db.insert(document)
        return document
    }
}

private actor LocalCorrectionInertFallback: ClaudeTextReplyServing {
    private(set) var calls = 0
    func sendText(_ submission: ClaudeTextTurnSubmission,
                  onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        calls += 1
        return .init(outcome: .failed(.runtimeUnavailable))
    }
    func messageProvenance(conversationID: ConversationID, messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] { [] }
}

/// Cancels the calling task only after the real database commit has won.
private struct LocalCorrectionCommitCancellation: MemoryPublicationIntentRepository {
    let base: SQLiteStore
    var afterCommitMessage: Message? = nil
    func prepareMemoryPublication(_ intent: MemoryPublicationIntent) async throws -> MemoryPublicationIntentRecord {
        try await base.prepareMemoryPublication(intent)
    }
    func memoryPublication(id: UUID) async throws -> MemoryPublicationIntentRecord? { try await base.memoryPublication(id: id) }
    func committedMemoryPublication(documentID: MemoryDocumentID) async throws -> MemoryPublicationIntentRecord? {
        try await base.committedMemoryPublication(documentID: documentID)
    }
    func pendingMemoryPublications(limit: Int) async throws -> [MemoryPublicationIntentRecord] {
        try await base.pendingMemoryPublications(limit: limit)
    }
    func commitMemoryPublication(id: UUID, expectedRevision: Int64, validation: MemoryPublicationValidation,
                                 now: Date) async throws -> MemoryPublicationIntentRecord {
        let result = try await base.commitMemoryPublication(id: id, expectedRevision: expectedRevision, validation: validation, now: now)
        if let message = afterCommitMessage { try await base.append(message, expectedPreviousSequence: message.sequence - 1) }
        withUnsafeCurrentTask { $0?.cancel() }
        return result
    }
    func abortMemoryPublication(id: UUID, expectedRevision: Int64, now: Date) async throws -> MemoryPublicationIntentRecord {
        try await base.abortMemoryPublication(id: id, expectedRevision: expectedRevision, now: now)
    }
    func memoryPublicationBlocksUse(documentID: MemoryDocumentID) async throws -> Bool {
        try await base.memoryPublicationBlocksUse(documentID: documentID)
    }
    func withdrawnMemoryClaimIDs(documentID: MemoryDocumentID) async throws -> [UUID] {
        try await base.withdrawnMemoryClaimIDs(documentID: documentID)
    }
}
