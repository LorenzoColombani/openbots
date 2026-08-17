import Foundation

/// The agent-initiated half of the relay (root cause of the 2026-08-13
/// failures: agents had NO sanctioned pass-on primitive — the app's relay only
/// fired on a leading-@ message typed by Lorenzo, so alfredo improvised with
/// SendMessage and failed, and nina's improvisation misrouted). An agent ends
/// its reply with `RELAY @name: message`; the APP executes it through the
/// broker — visible legs, queueing, one live process per session.
public struct RelayDirective: Equatable {
    public let target: String    // lowercase teammate name
    public let message: String

    /// Every `RELAY @name: message` directive in a reply. Anchored at line
    /// start (after trimming) so prose ABOUT relaying never triggers; the
    /// keyword is uppercase on purpose — it cannot appear by accident
    /// mid-sentence. A directive OUTSIDE any fence opens a block; lines inside
    /// ``` fences never open one (reviewer #5 Critical 2: an agent explaining
    /// the format in a code block was firing a real relay — the exact
    /// unasked-message class the directive exists to prevent).
    ///
    /// A directive carries its WHOLE block, not just its first line (live
    /// failure 2026-08-13): an agent handed a courier teammate an outbound
    /// message to pass on, shaped as
    ///
    ///     RELAY @teammate3: <one line of context> … Exact text:
    ///
    ///     "<the multi-line message to be sent>"
    ///
    /// and the old line-based parser delivered only `… Exact text:`. Hermes
    /// received an instruction whose payload had been silently deleted. It
    /// happened to end on a colon so Hermes caught it and asked; a truncation
    /// that lands on a plausible-looking sentence would have been ACTED ON.
    /// Nothing warned either side, which is what made it dangerous.
    ///
    /// The block ends at the next `RELAY @` (outside a fence), at an explicit
    /// `END RELAY` line, or at the end of the reply — so stacked relays still
    /// address different teammates, and a body may contain fenced code.
    public static func parse(_ reply: String) -> [RelayDirective] {
        var directives: [RelayDirective] = []
        var inFence = false
        var target: String?
        var body: [String] = []

        func close() {
            defer { target = nil; body = [] }
            guard let t = target else { return }
            let message = body.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }
            directives.append(RelayDirective(target: t, message: message))
        }

        for line in reply.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                // A fence INSIDE a relay body is content (agents quote drafts
                // in code blocks); outside one it is still inert.
                if target != nil { body.append(line) }
                continue
            }
            if !inFence, trimmed.hasPrefix("RELAY @") {
                // A line that ANNOUNCES a relay always ends the previous block,
                // even when its own header is malformed. Review finding I-6:
                // appending it to the open body delivered the SECOND teammate's
                // message into the FIRST teammate's inbox, verbatim and
                // unannounced, while the intended recipient got nothing —
                // strictly worse than the old parser, which ignored the line.
                // Dropping it loses one message loudly (the agent sees no
                // reply); absorbing it misdelivers one silently.
                close()
                if let head = header(trimmed) {
                    target = head.target
                    body = [head.rest]
                }
                continue
            }
            if !inFence, target != nil, trimmed == "END RELAY" {
                close()
                continue
            }
            if target != nil { body.append(line) }
        }
        close()
        return directives
    }

    /// Splits `RELAY @name: rest-of-line`. Returns nil when the name is missing
    /// or not a legal handle — same alphabet as `AgentStore.isValidName`, since
    /// hyphen/underscore names were once silently unreachable (reviewer #5
    /// Important 3). A nil head is treated as ordinary prose, so a malformed
    /// line never opens a block and never truncates one already open.
    private static func header(_ trimmed: String) -> (target: String, rest: String)? {
        let afterAt = trimmed.dropFirst("RELAY @".count)
        guard let colon = afterAt.firstIndex(of: ":") else { return nil }
        let target = afterAt[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty,
              target.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return (target, String(afterAt[afterAt.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces))
    }
}
