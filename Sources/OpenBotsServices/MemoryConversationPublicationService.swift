import Foundation
import OpenBotsDomain

public enum MemoryConversationPublicationError: Error, Equatable, Sendable {
    case invalidCandidate, boundsExceeded, unexpectedIntent, unadmittedReference
    case sourceUnavailable, staleReference, scopeDenied, unknownLineage, cyclicLineage
    case policyDenied, invalidReceipt, publicationChanged
}

/// This injected host boundary must resolve storage and verifier receipts, never
/// decode provider fields into authority. Missing lineage is explicitly unknown.
public protocol MemoryConversationPublicationResolving: Sendable {
    func resolveClaim(_ reference: MemoryClaimReference, context: MemoryPublicationContext) async throws -> MemoryPublicationClaimSnapshot?
    func resolveReceipt(_ id: UUID, context: MemoryPublicationContext) async throws -> MemoryPublicationReceipt?
    /// Freshly check every head, source/evidence stamp, scope and lineage binding.
    /// A caller still needs an atomic admission check when it saves/uses the result.
    func revalidate(_ receipt: MemoryPublicationReceipt, context: MemoryPublicationContext) async throws -> Bool
}

/// A local publication foundation. It launches nothing and writes nothing. Only
/// complete app-rendered plain-text units escape; provider prose has no output path.
public struct MemoryConversationPublicationService: Sendable {
    public static let rendererPolicyVersion: UInt16 = 1
    private let resolver: any MemoryConversationPublicationResolving

    public init(resolver: any MemoryConversationPublicationResolving) { self.resolver = resolver }

    public func publish(_ candidate: MemoryPublicationCandidate,
                        context: MemoryPublicationContext) async throws -> MemoryConversationPublication {
        let result = try await materialize(candidate, context: context, id: UUID(), createdAt: context.now)
        guard try await resolver.revalidate(result.receipt, context: context) else {
            throw MemoryConversationPublicationError.publicationChanged
        }
        return result
    }

    /// Reconstruct from closed inputs as well as checking hashes. A caller cannot
    /// substitute arbitrary prose and merely recompute the receipt's text digest.
    public func revalidate(_ publication: MemoryConversationPublication,
                           context: MemoryPublicationContext) async throws -> Bool {
        let receipt = publication.receipt
        guard receipt.policyVersion == Self.rendererPolicyVersion,
              receipt.runID == context.runID, receipt.messageID == context.messageID,
              receipt.teammateID == context.teammateID, receipt.selectedProjectID == context.selectedProjectID,
              receipt.intent == context.intent,
              receipt.omittedUnitCount == publication.omittedUnitCount,
              (0...MemoryPublicationLimits.units).contains(receipt.omittedUnitCount),
              receipt.renderedTextDigest == MemoryClaimDigests.bytes(Data(publication.text.utf8)) else { return false }
        let rebuilt = try await materialize(.init(units: receipt.units), context: context,
                                            id: receipt.id, createdAt: receipt.createdAt,
                                            carriedOmissions: receipt.omittedUnitCount)
        guard rebuilt == publication else { return false }
        return try await resolver.revalidate(receipt, context: context)
    }

