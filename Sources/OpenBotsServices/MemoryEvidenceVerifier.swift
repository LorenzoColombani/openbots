import Foundation
import OpenBotsContent
import OpenBotsDomain

public enum MemoryEvidenceVerifierError: Error, Equatable, Sendable {
    case unsupportedRegistry, invalidSource, staleActor, ambiguousIntent, unsupportedIntent, forgedReceipt, invalidScope
}

public enum MemoryUserCommandAction: Equatable, Sendable {
    case retainUncertain, confirmFirstHand, correctFirstHand, correctAdoptedQuotation, withdraw
}

/// A parsing result, never source authority or a successful memory mutation.
/// Callers supply only already-admitted current claims from the current scope.
public enum MemoryUserCommandTarget: Equatable, Sendable {
    case newClaim(action: MemoryUserCommandAction, body: String)
    case existingClaim(action: MemoryUserCommandAction, body: String, claimID: MemoryClaimID)
    case ambiguous
    case unsupported
}

/// One atomic replacement: the prior proposition remains withdrawn history;
/// the materially different statement has its own deterministic identity.
public struct MemoryUserCorrectionProposal: Equatable, Sendable {
    public let withdrawnPredecessor: MemoryClaim
    public let successor: MemoryClaim
    public init(withdrawnPredecessor: MemoryClaim, successor: MemoryClaim) {
        self.withdrawnPredecessor = withdrawnPredecessor; self.successor = successor
    }
}

/// Registered, deliberately narrow predicates. There is no provider-defined
/// callback, receipt deserializer or general semantic truth detector here.
public struct MemoryEvidenceVerifier: MemoryAdmissionEvidenceVerifying, Sendable {
    public static let userRegistryID = "user-explicit-memory-v1"
    public static let savedNameRegistryID = "teammate-saved-name-v1"
    public static let registryVersion: UInt16 = 1
    private let messages: any MessageRepository
    private let teammates: any TeammateRepository
    private let contexts: any ReadContextRepository
    private let verificationLifetime: TimeInterval

    public init(messages: any MessageRepository, teammates: any TeammateRepository,
                contexts: any ReadContextRepository, verificationLifetime: TimeInterval = 900) {
        self.messages = messages; self.teammates = teammates; self.contexts = contexts
        // This expires only the host check, never retained assertions or evidence.
        self.verificationLifetime = verificationLifetime.isFinite ? min(900, max(1, verificationLifetime)) : 1
    }

    /// Recognizes only the bounded whole-message grammar. A matching string from
    /// a model, quote, document or old message still cannot authorize admission.
    public static func recognizesUserCommand(_ text: String) -> Bool {
        (try? UserCommand(text: text)) != nil
    }

    public static func userTarget(text: String, claims: [MemoryClaim]) -> MemoryUserCommandTarget {
        guard let command = try? UserCommand(text: text) else { return .unsupported }
        guard claims.count <= 256, Set(claims.map(\.id)).count == claims.count else { return .ambiguous }
        if command.kind == .correct {
            let active = claims.filter { claim in
                Self.isCurrentTarget(claim) && (command.targetBody.map { $0.utf8.elementsEqual(claim.body.utf8) } ?? true)
            }
            guard active.count == 1, let prior = active.first else { return .ambiguous }
            return .existingClaim(action: command.action, body: command.body, claimID: prior.id)
        }
        let matching = claims.filter { Self.isCurrentTarget($0) && $0.body.utf8.elementsEqual(command.body.utf8) }
        if matching.isEmpty {
            // A withdrawn-only match does not authorize reviving that identity.
            // Historical duplicates may coexist with a distinct current claim.
            guard !claims.contains(where: { $0.body.utf8.elementsEqual(command.body.utf8) }) else { return .ambiguous }
            return command.kind == .withdraw ? .ambiguous : .newClaim(action: command.action, body: command.body)
        }
        guard matching.count == 1, let prior = matching.first else { return .ambiguous }
        return .existingClaim(action: command.action, body: command.body, claimID: prior.id)
    }

    private static func isCurrentTarget(_ claim: MemoryClaim) -> Bool {
        claim.hasKnownSemantics && claim.validity != .withdrawn
    }

