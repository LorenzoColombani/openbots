import Foundation
import OpenBotsDomain

public struct ConnectorAccessReading: Equatable, Sendable {
    public let definitions: [ConnectorDefinition]
    public let excludedCount: Int
    public let appEnabled: Bool
    public let selectedIDs: Set<String>
    public let revision: Int64
    public let isAvailable: Bool
    /// Connectors that were allowed once and are off now because the row itself
    /// changed underneath the grant — a plugin naming a new version is the
    /// usual way. Turning them off is right and deliberate; saying nothing is
    /// not. A browser connector went dark this way when Claude Code moved its
    /// Chrome DevTools plugin from 1.8.0 to 1.9.0, and the app simply looked
    /// broken. The state is durable rather than an event: the stale
    /// grant keeps the identity it was given, so the mismatch can be seen at
    /// any launch, not only the one where it happened.
    public let changedSinceAllowed: Set<String>
    /// Connectors the user has switched off for the whole app. A bot's own grant is
    /// left exactly as it was — killing a connector app-wide is not a decision
    /// about any one bot, and turning it back on must give every bot back what
    /// it already had rather than making the user set them all again.
    public let appDisabledIDs: Set<String>
    /// The chats this bot may read in Messages; empty in the app-wide pane.
    public let messagesChats: AppleMessagesChatScope
    public init(definitions: [ConnectorDefinition] = [], excludedCount: Int = 0, appEnabled: Bool = false,
                selectedIDs: Set<String> = [], revision: Int64 = 0, isAvailable: Bool = false,
                changedSinceAllowed: Set<String> = [], appDisabledIDs: Set<String> = [],
                messagesChats: AppleMessagesChatScope = .init(guids: [])) {
        self.definitions = definitions; self.excludedCount = excludedCount; self.appEnabled = appEnabled
        self.selectedIDs = selectedIDs; self.revision = revision; self.isAvailable = isAvailable
        self.changedSinceAllowed = changedSinceAllowed; self.appDisabledIDs = appDisabledIDs
        self.messagesChats = messagesChats
    }
}

/// What Delete asks of the connector grants once a bot is gone.
public protocol ConnectorGrantForgetting: Sendable {
    func forgetGrants(teammateID: TeammateID) async throws
}

