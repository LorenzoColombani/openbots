import Foundation
import OpenBotsDomain
import OpenBotsExecutionRules
import OpenBotsRuntime

/// UI code reaches the capability type through Services without importing the
/// execution-rules module, whose identifier types would shadow the domain's.
public typealias AgenticWebCapability = OpenBotsExecutionRules.AgenticWebCapability

/// One capability with an app-wide master switch AND a per-bot grant. A web
/// capability takes effect in that bot's own chat and team turns as well as
/// inside a sample-folder job; it never starts work on its own, and neither web
/// capability implies the other.
public enum AgenticCapability: Hashable, Sendable, CaseIterable {
    case sampleFolderJobs
    case web(AgenticWebCapability)
    /// "Work on this Mac": Claude Code's file and shell tools in the bot's own
    /// folder and the folders the user added, under the approval card.
    case work
    /// Hiring new bots from the bot's own reply: the app
    /// creates each one, sealed, and never more than three a reply.
    case hire
    /// Background throwaway workers: one-shot blank helpers.
    case workers
    /// Fetcher workers: workers that may use the web (separate grant).
    case fetchers

    public static var allCases: [AgenticCapability] {
        [.sampleFolderJobs] + AgenticWebCapability.allCases.map(AgenticCapability.web)
            + [.work, .hire, .workers, .fetchers]
    }

    /// The row this capability keeps between launches; nil for the jobs switch.
    var stored: AgenticWebSwitchCapability? {
        switch self {
        case .sampleFolderJobs: nil
        case .web(.search): .webSearch
        case .web(.fetch): .webFetch
        case .work: .work
        case .hire: .hire
        case .workers: .workers
        case .fetchers: .fetchers
        }
    }

    /// The switches that come back at launch, in one fixed order.
    static var persisted: [AgenticCapability] { allCases.filter { $0.stored != nil } }

    var logName: String {
        switch self {
        case .sampleFolderJobs: "jobs"
        case .web(let web): web.settingKey
        case .work: "work"
        case .hire: "hire"
        case .workers: "workers"
        case .fetchers: "fetchers"
        }
    }
}

/// Both switches of one capability for one bot, with the revision of each, so
/// a job admitted under one state is stopped by any later change to it.
public struct AgenticCapabilitySwitch: Equatable, Sendable {
    public let appEnabled: Bool
    public let botEnabled: Bool
    public let appRevision: UInt64
    public let botRevision: UInt64
    public var isEnabled: Bool { appEnabled && botEnabled }

    public static let off = AgenticCapabilitySwitch(appEnabled: false, botEnabled: false, appRevision: 0, botRevision: 0)

    public init(appEnabled: Bool, botEnabled: Bool, appRevision: UInt64, botRevision: UInt64) {
        self.appEnabled = appEnabled; self.botEnabled = botEnabled
        self.appRevision = appRevision; self.botRevision = botRevision
    }

    /// True when this reading predates `other` on either switch.
    public func isOlder(than other: Self) -> Bool {
        appRevision < other.appRevision || botRevision < other.botRevision
    }
}

/// Everything a job is admitted under. Equality covers every switch and every
/// revision: a job whose admitted state differs from the current one stops.
public struct AgenticJobAccess: Equatable, Sendable {
    public let jobs: AgenticCapabilitySwitch
    public let webSearch: AgenticCapabilitySwitch
    public let webFetch: AgenticCapabilitySwitch
    public let work: AgenticCapabilitySwitch
    public let hire: AgenticCapabilitySwitch
    public let workers: AgenticCapabilitySwitch
    public let fetchers: AgenticCapabilitySwitch

    public init(jobs: AgenticCapabilitySwitch, webSearch: AgenticCapabilitySwitch = .off,
                webFetch: AgenticCapabilitySwitch = .off, work: AgenticCapabilitySwitch = .off,
                hire: AgenticCapabilitySwitch = .off, workers: AgenticCapabilitySwitch = .off,
                fetchers: AgenticCapabilitySwitch = .off) {
        self.jobs = jobs; self.webSearch = webSearch; self.webFetch = webFetch; self.work = work
        self.hire = hire; self.workers = workers; self.fetchers = fetchers
    }

    public var appEnabled: Bool { jobs.appEnabled }
    public var botEnabled: Bool { jobs.botEnabled }
    public var appRevision: UInt64 { jobs.appRevision }
    public var botRevision: UInt64 { jobs.botRevision }
    /// A sample-folder job is admitted only with both job switches on.
    public var isEnabled: Bool { jobs.isEnabled }