    public func userProposal(messageID: MessageID, claimID: MemoryClaimID, scope: MemoryScope,
                             previous: MemoryClaim? = nil, previousReference: MemoryClaimReference? = nil,
                             authority: ReadContextReceipt, at now: Date) async throws -> MemoryClaim {
        try await validateScope(scope, authority: authority)
        let message = try await userMessage(messageID, authority: authority, at: now, requireLatest: true)
        let command = try UserCommand(text: text(message))
        if let previous {
            guard Self.isCurrentTarget(previous), previous.id == claimID, previousReference?.claimID == claimID,
                  command.targetBody.map({ exact($0, previous.body) }) ?? true,
                  previous.conditions == nil, previous.validFrom == nil, previous.validUntil == nil else {
                throw MemoryEvidenceVerifierError.ambiguousIntent
            }
            // A changed body requires the atomic old/new pair below. Never
            // silently repurpose the previous claim's stable identity.
            if !exact(command.body, previous.body) {
                throw MemoryEvidenceVerifierError.ambiguousIntent
            }
        } else if previousReference != nil || command.kind == .correct || command.kind == .withdraw {
            throw MemoryEvidenceVerifierError.ambiguousIntent
        }
        let validity: MemoryClaimValidity = command.kind == .withdraw ? .withdrawn : .active
        let observedAt = command.kind == .withdraw ? previous?.observedAt : message.createdAt
        let assessor = MemoryClaimAssessor(kind: .user, identity: message.id.persistedValue)
        var changes: [MemoryClaimChange] = []
        if let previousReference {
            let kind: MemoryClaimChange.Kind = command.kind == .withdraw ? .withdrawal : .correction
            changes = [MemoryClaimChange(kind: kind, previous: previousReference,
                                         reason: command.reason, changedAt: message.createdAt)]
        }
        let draft = MemoryClaim(id: claimID, body: command.body,
            assessment: .init(level: command.level, basis: command.basis, assessor: assessor,
                              assessedAt: message.createdAt), provenance: [], observedAt: observedAt,
            validity: validity, changes: changes)
        let reference = try userReference(claim: draft, message: message, command: command, scope: scope)
        return withEvidence(draft, reference: reference)
    }

    public func userCorrectionProposal(messageID: MessageID, previous: MemoryClaim,
                                       previousReference: MemoryClaimReference, scope: MemoryScope,
                                       authority: ReadContextReceipt, at now: Date) async throws -> MemoryUserCorrectionProposal {
        try await validateScope(scope, authority: authority)
        try previous.validate(scope: scope)
        let message = try await userMessage(messageID, authority: authority, at: now, requireLatest: true)
        let command = try UserCommand(text: text(message))
        guard command.kind == .correct, !exact(command.body, previous.body),
              command.targetBody.map({ exact($0, previous.body) }) ?? true,
              previous.hasKnownSemantics, previous.validity != .withdrawn,
              previous.conditions == nil, previous.validFrom == nil, previous.validUntil == nil,
              previousReference.claimID == previous.id,
              previousReference.claimDigest == (try MemoryClaimDigests.claim(previous)),
              previousReference.subjectDigest == (try MemoryClaimDigests.subject(previous, scope: scope)) else {
            throw MemoryEvidenceVerifierError.ambiguousIntent
        }
        let successorID = Self.correctionSuccessorID(message: message, previous: previousReference, body: command.body)
        guard successorID != previous.id else { throw MemoryEvidenceVerifierError.invalidSource }
        let assessor = MemoryClaimAssessor(kind: .user, identity: message.id.persistedValue)
        let withdrawn = MemoryClaim(id: previous.id, body: previous.body,
            assessment: .init(level: .uncertain, basis: Self.replacedClaimBasis, assessor: assessor, assessedAt: message.createdAt),
            provenance: [], observedAt: previous.observedAt, validity: .withdrawn,
            changes: [.init(kind: .withdrawal, previous: previousReference, reason: Self.replacedClaimBasis, changedAt: message.createdAt)])
        let successor = MemoryClaim(id: successorID, body: command.body,
            assessment: .init(level: command.level, basis: command.basis, assessor: assessor, assessedAt: message.createdAt),
            provenance: [], observedAt: message.createdAt,
            changes: [.init(kind: .supersession, previous: previousReference, reason: command.reason, changedAt: message.createdAt)])
        return try MemoryUserCorrectionProposal(
            withdrawnPredecessor: withEvidence(withdrawn, reference: userReference(claim: withdrawn, message: message, command: command, scope: scope)),
            successor: withEvidence(successor, reference: userReference(claim: successor, message: message, command: command, scope: scope)))
    }

