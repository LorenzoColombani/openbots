import Foundation
import OpenBotsDomain
import OpenBotsRuntime

/// Binds the connector grants a user set to the launch a turn actually runs.
///
/// The store answers "may this bot reach this connector"; a preparation answers
/// "where is that server, and how is it started". This is the only place the
/// two meet, and it is where a turn's own browser profile is made.
///
/// It holds one preparation per connector rather than one for the app: the
/// browser needs a directory of its own and Chrome on the disk, the mail reader
/// needs a console script and nothing else, and each is the only one that can
/// say so about its own row.
public actor ConnectorLaunchService: BotConnectorResolving {
    private let store: ConnectorAccessStore
    private let preparations: [any ConnectorLaunchPreparing]
    private let fence: FenceProxyResource
    /// App-owned, under `.noindex`: high-churn state stays out of Spotlight's index.
    private let profileRootURL: URL
    private let temporaryDirectoryURL: URL

    public init(store: ConnectorAccessStore, preparations: [any ConnectorLaunchPreparing],
                profileRootURL: URL, temporaryDirectoryURL: URL,
                fence: FenceProxyResource = FenceProxyResource()) {
        self.store = store
        self.preparations = preparations
        self.fence = fence
        self.profileRootURL = profileRootURL
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    /// The browser alone.
    public init(store: ConnectorAccessStore, preparation: BrowserConnectorPreparation,
                profileRootURL: URL, temporaryDirectoryURL: URL,
                fence: FenceProxyResource = FenceProxyResource()) {
        self.init(store: store, preparations: [preparation], profileRootURL: profileRootURL,
                  temporaryDirectoryURL: temporaryDirectoryURL, fence: fence)
    }

    /// The most connectors one bot's turn can launch together. Over it,
    /// `connectorAccess` hands back no connectors at all, so the per-bot switch
    /// that would take a bot past it refuses in words instead
    /// (`ConnectorSettingsModel.setSelected`).
    public static let maximumConnectorsPerBot = ClaudeTextConnectorAccess.maximumServerCount

    /// The default home for the browser profiles a turn owns, beside the app's
    /// other high-churn state and never in a synced folder.
    public static func defaultProfileRootURL(applicationSupportRoot: URL) -> URL {
        applicationSupportRoot.appendingPathComponent("BrowserProfiles.noindex", isDirectory: true)
    }

    public func connectorChanges() async -> AsyncStream<Void> { await store.changes() }

    /// Every server key this bot is *granted*, which is not the same as every
    /// one that could launch: a row no preparation owns is granted and still
    /// unlaunchable. Its only consumer compares the launched set against this
    /// one to spot a withdrawal, where a superset can only avoid a false
    /// withdrawal and never miss a real one. Anything that displays this to
    /// the user would need the launchable set instead.
    public func grantedConnectorNames(teammateID: TeammateID) async -> Set<String> {
        guard let lease = await store.lease(teammateID: teammateID),
              let configured = try? await store.configurations(for: lease) else { return [] }
        return Set(configured.map(\.launch.serverKey))
    }

    /// The chats this bot may read in Messages right now, for the watcher that
    /// ends a turn when one it launched with is taken away.
    public func messagesChats(teammateID: TeammateID) async -> AppleMessagesChatScope {
        await store.messagesChats(teammateID: teammateID)
    }

    /// The launch this turn runs with, or nil when the bot has no usable grant.
    ///
    /// Every refusal here is silent and total: a connector that cannot be
    /// prepared is simply not granted for this turn, and the turn runs as the
    /// shipped one. A half-prepared browser is not a degraded mode. The one
    /// refusal the user could cause by hand — more grants than a turn can launch — is
    /// stopped at the switch, where it can be said.
    public func connectorAccess(teammateID: TeammateID, runID: UUID) async -> ClaudeTextConnectorAccess? {
        guard let lease = await store.lease(teammateID: teammateID),
              let configured = try? await store.configurations(for: lease), !configured.isEmpty else { return nil }
        // Nothing is written to the disk in this loop. A directory is only made
        // once this whole function is certain to hand back a launch, because a
        // directory made for a launch that never happens is a directory nothing
        // owns: the reaper only ever sees the access object that was returned.
        // Two ways that used to happen — a connector no preparation handles
        // (browser-use is `uvx`, playwright is a different package), and a
        // grant withdrawn part-way through a multi-connector bot — are both
        // impossible now rather than merely unlikely.
        var servers: [ClaudeTextConnectorServer] = []
        for connector in configured {
            guard let preparation = preparations.first(where: { $0.prepares(connector.launch) })
            else { continue }
            // A fresh profile per turn, wiped when the turn ends, and only for
            // a connector that needs one: the run identifier is in the path
            // because that path is also how the turn's own browser is told
            // from the user's. A mail turn writes nothing at all.
            let profileURL = preparation.needsOwnedProfile
                ? profileRootURL
                    .appendingPathComponent("turn-\(runID.uuidString.lowercased())", isDirectory: true)
                    .appendingPathComponent(connector.launch.serverKey, isDirectory: true)
                : nil
            guard let server = try? preparation.server(for: connector.launch, profileURL: profileURL,
                                                       temporaryDirectoryURL: temporaryDirectoryURL,
                                                       fence: fence)
            else { continue }
            servers.append(server)
        }
        // The lease has to still be the one we resolved against: a switch moved
        // while the disk was being read revokes it, and this turn must not
        // launch on authority that has already been withdrawn.
        guard !servers.isEmpty, await store.isCurrent(lease),
              let access = try? ClaudeTextConnectorAccess(servers: servers) else { return nil }
        // Only now, and if any one of them cannot be made, the whole launch is
        // abandoned and what was made is taken back with it.
        let manager = FileManager()
        for profileURL in access.ownedProfileURLs {
            guard (try? manager.createDirectory(at: profileURL, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])) != nil else {
                for made in access.ownedProfileURLs { try? manager.removeItem(at: made) }
                try? manager.removeItem(at: turnDirectoryURL(runID: runID))
                return nil
            }
        }
        return access
    }

    /// The directory that holds every profile one turn owns.
    private func turnDirectoryURL(runID: UUID) -> URL {
        profileRootURL.appendingPathComponent("turn-\(runID.uuidString.lowercased())", isDirectory: true)
    }

    /// Removes any profile left behind by a turn that never got to clean up —
    /// a crash, a power cut, a force quit. Called at launch, before anything
    /// can be granted.
    public func removeAbandonedProfiles() {
        // No turn runs yet, so any Control this Mac screenshot still in the user's
        // temporary folder was left by one that never got to sweep.
        MacControlScreenshotSweep.remove(modifiedSince: .distantPast)
        let manager = FileManager()
        guard let entries = try? manager.contentsOfDirectory(at: profileRootURL,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("turn-") {
            try? manager.removeItem(at: entry)
        }
    }
}
