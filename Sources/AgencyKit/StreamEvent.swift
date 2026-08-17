import Foundation

/// Parsed `rate_limit_event` payload. Example payload shape:
/// {"rate_limit_info":{"status":"allowed_warning","resetsAt":1755000000,
///  "rateLimitType":"seven_day","utilization":0.5,"isUsingOverage":false}}
/// The CLI emits one of these on EVERY message — the status is a standing
/// account state, not a per-message alarm, so consumers must dedupe.
public struct RateLimitInfo: Equatable {
    public let status: String        // "allowed" | "allowed_warning" | "rejected"
    public let kind: String          // e.g. "seven_day", "five_hour"
    public let utilization: Double?  // 0.0–1.0
    public let resetsAt: Int?        // unix seconds

    public init(status: String, kind: String, utilization: Double?, resetsAt: Int?) {
        self.status = status; self.kind = kind
        self.utilization = utilization; self.resetsAt = resetsAt
    }

    public var isWarning: Bool { status != "allowed" }
    /// Identity of the underlying account state: two events with the same key
    /// are the SAME warning, not news.
    public var dedupeKey: String { "\(status)|\(kind)|\(resetsAt ?? 0)" }

    private static let resetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    /// e.g. "50% of the seven-day limit used — resets Aug 12, 12:00"
    public var humanSummary: String {
        var parts: [String] = []
        let window = kind.replacingOccurrences(of: "_", with: "-")
        if let u = utilization {
            parts.append("\(Int((u * 100).rounded()))% of the \(window) limit used")
        } else {
            // Plain words, not the wire token (reviewer #5 minor: bubbles were
            // showing "allowed_warning" verbatim).
            let word = status == "rejected" ? "limit reached" : "usage running high"
            parts.append("\(window) window: \(word)")
        }
        if let r = resetsAt {
            parts.append("resets \(Self.resetFormatter.string(from: Date(timeIntervalSince1970: Double(r))))")
        }
        return parts.joined(separator: " — ")
    }
}

/// One announcement per distinct warning state, shared by every consumer of
/// stream events (direct sends AND relays — they must not each re-announce
/// the same standing warning). The CLI emits a rate_limit_event on every
/// message; only a CHANGE in the underlying state is news.
public final class RateLimitGate {
    private let lock = NSLock()
    /// Per WINDOW (five_hour / seven_day / …), not one slot (reviewer #5
    /// Important 6: the CLI reports whichever window currently binds, so a
    /// routine five_hour "allowed" was wiping the standing seven_day warning
    /// and re-announcing it on the next event).
    private var lastKey: [String: String] = [:]

    public init() {}

    public func shouldAnnounce(_ info: RateLimitInfo) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard info.isWarning else {
            lastKey[info.kind] = nil   // THIS window cleared — its next warning is news
            return false
        }
        guard info.dedupeKey != lastKey[info.kind] else { return false }
        lastKey[info.kind] = info.dedupeKey
        return true
    }
}

public enum StreamEvent: Equatable {
    case sessionStarted(String)
    case textDelta(String)
    /// Carries the actual thinking text (his ask 2026-08-13: "I should be
    /// able to see MORE of the thinking process") — rendered as a transient
    /// dimmed pane while the run works, never persisted.
    case thinkingDelta(String)
    /// A tool call inside the agentic loop ("Read vault/x.md") — the working
    /// ticker for long runs. Transient, never persisted.
    case toolActivity(String)
    /// A new assistant message began inside the agentic loop. The streaming
    /// preview resets here so only the CURRENT message shows — Lorenzo does not
    /// want the accumulated tool-use narration ("thinking process") on screen.
    case messageBoundary
    case resultText(String, sessionID: String)
    case rateLimit(RateLimitInfo)
    /// The run finished with an error instead of a result (e.g. subtype
    /// "error_during_execution"): carries the CLI's own error text so the UI
    /// never shows an empty bubble in its place.
    case runError(String)
    /// Synthetic (never parsed): SessionRunner emits it when a stale session id
    /// was dropped and the message retried on a fresh session. Carries the
    /// reason so the user learns WHY, not just that it happened.
    case sessionRolledOver(reason: String)
    /// Synthetic (never parsed): the app-side vault diff after a run found a
    /// SUSPICIOUS write — a note whose byline names someone other than the agent
    /// that wrote it, or an overwrite of another teammate's note. Carries a
    /// human line for the thread so Lorenzo sees it as it happens.
    case vaultProvenanceAlert(String)
    /// The egress fence refused a CONNECT (spec 2026-08-13): a fenced agent's
    /// process tried a non-allowlisted host — or an odd PORT on an allowed one
    /// (review M8: without the port, a 443-rule denial on api.anthropic.com
    /// reads like the fence malfunctioning). Visible, never a silent failure.
    case egressDenied(host: String, port: UInt16)
    /// This run has been waiting >10s on the per-agent session lock (another
    /// run of the SAME teammate holds it — app + CLI, or a stuck child).
    /// Item-6 debt: the spinner alone looked like an unexplained stall.
    case lockWaiting
    case ignored