    public func savedTeammateNameProposal(claimID: MemoryClaimID, previous: MemoryClaim? = nil,
                                         previousReference: MemoryClaimReference? = nil,
                                         authority: ReadContextReceipt, at now: Date) async throws -> MemoryClaim {
        let scope = MemoryScope.teammate(authority.teammateID)
        try await validateScope(scope, authority: authority)
        let teammate = try await currentTeammate(authority, at: now)
        guard previous == nil ? previousReference == nil : previous?.id == claimID && previousReference?.claimID == claimID else {
            throw MemoryEvidenceVerifierError.ambiguousIntent
        }
        if let previous, let previousReference,
           !exact(previous.body, try Self.savedNameStatement(teammate.profile.displayName)) {
            return try await reconsiderSavedNameProposal(previous: previous, previousReference: previousReference,
                                                         authority: authority, at: now)
        }
        let changes = previousReference.map {
            [MemoryClaimChange(kind: .correction, previous: $0, reason: "Rechecked the saved bot name.", changedAt: now)]
        } ?? []
        let draft = MemoryClaim(id: claimID, body: try Self.savedNameStatement(teammate.profile.displayName),
            assessment: .init(level: .confirmed, basis: Self.savedNameBasis,
                              assessor: .init(kind: .app, identity: Self.savedNameRegistryID), assessedAt: now),
            provenance: [], observedAt: teammate.updatedAt, changes: changes)
        return try withEvidence(draft, reference: nameReference(claim: draft, teammate: teammate, scope: scope))
    }

    /// A changed stored profile supplies concrete contradictory evidence. Keep
    /// the earlier proposition/history and demote it; do not rewrite it as true.
    public func reconsiderSavedNameProposal(previous: MemoryClaim, previousReference: MemoryClaimReference,
                                             authority: ReadContextReceipt, at now: Date) async throws -> MemoryClaim {
        let scope = MemoryScope.teammate(authority.teammateID)
        try await validateScope(scope, authority: authority)
        let teammate = try await currentTeammate(authority, at: now)
        guard previousReference.claimID == previous.id,
              previousReference.claimDigest == (try MemoryClaimDigests.claim(previous)),
              previousReference.subjectDigest == (try MemoryClaimDigests.subject(previous, scope: scope)),
              previous.conditions == nil, previous.validFrom == nil, previous.validUntil == nil,
              previous.validity != .withdrawn,
              !exact(try Self.nameInStatement(previous.body), teammate.profile.displayName) else {
            throw MemoryEvidenceVerifierError.unsupportedIntent
        }
        let draft = MemoryClaim(id: previous.id, body: previous.body,
            assessment: .init(level: .uncertain, basis: Self.changedNameBasis,
                assessor: .init(kind: .app, identity: Self.savedNameRegistryID), assessedAt: now),
            provenance: [], observedAt: previous.observedAt, validity: .disputed,
            changes: [.init(kind: .reassessment, previous: previousReference,
                            reason: Self.changedNameBasis, changedAt: now)])
        return try withEvidence(draft, reference: nameReference(claim: draft, teammate: teammate, scope: scope))
    }

