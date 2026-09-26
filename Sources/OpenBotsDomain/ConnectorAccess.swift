import Foundation

public enum ConnectorAccessError: Error, Equatable, Sendable {
    case invalidState, staleRevision, revisionExhausted, unavailable, busy, definitionChanged
}

/// Where a catalog row came from. Three sources, and a row's own identity says
/// which: the servers Claude Code has configured on this Mac, the servers the
/// app itself pins and ships, and the Claude Desktop extensions installed on
/// this Mac. The second exists because the catalog contains
/// connectors no plugin provides — Apple Mail, its sender, Messages — and
/// because a plugin row may carry no environment of its own. The third joined
/// later; a build before it leaves those rows out of the record rather than
/// refusing it (`ConnectorAccessState.init(from:)`).
public enum ConnectorSource: String, Codable, Sendable {
    case claudePlugin = "claude-plugin"
    case appOwned = "openbots"
    case claudeExtension = "claude-extension"
}

/// A configured server's namespace and the exact configuration the user chose.
/// No executable, arguments, URL, authentication material or plugin text is saved.
public struct ConnectorIdentity: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let digest: String
    public init(id: String, digest: String) throws {
        self.id = id; self.digest = digest
        guard isValid else { throw ConnectorAccessError.invalidState }
    }

    /// The source named by the identity's first segment, or nil when the
    /// identity is not one this app writes.
    public var source: ConnectorSource? {
        guard let first = id.split(separator: ":", omittingEmptySubsequences: false).first else { return nil }
        return ConnectorSource(rawValue: String(first))
    }

    public var isValid: Bool {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        func validName(_ name: Substring) -> Bool {
            !name.isEmpty && name.utf8.count <= 100
                && name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
        }
        guard parts.count == 3, id.utf8.count <= 320, validName(parts[2]),
              digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return false }
        switch source {
        case .claudePlugin:
            // `claude-plugin:<plugin>@<owner>:<server>` — the plugin's own
            // two-part name, exactly as Claude Code records it.
            let plugin = parts[1].split(separator: "@", omittingEmptySubsequences: false)
            return plugin.count == 2 && plugin.allSatisfy(validName)
        case .appOwned:
            // `openbots:<connector>:<server>` — no owner segment: the app is
            // the owner, and the connector id is the app's own name for it.
            return validName(parts[1]) && !parts[1].contains("@")
        case .claudeExtension:
            // `claude-extension:<folder>:<server>` — the extension's own folder
            // name, as Claude Desktop installed it (`ant.dir.ant.anthropic.notes`).
            return validName(parts[1]) && !parts[1].contains("@")
        case nil:
            return false
        }
    }
}

public enum ConnectorTransport: String, Codable, Sendable { case stdio, http, sse }

/// Whether a row can be turned on at all, and if not, in the user's words why.
///
/// "Needs setup" is something the user
/// can fix from here — a permission, a login, an install — so the switch stays
/// live and turning it on opens the connect card; "unavailable" is something
/// that is simply not on this Mac, and the switch is dead.
public enum ConnectorAvailability: Equatable, Sendable {
    case ready
    case needsSetup(String)
    case unavailable(String)
    /// Unavailable because no part of this build can launch the row at all: a
    /// server Claude Code configured that no preparation of this app owns. It
    /// reads exactly like `unavailable`; it is its own case so that what hangs
    /// on "nothing here runs it" (a bot's Access sheet leaves such a row out)
    /// is decided by the kind of answer, never by comparing its words. Set by
    /// the catalog that asks the preparations, for a row none of them answered
    /// for, and by the Claude Desktop extension catalog, for an extension this
    /// build has not reviewed: no preparation launches either, and the user
    /// cannot fix either.
    case unowned(String)

    public var canBeEnabled: Bool {
        switch self {
        case .ready, .needsSetup: true
        case .unavailable, .unowned: false
        }
    }

    /// Whether no part of this build can launch the row.
    public var isUnowned: Bool {
        if case .unowned = self { return true }
        return false
    }

