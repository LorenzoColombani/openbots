import Foundation

public enum RepositoryError: Error, Equatable, Sendable {
    case notFound(entity: String, id: String)
    case alreadyExists(entity: String, id: String)
    case optimisticLockFailed(entity: String, id: String)
    case sequenceConflict(conversationID: ConversationID, expected: Int64, actual: Int64)
    case protectionModeMismatch
    case unavailable(reason: String)
}

public protocol TeammateRepository: Sendable {
    func teammate(id: TeammateID) async throws -> Teammate?
    func listTeammates(includingArchived: Bool) async throws -> [Teammate]
    func insert(_ teammate: Teammate) async throws
    func update(_ teammate: Teammate, expectedProfileRevision: UInt64) async throws
}

public protocol ProjectRepository: Sendable {
    func project(id: ProjectID) async throws -> Project?
    func listProjects(includingArchived: Bool) async throws -> [Project]
    func insert(_ project: Project) async throws
    func update(_ project: Project) async throws
    func setMembership(_ membership: ProjectMembership) async throws
    func activeMemberIDs(projectID: ProjectID) async throws -> Set<TeammateID>
}

/// Creates one project and its initial teammate memberships as a single
/// durable aggregate. Callers must not reproduce this operation by inserting
/// the project and then issuing independent membership writes, because a
/// failure could otherwise publish a partially configured project.
public protocol ProjectProvisioningRepository: Sendable {
    func provisionProject(
        _ project: Project,
        initialMemberIDs: Set<TeammateID>
    ) async throws
}

public protocol TeamRepository: Sendable {
    func team(id: TeamID) async throws -> Team?
    func listTeams(includingArchived: Bool) async throws -> [Team]
    func insert(_ team: Team) async throws
    func update(_ team: Team) async throws
}

/// Creates one team, its memberships and its team conversation (members as
/// participants) as a single durable aggregate. Callers must not reproduce this
/// with `TeamRepository.insert` followed by `ConversationRepository.insert`.
public protocol TeamProvisioningRepository: Sendable {
    func provisionTeam(_ team: Team, conversation: Conversation, selectConversation: Bool) async throws
    /// Rewrites one existing team's name, lead and memberships together with
    /// its conversation title and participants, in one transaction.
    ///
    /// Memberships alone are not enough. A durable turn is authorised by an
    /// unrevoked `team_memberships` row *and* an unclosed
    /// `conversation_participants` row, so a member added through
    /// `TeamRepository.update` alone is routed to and then refused. Callers
    /// must not reproduce this aggregate with `TeamRepository.update`.
    ///
    /// `expectedUpdatedAt` is the team's `updatedAt` as the caller read it
    /// before deriving this edit, and the write applies only while the stored
    /// row still carries it. A roster is computed outside the write
    /// transaction, so without that check a second writer's added member is
    /// revoked, or its removed member resurrected, with no error to either
    /// caller. A row that has moved refuses with
    /// `RepositoryError.optimisticLockFailed`.
    func updateTeam(_ team: Team, conversation: Conversation, expectedUpdatedAt: Date) async throws
}

public protocol TeamConversationRepository: Sendable {
    /// The active conversation of kind `team` for this team, if one exists.
    func teamConversation(teamID: TeamID) async throws -> Conversation?
    /// Participants that have not left (`left_at IS NULL`) of any conversation.
    func activeParticipantIDs(conversationID: ConversationID) async throws -> Set<TeammateID>
}

/// Durable two-phase handoff delivery. Updates are
/// compare-and-set on the state the caller last saw.
public protocol HandoffRepository: Sendable {
    func insert(_ record: HandoffRecord) async throws
    func update(_ record: HandoffRecord, expectedState: HandoffState) async throws
    func record(id: HandoffID) async throws -> HandoffRecord?
    /// Newest first.
    func records(conversationID: ConversationID) async throws -> [HandoffRecord]
}

public protocol ConversationRepository: Sendable {
    func conversation(id: ConversationID) async throws -> Conversation?
    func conversations(for teammateID: TeammateID, includingArchived: Bool) async throws -> [Conversation]
    func insert(_ conversation: Conversation, participantIDs: Set<TeammateID>) async throws
    func update(_ conversation: Conversation) async throws
}