    public func verify(artifact: MemoryClaimArtifact, predecessor: MemoryClaimArtifact?,
                       actor: MemoryPublicationActor, authority: ReadContextReceipt,
                       at now: Date) async throws -> MemoryAdmissionEvidence {
        try artifact.validate()
        try predecessor?.validate()
        guard artifact.hasKnownSemantics, now.timeIntervalSince1970.isFinite,
              predecessor == nil || predecessor?.scope == artifact.scope else {
            throw MemoryEvidenceVerifierError.invalidSource
        }
        try await validateScope(artifact.scope, authority: authority)
        let previousByID = Dictionary(uniqueKeysWithValues: (predecessor?.claims ?? []).map { ($0.id, $0) })
        let changed = try artifact.claims.filter { claim in
            guard let previous = previousByID[claim.id] else { return true }
            return try !sameBytes(previous, claim)
        }
        guard !changed.isEmpty else { throw MemoryEvidenceVerifierError.ambiguousIntent }
        var replacementByID: [MemoryClaimID: MemoryClaim] = [:]
        switch actor {
        case let .user(messageID):
            if changed.count == 2 {
                let oldCandidates = changed.compactMap { previousByID[$0.id] }
                guard oldCandidates.count == 1, let old = oldCandidates.first, let predecessor,
                      predecessor.claims.filter({ Self.isCurrentTarget($0) && exact($0.body, old.body) }).count == 1 else {
                    throw MemoryEvidenceVerifierError.ambiguousIntent
                }
                let bytes = try MemoryClaimCodec().encode(predecessor)
                let reference = try MemoryClaimCodec().reference(for: old, in: predecessor,
                    contentDigest: MemoryClaimDigests.bytes(bytes))
                let pair = try await userCorrectionProposal(messageID: messageID, previous: old,
                    previousReference: reference, scope: artifact.scope, authority: authority, at: now)
                guard previousByID[pair.successor.id] == nil else { throw MemoryEvidenceVerifierError.ambiguousIntent }
                replacementByID = [pair.withdrawnPredecessor.id: pair.withdrawnPredecessor, pair.successor.id: pair.successor]
                for claim in changed {
                    guard let expected = replacementByID[claim.id], try sameBytes(expected, claim) else {
                        throw MemoryEvidenceVerifierError.forgedReceipt
                    }
                }
            } else if changed.count != 1 { throw MemoryEvidenceVerifierError.ambiguousIntent }
        case let .app(registry):
            guard registry == Self.savedNameRegistryID else { throw MemoryEvidenceVerifierError.unsupportedRegistry }
        }
        var verified: [MemoryClaimVerifiedEvidence] = []
        var stamps: [MessageID: MemoryPublicationUserMessageEvidence] = [:]
        var previousIDs: Set<UUID> = []
        for claim in artifact.claims {
            if changed.contains(where: { $0.id == claim.id }) {
                let old = previousByID[claim.id]
                let reference: MemoryClaimReference?
                if let old, let predecessor {
                    let bytes = try MemoryClaimCodec().encode(predecessor)
                    reference = try MemoryClaimCodec().reference(for: old, in: predecessor,
                                                                 contentDigest: MemoryClaimDigests.bytes(bytes))
                } else { reference = nil }
                if case let .user(messageID) = actor {
                    // Replacement pairs were already reconstructed together
                    // from the actual command and exact predecessor above.
                    if replacementByID[claim.id] == nil {
                        if let old, let predecessor {
                            guard predecessor.claims.filter({ Self.isCurrentTarget($0) && exact($0.body, old.body) }).count == 1 else {
                                throw MemoryEvidenceVerifierError.ambiguousIntent
                            }
                        }
                        let expected = try await userProposal(messageID: messageID, claimID: claim.id,
                            scope: artifact.scope, previous: old, previousReference: reference, authority: authority, at: now)
                        guard try sameBytes(expected, claim) else { throw MemoryEvidenceVerifierError.forgedReceipt }
                    }
                } else {
                    guard claim.assessment.assessor == .init(kind: .app, identity: Self.savedNameRegistryID) else {
                        throw MemoryEvidenceVerifierError.forgedReceipt
                    }
                    // Time of the original proposal is retained; the source and
                    // host token are independently refreshed below.
                    guard let assessedAt = claim.assessment.assessedAt, assessedAt <= now else {
                        throw MemoryEvidenceVerifierError.invalidSource
                    }
                    let expected = try await savedTeammateNameProposal(claimID: claim.id, previous: old,
                        previousReference: reference, authority: authority, at: assessedAt)
                    guard try sameBytes(expected, claim) else { throw MemoryEvidenceVerifierError.forgedReceipt }
                }
            }
            let resolved = try await resolveRetained(claim, scope: artifact.scope, authority: authority, at: now)
            verified.append(resolved.receipt)
            if let stamp = resolved.stamp { stamps[stamp.messageID] = stamp }
        }
        // Original independence identities remain stable across copies and
        // assessment revisions. Resolve historical user sources, not their age.
        for old in predecessor?.claims ?? [] {
            for reference in old.assessment.evidence {
                switch reference.source.kind {
                case .userMessage:
                    guard let id = UUID(uuidString: reference.source.sourceID) else { throw MemoryEvidenceVerifierError.invalidSource }
                    let message = try await userMessage(MessageID(id), authority: authority, at: now, requireLatest: false)
                    let command = try UserCommand(text: text(message))
                    let expected = try userReference(claim: old, message: message, command: command, scope: artifact.scope)
                    guard expected == reference else { throw MemoryEvidenceVerifierError.forgedReceipt }
                    previousIDs.insert(message.id.rawValue)
                    let stamp = try userStamp(message)
                    stamps[stamp.messageID] = stamp
                    // A known contradiction cannot disappear simply because a
                    // new proposal omitted its evidence reference.
                    if reference.relation != .supports,
                       let current = artifact.claims.first(where: { $0.id == old.id }),
                       reference.subjectDigest == (try MemoryClaimDigests.subject(current, scope: artifact.scope)),
                       !verified.contains(where: { $0.reference.receiptID == reference.receiptID }) {
                        verified.append(hostReceipt(reference, claimID: old.id, scope: artifact.scope,
                            authority: .userAction, registry: Self.userRegistryID, independentID: message.id.rawValue, at: now))
                    }
                case .appObservation:
                    guard reference.source.sourceID == Self.nameSourceID(authority.teammateID),
                          let digest = reference.source.contentDigest,
                          reference.source.id == Self.stableID(reference.source.sourceID + ":" + digest) else {
                        throw MemoryEvidenceVerifierError.invalidSource
                    }
                    previousIDs.insert(reference.source.id)
                default: throw MemoryEvidenceVerifierError.unsupportedRegistry
                }
            }
        }
        try await validateScope(artifact.scope, authority: authority)
        return MemoryAdmissionEvidence(verified: verified,
            userMessages: stamps.values.sorted { $0.messageID.persistedValue < $1.messageID.persistedValue },
            previousIndependentEvidenceIDs: previousIDs)
    }

