import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices
import SwiftUI

/// One Access sheet per bot, instead of four switches across two windows to
/// let one bot read Gmail. Everything this bot may do, one row each with its own switch:
/// Work on this Mac, web search, web fetch, hiring, and every connector the
/// app lists except one nothing in this build can run that this bot does not
/// have on. Each row says, in words, when its app-wide master is off and where
/// that master lives, and a connector nothing in this build can run says its
/// switch does nothing, so a switch that is on but does nothing is never a
/// mystery.
///
/// Learned from the old app's profile sheet, which held every switch a seat
/// had (`AgentProfileSheet.swift:268-409` in the legacy app), re-expressed
/// over this app's two stores: the switch store the Details pane and Settings
/// already write for work and web, and the connector store they write for
/// connectors. This model owns no state of its own; it is two readers and two
/// writers over those stores, so a switch moved here is the switch Details
/// shows, and the other way round. Settings keeps the app-wide masters and the
/// connector import and connect, untouched.
@MainActor
public final class BotAccessModel: ObservableObject, Identifiable {
    public let id: UUID
    public let teammateID: TeammateID
    public let botName: String
    private let switches: AgenticJobAccessModel?
    private let connectors: ConnectorSettingsModel?
    /// Whether the two worker rows are listed; see `AgenticWorkerAvailability`.
    private let includesWorkers: Bool
    private var forwarding: [AnyCancellable] = []
    /// The user's Messages conversations, for choosing the chats this bot may read.
    private let messages: (any MessagesChatDirectory)?
    /// The user's conversations as the picker lists them, newest first; nil until
    /// read, and nil when the history cannot be read here.
    @Published public private(set) var messagesChoices: [MessagesChatChoice]?
    @Published public private(set) var messagesHistoryIsUnreadable = false
    @Published public private(set) var contactNames: MessagesContactNames = .refused

