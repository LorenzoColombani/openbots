import Foundation
import OpenBotsDomain

public protocol TeammateArchiving: Sendable {
    func archivedTeammates() async throws -> [Teammate]
    func archiveTeammate(id: TeammateID, expectedProfileRevision: UInt64) async throws -> Teammate
    func restoreTeammate(id: TeammateID, expectedProfileRevision: UInt64) async throws -> Teammate
}

/// Archive and restore only change durable lifecycle. This service has no
/// executor, cancellation, scheduling or attachment authority; its one act on
/// disk is dropping the archived bot's saved Claude sessions under the app
/// profile, through the retention service it is given.
public actor TeammateArchiveService: TeammateArchiving {
    private let repository: any TeammateArchiveRepository
    private let clock: any OpenBotsClock
    private let sessionRetention: (any ClaudeSessionRetaining)?

    public init(repository: any TeammateArchiveRepository, clock: any OpenBotsClock = SystemClock(),
                sessionRetention: (any ClaudeSessionRetaining)? = nil) {
        self.repository = repository
        self.clock = clock
        self.sessionRetention = sessionRetention
    }

    public func archivedTeammates() async throws -> [Teammate] {
        try await repository.archivedTeammates()
    }

    public func archiveTeammate(id: TeammateID, expectedProfileRevision: UInt64) async throws -> Teammate {
        try Task.checkCancellation()
        let archived = try await repository.archiveTeammate(id: id, expectedProfileRevision: expectedProfileRevision, now: clock.now())
        // The bot is archived once its row says so; its saved sessions go with
        // it. A session whose files could not be removed keeps its row, and a
        // listing that fails leaves every row, so the files stay findable;
        // neither undoes an archive that already happened. Nothing retries on
        // its own: this is the only drop, and archiving the bot again (after a
        // restore) is what would try once more.
        _ = try? await sessionRetention?.dropSessions(teammateID: id)
        return archived
    }

    public func restoreTeammate(id: TeammateID, expectedProfileRevision: UInt64) async throws -> Teammate {
        try Task.checkCancellation()
        return try await repository.restoreTeammate(id: id, expectedProfileRevision: expectedProfileRevision, now: clock.now())
    }
}