    /// Read-only revalidation is not a new assessment or user action. Older
    /// durable sources remain inspectable; unknown/multi-source interpretations
    /// fail closed until a registered predicate supports them.
    public func verifyRetained(claim: MemoryClaim, scope: MemoryScope, authority: ReadContextReceipt,
                               at now: Date) async throws -> [MemoryClaimVerifiedEvidence] {
        try claim.validate(scope: scope)
        guard claim.hasKnownSemantics else { throw MemoryEvidenceVerifierError.unsupportedRegistry }
        try await validateScope(scope, authority: authority)
        let resolved = try await resolveRetained(claim, scope: scope, authority: authority, at: now)
        try await validateScope(scope, authority: authority)
        return [resolved.receipt]
    }

    private func resolveRetained(_ claim: MemoryClaim, scope: MemoryScope, authority: ReadContextReceipt,
                                 at now: Date) async throws
        -> (receipt: MemoryClaimVerifiedEvidence, stamp: MemoryPublicationUserMessageEvidence?) {
        guard claim.provenance.count == 1, claim.assessment.evidence.count == 1,
              let reference = claim.assessment.evidence.first else { throw MemoryEvidenceVerifierError.forgedReceipt }
        switch reference.source.kind {
        case .userMessage:
            guard let id = UUID(uuidString: reference.source.sourceID) else { throw MemoryEvidenceVerifierError.invalidSource }
            let message = try await userMessage(MessageID(id), authority: authority, at: now, requireLatest: false)
            let command = try UserCommand(text: text(message))
            let expected = try userReference(claim: claim, message: message, command: command, scope: scope)
            guard reference == expected, claim.provenance == [expected.source] else {
                throw MemoryEvidenceVerifierError.forgedReceipt
            }
            return (hostReceipt(expected, claimID: claim.id, scope: scope, authority: .userAction,
                                registry: Self.userRegistryID, independentID: message.id.rawValue, at: now), try userStamp(message))
        case .appObservation:
            guard scope == .teammate(authority.teammateID) else { throw MemoryEvidenceVerifierError.invalidScope }
            let teammate = try await currentTeammate(authority, at: now)
            let expected = try nameReference(claim: claim, teammate: teammate, scope: scope)
            guard reference == expected, claim.provenance == [expected.source] else {
                throw MemoryEvidenceVerifierError.forgedReceipt
            }
            return (hostReceipt(expected, claimID: claim.id, scope: scope, authority: .appVerifier,
                                registry: Self.savedNameRegistryID, independentID: expected.source.id, at: now), nil)
        default: throw MemoryEvidenceVerifierError.unsupportedRegistry
        }
    }

    private func userReference(claim: MemoryClaim, message: Message, command: UserCommand,
                               scope: MemoryScope) throws -> MemoryClaimEvidenceReference {
        let replaced = command.kind == .correct && claim.validity == .withdrawn
        if replaced {
            guard !exact(claim.body, command.body), claim.assessment.level == .uncertain,
                  command.targetBody.map({ exact($0, claim.body) }) ?? true,
                  exact(claim.assessment.basis, Self.replacedClaimBasis), claim.changes.count == 1,
                  let change = claim.changes.first, change.kind == .withdrawal,
                  change.previous.claimID == claim.id, change.changedAt == message.createdAt,
                  change.previous.subjectDigest == (try MemoryClaimDigests.subject(claim, scope: scope)),
                  exact(change.reason, Self.replacedClaimBasis) else { throw MemoryEvidenceVerifierError.unsupportedIntent }
        } else {
            guard exact(claim.body, command.body), claim.assessment.level == command.level,
                  exact(claim.assessment.basis, command.basis),
                  claim.validity == (command.kind == .withdraw ? .withdrawn : .active),
                  command.kind == .withdraw || claim.observedAt == message.createdAt else {
                throw MemoryEvidenceVerifierError.unsupportedIntent
            }
            if command.kind == .correct, let change = claim.changes.first, change.kind == .supersession {
                guard claim.changes.count == 1, change.previous.claimID != claim.id,
                      change.changedAt == message.createdAt,
                      claim.id == Self.correctionSuccessorID(message: message, previous: change.previous, body: command.body) else {
                    throw MemoryEvidenceVerifierError.unsupportedIntent
                }
            }
        }
        guard claim.assessment.assessor == .init(kind: .user, identity: message.id.persistedValue),
              claim.assessment.assessedAt == message.createdAt, claim.conditions == nil,
              claim.validFrom == nil, claim.validUntil == nil else {
            throw MemoryEvidenceVerifierError.unsupportedIntent
        }
        let source = MemoryClaimSourceReference(id: message.id.rawValue, kind: .userMessage,
            sourceID: message.id.persistedValue, sourceRevision: UInt64(message.sequence),
            contentDigest: MemoryClaimDigests.bytes(Data(try text(message).utf8)), observedAt: message.createdAt, scope: scope)
        return try evidence(claim, source: source, scope: scope, registry: Self.userRegistryID,
                            relation: command.kind == .withdraw || replaced ? .invalidates : .supports)
    }