    public init(teammateID: TeammateID, botName: String,
                switches: AgenticJobAccessStore?, connectors: ConnectorAccessStore?,
                includesWorkers: Bool = AgenticWorkerAvailability.runsInThisBuild,
                messages: (any MessagesChatDirectory)? = nil) {
        self.teammateID = teammateID
        id = teammateID.rawValue
        self.botName = botName
        self.includesWorkers = includesWorkers
        self.messages = messages
        self.switches = switches.map { AgenticJobAccessModel(store: $0) }
        self.connectors = connectors.map { ConnectorSettingsModel(store: $0, teammateID: teammateID) }
        // The rows are read off the two child models, so their changes are
        // this model's changes.
        self.switches?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwarding)
        self.connectors?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwarding)
    }

    /// Points both readers at this bot and reads once. Safe to call again.
    public func load() async {
        switches?.selectTeammate(teammateID)
        await switches?.refresh()
        await connectors?.load()
        await loadMessagesChats()
    }

    // MARK: The chats this bot may read in Messages

    /// Reads the user's conversations, for the Messages row's line and the picker.
    /// Only when the sheet lists the app's Messages row.
    public func loadMessagesChats() async {
        guard let messages, messagesRowID != nil else { return }
        let listed = await messages.choices()
        messagesChoices = listed
        messagesHistoryIsUnreadable = listed == nil
        contactNames = await messages.contactNames()
    }

    /// The row of the app's own Messages connector, when the sheet lists it.
    public var messagesRowID: String? {
        guard let connectors,
              connectors.reading.definitions.contains(where: { $0.id == AppOwnedConnectorCatalog.messagesConnectorID })
        else { return nil }
        return "connector:\(AppOwnedConnectorCatalog.messagesConnectorID)"
    }

    /// Whether this row carries the Choose Chats button: the Messages row,
    /// once the user's history has been read.
    public func offersChatChoice(rowID: String) -> Bool {
        rowID == messagesRowID && messagesChoices != nil
    }

    /// The chats this bot reads now, as stored.
    public var chosenMessagesChats: AppleMessagesChatScope {
        connectors?.reading.messagesChats ?? .init(guids: [])
    }

    /// The chats this bot reads, in the words the user knows them by and in the
    /// picker's order; one Messages no longer keeps is said as such.
    public var chosenChatTitles: [String] {
        let chosen = Set(chosenMessagesChats.guids)
        // Before the history is read: the address each is filed under.
        guard let choices = messagesChoices else {
            return chosenMessagesChats.guids.map { String($0.split(separator: ";", maxSplits: 2).last ?? Substring($0)) }
        }
        let listed = choices.filter { chosen.contains($0.guid) }.map(\.title)
        let gone = chosen.subtracting(choices.map(\.guid))
        return listed + Array(repeating: BotAccessCopy.chatGone, count: gone.count)
    }

    /// The line under the Messages row.
    var messagesChatsLine: String {
        if messagesHistoryIsUnreadable { return BotAccessCopy.messagesHistoryUnreadable }
        return chosenMessagesChats.isEmpty ? BotAccessCopy.messagesNoChats
            : BotAccessCopy.messagesChats(chosenChatTitles)
    }

    public func setMessagesChats(_ guids: Set<String>) async {
        await connectors?.setMessagesChats(guids)
    }

    /// Asks macOS for Contacts, which asks the user once; only their press calls it.
    public func askForContactNames() async {
        guard let messages else { return }
        await messages.askForContactNames()
        await loadMessagesChats()
    }

    /// Re-reads both stores at once, for a caller that just wrote one.
    public func refresh() async {
        await switches?.refresh()
        await connectors?.reload()
    }

    public func stopObserving() {
        connectors?.stopObserving()
        forwarding.removeAll()
    }

    /// Every switch this bot has, once each, in the order the user reads them: the
    /// Mac, the web, then the connectors as the catalog lists them.
    public var rows: [BotAccessRow] {
        var rows: [BotAccessRow] = []
        if let switches {
            let selected = switches.teammateID == teammateID
            let frozen = !selected || !switches.isReady || switches.isUpdating
            rows.append(BotAccessRow(
                kind: .work, group: .mac, title: "Work on this Mac", summary: BotAccessCopy.workSummary,
                isOn: selected && switches.workBotEnabled, masterIsOn: switches.workAppEnabled,
                masterNote: switches.workAppEnabled ? nil : BotAccessCopy.masterOff(.permissions),
                badge: nil, notes: [], isFrozen: frozen))
            for capability in AgenticWebCapability.allCases {
                let masterIsOn = switches.webAppEnabled(capability)
                rows.append(BotAccessRow(
                    kind: .web(capability), group: .web, title: capability.displayName,
                    summary: BotAccessCopy.webSummary(capability),
                    isOn: selected && switches.webBotEnabled(capability), masterIsOn: masterIsOn,
                    masterNote: masterIsOn ? nil : BotAccessCopy.masterOff(.permissions),
                    badge: nil, notes: [], isFrozen: frozen))
            }
            rows.append(BotAccessRow(
                kind: .hire, group: .team, title: "Hire new bots", summary: BotAccessCopy.hireSummary,
                isOn: selected && switches.hireBotEnabled, masterIsOn: switches.hireAppEnabled,
                masterNote: switches.hireAppEnabled ? nil : BotAccessCopy.masterOff(.permissions),
                badge: nil, notes: [], isFrozen: frozen))
        }
        if let switches, includesWorkers {
            let selected = switches.teammateID == teammateID
            let frozen = !selected || !switches.isReady || switches.isUpdating
            rows.append(BotAccessRow(
                kind: .workers, group: .team, title: "Background workers", summary: BotAccessCopy.workersSummary,
                isOn: selected && switches.workersBotEnabled, masterIsOn: switches.workersAppEnabled,
                masterNote: switches.workersAppEnabled ? nil : BotAccessCopy.masterOff(.permissions),
                badge: nil, notes: [], isFrozen: frozen))
            rows.append(BotAccessRow(
                kind: .fetchers, group: .team, title: "Fetcher workers", summary: BotAccessCopy.fetchersSummary,
                isOn: selected && switches.fetchersBotEnabled, masterIsOn: switches.fetchersAppEnabled,
                masterNote: switches.fetchersAppEnabled ? nil : BotAccessCopy.masterOff(.permissions),
                badge: nil, notes: [], isFrozen: frozen))
        }
        if let connectors {
            let reading = connectors.reading
            for definition in reading.definitions {
                let isOn = reading.selectedIDs.contains(definition.id)
                guard Self.listsOnBotSheet(definition, isOn: isOn) else { continue }
                let unowned = definition.availability.isUnowned
                let killed = reading.appDisabledIDs.contains(definition.id)
                let masterIsOn = reading.appEnabled && !killed
                // The broader master first: with every connector off for the
                // app, naming this one row's own kill switch would send the user
                // to the wrong switch. A row nothing in this build can run
                // gets no master sentence at all: "counts once that one is on"
                // would be false for it, and its own note already says the
                // switch does nothing whatever the app-wide switches say.
                let masterNote: String? = !reading.isAvailable || unowned ? nil
                    : !reading.appEnabled ? BotAccessCopy.masterOff(.connectors)
                    : killed ? ConnectorCopy.appWideOff : nil
                var notes: [String] = []
                if unowned { notes.append(BotAccessCopy.unownedConnectorOn) }
                else if let reason = definition.availability.reason { notes.append(reason) }
                if reading.changedSinceAllowed.contains(definition.id) { notes.append(ConnectorCopy.botChanged) }
                // Messages reads by number or address, and a bot finds those
                // through Contacts.
                if definition.id == AppOwnedConnectorCatalog.messagesConnectorID, isOn,
                   reading.definitions.contains(where: { $0.id == AppOwnedConnectorCatalog.contactsConnectorID
                       && $0.availability.canBeEnabled }),
                   !reading.selectedIDs.contains(AppOwnedConnectorCatalog.contactsConnectorID) {
                    notes.append(BotAccessCopy.messagesNeedsContacts)
                }
                // Which chats it reads, said last, where Choose Chats sits.
                if definition.id == AppOwnedConnectorCatalog.messagesConnectorID, messages != nil {
                    notes.append(messagesChatsLine)
                }
                // Such a row is listed only while it is on, and its switch is
                // live so it can be turned off, killed app-wide or not: the
                // grant can never be used here, and left alone it would carry
                // into a later build that can run it with no hand on the
                // switch. Turning it on stays refused where the write happens
                // (`ConnectorSettingsModel.setSelected`), since the row can
                // never be enabled. Every other row freezes as Settings'
                // model says.
                let isFrozen = unowned
                    ? connectors.isWorking || !reading.isAvailable
                    : connectors.botSwitchIsFrozen(definition)
                rows.append(BotAccessRow(
                    kind: .connector(definition.id), group: .connectors, title: definition.title,
                    summary: definition.summary, isOn: isOn,
                    masterIsOn: masterIsOn, masterNote: masterNote, badge: definition.availability.badge,
                    notes: notes, isFrozen: isFrozen))
            }
        }
        return rows
    }

    public func row(_ id: String) -> BotAccessRow? { rows.first { $0.id == id } }

    /// A connector that no part of this build can launch — one Claude Code
    /// configured that this app has no way to run — is left off a bot's sheet
    /// unless this bot has it on. Off, its switch could only ever read as
    /// something switched off: Claude Code's own "imessage — unavailable" row
    /// read as iMessage not being enabled, beside the app's own Messages row,
    /// which is the one that sends and reads. On, it is listed so it can be
    /// switched off: otherwise a bot could keep such a grant that no surface
    /// could reach. Settings → Connectors & Skills lists it always, because the
    /// app-wide switch is the user's. An app-owned row that cannot run
    /// today keeps its place and its reason ("Messages is not installed on this
    /// Mac"): that is something to act on.
    static func listsOnBotSheet(_ definition: ConnectorDefinition, isOn: Bool) -> Bool {
        // The kind of answer, never its words: a row a preparation owns keeps
        // its place even when its reason reads like the unowned sentence.
        !definition.availability.isUnowned || isOn
    }

    /// Whether the sheet has a connectors part at all: only when the app keeps
    /// a connector store, whatever it currently lists.
    public var showsConnectors: Bool { connectors != nil }
    /// The catalog is readable and the sheet draws no connector row, read off
    /// the rows themselves so it can never disagree with what is drawn.
    public var connectorsAreEmpty: Bool {
        guard let connectors else { return false }
        return connectors.reading.isAvailable && !connectors.isWorking
            && !rows.contains { $0.group == .connectors }
    }
    /// The sentence the sheet shows when it draws no connector row: nothing is
    /// listed at all, or everything listed is a row nothing in this build can
    /// run and this bot has none of them on. Nil while a connector row is drawn.
    public var connectorsEmptyNote: String? {
        guard connectorsAreEmpty, let connectors else { return nil }
        return connectors.reading.definitions.isEmpty ? BotAccessCopy.noConnectors : BotAccessCopy.noRunnableConnectors
    }
    /// The connector store could not be read; every connector row is frozen.
    public var connectorsAreUnreadable: Bool {
        guard let connectors else { return false }
        return !connectors.reading.isAvailable && !connectors.isWorking
    }
    /// What the connector model has to say after a write, if anything.
    public var connectorNotice: String? { connectors?.notice }

    /// Moves one switch. The write goes to the store the row came from: the
    /// switch store for work and web, the connector store for a connector.
    public func setOn(_ on: Bool, rowID: String) async {
        guard let row = row(rowID) else { return }
        switch row.kind {
        case .work:
            await switches?.setWorkBotEnabled(on, teammateID: teammateID)
        case .web(let capability):
            await switches?.setWebBotEnabled(on, capability: capability, teammateID: teammateID)
        case .hire:
            await switches?.setHireBotEnabled(on, teammateID: teammateID)
        case .workers:
            await switches?.setWorkersBotEnabled(on, teammateID: teammateID)
        case .fetchers:
            await switches?.setFetchersBotEnabled(on, teammateID: teammateID)
        case .connector(let id):
            guard let connectors, let definition = connectors.reading.definitions.first(where: { $0.id == id }) else { return }
            await connectors.setSelected(on, definition: definition)
        }
    }
}