    public func capability(_ capability: AgenticCapability) -> AgenticCapabilitySwitch {
        switch capability {
        case .sampleFolderJobs: jobs
        case .web(let web): self.web(web)
        case .work: work
        case .hire: hire
        case .workers: workers
        case .fetchers: fetchers
        }
    }

    public func web(_ capability: AgenticWebCapability) -> AgenticCapabilitySwitch {
        switch capability {
        case .search: webSearch
        case .fetch: webFetch
        }
    }

    /// Web tools a job admitted under this state may use: each needs its own
    /// master switch AND its own bot grant, independently of the other.
    public var grantedWebCapabilities: Set<AgenticWebCapability> {
        Set(AgenticWebCapability.allCases.filter { web($0).isEnabled })
    }

    public func isOlder(than other: Self) -> Bool {
        jobs.isOlder(than: other.jobs) || webSearch.isOlder(than: other.webSearch)
            || webFetch.isOlder(than: other.webFetch) || work.isOlder(than: other.work)
            || hire.isOlder(than: other.hire) || workers.isOlder(than: other.workers)
            || fetchers.isOlder(than: other.fetchers)
    }
}

/// The native switches. The sample-folder jobs switch is session-local and
/// defaults off after app launch. The two web switches, app-wide and per bot,
/// come back from the app-owned database at launch (`restore(from:)`) and
/// every later change to them is written there at once; a write that fails is
/// reported through the diagnostics log and the live switch still moves. A
/// policy change invalidates an active job's snapshot even if the switch is
/// re-enabled. This is not provider admission or proof of containment.
public actor AgenticJobAccessStore {
    private struct Switch { var enabled = false; var revision: UInt64 = 0 }
    private var app: [AgenticCapability: Switch] = [:]
    private var bots: [OpenBotsDomain.TeammateID: [AgenticCapability: Switch]] = [:]
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// Where the web switches are kept between launches; absent until `restore(from:)`.
    private var repository: (any AgenticWebSwitchRepository)?
    /// Where a granted bot works; absent until composition names it.
    private var workspaces: (any BotWorkspaceResolving)?
    private var connectors: (any BotConnectorResolving)?
    /// Carries each folder change onto this store's own stream, so a watcher
    /// that listens for a switch hears a folder taken away the same way.
    private var workspaceChanges: Task<Void, Never>?
    private var connectorChanges: Task<Void, Never>?
    /// The tail of the write chain. Each write waits for the one before it, so
    /// two quick flips reach the database in the order they were made.
    private var lastWrite: Task<Void, Never>?
    private let reportWriteFailure: @Sendable (String) -> Void

    public init(reportWriteFailure: @escaping @Sendable (String) -> Void = { AgenticDiagnosticsLog.error("web-switch", $0) }) {
        self.reportWriteFailure = reportWriteFailure
    }

    public func current(teammateID: OpenBotsDomain.TeammateID) -> AgenticJobAccess {
        func state(_ capability: AgenticCapability) -> AgenticCapabilitySwitch {
            let master = app[capability] ?? Switch(), bot = bots[teammateID]?[capability] ?? Switch()
            return AgenticCapabilitySwitch(appEnabled: master.enabled, botEnabled: bot.enabled,
                appRevision: master.revision, botRevision: bot.revision)
        }
        return AgenticJobAccess(jobs: state(.sampleFolderJobs), webSearch: state(.web(.search)),
                                webFetch: state(.web(.fetch)), work: state(.work), hire: state(.hire),
                                workers: state(.workers), fetchers: state(.fetchers))
    }

    public func setAppEnabled(_ enabled: Bool, capability: AgenticCapability = .sampleFolderJobs) {
        let current = app[capability] ?? Switch()
        guard current.enabled != enabled else { return }
        let next = Self.advanced(current, to: enabled)
        app[capability] = next
        notify()
        if let stored = capability.stored {
            persist("app-wide \(capability.logName) \(next.enabled ? "on" : "off")") {
                try await $0.setAppWebSwitch(stored, enabled: next.enabled)
            }
        }
    }

    public func setBotEnabled(_ enabled: Bool, capability: AgenticCapability = .sampleFolderJobs,
                              teammateID: OpenBotsDomain.TeammateID) {
        let current = bots[teammateID]?[capability] ?? Switch()
        guard current.enabled != enabled else { return }
        let next = Self.advanced(current, to: enabled)
        bots[teammateID, default: [:]][capability] = next
        notify()
        if let stored = capability.stored {
            persist("bot \(teammateID) \(capability.logName) \(next.enabled ? "on" : "off")") {
                try await $0.setBotWebSwitch(stored, enabled: next.enabled, teammateID: teammateID)
            }
        }
    }

    /// The browser a granted bot may drive, bridged onto `changes()` the same
    /// way the folders are: a connector taken away is a grant taken away, and a
    /// turn already using it has to end.
    public func configureConnectors(_ resolver: any BotConnectorResolving) {
        connectors = resolver
        connectorChanges?.cancel()
        connectorChanges = Task { [weak self] in
            let changes = await resolver.connectorChanges()
            for await _ in changes {
                if Task.isCancelled { return }
                await self?.notify()
            }
        }
    }

    /// Where a granted bot works. Set once at composition; until then a work
    /// switch that is on grants nothing, because there is no folder to grant.
    /// From here on, a folder added or removed reaches every observer of
    /// `changes()`: the folders are part of what a work turn is launched
    /// with, and a change to them is a change to the grant.
    public func configureWorkspaces(_ resolver: any BotWorkspaceResolving) {
        workspaces = resolver
        workspaceChanges?.cancel()
        workspaceChanges = Task { [weak self] in
            let changes = await resolver.workspaceChanges()
            for await _ in changes {
                if Task.isCancelled { return }
                await self?.notify()
            }
        }
    }

    /// Brings back the web switches that were on when the app last ran, and
    /// writes every later change to `repository`. A restored "on" is a switch
    /// just turned on: its revision starts at 1 and observers are told, so a
    /// model or a withdrawal watcher reads it the way it reads a live flip. A
    /// web switch already moved in this session keeps its live value and is
    /// written through now. The jobs switch is neither read nor written.
    public func restore(from repository: any AgenticWebSwitchRepository) async {
        self.repository = repository
        var stored = AgenticWebSwitchSnapshot()
        do { stored = try await repository.loadWebSwitches() }
        catch { reportWriteFailure("restore failed, every web switch starts off: \(Self.describe(error))") }
        // The bot switches moved in this session, read before anything is
        // restored, so a restored grant is not written straight back.
        let touchedBots = bots
        var changed = false
        for capability in AgenticCapability.persisted {
            guard let row = capability.stored else { continue }
            if let touched = app[capability], touched.revision > 0 {
                persist("app-wide \(capability.logName) \(touched.enabled ? "on" : "off")") {
                    try await $0.setAppWebSwitch(row, enabled: touched.enabled)
                }
            } else if stored.app.contains(row) {
                app[capability] = Switch(enabled: true, revision: 1)
                changed = true
            }
        }
        for (teammateID, grants) in stored.bots {
            for capability in AgenticCapability.persisted {
                guard let row = capability.stored, grants.contains(row),
                      (touchedBots[teammateID]?[capability]?.revision ?? 0) == 0 else { continue }
                bots[teammateID, default: [:]][capability] = Switch(enabled: true, revision: 1)
                changed = true
            }
        }
        for (teammateID, switches) in touchedBots {
            for capability in AgenticCapability.persisted {
                guard let row = capability.stored, let touched = switches[capability], touched.revision > 0 else { continue }
                persist("bot \(teammateID) \(capability.logName) \(touched.enabled ? "on" : "off")") {
                    try await $0.setBotWebSwitch(row, enabled: touched.enabled, teammateID: teammateID)
                }
            }
        }
        if changed { notify() }
    }

    /// Returns once every write queued so far has landed or been reported, so
    /// the quit path and a test read the database after the last change.
    public func waitForPendingWrites() async {
        await lastWrite?.value
    }

    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        }
    }

    /// A switch that cannot advance its revision any further falls to off.
    private static func advanced(_ value: Switch, to enabled: Bool) -> Switch {
        guard value.revision < UInt64.max else { return Switch(enabled: false, revision: value.revision) }
        return Switch(enabled: enabled, revision: value.revision + 1)
    }

    /// Queues one write behind the last. Nothing is queued before `restore(from:)`
    /// has named the repository; a write that throws is reported, never retried.
    private func persist(_ change: String, _ write: @escaping @Sendable (any AgenticWebSwitchRepository) async throws -> Void) {
        guard let repository else { return }
        let previous = lastWrite, report = reportWriteFailure
        lastWrite = Task {
            await previous?.value
            do { try await write(repository) }
            catch { report("\(change) was not saved: \(Self.describe(error))") }
        }
    }

    private static func describe(_ error: any Error) -> String {
        String(String(describing: error).prefix(160))
    }

    private func notify() { for observer in observers.values { observer.yield(()) } }
    private func remove(_ id: UUID) { observers[id] = nil }
}