    private static let replacedClaimBasis = "The user replaced this proposition with a different statement; the earlier claim is withdrawn and remains private history."
    private static func correctionSuccessorID(message: Message, previous: MemoryClaimReference, body: String) -> MemoryClaimID {
        MemoryClaimID(stableID("memory-user-correction:" + message.id.persistedValue + ":" + previous.claimID.rawValue.uuidString.lowercased()
            + ":" + previous.subjectDigest + ":" + MemoryClaimDigests.bytes(Data(body.utf8))))
    }

    private func nameReference(claim: MemoryClaim, teammate: Teammate, scope: MemoryScope) throws -> MemoryClaimEvidenceReference {
        let agrees = exact(try Self.nameInStatement(claim.body), teammate.profile.displayName)
        guard claim.assessment.assessor == .init(kind: .app, identity: Self.savedNameRegistryID),
              claim.conditions == nil, claim.validFrom == nil, claim.validUntil == nil,
              let assessedAt = claim.assessment.assessedAt, teammate.updatedAt <= assessedAt else {
            throw MemoryEvidenceVerifierError.unsupportedIntent
        }
        if agrees {
            guard claim.assessment.level == .confirmed, claim.validity == .active,
                  exact(claim.assessment.basis, Self.savedNameBasis), claim.observedAt == teammate.updatedAt else {
                throw MemoryEvidenceVerifierError.unsupportedIntent
            }
        } else {
            guard claim.assessment.level == .uncertain, claim.validity == .disputed,
                  exact(claim.assessment.basis, Self.changedNameBasis),
                  let observedAt = claim.observedAt, observedAt <= teammate.updatedAt else {
                throw MemoryEvidenceVerifierError.unsupportedIntent
            }
        }
        struct Snapshot: Encodable { let id: TeammateID; let name: String; let revision: UInt64; let updatedAt: Date }
        let bytes = try MemoryClaimDigests.canonicalData(Snapshot(id: teammate.id, name: teammate.profile.displayName,
                                                                revision: teammate.profile.revision, updatedAt: teammate.updatedAt))
        let sourceID = Self.nameSourceID(teammate.id)
        let sourceDigest = MemoryClaimDigests.bytes(bytes)
        let source = MemoryClaimSourceReference(id: Self.stableID(sourceID + ":" + sourceDigest), kind: .appObservation,
            sourceID: sourceID, sourceRevision: teammate.profile.revision, contentDigest: sourceDigest,
            observedAt: teammate.updatedAt, scope: scope)
        return try evidence(claim, source: source, scope: scope, registry: Self.savedNameRegistryID,
                            relation: agrees ? .supports : .contradicts)
    }

    private func evidence(_ claim: MemoryClaim, source: MemoryClaimSourceReference, scope: MemoryScope,
                          registry: String, relation: MemoryClaimEvidenceRelation) throws -> MemoryClaimEvidenceReference {
        struct Binding: Encodable {
            let registry: String; let version: UInt16; let claimID: MemoryClaimID; let source: MemoryClaimSourceReference
            let subject: String; let relation: MemoryClaimEvidenceRelation; let level: MemoryClaimAssessmentLevel
            let validity: MemoryClaimValidity; let assessedAt: Date?
        }
        let subject = try MemoryClaimDigests.subject(claim, scope: scope)
        let digest = MemoryClaimDigests.bytes(try MemoryClaimDigests.canonicalData(Binding(registry: registry,
            version: Self.registryVersion, claimID: claim.id, source: source, subject: subject, relation: relation,
            level: claim.assessment.level, validity: claim.validity, assessedAt: claim.assessment.assessedAt)))
        return MemoryClaimEvidenceReference(receiptID: Self.stableID(digest), receiptDigest: digest,
                                             source: source, relation: relation, subjectDigest: subject)
    }

    private func hostReceipt(_ reference: MemoryClaimEvidenceReference, claimID: MemoryClaimID, scope: MemoryScope,
                             authority: MemoryClaimVerifiedEvidence.Authority, registry: String,
                             independentID: UUID, at now: Date) -> MemoryClaimVerifiedEvidence {
        MemoryClaimVerifiedEvidence(reference: reference, claimID: claimID, scope: scope, authority: authority,
            verifierID: registry, verifierVersion: Self.registryVersion, checkedAt: now,
            validUntil: now.addingTimeInterval(verificationLifetime), independentEvidenceID: independentID)
    }