    /// The badge's words, or nil when a row needs no badge.
    public var badge: String? {
        switch self {
        case .ready: nil
        case .needsSetup: "needs setup"
        case .unavailable, .unowned: "unavailable"
        }
    }

    /// Why the badge is there, for the line under the description.
    public var reason: String? {
        switch self {
        case .ready: nil
        case .needsSetup(let reason), .unavailable(let reason), .unowned(let reason): reason
        }
    }

    /// Where a row of this state belongs in the list the user reads. A row that
    /// works comes first, then one the user can fix, then one this build cannot
    /// drive at all. The order hides nothing: the dead row is still there, at
    /// the bottom, where it is no longer the first thing anyone meets. What a
    /// surface leaves out is that surface's own rule, not the order's: a bot's
    /// Access sheet leaves out an `unowned` row the bot does not have on.
    public var listRank: Int {
        switch self {
        case .ready: 0
        case .needsSetup: 1
        case .unavailable, .unowned: 2
        }
    }
}

/// Nonsecret inventory for presentation. Configured does not mean connected.
public struct ConnectorDefinition: Equatable, Identifiable, Sendable {
    public var id: String { identity.id }
    public let identity: ConnectorIdentity
    public let serverName: String
    public let pluginName: String
    public let transport: ConnectorTransport
    /// What the row is called, in the user's words rather than the server's key.
    public let title: String
    /// The plain two-line description: what it drives, and what it needs.
    public let summary: String
    /// Whether it can be turned on, and why not.
    public let availability: ConnectorAvailability

    public init(identity: ConnectorIdentity, serverName: String, pluginName: String,
                transport: ConnectorTransport, title: String? = nil, summary: String? = nil,
                availability: ConnectorAvailability = .ready) {
        self.identity = identity; self.serverName = serverName; self.pluginName = pluginName
        self.transport = transport
        // A row Claude Code configured has no copy of its own to show, so it
        // keeps reading as it always has: the server's name, and where it came
        // from underneath.
        self.title = title ?? serverName
        self.summary = summary ?? Self.defaultSummary(pluginName: pluginName)
        self.availability = availability
    }
}

extension ConnectorDefinition {
    /// What a row Claude Code configured says about itself when it brought no
    /// words of its own. Named because a decorator that replaces it has to be
    /// able to tell it from prose a source wrote deliberately.
    public static func defaultSummary(pluginName: String) -> String {
        "Configured in Claude Code · \(pluginName)"
    }

    /// The order the list is read in: what works, then what the user can fix,
    /// then what this build cannot drive, and within each the same identity
    /// order the catalog already mints, so two reads of the same state never
    /// reshuffle. Sorted by id alone, a user looking for browsing met
    /// `browser-use` first — a row with a dead switch, sitting above
    /// the browser that works, purely because "b" sorts before "c".
    public static func inListOrder(_ definitions: [ConnectorDefinition]) -> [ConnectorDefinition] {
        definitions.sorted {
            ($0.availability.listRank, $0.id) < ($1.availability.listRank, $1.id)
        }
    }
}

public struct ConnectorBotGrant: Codable, Equatable, Sendable {
    public let teammateID: TeammateID
    public let identity: ConnectorIdentity
    public let enabled: Bool
    /// Off because the row changed underneath it, rather than because the user
    /// turned it off. Recorded rather than inferred: an identity that no
    /// longer matches the catalog was the first guess and it is wrong in both
    /// directions — a switch the user turned off keeps the identity of that
    /// day and later looks changed, and a plugin rolled back to the version
    /// the user allowed matches again and goes silent while the switch is still off.
    public let revokedByChange: Bool
    public init(teammateID: TeammateID, identity: ConnectorIdentity, enabled: Bool,
                revokedByChange: Bool = false) {
        self.teammateID = teammateID; self.identity = identity; self.enabled = enabled
        self.revokedByChange = revokedByChange
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        teammateID = try container.decode(TeammateID.self, forKey: .teammateID)
        identity = try container.decode(ConnectorIdentity.self, forKey: .identity)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        // Written by every save of current builds; absent in a record from an
        // older build, which `ConnectorAccessState.seedingGrantFlags` fills in
        // once from the identity check rather than leaving the user with a row
        // that says nothing.
        revokedByChange = try container.decodeIfPresent(Bool.self, forKey: .revokedByChange) ?? false
    }
}

