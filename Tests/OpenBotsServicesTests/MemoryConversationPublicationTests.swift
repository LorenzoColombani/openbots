import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

struct MemoryConversationPublicationTests {
    @Test("Only a matching host observation can publish a closed explanation limitation",
          arguments: [MemoryExplanationLimitation.sourcesUnavailable, .lineageUnverifiable])
    func hostExplanationLimitation(_ reason: MemoryExplanationLimitation) async throws {
        let fixture = try publicationFixture(body: "PRIVATE-SOURCE-MUST-NOT-APPEAR")
        let resolver = PublicationFixtureResolver([fixture.snapshot])
        let service = MemoryConversationPublicationService(resolver: resolver)
        let unit = MemoryConversationPublicationRendering.limitationUnit(reason)
        #expect(throws: MemoryConversationPublicationError.invalidCandidate) {
            try MemoryConversationPublicationService.decodeCandidate(publicationWire([unit]))
        }
        let context = fixture.context(intent: .explanation, admitted: [], relevant: [], limitation: reason)
        let published = try await service.publish(.init(units: [unit]), context: context)
        #expect(published.completeUnits == [reason.text])
        #expect(published.receipt.units == [unit] && published.receipt.dependencies.isEmpty)
        #expect(published.receipt.lineage == .independent && published.omittedUnitCount == 0)
        #expect(!published.text.contains(fixture.snapshot.claim.body))
        #expect(!published.text.contains(fixture.reference.claimID.rawValue.uuidString))
        #expect(await resolver.claimReads == 0)
        #expect(try await service.revalidate(published, context: context))
        for invalid in [
            fixture.context(intent: .explanation, admitted: [], relevant: []),
            fixture.context(intent: .reply, admitted: [], relevant: [], limitation: reason),
            fixture.context(intent: .explanation, limitation: reason),
            fixture.context(intent: .explanation, admitted: [], relevant: [], explained: UUID(), limitation: reason)
        ] {
            await #expect(throws: MemoryConversationPublicationError.self) {
                _ = try await service.publish(.init(units: [unit]), context: invalid)
            }
        }
        for invalid in [[unit, unit], [.init(kind: .explanation, references: [])],
                        [.init(kind: unit.kind, references: [fixture.reference])]] {
            await #expect(throws: MemoryConversationPublicationError.self) {
                _ = try await service.publish(.init(units: invalid), context: context)
            }
        }
        let receipt = published.receipt
        let raw = "Invented reason and private source text."
        let forgedReceipt = MemoryPublicationReceipt(id: receipt.id, policyVersion: receipt.policyVersion,
            runID: receipt.runID, messageID: receipt.messageID, teammateID: receipt.teammateID,
            selectedProjectID: receipt.selectedProjectID, intent: receipt.intent,
            renderedTextDigest: MemoryClaimDigests.bytes(Data(raw.utf8)), units: receipt.units,
            dependencies: [], lineage: .independent, createdAt: receipt.createdAt)
        let forged = MemoryConversationPublication(completeUnits: [raw], receipt: forgedReceipt, omittedUnitCount: 0)
        #expect(try await !service.revalidate(forged, context: context))
        await resolver.setFinalValidation(false)
        await #expect(throws: MemoryConversationPublicationError.publicationChanged) {
            _ = try await service.publish(.init(units: [unit]), context: context)
        }
    }

    @Test("Closed wire accepts references, never provider prose or substituted fields")
    func closedWire() throws {
        let fixture = try publicationFixture()
        let wire = try publicationWire([.init(kind: .claim, references: [fixture.reference])])
        let decoded = try MemoryConversationPublicationService.decodeCandidate(wire)
        #expect(decoded.units == [.init(kind: .claim, references: [fixture.reference])])
        let valid = try #require(String(data: wire, encoding: .utf8))
        for invalid in [
            "The user definitely prefers quiet places.",
            valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"prose\":\"Definitely true\""),
            valid.replacingOccurrences(of: "\"kind\":\"claim\"", with: "\"kind\":\"claim\",\"body\":\"Substitution\""),
            valid.replacingOccurrences(of: "\"kind\":\"claim\"", with: "\"kind\":\"freeText\""),
            valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
            valid.replacingOccurrences(of: "\"documentRevision\":1", with: "\"documentRevision\":1,\"assessment\":\"confirmed\"")
        ] {
            #expect(throws: MemoryConversationPublicationError.self) {
                try MemoryConversationPublicationService.decodeCandidate(Data(invalid.utf8))
            }
        }
        #expect(throws: MemoryConversationPublicationError.boundsExceeded) {
            try MemoryConversationPublicationService.decodeCandidate(Data(repeating: 32, count: MemoryPublicationLimits.candidateBytes + 1))
        }
        #expect(throws: MemoryConversationPublicationError.self) {
            try MemoryConversationPublicationService.decodeCandidate(publicationWire(Array(repeating: decoded.units[0], count: 13)))
        }
    }

    @Test("Relevant low claims publish one complete qualified phrase, preserving negation and conditions")
    func completeLowUnit() async throws {
        let fixture = try publicationFixture(body: "I do not want a crowded venue", conditions: "only on work nights")
        let resolver = PublicationFixtureResolver([fixture.snapshot])
        let service = MemoryConversationPublicationService(resolver: resolver)
        let result = try await service.publish(fixture.candidate, context: fixture.context())
        #expect(result.completeUnits == ["I may have this wrong: \"I do not want a crowded venue\". Does that apply here? This applies only when \"only on work nights\"."])
        #expect(result.receipt.dependencies[0].reference == fixture.reference)
        #expect(result.receipt.dependencies[0].decision.requiredFraming == .unconfirmedPossibility)
        #expect(result.receipt.renderedTextDigest == MemoryClaimDigests.bytes(Data(result.text.utf8)))
        #expect(!result.text.contains("Confidence:"))
        #expect(try await service.revalidate(result, context: fixture.context(runID: result.receipt.runID, messageID: result.receipt.messageID)))
    }

    @Test("Irrelevant uncertain records do not load, appear, or trigger clarification")
    func irrelevantOmission() async throws {
        let fixture = try publicationFixture()
        let resolver = PublicationFixtureResolver([fixture.snapshot])
        let context = fixture.context(relevant: [])
        let service = MemoryConversationPublicationService(resolver: resolver)
        let result = try await service.publish(fixture.candidate, context: context)
        #expect(result.text.isEmpty)
        #expect(result.omittedUnitCount == 1)
        #expect(result.receipt.dependencies.isEmpty)
        #expect(await resolver.claimReads == 0)
        #expect(try await service.revalidate(result, context: context))
    }

    @Test("Middle uses checked attribution and hedging; higher support has no permanent badge")
    func naturalAssessmentRendering() async throws {
        let middle = try publicationFixture(level: .supportedInference)
        let high = try publicationFixture(level: .confirmed)
        for fixture in [middle, high] {
            let result = try await MemoryConversationPublicationService(resolver: PublicationFixtureResolver([fixture.snapshot]))
                .publish(fixture.candidate, context: fixture.context())
            if fixture.reference == middle.reference {
                #expect(result.text == "From what you've told me, \"I prefer quieter places\" seems plausible, but it may be wrong.")
            } else {
                #expect(result.text == "I'll take \"I prefer quieter places\" into account here.")
            }
            #expect(!result.text.contains("Confirmed"))
            #expect(!result.text.contains("Assessment:"))
            #expect(!result.text.contains(fixture.snapshot.claim.assessment.basis))
        }
    }

    @Test("Exact body and assessment substitution cannot use an admitted reference")
    func substitutionsRejected() async throws {
        let fixture = try publicationFixture()
        let changed = try publicationFixture(body: "Definitely a different statement", level: .confirmed)
        for claim in [changed.snapshot.claim,
                      MemoryClaim(id: fixture.snapshot.claim.id, body: fixture.snapshot.claim.body,
                                  assessment: changed.snapshot.claim.assessment,
                                  provenance: fixture.snapshot.claim.provenance)] {
            let substituted = MemoryPublicationClaimSnapshot(claim: claim, reference: fixture.reference,
                scope: fixture.snapshot.scope, useContext: fixture.snapshot.useContext, lineage: .independent)
            let service = MemoryConversationPublicationService(resolver: PublicationFixtureResolver([substituted]))
            await #expect(throws: MemoryConversationPublicationError.policyDenied) {
                try await service.publish(fixture.candidate, context: fixture.context())
            }
        }
    }

    @Test("Only current references and final revalidated publications escape")
    func currentAndFinalChecks() async throws {
        let fixture = try publicationFixture()
        let other = try publicationFixture()
        let stale = MemoryPublicationClaimSnapshot(claim: fixture.snapshot.claim, reference: other.reference,
            scope: fixture.snapshot.scope, useContext: fixture.snapshot.useContext, lineage: .independent)
        let resolver = PublicationFixtureResolver([fixture.snapshot])
        await resolver.replace(key: fixture.reference, value: stale)
        let service = MemoryConversationPublicationService(resolver: resolver)
        await #expect(throws: MemoryConversationPublicationError.staleReference) {
            try await service.publish(fixture.candidate, context: fixture.context())
        }
        await resolver.replace(key: fixture.reference, value: fixture.snapshot)
        await resolver.setFinalValidation(false)
        await #expect(throws: MemoryConversationPublicationError.publicationChanged) {
            try await service.publish(fixture.candidate, context: fixture.context())
        }
    }

    @Test("Withdrawn claims are denied in conversation and retained only in authorized history")
    func withdrawal() async throws {
        let fixture = try publicationFixture(validity: .withdrawn)
        let resolver = PublicationFixtureResolver([fixture.snapshot])
        let service = MemoryConversationPublicationService(resolver: resolver)
        await #expect(throws: MemoryConversationPublicationError.policyDenied) {
            try await service.publish(fixture.candidate, context: fixture.context())
        }
        let history = MemoryPublicationCandidate(units: [.init(kind: .overview, references: [fixture.reference])])
        await #expect(throws: MemoryConversationPublicationError.policyDenied) {
            try await service.publish(history, context: fixture.context(intent: .historyOverview))
        }
        await resolver.authorizeHistory()
        let result = try await service.publish(history, context: fixture.context(intent: .historyOverview))
        #expect(result.text.contains("withdrawn"))
        #expect(result.text.contains("Historical information"))
        #expect(result.receipt.intent == .historyOverview)
    }

    @Test("Grounded why uses linked receipt basis; missing linkage never invents reasoning")
    func why() async throws {
        let fixture = try publicationFixture(level: .supportedInference)
        let resolver = PublicationFixtureResolver([fixture.snapshot])
        let service = MemoryConversationPublicationService(resolver: resolver)
        let original = try await service.publish(fixture.candidate, context: fixture.context())
        await resolver.store(original.receipt)
        let whyCandidate = MemoryPublicationCandidate(units: [.init(kind: .explanation, references: [fixture.reference])])
        let explanation = try await service.publish(whyCandidate,
            context: fixture.context(intent: .explanation, explained: original.receipt.id))
        #expect(explanation.text.contains("That reply drew on"))
        #expect(explanation.text.contains("checked user message"))
        #expect(explanation.text.contains(fixture.snapshot.claim.assessment.basis))
        #expect(explanation.text.contains("Tentative"))
        #expect(!explanation.text.contains(fixture.snapshot.claim.provenance[0].sourceID))
        let missing = try await service.publish(.init(units: []), context: fixture.context(intent: .explanation))
        #expect(missing.text == "I don't have a recorded link explaining that wording, so I can't reliably say why it was used.")
        #expect(missing.receipt.dependencies.isEmpty)
    }

    @Test("Overview is requested, bounded, scoped, and distinguishes model inference")
    func overviewAndScopes() async throws {
        let fixture = try publicationFixture(sourceKind: .modelInference)
        let service = MemoryConversationPublicationService(resolver: PublicationFixtureResolver([fixture.snapshot]))
        let candidate = MemoryPublicationCandidate(units: [.init(kind: .overview, references: [fixture.reference])])
        await #expect(throws: MemoryConversationPublicationError.unexpectedIntent) {
            try await service.publish(candidate, context: fixture.context())
        }
        let result = try await service.publish(candidate, context: fixture.context(intent: .overview))
        #expect(result.text.hasPrefix("• "))
        #expect(result.text.contains("an inference or an earlier model response"))
        #expect(result.text.contains("not a complete inventory"))
        for scope in [MemoryScope.user, .teammate(TeammateID(UUID())), .project(ProjectID(UUID()))] {
            let denied = try publicationFixture(scope: scope)
            await #expect(throws: MemoryConversationPublicationError.scopeDenied) {
                try await MemoryConversationPublicationService(resolver: PublicationFixtureResolver([denied.snapshot]))
                    .publish(denied.candidate, context: denied.context())
            }
        }
        let projectID = ProjectID(UUID())
        let project = try publicationFixture(scope: .project(projectID))
        let allowed = try await MemoryConversationPublicationService(resolver: PublicationFixtureResolver([project.snapshot]))
            .publish(project.candidate, context: project.context(projectID: projectID))
        #expect(!allowed.text.isEmpty)
    }

    @Test("A high current claim cannot shed low publication ancestry")
    func historyCannotPromote() async throws {
        let low = try publicationFixture()
        let high = try publicationFixture(level: .confirmed)
        let resolver = PublicationFixtureResolver([low.snapshot, high.snapshot])
        let service = MemoryConversationPublicationService(resolver: resolver)
        let original = try await service.publish(low.candidate, context: low.context())
        await resolver.store(original.receipt)
        await resolver.replace(key: high.reference, value: MemoryPublicationClaimSnapshot(
            claim: high.snapshot.claim, reference: high.reference, scope: high.snapshot.scope,
            useContext: high.snapshot.useContext, lineage: .derived(receiptIDs: [original.receipt.id])))
        let result = try await service.publish(high.candidate, context: high.context())
        #expect(result.text.hasPrefix("I may have this wrong:"))
        #expect(Set(result.receipt.dependencies.map(\.reference)) == [low.reference, high.reference])
    }

    @Test("Unknown, missing, cyclic and excessive lineage all fail closed")
    func lineageFailures() async throws {
        let fixture = try publicationFixture()
        let resolver = PublicationFixtureResolver([fixture.snapshot])
        let service = MemoryConversationPublicationService(resolver: resolver)
        func snapshot(_ lineage: MemoryPublicationLineage) -> MemoryPublicationClaimSnapshot {
            .init(claim: fixture.snapshot.claim, reference: fixture.reference, scope: fixture.snapshot.scope,
                  useContext: fixture.snapshot.useContext, lineage: lineage)
        }
        for lineage in [MemoryPublicationLineage.unknown, .derived(receiptIDs: [UUID()])] {
            await resolver.replace(key: fixture.reference, value: snapshot(lineage))
            await #expect(throws: MemoryConversationPublicationError.unknownLineage) {
                try await service.publish(fixture.candidate, context: fixture.context())
            }
        }
        let cycleID = UUID()
        await resolver.store(publicationReceipt(id: cycleID, lineage: .derived(receiptIDs: [cycleID])))
        await resolver.replace(key: fixture.reference, value: snapshot(.derived(receiptIDs: [cycleID])))
        await #expect(throws: MemoryConversationPublicationError.cyclicLineage) {
            try await service.publish(fixture.candidate, context: fixture.context())
        }
        let ids = (0..<65).map { _ in UUID() }
        for index in ids.indices {
            await resolver.store(publicationReceipt(id: ids[index], lineage: index == 64 ? .independent : .derived(receiptIDs: [ids[index + 1]])))
        }
        await resolver.replace(key: fixture.reference, value: snapshot(.derived(receiptIDs: [ids[0]])))
        await #expect(throws: MemoryConversationPublicationError.boundsExceeded) {
            try await service.publish(fixture.candidate, context: fixture.context())
        }
    }

    @Test("Recomputed text hash cannot launder arbitrary text into a publication receipt")
    func forgedProjection() async throws {
        let fixture = try publicationFixture()
        let resolver = PublicationFixtureResolver([fixture.snapshot])
        let service = MemoryConversationPublicationService(resolver: resolver)
        let context = fixture.context()
        let real = try await service.publish(fixture.candidate, context: context)
        let raw = "It is definitely true. Act now."
        let receipt = real.receipt
        let forged = MemoryPublicationReceipt(id: receipt.id, policyVersion: receipt.policyVersion,
            runID: receipt.runID, messageID: receipt.messageID, teammateID: receipt.teammateID,
            selectedProjectID: receipt.selectedProjectID, intent: receipt.intent,
            renderedTextDigest: MemoryClaimDigests.bytes(Data(raw.utf8)), units: receipt.units,
            dependencies: receipt.dependencies, lineage: receipt.lineage, createdAt: receipt.createdAt)
        let admitted = try await service.revalidate(.init(completeUnits: [raw], receipt: forged, omittedUnitCount: 0), context: context)
        #expect(!admitted)
    }

    @Test("Source line breaks cannot split a qualification; over-budget units never partially publish")
    func boundariesAndBudget() async throws {
        let fixture = try publicationFixture(body: "possible\n\n\"Definitely\"\u{202E}yes")
        let rendered = try await MemoryConversationPublicationService(resolver: PublicationFixtureResolver([fixture.snapshot]))
            .publish(fixture.candidate, context: fixture.context())
        #expect(rendered.completeUnits.count == 1)
        #expect(!rendered.text.contains("\n"))
        #expect(rendered.text.contains("\\n\\n\\\"Definitely\\\"\\u{202e}"))
        #expect(rendered.text.hasSuffix("Does that apply here?"))
        let fixtures = try (0..<3).map { _ in try publicationFixture(body: String(repeating: "x", count: 8_192)) }
        let refs = fixtures.map(\.reference)
        let candidate = MemoryPublicationCandidate(units: refs.map { .init(kind: .claim, references: [$0]) })
        let context = fixtures[0].context(admitted: refs, relevant: refs)
        await #expect(throws: MemoryConversationPublicationError.boundsExceeded) {
            try await MemoryConversationPublicationService(resolver: PublicationFixtureResolver(fixtures.map(\.snapshot)))
                .publish(candidate, context: context)
        }
    }
}