/// Creates the smallest durable chat aggregate in one repository transaction.
///
/// The optional greeting is deliberately named as a fixture at this boundary:
/// its human-visible content must disclose that no production runtime produced
/// it. The application service owns that wording; persistence validates the
/// stable identities and sequence before storing the supplied message exactly.
public protocol DirectChatProvisioningRepository: Sendable {
    func provisionDirectChat(
        teammate: Teammate,
        conversation: Conversation,
        fixtureGreeting: Message?,
        selectConversation: Bool
    ) async throws
    /// New Bot: the bot, its chat, its first question and its mark
    /// as waiting to set itself up, in one transaction, so a bot that asks what
    /// it is for is always one the setup tool is offered to.
    func provisionSelfSettingChat(
        teammate: Teammate,
        conversation: Conversation,
        question: Message,
        selectConversation: Bool
    ) async throws
}

public extension DirectChatProvisioningRepository {
    func provisionSelfSettingChat(teammate: Teammate, conversation: Conversation, question: Message,
                                  selectConversation: Bool) async throws {
        throw RepositoryError.unavailable(reason: "This store cannot make a bot that sets itself up.")
    }
}

/// Persists the provisional, chat-led teammate hiring flow. A hiring draft is
/// not a teammate and owns no capabilities. Confirmation is the only boundary
/// that may atomically create the supplied durable teammate/direct-chat graph.
public protocol HiringDraftRepository: Sendable {
    func latestHiringDraft() async throws -> HiringDraftSnapshot?

    @discardableResult
    func createHiringDraft(_ snapshot: HiringDraftSnapshot) async throws -> HiringDraftSnapshot

    @discardableResult
    func reviseHiringDraft(
        _ draft: HiringDraft,
        expectedRevision: UInt64,
        appending turns: [HiringTurn]
    ) async throws -> HiringDraftSnapshot

    func cancelHiringDraft(id: HiringDraftID, expectedRevision: UInt64) async throws

    func confirmHiringDraft(
        id: HiringDraftID,
        expectedRevision: UInt64,
        teammate: Teammate,
        conversation: Conversation,
        fixtureGreeting: Message?,
        selectConversation: Bool
    ) async throws
}

/// Persists only the current direct-chat navigation choice. This is separate
/// from teammate and conversation mutation so presentation models can restore
/// selection without receiving a database handle or a broad settings surface.
public protocol ChatSelectionRepository: Sendable {
    func selectedConversationID() async throws -> ConversationID?
    func setSelectedConversationID(_ conversationID: ConversationID?) async throws
}

public protocol MessageRepository: Sendable {
    func append(_ message: Message, expectedPreviousSequence: Int64) async throws
    func message(id: MessageID) async throws -> Message?
    func page(conversationID: ConversationID, request: PageRequest) async throws -> Page<Message>
    func updateDeliveryState(
        messageID: MessageID,
        from expectedState: MessageDeliveryState,
        to newState: MessageDeliveryState,
        updatedAt: Date
    ) async throws
}

public protocol MemoryRepository: Sendable {
    func authorityContract() async throws -> MemoryAuthorityContract
    func document(id: MemoryDocumentID) async throws -> MemoryDocument?
    func allDocuments() async throws -> [MemoryDocument]
    func documents(scope: MemoryScope) async throws -> [MemoryDocument]
    func insert(_ document: MemoryDocument) async throws
    func insertRevision(
        _ document: MemoryDocument,
        expectedPredecessorID: MemoryDocumentID?
    ) async throws
}

public extension MemoryRepository {
    func authorityContract() async throws -> MemoryAuthorityContract {
        .appOwnedMarkdownV1
    }

    func allDocuments() async throws -> [MemoryDocument] {
        throw RepositoryError.unavailable(
            reason: "This memory repository cannot enumerate every scope."
        )
    }

    func insertRevision(
        _ document: MemoryDocument,
        expectedPredecessorID: MemoryDocumentID?
    ) async throws {
        guard document.supersedes == expectedPredecessorID else {
            throw RepositoryError.optimisticLockFailed(
                entity: "memory predecessor",
                id: expectedPredecessorID?.persistedValue ?? "initial"
            )
        }
        try await insert(document)
    }
}

public protocol CapabilityGrantRepository: Sendable {
    func activeGrants(teammateID: TeammateID) async throws -> [CapabilityGrant]
    func insert(_ grant: CapabilityGrant) async throws
    func update(_ grant: CapabilityGrant) async throws
}

/// Bots waiting to set themselves up: each keeps the
/// placeholder name it was born with until its setup call lands. One
/// `app_metadata` row per waiting bot; nil clears it.
public protocol BotSelfSetupRepository: Sendable {
    func pendingSelfSetupName(teammateID: TeammateID) async throws -> String?
    func setPendingSelfSetup(teammateID: TeammateID, placeholderName: String?) async throws
}