/// The chats one bot may read through the app's Messages connector, kept in
/// the connector record beside its switch. Kept when the switch goes off, so
/// turning Messages back on gives the bot back the chats the user chose; removed
/// with an empty list, or with the bot.
public struct ConnectorBotMessagesChats: Codable, Equatable, Sendable {
    public let teammateID: TeammateID
    public let chats: AppleMessagesChatScope
    public init(teammateID: TeammateID, chats: AppleMessagesChatScope) {
        self.teammateID = teammateID; self.chats = chats
    }
}

/// A single CAS-protected metadata record. Off switches keep their revision;
/// turning off and on can never resurrect an older running turn's lease.
public struct ConnectorAccessState: Codable, Equatable, Sendable {
    public static let maximumEncodedBytes = 1_048_576
    public static let maximumDefinitions = 256
    public static let maximumGrants = 4096
    public var revision: Int64
    public var appEnabled: Bool
    public var catalog: [ConnectorIdentity]
    public var grants: [ConnectorBotGrant]
    /// Whether `revokedByChange` has been filled in for a record written before
    /// the field existed. One migration, marked, so the guess is made once and
    /// never again — a guess made at every load would keep re-blaming a version
    /// bump for a switch the user turned off.
    public var grantFlagsSeeded: Bool
    /// The connectors the user has switched off for the whole app, by identity id
    /// rather than by identity: killing the browser must stay killed when the
    /// plugin names a new version, which is the one thing a digest cannot do.
    ///
    /// What is stored is the KILLED set, not the allowed one, so a row nobody
    /// has decided on — a new plugin, a row that appears after an update — is
    /// live: a kill-or-live switch. Storing the allowed set instead would
    /// silently kill every grant the user already had the moment this field
    /// arrived.
    public var appDisabledIDs: [String]
    /// The chats each bot may read in Messages, one entry per bot that has
    /// any. A bot with no entry reads none.
    public var messagesChats: [ConnectorBotMessagesChats]
    /// When each killed id was first read missing from the catalog, so a kill
    /// can be let go once its row has been gone for good (90 days). Without it
    /// a plugin the user uninstalled kept its kill forever, and the 257th kill
    /// failed `validate` and took the pane dark. Only killed ids appear here; a row
    /// read again loses its entry, so the count is of one unbroken absence.
    public var appDisabledAbsentSince: [String: Date]
    public init(revision: Int64 = 0, appEnabled: Bool = false,
                catalog: [ConnectorIdentity] = [], grants: [ConnectorBotGrant] = [],
                grantFlagsSeeded: Bool = true, appDisabledIDs: [String] = [],
                messagesChats: [ConnectorBotMessagesChats] = [], appDisabledAbsentSince: [String: Date] = [:]) {
        self.revision = revision; self.appEnabled = appEnabled; self.catalog = catalog; self.grants = grants
        self.grantFlagsSeeded = grantFlagsSeeded; self.appDisabledIDs = appDisabledIDs
        self.messagesChats = messagesChats; self.appDisabledAbsentSince = appDisabledAbsentSince
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(Int64.self, forKey: .revision)
        appEnabled = try container.decode(Bool.self, forKey: .appEnabled)
        // A row from a source this build does not know is left out, with any
        // grant on it: a newer build wrote it, and this is the build the user
        // rolled back to (as when the Claude Desktop extensions became a third
        // source). Kept, it fails `validate` and
        // takes every connector dark; left out, the only loss is that grant,
        // which fails closed. A malformed row from a known source is still
        // refused whole.
        catalog = try container.decode([ConnectorIdentity].self, forKey: .catalog)
            .filter { $0.source != nil }
        grants = try container.decode([ConnectorBotGrant].self, forKey: .grants)
            .filter { $0.identity.source != nil }
        grantFlagsSeeded = try container.decodeIfPresent(Bool.self, forKey: .grantFlagsSeeded) ?? false
        // Absent in every record written by an older build, and absent means
        // nothing is killed. A plain `decode` here would fail such a
        // record outright and take every connector dark with it.
        appDisabledIDs = try container.decodeIfPresent([String].self, forKey: .appDisabledIDs) ?? []
        // Absent in every record written by an older build, and absent means
        // no chats are named, so every bot reads none. A plain `decode`
        // would fail such a record outright and take every connector dark.
        messagesChats = try container.decodeIfPresent([ConnectorBotMessagesChats].self,
                                                      forKey: .messagesChats) ?? []
        // Absent in every record written by an older build, and absent
        // means no count has started: each gone kill starts counting at the
        // next reconciliation, so no kill is ever let go early by the upgrade.
        appDisabledAbsentSince = try container.decodeIfPresent([String: Date].self,
                                                               forKey: .appDisabledAbsentSince) ?? [:]
    }