private let publicationOwner = TeammateID(UUID(uuidString: "02020202-0202-0202-0202-020202020202")!)
private let publicationNow = Date(timeIntervalSince1970: 200)

private struct PublicationFixture {
    let snapshot: MemoryPublicationClaimSnapshot
    var reference: MemoryClaimReference { snapshot.reference }
    var candidate: MemoryPublicationCandidate { .init(units: [.init(kind: .claim, references: [reference])]) }
    func context(intent: MemoryConversationIntent = .reply, admitted: [MemoryClaimReference]? = nil,
                 relevant: [MemoryClaimReference]? = nil, explained: UUID? = nil, projectID: ProjectID? = nil,
                 runID: RunID = RunID(UUID()), messageID: MessageID = MessageID(UUID()),
                 limitation: MemoryExplanationLimitation? = nil) -> MemoryPublicationContext {
        .init(runID: runID, messageID: messageID, teammateID: publicationOwner, selectedProjectID: projectID,
              intent: intent, admittedReferences: admitted ?? [reference], relevantReferences: relevant ?? [reference],
              explainedReceiptID: explained, explanationLimitation: limitation, now: publicationNow)
    }
}

private func publicationFixture(body: String = "I prefer quieter places", level: MemoryClaimAssessmentLevel = .uncertain,
                                validity: MemoryClaimValidity = .active, conditions: String? = nil,
                                sourceKind: MemoryClaimSourceKind = .userMessage,
                                scope: MemoryScope = .teammate(publicationOwner)) throws -> PublicationFixture {
    let id = MemoryClaimID(UUID())
    let source = MemoryClaimSourceReference(id: UUID(), kind: sourceKind, sourceID: UUID().uuidString,
        sourceRevision: 1, contentDigest: MemoryClaimDigests.bytes(Data("source".utf8)),
        observedAt: Date(timeIntervalSince1970: 90), scope: scope)
    let basis = "A recorded statement supports this preference."
    let preliminary = MemoryClaim(id: id, body: body,
        assessment: .init(level: level, basis: basis, assessor: .init(kind: .user), assessedAt: Date(timeIntervalSince1970: 100)),
        provenance: [source], observedAt: Date(timeIntervalSince1970: 90), conditions: conditions, validity: validity)
    let evidence = MemoryClaimEvidenceReference(receiptID: UUID(), receiptDigest: MemoryClaimDigests.bytes(Data("receipt".utf8)),
        source: source, relation: .supports, subjectDigest: try MemoryClaimDigests.subject(preliminary, scope: scope))
    let claim = MemoryClaim(id: id, body: body,
        assessment: .init(level: level, basis: basis, assessor: .init(kind: .user),
                          assessedAt: Date(timeIntervalSince1970: 100), evidence: [evidence]),
        provenance: [source], observedAt: preliminary.observedAt, conditions: conditions, validity: validity)
    let reference = MemoryClaimReference(documentID: MemoryDocumentID(UUID()), documentRevision: 1,
        contentDigest: MemoryClaimDigests.bytes(Data("artifact".utf8)), claimID: id,
        claimDigest: try MemoryClaimDigests.claim(claim), subjectDigest: try MemoryClaimDigests.subject(claim, scope: scope))
    let verified = MemoryClaimVerifiedEvidence(reference: evidence, claimID: id, scope: scope, authority: .userAction,
        verifierID: "synthetic-user-action", verifierVersion: 1, checkedAt: Date(timeIntervalSince1970: 100),
        validUntil: Date(timeIntervalSince1970: 1_000), independentEvidenceID: source.id)
    let memberships: Set<ProjectID>
    if case let .project(id) = scope { memberships = [id] } else { memberships = [] }
    let context = MemoryClaimUseContext(purpose: .conversation, now: publicationNow, teammateID: publicationOwner,
        activeProjectMemberships: memberships, currentReference: reference, freshness: .current, isRelevant: true,
        verifiedEvidence: [verified], conditionsSatisfied: true)
    return .init(snapshot: .init(claim: claim, reference: reference, scope: scope, useContext: context, lineage: .independent))
}

