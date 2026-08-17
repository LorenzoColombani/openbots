import Foundation

public struct Agent: Codable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String        // lowercase, folder-safe
    public var emoji: String
    public var role: String
    public var model: String?      // nil = session default
    public var sessionID: String?  // set after first message
    /// Fencing (his ruling): the tools this teammate may use. nil (old rosters)
    /// falls back to AgentStore.defaultAllowedTools at invocation time.
    public var allowedTools: [String]?
    /// Granted connector ids (subset of the app-wide enabled catalog).
    /// nil (old rosters) = none — sealed by default, his ruling.
    public var connectors: [String]?
    /// Shell access (Bash → grep/awk/ffmpeg/Homebrew tools). nil/false = sealed.
    /// Made grantable 2026-08-13 after a live failure: a sealed agent couldn't
    /// grep a prior project's transcripts at all — Grok Bot's agents could, because it
    /// gates shell instead of removing it.
    public var shell: Bool?
    /// Web access (WebSearch + WebFetch). nil/false = sealed. Made a GRANT
    /// 2026-08-13 (his call, security round): web is an EGRESS path — the URL a
    /// fetch/search sends out can carry vault data past the file fence, and no
    /// OS sandbox stops a server-side web tool. Off by default makes a sealed
    /// agent truly airtight; "web means web" is preserved by opting each agent in.
    public var web: Bool?
    /// Absolute path to a custom avatar image copied INTO the agent's own folder
    /// (agents/<name>/avatar.<ext>). nil (old rosters, or "use emoji") = fall back
    /// to `emoji`, which stays the always-there default — nothing ever renders blank.
    public var avatarPath: String?
    /// Display name shown in the UI and personas (item 6, his call: rename is
    /// DISPLAY-ONLY). `name` stays the immutable handle — folder, @relay
    /// address, session key — because renaming the folder orphans the claude
    /// session (= total memory loss). nil = capitalized handle.
    public var displayName: String?
    /// Short label for what this teammate IS (R5) — "Correspondence",
    /// "Research". `role` used to carry this, the job, and the model
    /// heuristic all at once.
    public var title: String?
    /// What this teammate DOES — the answer that drives the model choice.
    /// Structured, so the picker no longer keyword-matches a paragraph.
    public var primaryJob: String?
    /// "Get notified when this agent finishes or needs input" (his profile
    /// screenshot 2026-08-13). nil = ON — notifications are the default, and
    /// only fire when Agency isn't the frontmost app.
    public var notifications: Bool?
    /// False/nil until the onboarding interview has completed (his design
    /// 2026-08-13: a new teammate appears NEUTRAL and interviews Lorenzo about
    /// its own role). While false the persona runs in interview mode.
    public var onboarded: Bool?
    /// Lorenzo's own standing instructions for this teammate (structure audit
    /// R2). They live HERE, in data, because the persona file is regenerated
    /// from the template on every app launch — anything hand-written into a
    /// CLAUDE.md was silently wiped, contradicting v2-agent-management's
    /// "hand edits win". Rendered into the persona; capped at 4,000 chars
    /// (Grok Bot's documented cap, adopted).
    public var instructions: String?

    /// The name humans see. The handle stays the address.
    public var display: String {
        displayName ?? name.prefix(1).uppercased() + name.dropFirst()
    }

    public init(name: String, emoji: String, role: String, model: String?, sessionID: String?,
                allowedTools: [String]? = nil, connectors: [String]? = nil,
                shell: Bool? = nil, web: Bool? = nil, avatarPath: String? = nil,
                displayName: String? = nil, instructions: String? = nil,
                title: String? = nil, primaryJob: String? = nil,
                onboarded: Bool? = nil, notifications: Bool? = nil) {
        self.name = name; self.emoji = emoji; self.role = role
        self.model = model; self.sessionID = sessionID; self.allowedTools = allowedTools
        self.connectors = connectors; self.shell = shell; self.web = web
        self.avatarPath = avatarPath; self.displayName = displayName
        self.instructions = instructions
        self.title = title; self.primaryJob = primaryJob
        self.onboarded = onboarded; self.notifications = notifications
    }
}

/// A named team (vault pockets spec 2026-08-13): members share the
/// vault/teams/<name>/ pocket; non-members are Read-denied there (which blocks
/// writes too). Membership lives in the roster — one visible source of truth.
public struct Team: Codable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String        // folder-safe, validated like agent names
    public var members: [String]   // agent names
    /// Group-thread face (R3 2026-08-14). nil renders as 👥.
    public var emoji: String?
    public init(name: String, members: [String] = [], emoji: String? = nil) {
        self.name = name; self.members = members; self.emoji = emoji
    }
}

public struct Roster: Codable, Equatable {
    /// Bumped whenever the roster gains a field whose LOSS would unfence
    /// something (2 = teams · 3 = team emoji / group threads). saveRosterUnlocked
    /// stamps this and REFUSES to overwrite a roster stamped newer than the
    /// binary understands (pocket review I3): version skew must fail CLOSED —
    /// an old binary silently dropping `teams` (Codable drops unknown fields;
    /// it wiped web grants once) would world-open every team pocket with no
    /// error anywhere. A stale agency-cli hitting `rosterNewerSchema` after
    /// the 3-bump is that guard WORKING — rebuild the CLI, don't downgrade.
    public static let currentSchemaVersion = 3
    public var agents: [Agent]
    /// nil (pre-pocket rosters) = no teams.
    public var teams: [Team]?
    /// Stamped on every save; nil on pre-guard rosters (treated as version 1).
    public var schemaVersion: Int?
    public init(agents: [Agent] = [], teams: [Team]? = nil, schemaVersion: Int? = nil) {
        self.agents = agents; self.teams = teams; self.schemaVersion = schemaVersion
    }
}

public enum MessageKind: String, Codable, Equatable {
    case user, agent, relayOut, relayIn, system
    /// Reply produced by a FORKED copy of the agent's session (queued message
    /// run in parallel) — labeled distinctly because the main session never
    /// learns what the fork did.
    case subagent
}

public struct ChatMessage: Codable, Equatable, Identifiable {
    /// Stored identity, NOT derived from `ts` (review I3): two messages logged
    /// within the same millisecond used to share an id, and SwiftUI's ForEach
    /// silently renders duplicate-id rows as one. The id is deliberately kept
    /// out of CodingKeys — identity is per-load, the log stores only content.
    public var id = UUID()
    public var ts: Date
    public var author: String
    public var kind: MessageKind
    public var text: String

    private enum CodingKeys: String, CodingKey { case ts, author, kind, text }

    public init(ts: Date = Date(), author: String, kind: MessageKind, text: String) {
        self.ts = ts; self.author = author; self.kind = kind; self.text = text
    }

    /// Content equality — `id` is per-load identity and must not affect it
    /// (round-trip tests compare a message against its decoded copy).
    public static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.ts == rhs.ts && lhs.author == rhs.author && lhs.kind == rhs.kind && lhs.text == rhs.text
    }
}