/// Resolves the folders a bot may work in. The switch store asks it only for a
/// bot whose two work switches are both on.
/// What a bot may reach outside the Mac. Separate from the workspace seam
/// because browsing is its own switch: a bot may browse with files and shell
/// switched off, and the two are never read together.
public protocol BotConnectorResolving: Sendable {
    func connectorAccess(teammateID: OpenBotsDomain.TeammateID, runID: UUID) async -> ClaudeTextConnectorAccess?
    func grantedConnectorNames(teammateID: OpenBotsDomain.TeammateID) async -> Set<String>
    /// The chats this bot may read in Messages right now.
    func messagesChats(teammateID: OpenBotsDomain.TeammateID) async -> AppleMessagesChatScope
    /// Yields whenever a connector grant, the app master, or the catalog moves.
    func connectorChanges() async -> AsyncStream<Void>
}

public protocol BotWorkspaceResolving: Sendable {
    func workAccess(teammateID: OpenBotsDomain.TeammateID) async -> ClaudeTextWorkAccess?
    /// What a turn without Work may read: the shared folder and the bot's skills.
    func readAccess(teammateID: OpenBotsDomain.TeammateID) async -> ClaudeTextReadAccess?
    /// Yields whenever a bot's folders change: one added or removed.
    func workspaceChanges() async -> AsyncStream<Void>
}