/// One switch on the sheet, read off the stores; never state of its own.
public struct BotAccessRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case work
        case web(AgenticWebCapability)
        case hire
        case workers
        case fetchers
        case connector(String)
    }
    /// The headings the rows sit under, in reading order.
    public enum Group: String, CaseIterable, Equatable, Sendable {
        case mac = "On this Mac"
        case web = "Web"
        case team = "Team"
        case connectors = "Connectors"
    }

    public let kind: Kind
    public let group: Group
    public let title: String
    public let summary: String
    /// This bot's own switch.
    public let isOn: Bool
    /// The app-wide switch of the same kind, read from Settings' store.
    public let masterIsOn: Bool
    /// In words, when the master is off: what did not happen and where the
    /// master lives. Nil while the master is on, and on a connector nothing in
    /// this build can run, whose own note says its switch does nothing.
    public let masterNote: String?
    /// The connector's Settings badge — "needs setup", "unavailable" — where one exists.
    public let badge: String?
    /// Why the badge is there, and whether the row changed since it was allowed.
    public let notes: [String]
    /// The switch cannot move: the store is unreadable, a write is in flight,
    /// the row cannot be driven by this build, or a connector was killed app-wide.
    /// The one exception is a connector nothing in this build can run, which is
    /// listed only while it is on: its switch moves, and only to off.
    public let isFrozen: Bool

    /// The Settings pane the master sentence names, for the Open Settings
    /// button beside it. Nil exactly when there is no sentence.
    public var masterPane: BotAccessMasterPane? {
        guard masterNote != nil else { return nil }
        // A connector's master, app-wide or its own kill switch, is in
        // Connectors & Skills; every other master is in Permissions.
        if case .connector = kind { return .connectors }
        return .permissions
    }

    public var id: String {
        switch kind {
        case .work: "work"
        case .web(let capability): capability.settingKey
        case .hire: "hire"
        case .workers: "workers"
        case .fetchers: "fetchers"
        case .connector(let id): "connector:\(id)"
        }
    }

    /// The same identifiers the Details switches carried, so a driver that
    /// found a switch there finds it here.
    public var accessibilityIdentifier: String {
        switch kind {
        case .work: "agentic.bot.work"
        case .web(let capability): "agentic.bot.\(capability.settingKey)"
        case .hire: "agentic.bot.hire"
        case .workers: "agentic.bot.workers"
        case .fetchers: "agentic.bot.fetchers"
        case .connector(let id): "connectors.server.\(id)"
        }
    }
}