/// Persistent selection, separate from discovery and connection. No operation
/// on this actor starts a connector. Runtime admission must acquire a lease and
/// keep observing changes; a saved grant alone is never execution authority.
public actor ConnectorAccessStore: ConnectorGrantForgetting {
    private let repository: any ConnectorAccessRepository
    private let catalogReader: any ConnectorCatalogReading
    private let listedTeammates: (@Sendable () async throws -> Set<TeammateID>)?
    private let clock: any OpenBotsClock
    private var state = ConnectorAccessState()
    private var catalog = ConnectorCatalogSnapshot()
    private var sessionID = UUID()
    private var available = false
    private var busy = false
    private var revoking = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// How long a killed id must be gone from the catalog, without a break,
    /// before its kill is let go.
    public static let killPruneInterval: TimeInterval = 90 * 86_400

    /// `listedTeammates` names the bots the workspace still lists, archived and
    /// deleted ones left out; nil counts every bot's grant, as before it existed.
    public init(repository: any ConnectorAccessRepository, catalog: any ConnectorCatalogReading,
                listedTeammates: (@Sendable () async throws -> Set<TeammateID>)? = nil,
                clock: any OpenBotsClock = SystemClock()) {
        self.repository = repository; catalogReader = catalog
        self.listedTeammates = listedTeammates; self.clock = clock
    }

    /// Read-only catalog discovery, then one atomic identity reconciliation.
    /// A disappeared or changed definition turns its old grants off durably.
    /// A failed read/write leaves access unavailable instead of reviving grants.
    public func restore() async throws {
        await beginChange()
        defer { endChange() }
        do {
            let stored = try await repository.loadConnectorAccess()
            try stored.validate()
            // The one-time fill-in for a record written before a grant could
            // say why it was off. It has to be WRITTEN: compared against its own
            // seeded self it never looks like a change, and a guess left unsaved
            // is a guess made again at every launch — which is the repeated
            // blame the marker exists to stop.
            let seeded = stored.seedingGrantFlags()
            let loaded = Self.holdingPriorIdentities(try await catalogReader.loadConnectorCatalog(),
                                                     prior: seeded.catalog)
            var next = try reconciled(seeded, with: loaded)
            if next != stored {
                if next.revision == stored.revision {
                    guard stored.revision < Int64.max else { throw ConnectorAccessError.revisionExhausted }
                    next.revision += 1
                }
                try await save(next, expectedRevision: stored.revision)
            }
            state = next; catalog = loaded; available = true
        } catch {
            available = false; catalog = .init()
            throw Self.safeError(error)
        }
    }

    public func refreshCatalog() async throws {
        await beginChange(revokes: false)
        defer { endChange() }
        guard available else { throw ConnectorAccessError.unavailable }
        do {
            let loaded = Self.holdingPriorIdentities(try await catalogReader.loadConnectorCatalog(),
                                                     prior: state.catalog)
            let next = try reconciled(state, with: loaded)
            if next != state {
                revokeLeases()
                try await save(next, expectedRevision: state.revision)
            }
            state = next; catalog = loaded; available = true
        } catch {
            available = false; catalog = .init()
            throw Self.safeError(error)
        }
    }

    public func current(teammateID: TeammateID? = nil) async -> ConnectorAccessReading {
        // The app-wide line counts only bots the workspace still lists: an
        // archived bot
        // keeps its grants, since archiving is reversible, but no listed bot's
        // switch could answer a line it raised. Read before the state, so the
        // reading is of one moment; a roster that cannot be read counts every
        // bot, because the line should fail toward showing, never toward silence.
        var listed: Set<TeammateID>?
        if teammateID == nil, let listedTeammates, state.grants.contains(where: \.revokedByChange) {
            listed = try? await listedTeammates()
        }
        let selected = teammateID.map { teammate in
            Set(state.grants.filter { $0.teammateID == teammate && $0.enabled && state.catalog.contains($0.identity) }.map { $0.identity.id })
        } ?? []
        // Why it is off is recorded on the grant, not guessed from its identity.
        // In a bot's pane that is this bot's grants; in the app-wide pane it is
        // any listed bot's — the line there means some bot's grant was revoked
        // by a change, because the row is the same row. And only a row the
        // catalog still holds can be named: nothing
        // draws an id with no row today, but a count or a dot one day would.
        // By id, not identity, so a plugin rolled back to the digest the user
        // allowed keeps its line.
        let held = Set(state.catalog.map(\.id))
        let stale = state.grants.filter { grant in
            (teammateID.map { grant.teammateID == $0 } ?? listed?.contains(grant.teammateID) ?? true)
                && !grant.enabled && grant.revokedByChange && held.contains(grant.identity.id)
        }
        // Read order, not storage order: a row this build cannot drive sinks
        // below the rows that work. Every other use of the catalog — the lease,
        // the grant comparison — sorts by identity on its own, so this moves
        // nothing but the list the user looks at.
        let definitions = ConnectorDefinition.inListOrder(catalog.connectors.map(\.definition))
        return .init(definitions: definitions, excludedCount: catalog.excludedCount,
            appEnabled: available && state.appEnabled, selectedIDs: available ? selected : [],
            revision: state.revision, isAvailable: available && !busy,
            changedSinceAllowed: available ? Set(stale.map { $0.identity.id }) : [],
            appDisabledIDs: available ? Set(state.appDisabledIDs) : [],
            messagesChats: available ? teammateID.map { messagesChats(teammateID: $0) } ?? .init(guids: [])
                : .init(guids: []))
    }

    /// The app-wide switch for one connector, a kill switch. Off here and no bot may launch it, whatever its own
    /// switch says; on again and every bot gets back exactly the grant it had.
    ///
    /// Keyed by identity id rather than identity, so a plugin naming a new
    /// version cannot resurrect something the user killed.
    public func setConnectorAppEnabled(_ enabled: Bool, id: String) async throws {
        await beginChange()
        defer { endChange() }
        try Task.checkCancellation()
        guard available else { throw ConnectorAccessError.unavailable }
        let killed = state.appDisabledIDs.contains(id)
        guard killed == enabled else { return }
        var next = state
        if enabled {
            next.appDisabledIDs.removeAll { $0 == id }
            next.appDisabledAbsentSince[id] = nil
        }
        else { next.appDisabledIDs = (next.appDisabledIDs + [id]).sorted() }
        try await persist(next)
    }

    public func setAppEnabled(_ enabled: Bool) async throws {
        await beginChange()
        defer { endChange() }
        try Task.checkCancellation()
        guard available else { throw ConnectorAccessError.unavailable }
        guard state.appEnabled != enabled else { return }
        var next = state
        next.appEnabled = enabled
        try await persist(next)
    }

    public func setBotEnabled(_ enabled: Bool, identity: ConnectorIdentity, teammateID: TeammateID) async throws {
        await beginChange()
        defer { endChange() }
        try Task.checkCancellation()
        guard available else { throw ConnectorAccessError.unavailable }
        guard state.catalog.contains(identity) else { throw ConnectorAccessError.definitionChanged }
        let index = state.grants.firstIndex { $0.teammateID == teammateID && $0.identity.id == identity.id }
        // A grant still carrying "switched off by a change" is not settled even
        // when the switch already reads the way the user just set it: the caption
        // is still on the row, and the user's hand on the switch is what answers it.
        if let index, state.grants[index].identity == identity, state.grants[index].enabled == enabled,
           !state.grants[index].revokedByChange { return }
        if index == nil, !enabled { return }
        var next = state
        let grant = ConnectorBotGrant(teammateID: teammateID, identity: identity, enabled: enabled)
        if let index { next.grants[index] = grant } else { next.grants.append(grant) }
        next.grants.sort { ($0.teammateID.persistedValue, $0.identity.id) < ($1.teammateID.persistedValue, $1.identity.id) }
        try await persist(next)
    }

    /// A deleted bot's grants go with it, and so do the
    /// chats it could read in Messages. Through this actor, never by editing
    /// the record under it: the record's revision must stay the one held here,
    /// or the next switch fails and takes access dark.
    public func forgetGrants(teammateID: TeammateID) async throws {
        await beginChange(revokes: false)
        defer { endChange() }
        guard available else { throw ConnectorAccessError.unavailable }
        guard state.grants.contains(where: { $0.teammateID == teammateID })
            || state.messagesChats.contains(where: { $0.teammateID == teammateID }) else { return }
        revokeLeases()
        var next = state
        next.grants.removeAll { $0.teammateID == teammateID }
        next.messagesChats.removeAll { $0.teammateID == teammateID }
        try await persist(next)
    }

    /// The chats this bot may read in Messages; empty when the user has named none.
    public func messagesChats(teammateID: TeammateID) -> AppleMessagesChatScope {
        state.messagesChats.first { $0.teammateID == teammateID }?.chats ?? .init(guids: [])
    }

    /// Names the chats this bot may read in Messages, replacing the ones it had.
    /// An empty list removes the entry, and the bot reads none. A list that
    /// cannot be kept — too many, a guid too long or with a control character
    /// in it — is refused before anything is written, so a refusal never takes
    /// access dark the way a failed write does.
    ///
    /// A change withdraws every lease, as each change here does. A running turn
    /// keeps the chats it was launched with until it ends; the reply service
    /// ends a turn whose chats were taken away (`wasWithdrawn`), and a chat
    /// added waits for the next turn.
    public func setMessagesChats(_ guids: [String], teammateID: TeammateID) async throws {
        let chats = AppleMessagesChatScope(guids: guids)
        guard chats.isValid, guids.allSatisfy(AppleMessagesChatScope.isChoosable) else {
            throw ConnectorAccessError.invalidState
        }
        await beginChange()
        defer { endChange() }
        try Task.checkCancellation()
        guard available else { throw ConnectorAccessError.unavailable }
        guard messagesChats(teammateID: teammateID) != chats else { return }
        var next = state
        next.messagesChats.removeAll { $0.teammateID == teammateID }
        if !chats.isEmpty { next.messagesChats.append(.init(teammateID: teammateID, chats: chats)) }
        next.messagesChats.sort { $0.teammateID.persistedValue < $1.teammateID.persistedValue }
        try await persist(next)
    }

    public func lease(teammateID: TeammateID) -> ConnectorAccessLease? {
        guard !busy else { return nil }
        return currentLease(teammateID: teammateID)
    }

    private func currentLease(teammateID: TeammateID) -> ConnectorAccessLease? {
        guard available, !revoking, state.appEnabled else { return nil }
        // A connector killed app-wide is not in any lease, whatever a bot's own
        // switch says. Three gates now, and every one of them must be open: the
        // master, this connector app-wide, and the bot's own selection.
        let killed = Set(state.appDisabledIDs)
        let identities = state.grants.filter {
            $0.teammateID == teammateID && $0.enabled && state.catalog.contains($0.identity)
                && !killed.contains($0.identity.id)
        }
            .map(\.identity).sorted { $0.id < $1.id }
        guard !identities.isEmpty else { return nil }
        return .init(teammateID: teammateID, revision: state.revision, sessionID: sessionID, identities: identities)
    }

    public func isCurrent(_ captured: ConnectorAccessLease) -> Bool { currentLease(teammateID: captured.teammateID) == captured }

    /// The exact transient definitions behind a still-current lease. A future
    /// launch must refresh the catalog first; this is not a connection check.
    ///
    /// The app's Messages row comes back carrying this bot's chats, read under
    /// the same lease: a list changed since the lease was taken has already
    /// made it stale, so the chats and the grant are of one moment.
    public func configurations(for captured: ConnectorAccessLease) throws -> [ConfiguredConnector] {
        guard isCurrent(captured) else { throw ConnectorAccessError.definitionChanged }
        return try captured.identities.map { identity in
            guard let value = catalog.connectors.first(where: { $0.definition.identity == identity }) else {
                throw ConnectorAccessError.definitionChanged
            }
            guard value.launch.command == AppleMessagesConnectorPreparation.command else { return value }
            return ConfiguredConnector(definition: value.definition,
                                       launch: value.launch.reading(messagesChats(teammateID: captured.teammateID)),
                                       holdsPriorIdentity: value.holdsPriorIdentity)
        }
    }

    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }

    private func beginChange(revokes: Bool = true) async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else { busy = true }
        if revokes { revokeLeases() }
    }

    private func endChange() {
        revoking = false
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        notify()
    }

    private func revokeLeases() { revoking = true; sessionID = UUID(); notify() }

    private func persist(_ candidate: ConnectorAccessState) async throws {
        do {
            var next = candidate
            guard state.revision < Int64.max else { throw ConnectorAccessError.revisionExhausted }
            next.revision = state.revision + 1
            try await save(next, expectedRevision: state.revision)
            state = next
        } catch {
            // In particular, a failed attempt to turn access off must not
            // restore the previously granted live access for this session.
            available = false
            throw Self.safeError(error)
        }
    }

    /// Every write into the record passes here, so every writer is checked by
    /// the store the same way. The launch write that carried only the one-time
    /// fill-in used to reach the repository unchecked;
    /// the repository checks again on its side, which is its own business.
    private func save(_ next: ConnectorAccessState, expectedRevision: Int64) async throws {
        try next.validate()
        try await repository.saveConnectorAccess(next, expectedRevision: expectedRevision)
    }

    /// A row that could not tell what it is bound to on this read wears the
    /// identity it already had, so reconciliation sees no change and no grant
    /// is revoked. Without this, a Google helper that missed its two seconds at
    /// launch turned every bot's Google switch off for good, because a grant
    /// revoked by a change stays off when the old identity comes back. A row
    /// with no identity before it has nothing to keep and loads as itself.
    static func holdingPriorIdentities(_ loaded: ConnectorCatalogSnapshot,
                                       prior: [ConnectorIdentity]) -> ConnectorCatalogSnapshot {
        guard loaded.connectors.contains(where: \.holdsPriorIdentity) else { return loaded }
        let connectors = loaded.connectors.map { connector -> ConfiguredConnector in
            let definition = connector.definition
            guard connector.holdsPriorIdentity,
                  let kept = prior.first(where: { $0.id == definition.id }) else { return connector }
            return ConfiguredConnector(
                definition: .init(identity: kept, serverName: definition.serverName,
                                  pluginName: definition.pluginName, transport: definition.transport,
                                  title: definition.title, summary: definition.summary,
                                  availability: definition.availability),
                launch: connector.launch, holdsPriorIdentity: true)
        }
        return ConnectorCatalogSnapshot(connectors: connectors, excludedCount: loaded.excludedCount)
    }

    private func reconciled(_ prior: ConnectorAccessState, with loaded: ConnectorCatalogSnapshot) throws -> ConnectorAccessState {
        let identities = loaded.connectors.map { $0.definition.identity }.sorted { $0.id < $1.id }
        guard identities.count <= ConnectorAccessState.maximumDefinitions,
              Set(identities.map(\.id)).count == identities.count else { throw ConnectorAccessError.invalidState }
        var next = prior
        if identities != prior.catalog {
            next.catalog = identities
            next.grants = prior.grants.map {
                // Only a grant this reconciliation takes away carries the reason.
                // One already off keeps whatever it had, so a switch the user
                // turned off themselves is never blamed on a version bump, and one revoked
                // by an earlier change keeps saying so if that version comes back.
                let revoked = $0.enabled && !identities.contains($0.identity)
                return ConnectorBotGrant(teammateID: $0.teammateID, identity: $0.identity,
                    enabled: $0.enabled && identities.contains($0.identity),
                    revokedByChange: revoked || $0.revokedByChange)
            }
        }
        // Run on every reconciliation, the catalog changed or not: a catalog
        // that holds still for 90 days must still let a gone kill go.
        next = Self.countingKillAbsence(next, now: clock.now())
        // Nothing changed is nothing written, so an unchanged refresh keeps
        // every running bot's lease current.
        guard next != prior else { return prior }
        guard prior.revision < Int64.max else { throw ConnectorAccessError.revisionExhausted }
        next.revision = prior.revision + 1
        try next.validate()
        return next
    }

    /// A kill outlives the catalog it was made in — that is what stops a
    /// version bump handing back something the user refused — but not forever: once
    /// its id has been gone for `killPruneInterval` without a break, it is let
    /// go. Letting go gives nothing back: every grant
    /// to an id the catalog lacks was already switched off by reconciliation,
    /// so a row that returns later is live for the app with no bot on.
    ///
    /// Two kills are never counted. One the catalog holds, a row unsure of its
    /// identity included, since it is still the user's decision about a row
    /// they can see. And one from a source this build does not know: this build can
    /// never list it, so its absence here proves nothing, and it must still be
    /// killed when the app rolls forward again.
    static func countingKillAbsence(_ state: ConnectorAccessState, now: Date) -> ConnectorAccessState {
        let held = Set(state.catalog.map(\.id))
        var since: [String: Date] = [:]
        var letGo: Set<String> = []
        for id in state.appDisabledIDs where !held.contains(id) {
            guard let source = id.split(separator: ":", maxSplits: 1).first,
                  ConnectorSource(rawValue: String(source)) != nil else { continue }
            // Missing its time — first seen gone now, or a record written
            // before the time was kept — means the count starts now.
            let start = state.appDisabledAbsentSince[id] ?? now
            if now.timeIntervalSince(start) >= killPruneInterval { letGo.insert(id) } else { since[id] = start }
        }
        var next = state
        next.appDisabledIDs.removeAll { letGo.contains($0) }
        next.appDisabledAbsentSince = since
        return next
    }
    private static func safeError(_ error: any Error) -> ConnectorAccessError {
        error as? ConnectorAccessError ?? .unavailable
    }
    private func notify() { for observer in observers.values { observer.yield(()) } }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
}