private actor PublicationFixtureResolver: MemoryConversationPublicationResolving {
    var snapshots: [MemoryClaimReference: MemoryPublicationClaimSnapshot]
    var receipts: [UUID: MemoryPublicationReceipt] = [:]
    var finalValidation = true
    var historyAuthorized = false
    private(set) var claimReads = 0
    init(_ snapshots: [MemoryPublicationClaimSnapshot]) {
        self.snapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.reference, $0) })
    }
    func resolveClaim(_ reference: MemoryClaimReference, context: MemoryPublicationContext) async throws -> MemoryPublicationClaimSnapshot? {
        claimReads += 1
        guard let value = snapshots[reference] else { return nil }
        let prior = value.useContext
        let use = MemoryClaimUseContext(purpose: context.intent == .historyOverview ? .ownerInspection : .conversation,
            now: context.now, teammateID: context.teammateID, selectedProjectID: context.selectedProjectID,
            activeProjectMemberships: prior.activeProjectMemberships, currentReference: prior.currentReference,
            freshness: prior.freshness, isRelevant: true, ownerInspectionAuthorized: historyAuthorized,
            verifiedEvidence: prior.verifiedEvidence, conditionsSatisfied: prior.conditionsSatisfied)
        return .init(claim: value.claim, reference: value.reference, scope: value.scope, useContext: use, lineage: value.lineage)
    }
    func resolveReceipt(_ id: UUID, context: MemoryPublicationContext) async throws -> MemoryPublicationReceipt? { receipts[id] }
    func revalidate(_ receipt: MemoryPublicationReceipt, context: MemoryPublicationContext) async throws -> Bool { finalValidation }
    func replace(key: MemoryClaimReference, value: MemoryPublicationClaimSnapshot) { snapshots[key] = value }
    func store(_ receipt: MemoryPublicationReceipt) { receipts[receipt.id] = receipt }
    func setFinalValidation(_ value: Bool) { finalValidation = value }
    func authorizeHistory() { historyAuthorized = true }
}

private func publicationWire(_ units: [MemoryPublicationUnit]) throws -> Data {
    struct Wire: Encodable { let version: Int; let units: [MemoryPublicationUnit] }
    return try MemoryClaimDigests.canonicalData(Wire(version: 1, units: units))
}

private func publicationReceipt(id: UUID, lineage: MemoryPublicationLineage) -> MemoryPublicationReceipt {
    .init(id: id, policyVersion: 1, runID: RunID(UUID()), messageID: MessageID(UUID()), teammateID: publicationOwner,
          selectedProjectID: nil, intent: .reply, renderedTextDigest: MemoryClaimDigests.bytes(Data()),
          units: [], dependencies: [], lineage: lineage, createdAt: publicationNow)
}