/// Where a row's app-wide master lives, so the sentence under a row sends the user
/// to the right pane of Settings.
public enum BotAccessMasterPane: Equatable, Sendable {
    case permissions
    case connectors

    /// The pane's own name, so the sentence and the pane cannot drift apart.
    var settingsName: String { settingsSection.rawValue }

    /// The pane Open Settings selects. It only opens the pane: turning a
    /// master on stays the user's own press in Settings, app-wide and per bot.
    public var settingsSection: WorkspaceSettingsSection {
        switch self {
        case .permissions: .permissions
        case .connectors: .connectors
        }
    }
}

/// Whether a throwaway worker can run in this build. The two worker switches
/// arrived with the foundation before the host channel, the worker's blank run
/// and the holder's wake, and a bot's switches ship as their features land, so
/// the Access sheet, the Details line and Settings left them out until all
/// three landed. False again would hide both switches.
public enum AgenticWorkerAvailability {
    public static let runsInThisBuild = true
}

/// The sentences the sheet and the Details summary say, named so a test can
/// read them (a string inside a view body is the one thing nothing in this
/// repo can assert on).
public enum BotAccessCopy {
    /// Under a row whose app-wide master is off. Names what did not happen and
    /// where the master lives; the bot's own choice is kept, as it is today.
    /// It promises no more than that: a needs-setup or unavailable connector
    /// row still does not work once the master is on.
    public static func masterOff(_ pane: BotAccessMasterPane) -> String {
        "Off for the whole app in Settings → \(pane.settingsName). "
            + "This bot's switch is kept and counts once that one is on."
    }
    /// Beside a master sentence: opens that Settings pane and nothing more.
    public static let openSettings = "Open Settings"
    /// Under the Messages row: the bot reads only the chats the user chose.
    public static let messagesNoChats = "Reads none of your chats yet. Choose the ones it may read."
    /// Under the Messages row while Contacts is off for this bot: a bot finding
    /// someone's texts by name needs both the Contacts and the Messages connector.
    public static let messagesNeedsContacts = "To find someone's texts by their name, turn on Contacts for this bot too. "
        + "Without it, it needs their number or email address."
    public static func messagesChats(_ titles: [String]) -> String {
        var said = titles.prefix(3).joined(separator: ", ")
        if titles.count > 3 { said += " and \(titles.count - 3) more" }
        return "Reads only these chats: \(said)."
    }
    /// Said when the history will not open. Full Disk Access is the usual
    /// reason but not the only one SQLite gives the same answer for, so the
    /// sentence names it as the thing to check rather than the cause.
    public static let messagesHistoryUnreadable = "Your Messages history cannot be read from here, so no chat "
        + "can be chosen yet. Check that OpenBots Next is on in System Settings, Privacy & Security, Full Disk Access."
    /// A chat the user chose that Messages no longer keeps.
    public static let chatGone = "A chat no longer in Messages"
    public static let chooseChats = "Choose Chats…"
    public static func pickerTitle(_ botName: String) -> String { "Chats \(botName) may read" }
    public static func pickerCaption(_ botName: String) -> String {
        "\(botName) reads only the chats ticked here. The rest of Messages stays closed to it, and every text "
            + "it sends still asks you first."
    }
    public static func pickerCount(_ count: Int) -> String {
        "\(count) of \(AppleMessagesChatScope.maximumChats) chosen"
    }
    public static let pickerLimit = "A bot can read at most \(AppleMessagesChatScope.maximumChats) chats. "
        + "Untick one to choose another."
    public static let showContactNames = "Show Names from Contacts"
    /// Said when macOS keeps Contacts closed to the app. It sends the user to no
    /// switch: on a Mac that has never been asked, the hardened-runtime app
    /// cannot raise the Contacts prompt without the Contacts entitlement, so
    /// there may be nothing in System Settings to turn on. Where Contacts is
    /// allowed this is never shown.
    public static let contactNamesOff = "Names from Contacts are not shown: macOS does not let OpenBots Next read "
        + "Contacts. Each chat is listed by its number or address."
    public static let sheetCaption = "Each switch here is this bot's own. The app-wide switches stay in Settings, "
        + "and the bot can use something only when both are on."
    /// Under a connector nothing in this build can run, listed only while this
    /// bot has it on.
    public static let unownedConnectorOn = "Nothing in this version of OpenBots Next can run this connector, "
        + "so this switch does nothing. You can switch it off, and then the row leaves this sheet. "
        + "It cannot be switched back on."
    /// The sheet's empty line when the catalog lists nothing at all.
    public static let noConnectors = "No connectors are set up on this Mac yet."
    /// The sheet's empty line when every connector listed is one nothing in
    /// this build can run and this bot has none of them on ("no connectors are
    /// set up" would be false then, and Settings lists exactly those rows).
    public static let noRunnableConnectors = "None of the connectors on this Mac can be run by this version of "
        + "OpenBots Next, so this bot has none to switch on. Settings → Connectors & Skills lists them, each with the reason."
    public static let connectorsUnreadable = "Connector settings could not be read. "
        + "Reload the list under Settings → Connectors & Skills."
    /// Under the Access button in Details. It names what the sheet holds and
    /// promises no more: the sheet leaves out a connector nothing in this build
    /// can run unless the bot has it on, and it shows a sentence, not a switch,
    /// where a master is off.
    public static let detailsCaption = "This bot's own switches for Work on this Mac, web search, web fetch, "
        + (AgenticWorkerAvailability.runsInThisBuild ? "hiring, workers" : "hiring")
        + " and connectors, in one place. The app-wide switches stay in Settings."
    /// The same line where the app keeps no connector store.
    public static let detailsCaptionWithoutConnectors = "This bot's own switches for Work on this Mac, "
        + (AgenticWorkerAvailability.runsInThisBuild ? "web search, web fetch, hiring and workers" : "web search, web fetch and hiring")
        + ", in one place. The app-wide switches stay in Settings."
    /// The hire row: what a hire does and what the new bot starts with.
    public static let hireSummary = "Ask OpenBots for a new bot from its own replies, at most three a reply. "
        + "A new bot starts with every switch off and no connectors; like every bot, it reads the team's shared folder "
        + "and the skills you give it. " + hireOffTakesEffect
    /// Turning hiring off never cuts a reply short, and the switch says so;
    /// the workers and fetchers switches the same.
    public static let hireOffTakesEffect = "Turned off while the bot is answering, it takes effect when that reply ends."
    public static let workersSummary = "Start a one-time background worker for a chore no other bot owns, like "
        + "summarising some files. A worker has no chat, no memory and no place in the sidebar. It ends after one reply, "
        + "and this bot answers you with what it found. Needs Work on this Mac or web. " + hireOffTakesEffect
    public static let fetchersSummary = "Let this bot's workers use its own web search and fetch. "
        + "Pages they read are data, never instructions. Needs this bot's web switches. " + hireOffTakesEffect
    /// The one line Details keeps: what is effectively on for the selected bot.
    @MainActor public static func switchSummary(_ switches: AgenticJobAccessModel,
                                                includesWorkers: Bool = AgenticWorkerAvailability.runsInThisBuild) -> String {
        let work = "Work on this Mac \(switches.workIsEnabled ? "on" : "off")"
        let web = AgenticWebCapability.allCases.map { "\($0.displayName) \(switches.webIsEnabled($0) ? "on" : "off")" }
        let hire = "Hiring \(switches.hireIsEnabled ? "on" : "off")"
        // The sheet's own row title, so the summary and the switch it names
        // read the same ("Fetchers" alone named nothing).
        let workers = includesWorkers ? ["Workers \(switches.workersIsEnabled ? "on" : "off")",
                                         "Fetcher workers \(switches.fetchersIsEnabled ? "on" : "off")"] : []
        return ([work] + web + [hire] + workers).joined(separator: " · ") + "."
    }
    /// The own-folder rule is `AgenticWebCopy.ownFolderRule`, one sentence
    /// for every surface that states it, so the row and the Settings caption
    /// cannot drift apart again.
    static let workSummary = "Read, write and run commands in its own folder and the folders you add to it, as you. "
        + AgenticWebCopy.ownFolderRule
    static func webSummary(_ capability: AgenticWebCapability) -> String {
        switch capability {
        case .search: "Look things up on the web, in its conversations."
        case .fetch: "Read one web page it names, in its conversations."
        }
    }
}