/// The two web capabilities the app keeps switches for, spelled the way the
/// database stores them. A raw value never changes once a row carries it.
public enum AgenticWebSwitchCapability: String, CaseIterable, Codable, Hashable, Sendable {
    case webSearch
    case webFetch
    /// "Work on this Mac" (files and shell), kept in the same rows as the web
    /// switches: one app-wide master, one grant per bot.
    case work
    /// Hiring new bots from a reply, in the same rows: one app-wide master, one
    /// grant per bot.
    case hire
    /// Background throwaway workers: one-shot blank helpers,
    /// no sidebar seat, local files only unless fetchers are also granted.
    case workers
    /// Fetcher workers: workers that may use web search/fetch. Separate from
    /// the holder's own web grant; treated like a web door for poisoned pages.
    case fetchers
}

/// Every stored web switch, read in one query at launch: the app-wide
/// switches that are on, and for each bot the grants that are on. A switch
/// that is off has no entry. A bot that is archived keeps its entry; nothing
/// shows it while the bot is archived, and it is there again on restore.
public struct AgenticWebSwitchSnapshot: Equatable, Sendable {
    public var app: Set<AgenticWebSwitchCapability>
    public var bots: [TeammateID: Set<AgenticWebSwitchCapability>]

    public init(app: Set<AgenticWebSwitchCapability> = [], bots: [TeammateID: Set<AgenticWebSwitchCapability>] = [:]) {
        self.app = app
        self.bots = bots
    }
}

/// Keeps the app-wide web switches and each bot's own web grants between
/// launches: the web switches survive a relaunch. The sample-folder jobs switch is
/// deliberately absent; it stays session-local. These rows are not
/// `CapabilityGrant`s: a bot's web grant is one half of a two-switch rule and means
/// nothing without the app-wide half, so the pair lives together here rather than
/// in the authority table an executor reads as "what this teammate may do".
public protocol AgenticWebSwitchRepository: Sendable {
    func loadWebSwitches() async throws -> AgenticWebSwitchSnapshot
    func setAppWebSwitch(_ capability: AgenticWebSwitchCapability, enabled: Bool) async throws
    func setBotWebSwitch(_ capability: AgenticWebSwitchCapability, enabled: Bool, teammateID: TeammateID) async throws
}

/// One Claude session per bot and conversation, resumed turn after turn. The
/// id is the CLI's own; the dates say when the session began and when it last
/// answered.
public struct StoredClaudeSession: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let startedAt: Date
    public let lastUsedAt: Date
    /// The CLI refused to continue this session and what it kept of it could
    /// not be removed: the row stays only so those files can still be found
    /// (a row is never cleared while its files stay behind unfindable), and no
    /// turn asks for the session again. Absent in rows written before the mark
    /// existed, and absent means not refused.
    public let isRefused: Bool
    /// SHA-256 hex of the system prompt the session started with. The CLI
    /// ignores the prompt on `--resume`, so the first turn's prompt is the one
    /// the session keeps; a turn whose prompt would differ (a profile edit, a
    /// new voice, an app update's wording) starts a new session instead. Nil
    /// on a row written before the digest existed, which reads as different.
    public let systemPromptDigest: String?
    /// The sequence of the chat's last message when the session last answered.
    /// A continuing turn quotes nothing, so a message saved in the chat
    /// outside the session (a reply the app wrote itself) would never reach
    /// the bot; a chat whose last message is not this one starts a new session
    /// that quotes it. Nil on a row written before it existed, which reads as
    /// different.
    public let lastSequence: Int64?
    /// Whether the turn that started the session left any earlier message out
    /// of what it quoted. Its continuing turns quote nothing and repeat this in
    /// their "not included" notice. Nil on a row written before it
    /// existed: the turn's own window decides, as before.
    public let leftOutMessages: Bool?
    /// The session read the user's texts, or the user's Chrome, in some reply:
    /// what it read stays in the session, so every later reply that continues
    /// it keeps the fences a private read closes (the fence lasts the whole
    /// session, not the reply). Nil on a row written before it
    /// existed, and on a session that read neither.
    public let readTexts: Bool?
    public let readChrome: Bool?
    /// The same for the user's Mail, contacts, calendars, notes, Gmail or
    /// Drive: the first such connector's role name, nil when none.
    public let readPrivate: String?
    public init(sessionID: UUID, startedAt: Date, lastUsedAt: Date,
                isRefused: Bool = false, systemPromptDigest: String? = nil, lastSequence: Int64? = nil,
                leftOutMessages: Bool? = nil, readTexts: Bool? = nil, readChrome: Bool? = nil,
                readPrivate: String? = nil) {
        self.sessionID = sessionID; self.startedAt = startedAt; self.lastUsedAt = lastUsedAt
        self.isRefused = isRefused; self.systemPromptDigest = systemPromptDigest; self.lastSequence = lastSequence
        self.leftOutMessages = leftOutMessages
        self.readTexts = readTexts; self.readChrome = readChrome; self.readPrivate = readPrivate
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        lastUsedAt = try container.decode(Date.self, forKey: .lastUsedAt)
        isRefused = try container.decodeIfPresent(Bool.self, forKey: .isRefused) ?? false
        systemPromptDigest = try container.decodeIfPresent(String.self, forKey: .systemPromptDigest)
        lastSequence = try container.decodeIfPresent(Int64.self, forKey: .lastSequence)
        leftOutMessages = try container.decodeIfPresent(Bool.self, forKey: .leftOutMessages)
        readTexts = try container.decodeIfPresent(Bool.self, forKey: .readTexts)
        readChrome = try container.decodeIfPresent(Bool.self, forKey: .readChrome)
        readPrivate = try container.decodeIfPresent(String.self, forKey: .readPrivate)
    }
}

