import Foundation
import OpenBotsDomain

public protocol TeammateDeleting: Sendable {
    func inventory(id: TeammateID) async throws -> TeammateDeleteInventory
    func deleteTeammate(id: TeammateID, expectedProfileRevision: UInt64) async throws -> TeammateDeleteInventory
    /// The bots Delete kept only for their team chat history, whose messages
    /// there read as "Deleted bot".
    func deletedTeammateIDs() async throws -> Set<TeammateID>
}

public actor TeammateDeletionService: TeammateDeleting {
    private let repository: any TeammateDeletionRepository
    private let clock: any OpenBotsClock
    private let sessionRetention: (any ClaudeSessionRetaining)?
    private let connectorGrants: (any ConnectorGrantForgetting)?
    private let fileManager: FileManager
    /// The app's memory tree, whose `Documents/Teammates/<id>` folder holds a
    /// bot's own memory files (`AuthoritativeMarkdown.relativePath`).
    private let memoryRoot: URL?

    public init(
        repository: any TeammateDeletionRepository,
        clock: any OpenBotsClock = SystemClock(),
        sessionRetention: (any ClaudeSessionRetaining)? = nil,
        connectorGrants: (any ConnectorGrantForgetting)? = nil,
        fileManager: FileManager = .default,
        memoryRoot: URL? = nil
    ) {
        self.repository = repository
        self.clock = clock
        self.sessionRetention = sessionRetention
        self.connectorGrants = connectorGrants
        self.fileManager = fileManager
        self.memoryRoot = memoryRoot
    }

    public func inventory(id: TeammateID) async throws -> TeammateDeleteInventory {
        try await repository.inventory(id: id)
    }

    public func deletedTeammateIDs() async throws -> Set<TeammateID> {
        try await repository.deletedTeammateIDs()
    }

    public func deleteTeammate(id: TeammateID, expectedProfileRevision: UInt64) async throws -> TeammateDeleteInventory {
        let before = try await repository.inventory(id: id)
        _ = try await repository.deleteTeammate(
            id: id,
            expectedProfileRevision: expectedProfileRevision,
            now: clock.now()
        )
        // Only after the delete: a refused delete keeps every saved session.
        // Their rows are app_metadata keys the delete leaves, so they are still
        // found here; a row whose files could not be removed stays, by design.
        // A bot kept as "Deleted bot" for its team chat history loses them too.
        if let sessionRetention {
            _ = try? await sessionRetention.dropSessions(teammateID: id)
        }
        // Its connector grants too, through the connector store, whose revision
        // a change made inside the delete would have left stale. A grant left
        // by a failure names a bot that no longer exists and admits nothing.
        if let connectorGrants {
            do { try await connectorGrants.forgetGrants(teammateID: id) }
            catch { AgenticDiagnosticsLog.error("delete", "connector grants kept: \(String(describing: error).prefix(160))") }
        }
        // Recoverable material goes to Trash where macOS permits: the bot's
        // folders, and its own memory files, whose rows the delete removed.
        let memoryFolder = memoryRoot?.appending(path: "Documents/Teammates/\(id.persistedValue)", directoryHint: .isDirectory)
        var folders = [before.botHomePath, before.skillsPath].compactMap { $0 }.map { URL(fileURLWithPath: $0) }
        if let memoryFolder, fileManager.fileExists(atPath: memoryFolder.path) { folders.append(memoryFolder) }
        for url in folders {
            var resulting: NSURL?
            try? fileManager.trashItem(at: url, resultingItemURL: &resulting)
        }
        return before
    }
}
