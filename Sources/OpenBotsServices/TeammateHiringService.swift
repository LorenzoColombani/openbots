import Foundation
import OpenBotsDomain

/// One call of the hire tool, as the reply service hands it over: which reply
/// made it, under which tool use, from which bot in which conversation, with
/// the tool's arguments exactly as they came.
public struct TeammateHireSubmission: Equatable, Sendable {
    /// The reply the call belongs to (its run). Three calls a reply at most.
    public let replyID: UUID
    public let toolUseID: String
    public let hirerID: TeammateID
    public let conversationID: ConversationID
    public let argumentsJSON: Data
    /// False when the call did not come from the bot's own reply.
    public let isOwnCall: Bool
    /// Both hire switches were on when this reply began. They hold for the
    /// whole reply: switching hiring off takes effect once the bot has
    /// finished its turn. Without it the switches are read at the call.
    public let grantedForTheReply: Bool

    public init(replyID: UUID, toolUseID: String, hirerID: TeammateID, conversationID: ConversationID,
                argumentsJSON: Data, isOwnCall: Bool, grantedForTheReply: Bool = false) {
        self.replyID = replyID; self.toolUseID = toolUseID; self.hirerID = hirerID
        self.conversationID = conversationID; self.argumentsJSON = argumentsJSON; self.isOwnCall = isOwnCall
        self.grantedForTheReply = grantedForTheReply
    }
}

/// Bots that hire bots.
public protocol TeammateHiring: Sendable {
    /// One call, answered once: a teammate made, or a refusal with its reason.
    func hire(_ submission: TeammateHireSubmission) async -> TeammateHireOutcome
    /// The reply is over. Its outcomes in call order, and nothing kept of it.
    func finishReply(_ replyID: UUID) async -> [TeammateHireOutcome]
}

/// Makes a new bot's desk. The workspace service makes one on first use; a
/// hire asks for it at once, so the newcomer has its own folder from the start.
public protocol TeammateDeskProvisioning: Sendable {
    func workspace(teammateID: TeammateID) async throws -> BotWorkspace
}

extension BotWorkspaceService: TeammateDeskProvisioning {}

/// Creates a bot with its direct chat, and says whether the new chat is
/// selected. A hire never selects: the conversation the hire came from stays
/// in front of the person.
public protocol TeammateChatProvisioning: Sendable {
    func createTeammateAndDirectChat(_ draft: DurableTeammateDraft,
                                     selectConversation: Bool) async throws -> DurableTeammateChatCreationSnapshot
}

extension DurableTeammateChatService: TeammateChatProvisioning {}