/// One bot's stored session in one of its conversations, as listed across the bot.
public struct StoredClaudeSessionRecord: Equatable, Sendable {
    public let conversationID: ConversationID
    public let session: StoredClaudeSession
    public init(conversationID: ConversationID, session: StoredClaudeSession) {
        self.conversationID = conversationID; self.session = session
    }
}

public protocol ClaudeSessionRepository: Sendable {
    func storedClaudeSession(conversationID: ConversationID, teammateID: TeammateID) async throws -> StoredClaudeSession?
    func storeClaudeSession(_ session: StoredClaudeSession, conversationID: ConversationID, teammateID: TeammateID) async throws
    func clearClaudeSession(conversationID: ConversationID, teammateID: TeammateID) async throws
    /// Every session stored for one bot, across its conversations.
    func storedClaudeSessions(teammateID: TeammateID) async throws -> [StoredClaudeSessionRecord]
}

/// One folder a bot may work in besides its own: the path the user picked and
/// a bookmark that survives a rename or a move. The bookmark wins when it
/// resolves; the path is the fallback.
public struct BotWorkspaceFolder: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let path: String
    public let bookmark: Data?

    public init(id: UUID, path: String, bookmark: Data?) {
        self.id = id; self.path = path; self.bookmark = bookmark
    }
}

/// Where a bot works on the Mac: its own folder under the content root and
/// the folders the user added. One record per bot, written whole.
public struct BotWorkspaceRecord: Codable, Equatable, Sendable {
    public let homePath: String
    public let folders: [BotWorkspaceFolder]

    public init(homePath: String, folders: [BotWorkspaceFolder]) {
        self.homePath = homePath; self.folders = folders
    }
}

public protocol BotWorkspaceRepository: Sendable {
    func loadBotWorkspace(teammateID: TeammateID) async throws -> BotWorkspaceRecord?
    func saveBotWorkspace(_ record: BotWorkspaceRecord, teammateID: TeammateID) async throws
}

public protocol ApprovalRepository: Sendable {
    func approval(id: ApprovalID) async throws -> ApprovalRequest?
    func insert(_ approval: ApprovalRequest) async throws
    func update(_ approval: ApprovalRequest, expectedState: ApprovalState) async throws
    /// The cards a conversation has seen, newest first.
    func approvals(conversationID: ConversationID, limit: Int) async throws -> [ApprovalRequest]
}

public extension ApprovalRepository {
    func approvals(conversationID: ConversationID, limit: Int) async throws -> [ApprovalRequest] { [] }
}

/// One line of what a bot did during a run (the "what happened" record).
public struct RunActivityLine: Equatable, Sendable, Identifiable {
    public let runID: RunID
    public let teammateID: TeammateID
    public let sequence: Int64
    public let recordedAt: Date
    public let line: String

    public var id: String { "\(runID.rawValue.uuidString)-\(sequence)" }

    public init(runID: RunID, teammateID: TeammateID, sequence: Int64, recordedAt: Date, line: String) {
        self.runID = runID; self.teammateID = teammateID; self.sequence = sequence
        self.recordedAt = recordedAt; self.line = line
    }
}

public protocol RunActivityRepository: Sendable {
    /// Appends one line to a run; a run keeps at most `maximumRunActivityLines`.
    func recordRunActivity(runID: RunID, line: String, at date: Date) async throws
    /// A conversation's lines across its runs, oldest first, bounded.
    func runActivity(conversationID: ConversationID, limit: Int) async throws -> [RunActivityLine]
    /// One run's lines, in the order they were written.
    func runActivity(runID: RunID) async throws -> [RunActivityLine]
}

public let maximumRunActivityLines = 200