    /// The one-time fill-in for a record written before the field existed: a
    /// grant that is off while the catalog holds its id at a different digest
    /// was, as far as anything can now tell, turned off by that change, and
    /// starting it at false would show the user nothing.
    public func seedingGrantFlags() -> ConnectorAccessState {
        guard !grantFlagsSeeded else { return self }
        let live = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next = self
        next.grants = grants.map { grant in
            guard !grant.enabled, live[grant.identity.id].map({ $0 != grant.identity }) == true else { return grant }
            return ConnectorBotGrant(teammateID: grant.teammateID, identity: grant.identity,
                                     enabled: false, revokedByChange: true)
        }
        next.grantFlagsSeeded = true
        return next
    }
    public func validate() throws {
        guard revision >= 0, catalog.count <= Self.maximumDefinitions, grants.count <= Self.maximumGrants,
              catalog.allSatisfy(\.isValid), grants.allSatisfy({ $0.identity.isValid }),
              Set(catalog.map(\.id)).count == catalog.count,
              // A killed row outlives the catalog it was killed in, so this is
              // not checked against the catalog — only kept bounded and unique,
              // and each id short enough to be one the app could ever mint.
              appDisabledIDs.count <= Self.maximumDefinitions,
              Set(appDisabledIDs).count == appDisabledIDs.count,
              appDisabledIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 320 }),
              // One entry per bot, never an empty one, each list one that fits.
              messagesChats.count <= Self.maximumGrants,
              Set(messagesChats.map(\.teammateID)).count == messagesChats.count,
              messagesChats.allSatisfy({ !$0.chats.isEmpty && $0.chats.isValid }),
              // A count is kept only for a kill, so un-killing must drop it.
              Set(appDisabledAbsentSince.keys).isSubset(of: appDisabledIDs)
        else { throw ConnectorAccessError.invalidState }
        var keys: Set<String> = []
        for grant in grants {
            // An enabled grant is in the catalog, and says nothing about being
            // revoked: the reason is set only while switching one off and
            // cleared by the user turning it on (stated here rather than left to
            // hold by construction).
            guard keys.insert(grant.teammateID.persistedValue + ":" + grant.identity.id).inserted,
                  !grant.enabled || (catalog.contains(grant.identity) && !grant.revokedByChange)
            else { throw ConnectorAccessError.invalidState }
        }
    }
}

public protocol ConnectorAccessRepository: Sendable {
    func loadConnectorAccess() async throws -> ConnectorAccessState
    /// The next record must advance exactly once from the supplied revision.
    func saveConnectorAccess(_ state: ConnectorAccessState, expectedRevision: Int64) async throws
}

/// Captured by a future runtime launch; usable only while every field still
/// matches the store. A new store/session never accepts a previous lease.
public struct ConnectorAccessLease: Equatable, Sendable {
    public let teammateID: TeammateID
    public let revision: Int64
    public let sessionID: UUID
    public let identities: [ConnectorIdentity]
    public init(teammateID: TeammateID, revision: Int64, sessionID: UUID, identities: [ConnectorIdentity]) {
        self.teammateID = teammateID; self.revision = revision; self.sessionID = sessionID; self.identities = identities
    }
}