    private func validateScope(_ scope: MemoryScope, authority: ReadContextReceipt) async throws {
        switch scope {
        case .user: throw MemoryEvidenceVerifierError.invalidScope
        case let .teammate(id): guard id == authority.teammateID else { throw MemoryEvidenceVerifierError.invalidScope }
        case let .project(id):
            guard id == authority.selectedProjectID, authority.projectMembershipJoinedAt != nil else {
                throw MemoryEvidenceVerifierError.invalidScope
            }
        }
        try await contexts.revalidateReadContext(authority.selecting(messageIDs: [], memoryDocumentIDs: []))
    }

    private func userMessage(_ id: MessageID, authority: ReadContextReceipt, at now: Date,
                             requireLatest: Bool) async throws -> Message {
        guard let message = try await messages.message(id: id), message.id == id,
              message.conversationID == authority.conversationID, message.author == .user,
              message.outputClass == .conversation, message.sequence > 0,
              message.createdAt.timeIntervalSince1970.isFinite, message.updatedAt.timeIntervalSince1970.isFinite,
              message.createdAt <= message.updatedAt, message.updatedAt <= now else {
            throw MemoryEvidenceVerifierError.invalidSource
        }
        _ = try text(message)
        if requireLatest {
            let page = try await messages.page(conversationID: authority.conversationID, request: PageRequest(limit: 1))
            guard page.elements.count == 1, page.elements[0].id == id else { throw MemoryEvidenceVerifierError.staleActor }
        }
        return message
    }

    private func currentTeammate(_ authority: ReadContextReceipt, at now: Date) async throws -> Teammate {
        guard now.timeIntervalSince1970.isFinite,
              let teammate = try await teammates.teammate(id: authority.teammateID),
              teammate.profile.revision == authority.profileRevision,
              teammate.updatedAt.timeIntervalSince1970.isFinite, teammate.updatedAt <= now else {
            throw MemoryEvidenceVerifierError.invalidSource
        }
        return teammate
    }