public extension BotWorkspaceResolving {
    func readAccess(teammateID: OpenBotsDomain.TeammateID) async -> ClaudeTextReadAccess? { nil }
}

extension AgenticJobAccessStore {
    /// What a turn without Work may read: every bot reads the shared folder
    /// and its skills. Not gated on any
    /// switch; a turn with Work reads through its own folders instead.
    public func readAccess(teammateID: OpenBotsDomain.TeammateID) async -> ClaudeTextReadAccess? {
        guard let workspaces else { return nil }
        return await workspaces.readAccess(teammateID: teammateID)
    }

    /// The browser this turn may drive, or nil when no connector service was
    /// configured or the bot has no grant. Deliberately not gated on any web or
    /// work switch: the connector has its own pair, kept by the connector
    /// store, and browsing must work with files and shell off.
    public func connectorAccess(teammateID: OpenBotsDomain.TeammateID, runID: UUID) async -> ClaudeTextConnectorAccess? {
        guard let connectors else { return nil }
        return await connectors.connectorAccess(teammateID: teammateID, runID: runID)
    }

    public func grantedConnectorNames(teammateID: OpenBotsDomain.TeammateID) async -> Set<String> {
        guard let connectors else { return [] }
        return await connectors.grantedConnectorNames(teammateID: teammateID)
    }

    public func messagesChats(teammateID: OpenBotsDomain.TeammateID) async -> AppleMessagesChatScope {
        guard let connectors else { return .init(guids: []) }
        return await connectors.messagesChats(teammateID: teammateID)
    }

    /// Whether this bot may hire right now: the app-wide hire switch AND its
    /// own. Read when a reply begins; that reading holds until the reply ends.
    public func hireGranted(teammateID: OpenBotsDomain.TeammateID) async -> Bool {
        current(teammateID: teammateID).hire.isEnabled
    }

    /// Whether this bot may spawn background workers right now.
    public func workersGranted(teammateID: OpenBotsDomain.TeammateID) async -> Bool {
        current(teammateID: teammateID).workers.isEnabled
    }

    /// Whether this bot's workers may use the web (fetcher grant).
    public func fetchersGranted(teammateID: OpenBotsDomain.TeammateID) async -> Bool {
        current(teammateID: teammateID).fetchers.isEnabled
    }

    /// The folders a work turn for this bot may reach, or nil when either
    /// work switch is off or no workspace service was configured.
    public func workAccess(teammateID: OpenBotsDomain.TeammateID) async -> ClaudeTextWorkAccess? {
        guard current(teammateID: teammateID).work.isEnabled, let workspaces else { return nil }
        return await workspaces.workAccess(teammateID: teammateID)
    }
}
