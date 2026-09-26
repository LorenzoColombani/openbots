import Foundation
import OpenBotsDomain

/// One call of the setup tool, as the reply service hands it over.
public struct BotSelfSetupSubmission: Equatable, Sendable {
    public let toolUseID: String
    public let teammateID: TeammateID
    /// The arguments as the call ran them: after the switch card, only the
    /// switches the person approved.
    public let argumentsJSON: Data
    /// False when the call did not come from the bot's own reply.
    public let isOwnCall: Bool

    public init(toolUseID: String, teammateID: TeammateID, argumentsJSON: Data, isOwnCall: Bool) {
        self.toolUseID = toolUseID; self.teammateID = teammateID
        self.argumentsJSON = argumentsJSON; self.isOwnCall = isOwnCall
    }
}

/// The switches a setup sets: the bot's own, never an app-wide master, whose
/// state it only reads to name it.
public protocol BotSetupSwitching: Sendable {
    func setBotSwitchOn(_ setupSwitch: BotSetupSwitch, teammateID: TeammateID) async
    func isOnForTheApp(_ setupSwitch: BotSetupSwitch) async -> Bool
}

extension BotSetupSwitch {
    var capability: AgenticCapability {
        switch self {
        case .webSearch: .web(.search)
        case .webFetch: .web(.fetch)
        case .work: .work
        }
    }
}

extension AgenticJobAccessStore: BotSetupSwitching {
    public func setBotSwitchOn(_ setupSwitch: BotSetupSwitch, teammateID: TeammateID) async {
        setBotEnabled(true, capability: setupSwitch.capability, teammateID: teammateID)
    }

    public func isOnForTheApp(_ setupSwitch: BotSetupSwitch) async -> Bool {
        // Any bot's reading carries the master's state.
        let access = current(teammateID: TeammateID(UUID()))
        return switch setupSwitch {
        case .webSearch: access.webSearch.appEnabled
        case .webFetch: access.webFetch.appEnabled
        case .work: access.work.appEnabled
        }
    }
}

/// Moves a bot's folder to its new name while the folder is still unused.
public protocol BotFolderRenaming: Sendable {
    @discardableResult
    func followRename(teammateID: TeammateID, from oldName: String) async -> Bool
}

extension BotWorkspaceService: BotFolderRenaming {}

/// A new bot sets itself up.
public protocol BotSelfSetting: Sendable {
    /// The placeholder name a bot waiting to set itself up was born with; nil
    /// for every other bot.
    func placeholderName(teammateID: TeammateID) async -> String?
    /// Marks a bot just born under a placeholder name as waiting for setup.
    func markPending(teammateID: TeammateID, placeholderName: String) async throws
    /// One call, answered once.
    func setUp(_ submission: BotSelfSetupSubmission) async -> Result<BotSelfSetup, BotSelfSetupRefusal>
}