    private func materialize(_ candidate: MemoryPublicationCandidate, context: MemoryPublicationContext,
                             id: UUID, createdAt: Date, carriedOmissions: Int = 0) async throws -> MemoryConversationPublication {
        try Self.validate(candidate, context: context)
        if let limitation = context.explanationLimitation {
            guard carriedOmissions == 0 else { throw MemoryConversationPublicationError.invalidReceipt }
            return makePublication(units: [limitation.text],
                candidate: candidate, context: context, id: id, createdAt: createdAt, dependencies: [],
                lineage: .independent, omitted: 0)
        }
        var accepted: [MemoryPublicationUnit] = []
        var omitted = carriedOmissions
        for unit in candidate.units {
            let relevant = unit.references.filter { context.relevantReferences.contains($0) }
            if relevant.isEmpty && !unit.references.isEmpty { omitted += 1; continue }
            // Never silently rewrite a grouped candidate by stripping one member.
            guard relevant.count == unit.references.count else { throw MemoryConversationPublicationError.policyDenied }
            accepted.append(unit)
        }
        var explainedReceipt: MemoryPublicationReceipt?
        if context.intent == .explanation, let explainedID = context.explainedReceiptID {
            guard let receipt = try await resolver.resolveReceipt(explainedID, context: context) else {
                throw MemoryConversationPublicationError.unknownLineage
            }
            try validateReceipt(receipt, expectedID: explainedID, context: context)
            let requested = accepted.flatMap(\.references)
            guard requested.allSatisfy({ ref in receipt.dependencies.contains { $0.reference == ref } }) else {
                throw MemoryConversationPublicationError.invalidReceipt
            }
            guard !requested.isEmpty || receipt.dependencies.isEmpty else {
                throw MemoryConversationPublicationError.invalidReceipt
            }
            explainedReceipt = receipt
        }
        // Context inclusion alone cannot explain a model's wording. This fixed
        // statement does not infer causality or expose an unavailable source.
        if context.intent == .explanation && explainedReceipt == nil {
            return makePublication(units: ["I don't have a recorded link explaining that wording, so I can't reliably say why it was used."],
                candidate: .init(units: []), context: context, id: id, createdAt: createdAt, dependencies: [],
                lineage: .independent, omitted: omitted)
        }

        let roots = accepted.flatMap(\.references).map(Node.claim)
            + (explainedReceipt.map { [Node.receipt($0.id)] } ?? [])
        let graph = try await resolveGraph(roots: roots, context: context)
        var rendered: [String] = []
        for unit in accepted {
            for reference in unit.references {
                guard let value = graph.claims[reference] else { throw MemoryConversationPublicationError.sourceUnavailable }
                let framing = try graph.framing(for: .claim(reference))
                if unit.kind == .clarification && framing != .unconfirmedPossibility && framing != .reconsideration {
                    throw MemoryConversationPublicationError.policyDenied
                }
                if unit.kind == .reconsideration && framing != .reconsideration {
                    throw MemoryConversationPublicationError.policyDenied
                }
                let text: String
                switch context.intent {
                case .reply: text = MemoryConversationPublicationRendering.statement(value.snapshot, framing: framing)
                case .explanation: text = MemoryConversationPublicationRendering.explanation(value.snapshot, framing: framing)
                case .overview, .historyOverview:
                    text = "• " + MemoryConversationPublicationRendering.overview(value.snapshot, framing: framing)
                }
                rendered.append(text)
            }
        }
        if context.intent == .overview || context.intent == .historyOverview {
            rendered.append(rendered.isEmpty
                ? "No relevant memory is available in this bounded view."
                : "This is a bounded view of the relevant memory available here, not a complete inventory.")
        }
        if context.intent == .explanation && rendered.isEmpty {
            guard graph.claims.isEmpty else { throw MemoryConversationPublicationError.invalidReceipt }
            rendered.append("That local reply has no recorded memory-claim dependencies. I can't infer any further reason for its wording.")
        }
        let dependencies = graph.claimOrder.compactMap { reference -> MemoryPublicationDependency? in
            guard let value = graph.claims[reference] else { return nil }
            return .init(reference: reference, scope: value.snapshot.scope,
                sourceStamps: value.snapshot.claim.provenance, evidenceStamps: value.snapshot.claim.assessment.evidence,
                decision: value.decision)
        }
        let receiptIDs = graph.receiptOrder
        let result = makePublication(units: rendered, candidate: .init(units: accepted), context: context, id: id,
            createdAt: createdAt, dependencies: dependencies,
            lineage: receiptIDs.isEmpty ? .independent : .derived(receiptIDs: receiptIDs), omitted: omitted)
        guard result.text.utf8.count <= MemoryPublicationLimits.renderedBytes else {
            throw MemoryConversationPublicationError.boundsExceeded
        }
        return result
    }

    private func makePublication(units: [String], candidate: MemoryPublicationCandidate,
                                 context: MemoryPublicationContext, id: UUID, createdAt: Date,
                                 dependencies: [MemoryPublicationDependency], lineage: MemoryPublicationLineage,
                                 omitted: Int) -> MemoryConversationPublication {
        let text = units.joined(separator: "\n\n")
        let receipt = MemoryPublicationReceipt(id: id, policyVersion: Self.rendererPolicyVersion,
            runID: context.runID, messageID: context.messageID, teammateID: context.teammateID,
            selectedProjectID: context.selectedProjectID, intent: context.intent,
            renderedTextDigest: MemoryClaimDigests.bytes(Data(text.utf8)), units: candidate.units,
            dependencies: dependencies, omittedUnitCount: omitted, lineage: lineage, createdAt: createdAt)
        return .init(completeUnits: units, receipt: receipt, omittedUnitCount: omitted)
    }

