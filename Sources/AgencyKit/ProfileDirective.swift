import Foundation

/// The onboarding interview's output (his design 2026-08-13: click "+", a
/// neutral teammate appears and INTERVIEWS Lorenzo in chat about what it's
/// for — like Claude asking clarifying questions — and its own answers become
/// its profile).
///
/// Same shape as RelayDirective, for the same reason: the agent can't write
/// the roster, so it ends its final turn with a structured block and the APP
/// applies it. Everything stays inspectable and app-authored.
///
///     PROFILE name: Chancelor Paperplane
///     PROFILE title: Correspondence
///     PROFILE description: Handles the agency inbox and calendar
///     PROFILE instructions: Draft, never send without asking.
///     PROFILE work: everyday
public struct ProfileDirective: Equatable {
    public var displayName: String?
    /// The teammate's own avatar pick (his ask 2026-08-13: chosen
    /// automatically, not left as the neutral placeholder).
    public var emoji: String?
    public var title: String?
    public var description: String?
    public var instructions: String?
    public var work: AgentStore.WorkKind?
    /// Connector ids the interview believes the job needs. PROPOSED only —
    /// the app never grants on an agent's say-so; Lorenzo taps to confirm.
    public var proposedConnectors: [String] = []

    public var isEmpty: Bool {
        displayName == nil && title == nil && description == nil
            && instructions == nil && work == nil && emoji == nil
            && proposedConnectors.isEmpty
    }

    /// Parses every `PROFILE <field>: value` line in a reply. Anchored at line
    /// start after trimming, uppercase keyword, and lines inside ``` fences are
    /// SKIPPED — the same rules RelayDirective learned the hard way (an agent
    /// explaining the format in a code block used to fire a real relay).
    public static func parse(_ reply: String) -> ProfileDirective {
        var out = ProfileDirective()
        var inFence = false
        for line in reply.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence, trimmed.hasPrefix("PROFILE ") else { continue }
            let rest = trimmed.dropFirst("PROFILE ".count)
            guard let colon = rest.firstIndex(of: ":") else { continue }
            let key = rest[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(rest[rest.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "name":         out.displayName = value
            case "emoji":
                // One glyph, not a sentence — a model that writes "a book 📚"
                // must not put that in the sidebar.
                let first = value.split(separator: " ").first.map(String.init) ?? value
                out.emoji = String(first.prefix(4))
            case "title":        out.title = value
            case "description":  out.description = value
            case "instructions": out.instructions = String(value.prefix(AgentStore.maxInstructions))
            case "needs":
                out.proposedConnectors = value.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { Connector.byID($0) != nil }
            case "work":
                out.work = AgentStore.WorkKind.allCases.first {
                    $0.rawValue.lowercased() == value.lowercased().replacingOccurrences(of: " ", with: "")
                        || value.lowercased().hasPrefix($0.rawValue.prefix(5).lowercased())
                }
            default: break
            }
        }
        return out
    }

    /// The reply with its PROFILE lines removed — what Lorenzo actually reads.
    /// The block is bookkeeping, not conversation.
    public static func strip(_ reply: String) -> String {
        var inFence = false
        return reply.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inFence.toggle(); return true }
            return inFence || !t.hasPrefix("PROFILE ")
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}


/// The interview's answer CARDS (his design 2026-08-13: "same UI and UX as in
/// the Claude ai app"). A question arrives with a few broad categories to tap,
/// plus — always, appended by the app, never by the agent — a "something else"
/// card and the manual escape hatch.
///
///     OPTION: Research and analysis
///     OPTION: Writing and drafting
public enum InterviewOptions {
    /// Text the app appends to every question, so the two escapes always
    /// exist even if the agent forgets them.
    public static let somethingElse = "Something else — I'll type it"
    public static let manual = "Configure manually"

    public static func parse(_ reply: String) -> [String] {
        var out: [String] = []
        var inFence = false
        for line in reply.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence, t.hasPrefix("OPTION:") else { continue }
            let value = String(t.dropFirst("OPTION:".count)).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, !out.contains(value) { out.append(value) }
        }
        return out
    }

    public static func strip(_ reply: String) -> String {
        var inFence = false
        return reply.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inFence.toggle(); return true }
            return inFence || !t.hasPrefix("OPTION:")
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
