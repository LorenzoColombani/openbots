import Foundation
import OpenBotsDomain

/// Drops every saved Claude session of one bot.
public protocol ClaudeSessionRetaining: Sendable {
    func dropSessions(teammateID: TeammateID) async throws -> ClaudeSessionDropReport
}

/// One session dropped whole: the row it had and what the CLI kept of it.
public struct DroppedClaudeSession: Equatable, Sendable {
    public let record: StoredClaudeSessionRecord
    public let removal: ClaudeSessionTranscriptRemoval
    public init(record: StoredClaudeSessionRecord, removal: ClaudeSessionTranscriptRemoval) {
        self.record = record; self.removal = removal
    }
}

/// What one drop did: the sessions gone whole, and the rows kept because what
/// the CLI holds of them could not be removed, so those files can still be
/// found. Nothing drops a kept row again on its own: archiving is the only
/// drop, and an archived bot cannot be archived again until it is restored.
public struct ClaudeSessionDropReport: Equatable, Sendable {
    public let dropped: [DroppedClaudeSession]
    public let kept: [StoredClaudeSessionRecord]
    public init(dropped: [DroppedClaudeSession], kept: [StoredClaudeSessionRecord]) {
        self.dropped = dropped; self.kept = kept
    }
}

/// Drops a bot's saved sessions whole: what the CLI kept under the app
/// profile first, then the row, so a row is never cleared while its files stay
/// behind unfindable. Only rows this build can read are listed, so a row it
/// cannot read is never dropped: its session, and so its files, cannot be
/// identified, and it stays.
public struct ClaudeSessionRetentionService: ClaudeSessionRetaining {
    private let sessions: any ClaudeSessionRepository
    private let profileURL: URL
    private let remove: @Sendable (URL, UUID) throws -> ClaudeSessionTranscriptRemoval

    public init(sessions: any ClaudeSessionRepository, profileURL: URL,
                remove: @escaping @Sendable (URL, UUID) throws -> ClaudeSessionTranscriptRemoval = ClaudeSessionTranscriptLocator.removeFromProfile) {
        self.sessions = sessions; self.profileURL = profileURL; self.remove = remove
    }

    public func dropSessions(teammateID: TeammateID) async throws -> ClaudeSessionDropReport {
        var dropped: [DroppedClaudeSession] = []
        var kept: [StoredClaudeSessionRecord] = []
        for record in try await sessions.storedClaudeSessions(teammateID: teammateID) {
            try Task.checkCancellation()
            let removal: ClaudeSessionTranscriptRemoval
            do { removal = try remove(profileURL, record.session.sessionID) }
            catch { kept.append(record); continue }
            try await sessions.clearClaudeSession(conversationID: record.conversationID, teammateID: teammateID)
            dropped.append(DroppedClaudeSession(record: record, removal: removal))
        }
        return ClaudeSessionDropReport(dropped: dropped, kept: kept)
    }
}