    private enum Node: Hashable { case claim(MemoryClaimReference), receipt(UUID) }
    private struct ResolvedClaim { let snapshot: MemoryPublicationClaimSnapshot; let decision: MemoryClaimUseDecision }
    private struct Graph {
        var edges: [Node: [Node]] = [:]
        var claims: [MemoryClaimReference: ResolvedClaim] = [:]
        var claimOrder: [MemoryClaimReference] = []
        var receiptOrder: [UUID] = []
        var receipts: [MemoryPublicationReceipt] = []

        func framing(for root: Node) throws -> MemoryClaimRequiredFraming {
            var active = Set<Node>(), complete = Set<Node>()
            var stack: [(Node, Bool)] = [(root, false)]
            var result = MemoryClaimRequiredFraming.none
            while let (node, leaving) = stack.popLast() {
                if leaving { active.remove(node); complete.insert(node); continue }
                if complete.contains(node) { continue }
                guard active.insert(node).inserted else { throw MemoryConversationPublicationError.cyclicLineage }
                guard let next = edges[node] else { throw MemoryConversationPublicationError.unknownLineage }
                if case let .claim(reference) = node, let value = claims[reference] {
                    result = MemoryConversationPublicationRendering.stronger(result, value.decision.requiredFraming)
                }
                stack.append((node, true))
                stack.append(contentsOf: next.reversed().map { ($0, false) })
            }
            return result
        }
    }

    private func resolveGraph(roots: [Node], context: MemoryPublicationContext) async throws -> Graph {
        var result = Graph()
        var pending = Array(roots.reversed())
        while let node = pending.popLast() {
            if result.edges[node] != nil { continue }
            let next: [Node]
            switch node {
            case let .claim(reference):
                guard result.claimOrder.count < MemoryPublicationLimits.dependencyReferences else {
                    throw MemoryConversationPublicationError.boundsExceeded
                }
                guard let snapshot = try await resolver.resolveClaim(reference, context: context) else {
                    throw MemoryConversationPublicationError.sourceUnavailable
                }
                guard snapshot.reference == reference, snapshot.useContext.currentReference == reference else {
                    throw MemoryConversationPublicationError.staleReference
                }
                try validateScope(snapshot, context: context)
                let decision = MemoryClaimUsePolicy.evaluate(claim: snapshot.claim, reference: reference,
                    scope: snapshot.scope, context: snapshot.useContext)
                guard decision.disposition != .deny else { throw MemoryConversationPublicationError.policyDenied }
                result.claims[reference] = .init(snapshot: snapshot, decision: decision)
                result.claimOrder.append(reference)
                next = try lineageNodes(snapshot.lineage)
            case let .receipt(receiptID):
                guard result.receiptOrder.count < MemoryPublicationLimits.ancestorReceipts else {
                    throw MemoryConversationPublicationError.boundsExceeded
                }
                guard let receipt = try await resolver.resolveReceipt(receiptID, context: context) else {
                    throw MemoryConversationPublicationError.unknownLineage
                }
                try validateReceipt(receipt, expectedID: receiptID, context: context)
                result.receiptOrder.append(receiptID)
                result.receipts.append(receipt)
                next = receipt.dependencies.map { .claim($0.reference) } + (try lineageNodes(receipt.lineage))
            }
            result.edges[node] = next
            pending.append(contentsOf: next.reversed())
        }
        // Traverse even receipt-only roots; cycles must not disappear just because
        // an explanation or overview happens to render no claim at its surface.
        for root in roots { _ = try result.framing(for: root) }
        for receipt in result.receipts {
            for dependency in receipt.dependencies {
                guard let current = result.claims[dependency.reference],
                      dependency.scope == current.snapshot.scope,
                      dependency.sourceStamps == current.snapshot.claim.provenance,
                      dependency.evidenceStamps == current.snapshot.claim.assessment.evidence else {
                    throw MemoryConversationPublicationError.invalidReceipt
                }
            }
        }
        return result
    }