/// Turns one setup call into the bot's own profile and switches. The profile is
/// written only while the person has not written any of it (the person's edits win);
/// the switches are the bot's own; the waiting mark goes, so the tool is never
/// offered again; the folder follows the new name while it is unused.
public actor BotSelfSetupService: BotSelfSetting {
    private let repository: any BotSelfSetupRepository
    private let teammates: any TeammateRepository
    private let switches: any BotSetupSwitching
    private let folders: (any BotFolderRenaming)?
    private let clock: any OpenBotsClock
    /// Each tool use's answer, so a repeat gets the same one.
    private var answered: [String: Result<BotSelfSetup, BotSelfSetupRefusal>] = [:]
    /// Bots whose setup is being written right now.
    private var inHand: Set<TeammateID> = []

    public init(repository: any BotSelfSetupRepository, teammates: any TeammateRepository,
                switches: any BotSetupSwitching, folders: (any BotFolderRenaming)? = nil,
                clock: any OpenBotsClock = SystemClock()) {
        self.repository = repository; self.teammates = teammates; self.switches = switches
        self.folders = folders; self.clock = clock
    }

    public func placeholderName(teammateID: TeammateID) async -> String? {
        do { return try await repository.pendingSelfSetupName(teammateID: teammateID) } catch {
            AgenticDiagnosticsLog.error("setup", "waiting mark not read: \(String(describing: error).prefix(160))")
            return nil
        }
    }

    public func markPending(teammateID: TeammateID, placeholderName: String) async throws {
        try await repository.setPendingSelfSetup(teammateID: teammateID, placeholderName: placeholderName)
    }

    public func setUp(_ submission: BotSelfSetupSubmission) async -> Result<BotSelfSetup, BotSelfSetupRefusal> {
        if let answer = answered[submission.toolUseID] { return answer }
        guard submission.isOwnCall else { return .failure(.notTheBot) }
        let id = submission.teammateID
        guard inHand.insert(id).inserted else { return .failure(.notPending) }
        defer { inHand.remove(id) }
        let answer = await write(submission)
        answered[submission.toolUseID] = answer
        return answer
    }

    private func write(_ submission: BotSelfSetupSubmission) async -> Result<BotSelfSetup, BotSelfSetupRefusal> {
        let id = submission.teammateID
        guard let placeholder = await placeholderName(teammateID: id),
              var teammate = try? await teammates.teammate(id: id), teammate.lifecycle == .active else {
            return .failure(.notPending)
        }
        let request: BotSelfSetupRequest
        switch BotSelfSetupRequest.parse(argumentsJSON: submission.argumentsJSON) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let parsed): request = parsed
        }
        let fields = request.profileFields
        var wroteProfile = false
        if BotSelfSetup.isUntouched(teammate.profile, placeholderName: placeholder) {
            // The hire's name rule: no other bot, active or archived, holds it.
            let roster: [Teammate]
            do { roster = try await teammates.listTeammates(includingArchived: true) } catch {
                AgenticDiagnosticsLog.error("setup", "roster not read, so the name went unchecked: \(String(describing: error).prefix(160))")
                return .failure(.notSaved)
            }
            if let other = roster.first(where: { $0.id != id && TeammateProfile.namesMatch($0.profile.displayName, fields.handle) }) {
                return .failure(.profile(other.lifecycle == .archived
                    ? .nameArchived(existingName: other.profile.displayName)
                    : .nameTaken(existingName: other.profile.displayName)))
            }
            let expected = teammate.profile.revision
            do {
                teammate.profile = try teammate.profile.revised(displayName: fields.handle, role: fields.purpose,
                    detailedInstructions: .some(fields.instructions), seat: .some(fields.seat))
                teammate.updatedAt = max(teammate.updatedAt, clock.now())
                try await teammates.update(teammate, expectedProfileRevision: expected)
                wroteProfile = true
            } catch RepositoryError.optimisticLockFailed {
                // The person saved the profile while the bot was writing: their words stand.
                teammate = (try? await teammates.teammate(id: id)) ?? teammate
            } catch {
                AgenticDiagnosticsLog.error("setup", "profile not saved: \(String(describing: error).prefix(160))")
                return .failure(.notSaved)
            }
        }
        var offForTheApp: [BotSetupSwitch] = []
        for chosen in request.switches {
            await switches.setBotSwitchOn(chosen, teammateID: id)
            if await !switches.isOnForTheApp(chosen) { offForTheApp.append(chosen) }
        }
        do { try await repository.setPendingSelfSetup(teammateID: id, placeholderName: nil) } catch {
            // Left waiting, the next turn offers the tool again, and a profile
            // no longer untouched is kept as it is.
            AgenticDiagnosticsLog.error("setup", "waiting mark not cleared: \(String(describing: error).prefix(160))")
        }
        if wroteProfile { await folders?.followRename(teammateID: id, from: placeholder) }
        return .success(BotSelfSetup(previousName: placeholder, name: teammate.profile.displayName,
            purpose: teammate.profile.role, wroteProfile: wroteProfile,
            turnedOn: request.switches, offForTheApp: offForTheApp))
    }
}