/// Turns one hire call into a teammate or a refusal. It reads both hire
/// switches again at the call, holds each reply to three calls with refused
/// ones counted, answers one tool use once, keeps the one name rule, and
/// creates the newcomer sealed: every switch off, no connectors, no folder
/// but its own desk, its own direct chat, the person's selection untouched.
/// A hire from a team conversation joins that team.
public actor TeammateHiringService: TeammateHiring {
    private let access: any ClaudeTextReplyWebAccessResolving
    private let teammates: any TeammateRepository
    private let conversations: any ConversationRepository
    private let chats: any TeammateChatProvisioning
    private let desks: (any TeammateDeskProvisioning)?
    private let teamChats: (any TeamChatServing)?
    private let uuidGenerator: any UUIDGenerator
    private var ledgers: [UUID: TeammateHireLedger] = [:]
    /// Names a hire is creating right now, so two calls for one name never
    /// both pass the roster check before either is saved.
    private var namesInHand: [String] = []

    public init(access: any ClaudeTextReplyWebAccessResolving, teammates: any TeammateRepository,
                conversations: any ConversationRepository, chats: any TeammateChatProvisioning,
                desks: (any TeammateDeskProvisioning)? = nil, teamChats: (any TeamChatServing)? = nil,
                uuidGenerator: any UUIDGenerator = SystemUUIDGenerator()) {
        self.access = access; self.teammates = teammates; self.conversations = conversations
        self.chats = chats; self.desks = desks; self.teamChats = teamChats; self.uuidGenerator = uuidGenerator
    }

    public func hire(_ submission: TeammateHireSubmission) async -> TeammateHireOutcome {
        let replyID = submission.replyID, toolUseID = submission.toolUseID
        var ledger = ledgers[replyID] ?? TeammateHireLedger()
        // The same tool use again gets the answer it already had, uncounted.
        switch ledger.admission(toolUseID: toolUseID) {
        case .repeatOf(let outcome): return outcome
        case .refuse(.alreadyInHand): return .refused(.alreadyInHand)
        case .refuse, .proceed: break
        }
        // The switches first: as they were when the reply began, or read now
        // for a call that carries no such reading. The reason is the one the user
        // cares about.
        let granted: Bool
        if submission.grantedForTheReply { granted = true } else { granted = await access.hireGranted(teammateID: submission.hirerID) }
        guard granted else {
            return record(.refused(.switchedOff), toolUseID: toolUseID, replyID: replyID)
        }
        ledger = ledgers[replyID] ?? TeammateHireLedger()
        if case .refuse(let refusal) = ledger.admission(toolUseID: toolUseID) {
            return refusal == .alreadyInHand ? .refused(.alreadyInHand)
                : record(.refused(refusal), toolUseID: toolUseID, replyID: replyID)
        }
        guard submission.isOwnCall else {
            return record(.refused(.notTheBot), toolUseID: toolUseID, replyID: replyID)
        }
        ledger.begin(toolUseID: toolUseID)
        ledgers[replyID] = ledger
        let outcome = await create(submission)
        return record(outcome, toolUseID: toolUseID, replyID: replyID)
    }

    public func finishReply(_ replyID: UUID) -> [TeammateHireOutcome] {
        ledgers.removeValue(forKey: replyID)?.outcomes ?? []
    }

    private func record(_ outcome: TeammateHireOutcome, toolUseID: String, replyID: UUID) -> TeammateHireOutcome {
        ledgers[replyID, default: TeammateHireLedger()].record(toolUseID: toolUseID, outcome: outcome)
        return outcome
    }

    private func create(_ submission: TeammateHireSubmission) async -> TeammateHireOutcome {
        guard let hirer = try? await teammates.teammate(id: submission.hirerID), hirer.lifecycle == .active,
              let conversation = try? await conversations.conversation(id: submission.conversationID),
              conversation.lifecycle == .active else { return .refused(.hirerUnavailable) }
        let request: TeammateHireRequest
        switch TeammateHireRequest.parse(argumentsJSON: submission.argumentsJSON) {
        case .failure(let refusal): return .refused(refusal)
        case .success(let parsed): request = parsed
        }
        // Stricter than the New Bot sheet, where an archived bot has given its
        // name up: a newcomer with it would block that bot's restore, and the
        // person never picked the name. Read before the names in hand are
        // taken, so no suspension falls between that check and its claim. The
        // store frees an archived bot's name, so a roster that cannot be read
        // refuses: nothing downstream would.
        let roster: [Teammate]
        do { roster = try await teammates.listTeammates(includingArchived: true) } catch {
            AgenticDiagnosticsLog.error("hire", "roster not read, so the name went unchecked: \(String(describing: error).prefix(160))")
            return .refused(.notCreated)
        }
        if let archived = roster.first(where: {
            $0.lifecycle == .archived && TeammateProfile.namesMatch($0.profile.displayName, request.handle)
        }) {
            return .refused(.nameArchived(existingName: archived.profile.displayName))
        }
        if let held = namesInHand.first(where: { TeammateProfile.namesMatch($0, request.handle) }) {
            return .refused(.nameTaken(existingName: held))
        }
        namesInHand.append(request.handle)
        defer { namesInHand.removeAll { TeammateProfile.namesMatch($0, request.handle) } }

        let id = TeammateID(uuidGenerator.next())
        do {
            let appearance = try CreatureAllocation(id: id.rawValue).appearance()
            _ = try await chats.createTeammateAndDirectChat(
                DurableTeammateDraft(teammateID: id, displayName: request.handle, role: request.purpose,
                                     detailedInstructions: request.instructions, seat: request.seat,
                                     profileWrittenByHirer: hirer.profile.displayName, appearance: appearance),
                selectConversation: false)
        } catch let taken as TeammateNameTakenError {
            return .refused(.nameTaken(existingName: taken.existingName))
        } catch {
            AgenticDiagnosticsLog.error("hire", "teammate not created: \(String(describing: error).prefix(160))")
            return .refused(.notCreated)
        }
        // The desk is made on first use anyway, so a desk that cannot be
        // made now never undoes the hire.
        if let desks {
            do { _ = try await desks.workspace(teammateID: id) }
            catch { AgenticDiagnosticsLog.error("hire", "desk not made yet: \(String(describing: error).prefix(160))") }
        }
        var joined = false, inTeam = false
        if case .team = conversation.kind {
            inTeam = true
            joined = await join(id, teamConversation: conversation.id)
        }
        // A failed join leaves the hire standing, and the lead is told, so it
        // never briefs a newcomer no handoff here can reach.
        return .hired(TeammateHire(teammateID: id, name: request.handle, purpose: request.purpose, joinedTeam: joined,
                                   couldNotJoinTeam: inTeam && !joined))
    }

    /// Adds the newcomer to the team whose conversation the hire came from,
    /// through the team service so the roster change is published like an
    /// edit. A write that loses to another writer is tried once more on a
    /// fresh read; the hire stands whether or not the join lands.
    private func join(_ id: TeammateID, teamConversation: ConversationID) async -> Bool {
        guard let teamChats else { return false }
        for _ in 0..<2 {
            guard let snapshot = try? await teamChats.teamChat(conversationID: teamConversation) else { return false }
            let edit = TeamChatEdit(teamID: snapshot.team.id, name: snapshot.team.name, leadID: snapshot.team.leadID,
                                    memberIDs: Set(snapshot.members.map(\.id)).union([id]),
                                    expectedUpdatedAt: snapshot.team.updatedAt)
            do {
                _ = try await teamChats.updateTeamChat(edit)
                return true
            } catch TeamChatError.teamChangedElsewhere {
                continue
            } catch {
                AgenticDiagnosticsLog.error("hire", "team not joined: \(String(describing: error).prefix(160))")
                return false
            }
        }
        return false
    }
}
