import Foundation

/// @-name completion for the composer. Lives in the kit so it is testable —
/// the first version was View-private and its "leading @ only" rule shipped a
/// live gap: "hey once @annoyinglibrarian…" (mid-sentence mention, exactly how
/// Lorenzo types) got no suggestions at all.
public enum Mentions {
    /// The fragment being typed: the draft's trailing token when that token
    /// starts with "@" at a word boundary. Returns nil otherwise — including
    /// for "a@b" (the @ is not token-initial, e.g. an email address) and for
    /// a bare "@" (his spec: suggestions appear after @ AND a letter).
    public static func activeFragment(in draft: String) -> String? {
        guard let atIndex = draft.lastIndex(of: "@") else { return nil }
        // Token-initial: "@" at the start of the draft or after whitespace.
        if atIndex > draft.startIndex {
            let before = draft[draft.index(before: atIndex)]
            guard before.isWhitespace || before.isNewline else { return nil }
        }
        let fragment = String(draft[draft.index(after: atIndex)...])
        guard !fragment.isEmpty,
              !fragment.contains(where: { $0.isWhitespace || $0.isNewline })
        else { return nil }
        return fragment.lowercased()
    }

    /// Agents whose name completes the fragment being typed. Excludes the
    /// thread's own agent (@self is just prose) and an exact match — when the
    /// name is already complete, Return must SEND, not rewrite the draft.
    /// DISPLAY names match too (his ask 2026-08-13: "@Bruno the Writer" should
    /// work like a name) — completion still inserts the @handle, because the
    /// handle is the address relays resolve.
    public static func suggestions(draft: String, agents: [Agent], thread: String) -> [Agent] {
        guard let fragment = activeFragment(in: draft) else { return [] }
        return agents.filter {
            guard $0.name != thread, $0.name != fragment else { return false }
            return $0.name.hasPrefix(fragment)
                || $0.display.lowercased().hasPrefix(fragment)
        }
    }

    /// Resolves "@target question" to (agent, question) — the in-app relay
    /// command. Handles resolve as a single token; DISPLAY names resolve too
    /// (spaces included), longest-first so "Bruno the Writer" isn't shadowed
    /// by an agent displayed as "Bruno". Lives in the kit so it is TESTED —
    /// the app's parseRelay delegates here.
    public static func resolveRelay(text: String, agents: [Agent]) -> (target: Agent, question: String)? {
        guard text.hasPrefix("@") else { return nil }
        let body = String(text.dropFirst())
        // LONGEST match wins across both namespaces: "Bruno the Writer" is
        // usually prefixed by the handle word ("bruno …"), so handle-first
        // would mis-split "@Bruno the Writer go" into a question starting
        // "the Writer go". Ties go to the handle (the canonical address).
        var best: (target: Agent, question: String, span: Int)?
        if let space = body.firstIndex(of: " ") {
            let handle = String(body[..<space]).lowercased()
            let question = String(body[body.index(after: space)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !question.isEmpty, let target = agents.first(where: { $0.name == handle }) {
                best = (target, question, handle.count)
            }
        }
        let lower = body.lowercased()
        for agent in agents {
            let d = agent.display.lowercased()
            guard lower.hasPrefix(d + " ") else { continue }
            let question = String(body.dropFirst(d.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { continue }
            if best == nil || d.count > best!.span {
                best = (agent, question, d.count)
            }
        }
        return best.map { ($0.target, $0.question) }
    }

    /// True when the fragment being typed starts the draft — i.e. completing
    /// it produces a RELAY, not a plain-text mention. The composer labels the
    /// chips differently (reviewer #5: a mid-sentence chip must not promise a
    /// relay the send path won't perform).
    public static func fragmentIsLeading(in draft: String) -> Bool {
        draft.lastIndex(of: "@") == draft.startIndex
    }

    /// Replaces the trailing @fragment with the full name plus a space,
    /// preserving everything typed before it. `ifFragment` guards against a
    /// stale click (reviewer #5: the AppKit field editor can lag the SwiftUI
    /// binding under re-render load — a chip built for "@e" must never clobber
    /// a draft that has since moved on).
    public static func complete(draft: String, with agent: Agent,
                                ifFragment expected: String? = nil) -> String {
        if let expected, activeFragment(in: draft) != expected { return draft }
        guard let atIndex = draft.lastIndex(of: "@") else { return draft }
        return String(draft[..<atIndex]) + "@" + agent.name + " "
    }
}
