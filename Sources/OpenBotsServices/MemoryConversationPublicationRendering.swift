import Foundation
import OpenBotsDomain

enum MemoryConversationPublicationRendering {
    static func limitationUnit(_ limitation: MemoryExplanationLimitation) -> MemoryPublicationUnit {
        let kind: MemoryPublicationUnitKind = limitation == .sourcesUnavailable
            ? .explanationSourcesUnavailable : .explanationLineageUnverifiable
        return .init(kind: kind, references: [])
    }

    static func stronger(_ left: MemoryClaimRequiredFraming, _ right: MemoryClaimRequiredFraming) -> MemoryClaimRequiredFraming {
        let order: [MemoryClaimRequiredFraming] = [.none, .attributionAndHedge, .unconfirmedPossibility, .reconsideration, .historyOnly]
        return order.firstIndex(of: left)! >= order.firstIndex(of: right)! ? left : right
    }

    static func statement(_ snapshot: MemoryPublicationClaimSnapshot, framing: MemoryClaimRequiredFraming) -> String {
        let body = quote(snapshot.claim.body)
        let sentence: String
        switch framing {
        case .none: sentence = "I'll take \(body) into account here."
        case .attributionAndHedge: sentence = "\(attribution(snapshot)), \(body) seems plausible, but it may be wrong."
        case .unconfirmedPossibility: sentence = "I may have this wrong: \(body). Does that apply here?"
        case .reconsideration: sentence = "I need to reconsider \(body). Is that still applicable?"
        case .historyOnly: sentence = historicalState(snapshot.claim) + ": " + body + "."
        }
        return sentence + qualifications(snapshot.claim)
    }

    static func explanation(_ snapshot: MemoryPublicationClaimSnapshot, framing: MemoryClaimRequiredFraming) -> String {
        "That reply drew on \(quote(snapshot.claim.body)). \(sourceDescription(snapshot)) "
            + basis(snapshot.claim) + " " + assessment(framing) + qualifications(snapshot.claim)
    }

    static func overview(_ snapshot: MemoryPublicationClaimSnapshot, framing: MemoryClaimRequiredFraming) -> String {
        quote(snapshot.claim.body) + " — " + assessment(framing) + " "
            + (snapshot.claim.validity == .withdrawn ? "It was withdrawn from active use. " : "")
            + sourceDescription(snapshot) + " " + basis(snapshot.claim) + qualifications(snapshot.claim)
    }

    private static func attribution(_ snapshot: MemoryPublicationClaimSnapshot) -> String {
        let verified = snapshot.useContext.verifiedEvidence.filter { snapshot.claim.assessment.evidence.contains($0.reference) }
        if !verified.isEmpty && verified.allSatisfy({ $0.authority == .userAction && $0.reference.source.kind == .userMessage }) {
            return "From what you've told me"
        }
        if !verified.isEmpty && verified.allSatisfy({ $0.reference.source.kind == .appObservation }) {
            return "From the recorded observations"
        }
        return "Based on the recorded sources"
    }

    private static func sourceDescription(_ snapshot: MemoryPublicationClaimSnapshot) -> String {
        let sources = snapshot.claim.provenance
        guard !sources.isEmpty else { return "The original source is not recorded." }
        // This reports the retained source type, not a fabricated quotation,
        // inaccessible source identity, or the model's hidden reasoning.
        if sources.allSatisfy({ $0.kind == .userMessage }) {
            let checked = snapshot.useContext.verifiedEvidence.contains {
                $0.authority == .userAction && sources.contains($0.reference.source)
            }
            return checked ? "Its source is a checked user message." : "Its recorded source is a user message; that attribution has not been checked here."
        }
        if sources.contains(where: { $0.kind == .modelInference || $0.kind == .modelEcho }) {
            return "Its origin includes an inference or an earlier model response, not independent evidence by itself."
        }
        if sources.allSatisfy({ $0.kind == .appObservation }) { return "It comes from recorded app observations." }
        return "It comes from recorded sources; their presence alone does not establish the claim."
    }

    private static func basis(_ claim: MemoryClaim) -> String {
        claim.assessment.basis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No assessment basis is recorded."
            : "The recorded basis is \(quote(claim.assessment.basis))."
    }

    private static func assessment(_ framing: MemoryClaimRequiredFraming) -> String {
        switch framing {
        case .none: "Well supported for now, but still revisable."
        case .attributionAndHedge: "Tentative; it needs attribution and could be wrong."
        case .unconfirmedPossibility: "Not established; it is only a possibility."
        case .reconsideration: "Needs reconsideration before I rely on it."
        case .historyOnly: "Historical information, not current guidance."
        }
    }

    private static func historicalState(_ claim: MemoryClaim) -> String {
        claim.validity == .withdrawn ? "Previously recorded, now withdrawn" : "Previously recorded"
    }

    private static func qualifications(_ claim: MemoryClaim) -> String {
        var values: [String] = []
        if let conditions = claim.conditions { values.append("This applies only when \(quote(conditions)).") }
        if let from = claim.validFrom { values.append("It applies from \(timestamp(from)).") }
        if let until = claim.validUntil { values.append("It applies before \(timestamp(until)).") }
        return values.isEmpty ? "" : " " + values.joined(separator: " ")
    }

    private static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// Render untrusted source text literally inside one complete quoted unit.
    /// Escape line/control/quote boundaries; downstream must use plain text.
    private static func quote(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: escaped += "\\\""
            case 92: escaped += "\\\\"
            case 10: escaped += "\\n"
            case 13: escaped += "\\r"
            case 9: escaped += "\\t"
            case 0...31, 127...159, 0x2028...0x202E, 0x2066...0x2069:
                escaped += "\\u{" + String(scalar.value, radix: 16) + "}"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"" + escaped + "\""
    }
}