    public static func parse(line: String) -> StreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String
        else { return .ignored }

        switch type {
        case "system":
            // Only the init event names the session; later system events (compact
            // boundaries etc.) may carry a session_id too and must not re-trigger.
            if obj["subtype"] as? String == "init",
               let sid = obj["session_id"] as? String { return .sessionStarted(sid) }
            return .ignored
        case "stream_event":
            guard let event = obj["event"] as? [String: Any],
                  let etype = event["type"] as? String else { return .ignored }
            if etype == "message_start" { return .messageBoundary }
            guard etype == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  let dtype = delta["type"] as? String else { return .ignored }
            if dtype == "text_delta", let text = delta["text"] as? String { return .textDelta(text) }
            if dtype == "thinking_delta" {
                return .thinkingDelta(delta["thinking"] as? String ?? "")
            }
            return .ignored
        case "assistant":
            // Full assistant messages carry tool_use blocks — the "what is it
            // DOING" signal for the working ticker. One event per message:
            // the first tool call names the activity.
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return .ignored }
            for block in content where block["type"] as? String == "tool_use" {
                guard let tool = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                // The most human-meaningful argument, tool by tool. Kept as
                // statements, not one ?? chain — newer Swift compilers time
                // out type-checking the chained casts + .map closure (CI).
                func str(_ key: String) -> String? { input[key] as? String }
                var detail = str("file_path") ?? str("path")
                if detail == nil, let pattern = str("pattern") { detail = "\"\(pattern)\"" }
                detail = detail ?? str("command") ?? str("url") ?? str("query")
                let detailText = detail ?? ""
                let clipped = detailText.count > 80 ? String(detailText.prefix(80)) + "…" : detailText
                return .toolActivity(clipped.isEmpty ? tool : "\(tool) \(clipped)")
            }
            return .ignored
        case "result":
            if let result = obj["result"] as? String,
               let sid = obj["session_id"] as? String {
                return .resultText(result, sessionID: sid)
            }
            // Error results carry no "result" string — surface them instead of
            // ignoring them into an empty bubble (real capture: subtype
            // "error_during_execution", is_error: true, errors: [...]).
            if obj["is_error"] as? Bool == true || obj["errors"] != nil {
                let errors = (obj["errors"] as? [String])?.joined(separator: "; ")
                let subtype = obj["subtype"] as? String
                return .runError(errors ?? subtype ?? "run failed")
            }
            return .ignored
        case "rate_limit_event":
            // Structured, not substring-matched (debt: the old text filter fired
            // a bubble on every message once the account entered a warning state).
            guard let info = obj["rate_limit_info"] as? [String: Any],
                  let status = info["status"] as? String else { return .ignored }
            return .rateLimit(RateLimitInfo(
                status: status,
                kind: info["rateLimitType"] as? String ?? "unknown",
                utilization: info["utilization"] as? Double,
                resetsAt: info["resetsAt"] as? Int))
        default:
            return .ignored
        }
    }
}