    private func lineageNodes(_ lineage: MemoryPublicationLineage) throws -> [Node] {
        switch lineage {
        case .independent: return []
        case .unknown: throw MemoryConversationPublicationError.unknownLineage
        case let .derived(ids):
            guard !ids.isEmpty, ids.count <= MemoryPublicationLimits.ancestorReceipts,
                  Set(ids).count == ids.count else { throw MemoryConversationPublicationError.boundsExceeded }
            return ids.map(Node.receipt)
        }
    }

    private func validateScope(_ snapshot: MemoryPublicationClaimSnapshot, context: MemoryPublicationContext) throws {
        let use = snapshot.useContext
        guard use.teammateID == context.teammateID, use.selectedProjectID == context.selectedProjectID,
              use.now == context.now,
              use.purpose == (context.intent == .historyOverview ? .ownerInspection : .conversation) else {
            throw MemoryConversationPublicationError.scopeDenied
        }
        switch snapshot.scope {
        case .user: throw MemoryConversationPublicationError.scopeDenied
        case let .teammate(id):
            guard id == context.teammateID else { throw MemoryConversationPublicationError.scopeDenied }
        case let .project(id):
            guard id == context.selectedProjectID, use.activeProjectMemberships.contains(id) else {
                throw MemoryConversationPublicationError.scopeDenied
            }
        }
    }

    private func validateReceipt(_ receipt: MemoryPublicationReceipt, expectedID: UUID,
                                 context: MemoryPublicationContext) throws {
        guard receipt.id == expectedID, receipt.policyVersion == Self.rendererPolicyVersion,
              receipt.teammateID == context.teammateID, receipt.selectedProjectID == context.selectedProjectID,
              receipt.intent != .historyOverview || context.intent == .historyOverview,
              receipt.dependencies.count <= MemoryPublicationLimits.dependencyReferences,
              receipt.units.count <= MemoryPublicationLimits.units,
              (0...MemoryPublicationLimits.units).contains(receipt.omittedUnitCount),
              Set(receipt.dependencies.map(\.reference)).count == receipt.dependencies.count,
              receipt.createdAt <= context.now, receipt.createdAt.timeIntervalSince1970.isFinite,
              Self.validDigest(receipt.renderedTextDigest),
              receipt.units.flatMap(\.references).allSatisfy({ ref in receipt.dependencies.contains { $0.reference == ref } }) else {
            throw MemoryConversationPublicationError.invalidReceipt
        }
    }

    private static func validate(_ candidate: MemoryPublicationCandidate, context: MemoryPublicationContext) throws {
        guard candidate.version == 1, candidate.units.count <= MemoryPublicationLimits.units,
              context.now.timeIntervalSince1970.isFinite,
              context.admittedReferences.count <= MemoryPublicationLimits.dependencyReferences,
              Set(context.admittedReferences).count == context.admittedReferences.count,
              Set(context.relevantReferences).count == context.relevantReferences.count,
              context.relevantReferences.allSatisfy({ context.admittedReferences.contains($0) }) else {
            throw MemoryConversationPublicationError.invalidCandidate
        }
        let all = candidate.units.flatMap(\.references)
        guard Set(all).count == all.count else { throw MemoryConversationPublicationError.invalidCandidate }
        if let limitation = context.explanationLimitation {
            guard context.intent == .explanation, context.admittedReferences.isEmpty,
                  context.relevantReferences.isEmpty, context.explainedReceiptID == nil,
                  candidate.units == [MemoryConversationPublicationRendering.limitationUnit(limitation)] else {
                throw MemoryConversationPublicationError.unexpectedIntent
            }
            return
        }
        for unit in candidate.units {
            guard unit.references.count <= MemoryPublicationLimits.referencesPerUnit,
                  !unit.references.isEmpty || unit.kind == .explanation,
                  unit.references.allSatisfy({ context.admittedReferences.contains($0) }) else {
                throw MemoryConversationPublicationError.unadmittedReference
            }
            let allowed: Bool
            switch (context.intent, unit.kind) {
            case (.reply, .claim), (.reply, .clarification), (.reply, .reconsideration): allowed = unit.references.count == 1
            case (.explanation, .explanation): allowed = true
            case (.overview, .overview), (.historyOverview, .overview): allowed = true
            default: allowed = false
            }
            guard allowed else { throw MemoryConversationPublicationError.unexpectedIntent }
        }
    }

    static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