/// The sheet itself: a heading with the bot's name, the rows under three
/// headings, Done. Opened from the Access button in Details and from the
/// sidebar row's menu.
public struct BotAccessSheet: View {
    @ObservedObject private var model: BotAccessModel
    private let onDone: @MainActor () -> Void
    /// Opens Settings on one pane, for the button beside a master sentence.
    /// Nil where the app cannot open Settings; the sentence still says where.
    private let openSettings: (@MainActor (WorkspaceSettingsSection) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    /// The chat picker while it is open.
    @State private var chatPicker: MessagesChatPickerModel?

    public init(model: BotAccessModel, onDone: @escaping @MainActor () -> Void,
                openSettings: (@MainActor (WorkspaceSettingsSection) -> Void)? = nil) {
        self.model = model; self.onDone = onDone; self.openSettings = openSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Access for \(model.botName)")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(BotAccessCopy.sheetCaption)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("bot-access.done")
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(BotAccessRow.Group.allCases, id: \.self) { group in
                        let rows = model.rows.filter { $0.group == group }
                        if !rows.isEmpty || (group == .connectors && model.showsConnectors) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(group.rawValue)
                                    .font(.headline)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(rows) { row in
                                    BotAccessRowView(row: row, openSettings: openSettings) { on in
                                        Task { await model.setOn(on, rowID: row.id) }
                                    }
                                    if model.offersChatChoice(rowID: row.id), let choices = model.messagesChoices {
                                        Button(BotAccessCopy.chooseChats) {
                                            chatPicker = MessagesChatPickerModel(
                                                botName: model.botName, choices: choices,
                                                chosen: model.chosenMessagesChats)
                                        }
                                        .accessibilityIdentifier("bot-access.choose-chats")
                                    }
                                }
                                if group == .connectors {
                                    if let empty = model.connectorsEmptyNote {
                                        Text(empty)
                                            .font(.callout).foregroundStyle(.secondary)
                                    } else if model.connectorsAreUnreadable {
                                        Text(BotAccessCopy.connectorsUnreadable)
                                            .font(.callout).foregroundStyle(.secondary)
                                    }
                                    if let notice = model.connectorNotice {
                                        Text(notice).font(.callout).foregroundStyle(.secondary)
                                            .accessibilityIdentifier("bot-access.notice")
                                    }
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(group.rawValue)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 420, idealHeight: 620)
        .background(OpenBotsVisualStyle.surface(for: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Access for \(model.botName)")
        .accessibilityIdentifier("bot-access")
        .task(id: model.id) { await model.load() }
        .sheet(item: $chatPicker) { picker in
            MessagesChatPickerSheet(
                picker: picker, contactNames: model.contactNames,
                onAskForNames: {
                    Task {
                        await model.askForContactNames()
                        // The list is rebuilt with the names, keeping the user's ticks.
                        if let choices = model.messagesChoices {
                            let kept = AppleMessagesChatScope(guids: Array(picker.selected))
                            chatPicker = MessagesChatPickerModel(botName: model.botName, choices: choices, chosen: kept)
                        }
                    }
                },
                onCancel: { chatPicker = nil },
                onSave: { chosen in
                    chatPicker = nil
                    Task { await model.setMessagesChats(chosen) }
                })
        }
    }
}

private struct BotAccessRowView: View {
    let row: BotAccessRow
    var openSettings: (@MainActor (WorkspaceSettingsSection) -> Void)?
    let onSet: @MainActor (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.title).font(.body.weight(.medium))
                    if let badge = row.badge {
                        Text(badge)
                            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                            .accessibilityIdentifier("bot-access.badge.\(row.id)")
                    }
                }
                Text(row.summary).font(.caption).foregroundStyle(.secondary)
                ForEach(row.notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if let note = row.masterNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("bot-access.master.\(row.id)")
                    // Takes the user to the pane only; the master itself
                    // stays the user's own press there.
                    if let pane = row.masterPane, let openSettings {
                        Button(BotAccessCopy.openSettings) { openSettings(pane.settingsSection) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("Open Settings → \(pane.settingsName)")
                            .accessibilityIdentifier("bot-access.master.\(row.id).open-settings")
                    }
                }
            }
            Spacer(minLength: 0)
            Toggle(row.title, isOn: Binding(get: { row.isOn }, set: { onSet($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(row.isFrozen)
                .accessibilityIdentifier(row.accessibilityIdentifier)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bot-access.row.\(row.id)")
    }
}

/// What Details shows in place of the switches it used to carry: one line per
/// kind with the bot's current state, and the button that opens the sheet.
/// Reads the same shared switch model Details always read, and selects this
/// bot on it exactly as the old control did, so the workspace's view of the
/// selected bot's grants is unchanged.
struct BotAccessSummaryView: View {
    let switches: AgenticJobAccessModel?
    let teammateID: TeammateID
    let hasConnectors: Bool
    var onOpen: (@MainActor () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Access").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if let switches {
                BotAccessSwitchSummaryLine(switches: switches, teammateID: teammateID)
            }
            Button("Access…") { onOpen?() }
                .disabled(onOpen == nil)
                .accessibilityIdentifier("details.access.open")
                .help("Every switch this bot has, in one place")
            Text(hasConnectors ? BotAccessCopy.detailsCaption : BotAccessCopy.detailsCaptionWithoutConnectors)
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("details.access")
    }
}

/// The one line Details keeps: what is effectively on for this bot, master
/// and grant together, read off the workspace's shared switch model.
private struct BotAccessSwitchSummaryLine: View {
    @ObservedObject var switches: AgenticJobAccessModel
    let teammateID: TeammateID

    var body: some View {
        Text(summary).font(.callout)
            .accessibilityIdentifier("details.access.summary")
            .task(id: teammateID) {
                switches.selectTeammate(teammateID)
                await switches.refresh()
            }
    }

    private var summary: String {
        guard switches.isReady, switches.teammateID == teammateID else { return "Reading this bot's switches…" }
        return BotAccessCopy.switchSummary(switches)
    }
}