    private func text(_ message: Message) throws -> String {
        guard message.parts.count == 1, message.parts[0].ordinal == 0,
              case let .text(text) = message.parts[0].content, !text.isEmpty,
              text.utf8.count <= 8_192, !text.contains("\0") else { throw MemoryEvidenceVerifierError.invalidSource }
        return text
    }
    private func userStamp(_ message: Message) throws -> MemoryPublicationUserMessageEvidence {
        try MemoryPublicationUserMessageEvidence(messageID: message.id,
            contentDigest: MemoryClaimDigests.bytes(Data(try text(message).utf8)), updatedAt: message.updatedAt)
    }
    private func withEvidence(_ claim: MemoryClaim, reference: MemoryClaimEvidenceReference) -> MemoryClaim {
        MemoryClaim(id: claim.id, body: claim.body,
            assessment: .init(level: claim.assessment.level, basis: claim.assessment.basis,
                assessor: claim.assessment.assessor, assessedAt: claim.assessment.assessedAt,
                policyVersion: claim.assessment.policyVersion, evidence: [reference]), provenance: [reference.source],
            observedAt: claim.observedAt, validFrom: claim.validFrom, validUntil: claim.validUntil,
            conditions: claim.conditions, validity: claim.validity, changes: claim.changes)
    }
    private func sameBytes(_ lhs: MemoryClaim, _ rhs: MemoryClaim) throws -> Bool {
        try MemoryClaimDigests.canonicalData(lhs) == MemoryClaimDigests.canonicalData(rhs)
    }
    private func exact(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    private static let savedNameBasis = "Read the current saved bot profile; this verifies the stored name only."
    private static let changedNameBasis = "The current saved bot name differs from this earlier claim; it needs review."
    public static func savedNameStatement(_ name: String) throws -> String {
        let literal = String(decoding: try MemoryClaimDigests.canonicalData(name), as: UTF8.self)
        return "This bot's saved display name is \(literal)."
    }
    private static func nameInStatement(_ body: String) throws -> String {
        let prefix = "This bot's saved display name is "
        guard body.hasPrefix(prefix), body.hasSuffix("."),
              let name = try? JSONDecoder().decode(String.self, from: Data(body.dropFirst(prefix.count).dropLast().utf8)),
              body.utf8.elementsEqual(try savedNameStatement(name).utf8) else {
            throw MemoryEvidenceVerifierError.unsupportedIntent
        }
        return name
    }
    private static func nameSourceID(_ id: TeammateID) -> String { "teammate.saved-name:" + id.persistedValue }
    private static func stableID(_ text: String) -> UUID {
        let chars = Array(MemoryClaimDigests.bytes(Data(text.utf8)).prefix(32))
        let value = String(chars[0..<8]) + "-" + String(chars[8..<12]) + "-" + String(chars[12..<16])
            + "-" + String(chars[16..<20]) + "-" + String(chars[20..<32])
        return UUID(uuidString: value)!
    }

    private struct UserCommand {
        enum Kind { case confirm, uncertain, correct, withdraw }
        enum Form { case explicit, remember, forget, formerResidence, adoptedQuotation, namedQuotedReplacement }
        let kind: Kind
        let form: Form
        let body: String
        let targetBody: String?
        var isQuotedReplacement: Bool { form == .adoptedQuotation || form == .namedQuotedReplacement }
        var action: MemoryUserCommandAction {
            switch kind {
            case .confirm: .confirmFirstHand
            case .uncertain: .retainUncertain
            case .correct: isQuotedReplacement ? .correctAdoptedQuotation : .correctFirstHand
            case .withdraw: .withdraw
            }
        }
        var level: MemoryClaimAssessmentLevel {
            kind == .uncertain || kind == .withdraw || isQuotedReplacement ? .uncertain : .confirmed
        }
        var basis: String {
            if isQuotedReplacement {
                return "The user explicitly adopted this quoted replacement; it has not been independently verified."
            }
            if form == .remember {
                return "The user asked to remember this statement; it has not been independently verified."
            }
            if form == .formerResidence {
                return "The user stated they no longer live at this place; the earlier residence claim is withdrawn."
            }
            if form == .forget {
                return "The user asked to stop using this memory; private history remains."
            }
            switch kind {
            case .confirm, .correct: return "The user explicitly attested this from first-hand knowledge; the assessment remains fallible."
            case .uncertain: return "The user explicitly asked to retain this as uncertain."
            case .withdraw: return "The user explicitly withdrew this memory; private history remains."
            }
        }
        var reason: String { basis }
        init(text: String) throws {
            guard text.utf8.count <= 8_192, !text.contains("\0") else {
                throw MemoryEvidenceVerifierError.unsupportedIntent
            }
            let prefixes: [(String, Kind, Form)] = [
                ("I confirm from first-hand knowledge: ", .confirm, .explicit),
                ("Remember as uncertain: ", .uncertain, .explicit),
                ("Correct from first-hand knowledge to: ", .correct, .explicit),
                ("Replace it with this: ", .correct, .adoptedQuotation),
                ("Replace ", .correct, .namedQuotedReplacement),
                ("Withdraw this memory: ", .withdraw, .explicit),
                ("Remember that ", .uncertain, .remember),
                ("Please forget that ", .withdraw, .forget),
                ("Forget that ", .withdraw, .forget),
                ("I no longer live in ", .withdraw, .formerResidence)
            ]
            guard let match = prefixes.first(where: { text.hasPrefix($0.0) }) else {
                throw MemoryEvidenceVerifierError.unsupportedIntent
            }
            var remainder = String(text.dropFirst(match.0.count))
            var target: String?
            guard !remainder.isEmpty, !remainder.contains("\n"), !remainder.contains("\r"),
                  !remainder.contains("?"), !remainder.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MemoryEvidenceVerifierError.ambiguousIntent
            }
            if match.2 == .adoptedQuotation {
                remainder = try Self.unquote(remainder)
            } else if match.2 == .namedQuotedReplacement {
                let separator: String
                if remainder.hasPrefix("\"") && remainder.hasSuffix("\"") { separator = "\" with \"" }
                else if remainder.hasPrefix("“") && remainder.hasSuffix("”") { separator = "” with “" }
                else { throw MemoryEvidenceVerifierError.ambiguousIntent }
                let parts = String(remainder.dropFirst().dropLast()).components(separatedBy: separator)
                guard parts.count == 2 else { throw MemoryEvidenceVerifierError.ambiguousIntent }
                try Self.validateQuotedBody(parts[0]); try Self.validateQuotedBody(parts[1])
                target = parts[0]; remainder = parts[1]
            }
            // This single bounded transformation withdraws the exact prior
            // residence assertion. It never infers a replacement residence.
            self.body = match.2 == .formerResidence ? "I live in " + remainder : remainder
            self.targetBody = target
            self.kind = match.1; self.form = match.2
        }
        private static func unquote(_ text: String) throws -> String {
            guard (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("“") && text.hasSuffix("”")),
                  text.count >= 2 else {
                    throw MemoryEvidenceVerifierError.ambiguousIntent
            }
            let body = String(text.dropFirst().dropLast())
            try validateQuotedBody(body)
            return body
        }
        private static func validateQuotedBody(_ body: String) throws {
            guard !body.isEmpty, !body.trimmingCharacters(in: .whitespaces).isEmpty,
                  !body.contains("\""), !body.contains("“"), !body.contains("”") else {
                throw MemoryEvidenceVerifierError.ambiguousIntent
            }
        }
    }
}
