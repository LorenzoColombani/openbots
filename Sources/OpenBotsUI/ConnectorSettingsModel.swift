import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public final class ConnectorSettingsModel: ObservableObject {
    @Published public private(set) var reading = ConnectorAccessReading()
    @Published public private(set) var isWorking = false
    @Published public private(set) var notice: String?
    /// What the last Google account action said: connect, disconnect, the
    /// client file. It is drawn in the Google account section, under the button
    /// the user pressed, not below every row (the browser sends the user back
    /// "for the reason", and at the bottom of the pane it is missed).
    @Published public private(set) var googleNotice: String?
    /// The page of the Google Cloud switch that would fix the last failure,
    /// when the failure named one.
    @Published public private(set) var googleSwitchPage: URL?
    @Published public private(set) var googleStatus: GoogleWorkspaceConnectionStatus?
    @Published public private(set) var googleClientConfigurationStatus:
        GoogleWorkspaceClientConfigurationStatus?
    public let teammateID: TeammateID?
    private let store: ConnectorAccessStore
    private let googleAuthorization: GoogleWorkspaceAuthorizationService?
    private var observation: Task<Void, Never>?

    public init(store: ConnectorAccessStore, teammateID: TeammateID? = nil,
                googleAuthorization: GoogleWorkspaceAuthorizationService? = nil) {
        self.store = store; self.teammateID = teammateID
        self.googleAuthorization = googleAuthorization
    }

    public func load() async {
        if observation == nil {
            let stream = await store.changes()
            observation = Task { [weak self] in
                for await _ in stream {
                    guard !Task.isCancelled, let self else { return }
                    self.reading = await self.store.current(teammateID: self.teammateID)
                }
            }
        }
        await perform {
            if !(await self.store.current()).isAvailable { try await self.store.restore() }
        }
        if teammateID == nil {
            // A fresh read shows the status as it is now; the last action's
            // reason goes with it, as it did when the pane had one notice.
            clearGoogleNotice()
            googleStatus = await googleAuthorization?.status()
            googleClientConfigurationStatus = await googleAuthorization?.clientConfigurationStatus()
        }
    }

    public func refresh() async {
        await perform {
            if (await self.store.current()).isAvailable { try await self.store.refreshCatalog() }
            else { try await self.store.restore() }
        }
    }
    /// Re-reads the store without touching the catalog: what the change stream
    /// does on its own, made callable so a caller that just wrote a master
    /// switch can read the result at once instead of waiting on the stream.
    public func reload() async {
        reading = await store.current(teammateID: teammateID)
    }
    public func setAppEnabled(_ enabled: Bool) async {
        await perform { try await self.store.setAppEnabled(enabled) }
    }
    /// The app-wide switch for one connector, in app settings. Turning one off
    /// takes it away from every bot at once; turning it back on returns each
    /// bot exactly the selection it already had.
    /// Every row can be switched here, including one this build cannot drive:
    /// the switch is the user's decision about the connector, not a claim that it
    /// works today. Refusing it would leave a dead switch under a caption
    /// promising every row can be turned off, and would mean a later build that
    /// CAN drive the row turns it on with no hand ever on that switch.
    public func setConnectorAppEnabled(_ enabled: Bool, definition: ConnectorDefinition) async {
        guard teammateID == nil else { return }
        await perform { try await self.store.setConnectorAppEnabled(enabled, id: definition.id) }
    }
    /// Names the chats this bot may read in Messages.
    public func setMessagesChats(_ guids: Set<String>) async {
        guard let teammateID else { return }
        await perform { try await self.store.setMessagesChats(Array(guids), teammateID: teammateID) }
    }

    public func setSelected(_ selected: Bool, definition: ConnectorDefinition) async {
        guard let teammateID else { return }
        // The switch is already disabled for a row that cannot be enabled; this
        // is the same rule where it cannot be styled away. Turning one *off* is
        // always allowed — a row that became unavailable while it was on must
        // still be switchable off.
        guard !selected || definition.availability.canBeEnabled else {
            notice = definition.availability.reason
            return
        }
        // A turn launches at most so many connectors, and past that the launch
        // hands back none at all — the bot would answer with no connector and no
        // word about why. So the grant that would get there is refused here,
        // where the user can read the reason. Every row this bot has switched on
        // counts, including one killed app-wide or one that cannot run today:
        // either can come back without the user's hand on this switch, and counting
        // only the live ones let a kill, a new grant and an un-kill carry a bot
        // past the bound in silence. The one grant that takes no place is a row
        // nothing in this build can launch at all: the launch skips it, so
        // counting it refused a connector the turn would have run (an old
        // iMessage plugin grant, for one). A selected
        // id with no row to say otherwise still counts.
        if selected, !reading.selectedIDs.contains(definition.id) {
            let unowned = Set(reading.definitions.filter(\.availability.isUnowned).map(\.id))
            guard reading.selectedIDs.subtracting(unowned).count < ConnectorLaunchService.maximumConnectorsPerBot else {
                notice = ConnectorCopy.tooManyConnectors
                return
            }
        }
        await perform { try await self.store.setBotEnabled(selected, identity: definition.identity, teammateID: teammateID) }
    }

    public var showsGoogleAccount: Bool {
        teammateID == nil && reading.definitions.contains { $0.id.hasPrefix("openbots:google-") }
    }

    public var canConnectGoogle: Bool {
        guard googleAuthorization?.isConfigured == true,
              googleClientConfigurationStatus?.isReady == true, !isWorking else { return false }
        return googleStatus?.state == .disconnected || googleStatus?.state == .invalid
    }

    public var canImportGoogleClientConfiguration: Bool {
        teammateID == nil && googleAuthorization?.isConfigured == true && !isWorking
    }

    public var googleIsConnected: Bool { googleStatus?.state == .connected }

    public func importGoogleClientConfiguration(from url: URL) async {
        guard teammateID == nil, let googleAuthorization, !isWorking else { return }
        isWorking = true; clearGoogleNotice()
        do {
            googleClientConfigurationStatus = try await googleAuthorization
                .importClientConfiguration(from: url)
            googleNotice = ConnectorCopy.googleSignInFileSaved
            try await store.refreshCatalog()
        } catch {
            googleNotice = (error as? LocalizedError)?.errorDescription
                ?? ConnectorCopy.googleSignInFileNotSaved
            googleClientConfigurationStatus = await googleAuthorization.clientConfigurationStatus()
        }
        reading = await store.current(teammateID: nil)
        isWorking = false
    }

    public func googleClientConfigurationSelectionFailed() {
        clearGoogleNotice()
        googleNotice = ConnectorCopy.googleSignInFileNotChosen
    }

    private func clearGoogleNotice() { googleNotice = nil; googleSwitchPage = nil }

    public func connectGoogle() async {
        guard teammateID == nil, let googleAuthorization, !isWorking else { return }
        isWorking = true; clearGoogleNotice()
        do {
            googleStatus = try await googleAuthorization.authorize()
        } catch {
            let failure = (error as? LocalizedError)?.errorDescription
                ?? "The Google account was not connected."
            googleStatus = await googleAuthorization.status()
            googleClientConfigurationStatus = await googleAuthorization.clientConfigurationStatus()
            googleNotice = ConnectorCopy.googleConnectNotice(afterFailure: failure,
                                                              status: googleStatus)
            if googleStatus?.state != .connected {
                googleSwitchPage = (error as? GoogleWorkspaceAuthorizationError)?.switchPage
            }
        }
        do {
            try await store.refreshCatalog()
        } catch {
            googleNotice = googleNotice
                ?? "Connector settings could not be updated. Reload the list before enabling access."
        }
        reading = await store.current(teammateID: nil)
        isWorking = false
    }

    public func disconnectGoogle() async {
        guard teammateID == nil, let googleAuthorization, !isWorking else { return }
        isWorking = true; clearGoogleNotice()
        do {
            // Local authority goes dark first. The catalog refresh rotates the
            // connection-bound identities and cancels active leases before a
            // fallible provider cleanup request begins.
            googleStatus = try await googleAuthorization.stageRevocation()
            try await store.refreshCatalog()
            googleStatus = try await googleAuthorization.finishRevocation()
            try await store.refreshCatalog()
        } catch {
            googleNotice = (error as? LocalizedError)?.errorDescription
                ?? ConnectorCopy.googleDisconnectUnconfirmed
            googleStatus = await googleAuthorization.status()
            try? await store.refreshCatalog()
        }
        reading = await store.current(teammateID: nil)
        isWorking = false
    }
    /// Whether a bot's own switch for this row is frozen. A grant to a row this
    /// build cannot drive is authority that could never be exercised, and a row
    /// killed for the whole app is not this bot's to revive, so both fail
    /// closed here.
    public func botSwitchIsFrozen(_ definition: ConnectorDefinition) -> Bool {
        isWorking || !reading.isAvailable || !definition.availability.canBeEnabled
            || reading.appDisabledIDs.contains(definition.id)
    }
    /// Whether the app-wide switch for this row is frozen. Only the store being
    /// unreachable freezes it: the switch records the user's decision about the
    /// connector, not whether this build can run it today.
    public func appSwitchIsFrozen(_ definition: ConnectorDefinition) -> Bool {
        _ = definition
        return isWorking || !reading.isAvailable
    }
    /// The line under a row whose grant was switched off because the row
    /// changed, or nil when it was not. The app-wide wording names whose switch
    /// went off; a bot's own pane speaks to that bot's switch.
    public func changedLine(for definition: ConnectorDefinition) -> String? {
        guard reading.changedSinceAllowed.contains(definition.id) else { return nil }
        // A row nothing in this build can run cannot be turned back on anywhere,
        // so no line may send the user to a switch for it.
        if definition.availability.isUnowned { return ConnectorCopy.changedAndUnowned }
        return teammateID == nil ? ConnectorCopy.appWideChanged : ConnectorCopy.botChanged
    }
    public func stopObserving() { observation?.cancel(); observation = nil }
    deinit { observation?.cancel() }

    private func perform(_ operation: @MainActor () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true; notice = nil
        do { try await operation() }
        catch {
            notice = "Connector settings could not be updated. Reload the list before enabling access."
        }
        reading = await store.current(teammateID: teammateID)
        isWorking = false
    }
}

/// A standalone surface for composition in app settings or a bot's Access sheet.
/// Every row is a verified local definition, never a fixture or a connection
/// claim. Account-hosted services are intentionally absent from this inventory.
/// The sentences this pane says, named so a test can read them. Wording is
/// where this pane goes wrong — a line that reads false once the row beside it
/// gains a switch — and a string sitting
/// inside a view body is the one thing nothing in this repo can assert on.
public enum ConnectorCopy {
    /// The bot's own switches live on its Access sheet, opened with Access…
    /// from Details or from its row in the sidebar.
    public static let master = "This switch is the master. Each row below turns one connector on or off for the "
        + "whole app, and each bot still chooses its own on its Access sheet — all three have to be on."
    /// In the app-wide pane the reason is ORed across every bot's grants, so
    /// the sentence has to name WHOSE switch went off. It used to read "this
    /// was switched off" directly beneath a row switch that was on.
    ///
    /// "Changed" rather than "a new version": the identity covers the whole
    /// canonical configuration — arguments, url, plugin root — so a flag added
    /// or a plugin reinstalled elsewhere trips it with no version change.
    public static let appWideChanged = "A bot’s own switch for this was turned off when it changed. "
        + "Turn it back on from that bot’s Access sheet."
    /// The same line under a row nothing in this build can run: no bot's sheet
    /// lists such a row once its switch is off, and no switch can turn it on,
    /// so the line sends the user nowhere.
    public static let changedAndUnowned = "A bot’s own switch for this was turned off when it changed. "
        + "Nothing in this version of OpenBots Next can run this connector, so it cannot be turned back on for any bot."
    public static let botChanged = "This connector or its connected account changed since you allowed it, "
        + "so it was switched off. Check the row and turn it back on to grant the current one."
    public static let appWideOff = "Turned off for every bot in Settings → Connectors & Skills."
    /// Said when a bot's switch would take it past what one turn can launch.
    public static let tooManyConnectors = "A bot can use at most \(ConnectorLaunchService.maximumConnectorsPerBot) "
        + "connectors at once, and this one already has that many on. Turn one of them off first."
    /// The Google box, up front: what
    /// bots can and cannot do, in two plain sentences. The exact permissions
    /// Google is asked for wait behind a disclosure.
    public static func googleHeading(isConnected: Bool) -> String {
        isConnected ? "Google account" : "Connect Google account"
    }
    public static let googleSummary = "Bots you allow can read the OpenBots Gmail, Calendar and Drive, and save "
        + "email drafts. They cannot change the Calendar or Drive, and they send an email only through the Gmail "
        + "send switch, after you approve it on a card."
    public static let googleDetailsTitle = "What Google is asked for"
    public static let googleNotConnected = "Not connected. You sign in to Google in your web browser, "
        + "and OpenBots never sees your password."
    public static let googleConnectTitle = "Sign in to Google…"
    public static let googleSignInFileReady = "The Google sign-in file is saved on this Mac."
    public static let googleSignInFileMissing = "Choose the Google sign-in file once before you connect."
    public static let googleSignInFileSaved = "The Google sign-in file is saved on this Mac. "
        + "The file you chose was not changed."
    public static let googleSignInFileNotSaved = "The Google sign-in file could not be saved."
    public static let googleSignInFileNotChosen = "The Google sign-in file could not be chosen. Nothing was saved."
    public static let googleDisconnectMessage = "OpenBots stops using the account on this Mac first, then asks "
        + "Google to end its access and forgets the sign-in. The switches for the whole app stay as you set them. "
        + "After you connect again, allow the account for each bot again."
    public static let googleDisconnectUnconfirmed = "Google has not confirmed the disconnect yet. OpenBots no "
        + "longer uses the account. Try again when you are online."
    public static let googleFinishDisconnectTitle = "Finish disconnecting"
    /// Behind the disclosure: every fact about the access Google grants.
    public static let googleAuthorizationDisclosure = "Google provides the private Gmail, Calendar and "
        + "Drive data for the separate OpenBots account; there is no anonymous route to it. OpenBots requests "
        + "exactly gmail.readonly, gmail.compose, calendar.calendarlist.readonly, "
        + "calendar.events.readonly and drive.readonly. Google’s gmail.compose permission saves drafts and "
        + "also allows sending; OpenBots sends only through the Gmail send row, which has its own switch "
        + "and shows you every message on a card first. drive.readonly can "
        + "change nothing in Drive. Google owns the sign-in and "
        + "consent page in your system browser; OpenBots never receives your password. If you allow it, "
        + "the bundled helper creates and refreshes OAuth tokens and keeps them across launches only in "
        + "OpenBots Next’s local, non-syncing Keychain item. Before connecting, choose the Google sign-in "
        + "file once: the original Google Desktop OAuth client JSON. OpenBots verifies that it belongs to this build, leaves "
        + "the source file unchanged, and stores only its issued client secret in a separate local, "
        + "non-syncing Keychain item. Disconnect disables local use first, asks "
        + "Google to revoke the grant, and keeps only a non-authorizing cleanup retry if Google is "
        + "unreachable. If you decline, no new token is saved and the three Google rows remain unavailable."
    public static func googleConnectedAccount(_ email: String?) -> String {
        "Connected as \(email ?? "an account")"
    }
    public static func googleClientConfigurationImportTitle(isReady: Bool) -> String {
        isReady ? "Choose a new Google sign-in file…" : "Choose the Google sign-in file…"
    }
    public static func googleConnectNotice(afterFailure failure: String,
                                           status: GoogleWorkspaceConnectionStatus?) -> String {
        guard status?.state == .connected else { return failure }
        return "Google finished connecting even though its final confirmation was interrupted. "
            + "OpenBots verified the saved connection before showing it as connected."
    }
}

public struct ConnectorSettingsView: View {
    @ObservedObject private var model: ConnectorSettingsModel
    @State private var confirmsGoogleDisconnect = false
    @State private var choosesGoogleClientConfiguration = false
    public init(model: ConnectorSettingsModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.teammateID == nil {
                Toggle("Allow selected connectors", isOn: Binding(get: { model.reading.appEnabled }, set: { enabled in
                    Task { await model.setAppEnabled(enabled) }
                }))
                .disabled(model.isWorking || !model.reading.isAvailable)
                .accessibilityIdentifier("connectors.master")
                Text(ConnectorCopy.master)
                    .font(.callout).foregroundStyle(.secondary)
                if model.showsGoogleAccount { googleAccount }
            } else if !model.reading.appEnabled {
                Text("Connector access is off in app settings. Your selections will be kept.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.reading.definitions) { definition in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(definition.title)
                            if let badge = definition.availability.badge {
                                Text(badge)
                                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(.quaternary))
                                    .accessibilityIdentifier("connectors.badge.\(definition.id)")
                            }
                        }
                        Text(definition.summary)
                            .font(.caption).foregroundStyle(.secondary)
                        // Why it cannot be turned on yet, in the words the row
                        // itself carries: a needs-setup row names the one thing
                        // that fixes it, so the badge is never a dead end.
                        if let reason = definition.availability.reason {
                            Text(reason)
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("connectors.reason.\(definition.id)")
                        }
                        // Switched off underneath the user because the row changed —
                        // a plugin naming a new version is the usual way. The
                        // switch going quiet with no word is what made the app
                        // look broken when Chrome DevTools moved to 1.9.0.
                        // In a bot's pane, a switch that will not move because
                        // the connector is off for the whole app has to say so.
                        // A dead toggle with no reason on it is the same defect
                        // as the silently revoked grant, wearing a different hat.
                        if model.teammateID != nil, model.reading.appDisabledIDs.contains(definition.id) {
                            Text(ConnectorCopy.appWideOff)
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("connectors.appoff.\(definition.id)")
                        }
                        if let changed = model.changedLine(for: definition) {
                            // The app-wide wording names WHOSE switch went off.
                            // This line used to say "it was switched off" while
                            // sitting under a row whose own switch is on, and
                            // once that row got a switch of its own the two
                            // read as a contradiction six pixels apart — which
                            // is the pane looking broken when it is not.
                            Text(changed)
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("connectors.changed.\(definition.id)")
                        }
                    }
                    Spacer(minLength: 16)
                    if model.teammateID != nil {
                        Toggle("Allow \(definition.title)", isOn: Binding(
                            get: { model.reading.selectedIDs.contains(definition.id) },
                            set: { selected in Task { await model.setSelected(selected, definition: definition) } }))
                            .labelsHidden()
                            .disabled(model.botSwitchIsFrozen(definition))
                            .accessibilityIdentifier("connectors.server.\(definition.id)")
                    } else {
                        // The app-wide switch for this one connector. Off here
                        // and no bot can launch it, whatever its own switch
                        // says; on again and every bot keeps what it had.
                        // This switch reads the decision that is stored and
                        // nothing else. Mixing in whether the build can drive
                        // the row would make it say something it was never set
                        // to, and would flip it on by itself the day a later
                        // build learns to drive that row. Whether it works
                        // today is the badge's job, on the same line.
                        Toggle("Allow \(definition.title) for every bot", isOn: Binding(
                            get: { !model.reading.appDisabledIDs.contains(definition.id) },
                            set: { enabled in Task { await model.setConnectorAppEnabled(enabled, definition: definition) } }))
                            .labelsHidden()
                            .disabled(model.appSwitchIsFrozen(definition))
                            .accessibilityIdentifier("connectors.app.\(definition.id)")
                    }
                }
            }
            if model.reading.definitions.isEmpty, !model.isWorking {
                Text("No compatible local connector configurations found.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("This list reads local configuration only. Listing or selecting a connector does not connect to its service.")
                .font(.callout).foregroundStyle(.secondary)
            if model.reading.excludedCount > 0 {
                Text("Some configurations could not be read safely, so they are not listed. Nothing was changed where they came from.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            Button("Reload configured connectors") { Task { await model.refresh() } }
                .disabled(model.isWorking)
                .accessibilityIdentifier("connectors.reload")
        }
        .fixedSize(horizontal: false, vertical: true)
        .task { await model.load() }
        .onDisappear { model.stopObserving() }
        .fileImporter(isPresented: $choosesGoogleClientConfiguration,
                      allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                Task { await model.importGoogleClientConfiguration(from: url) }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    model.googleClientConfigurationSelectionFailed()
                }
            }
        }
        .alert("Disconnect the OpenBots Google account?", isPresented: $confirmsGoogleDisconnect) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) { Task { await model.disconnectGoogle() } }
        } message: {
            Text(ConnectorCopy.googleDisconnectMessage)
        }
    }

    @ViewBuilder
    private var googleAccount: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ConnectorCopy.googleHeading(isConnected: model.googleIsConnected)).font(.headline)
            googleClientConfiguration
            switch model.googleStatus?.state {
            case .connected:
                Text(ConnectorCopy.googleConnectedAccount(model.googleStatus?.accountEmail))
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("connectors.google.account")
                Button("Disconnect Google account", role: .destructive) {
                    confirmsGoogleDisconnect = true
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("connectors.google.disconnect")
            case .disconnected:
                Text(ConnectorCopy.googleNotConnected)
                    .font(.callout).foregroundStyle(.secondary)
                googleConnect
            case .invalid:
                Text(model.googleStatus?.reason ?? "The Google connection is not ready in this build.")
                    .font(.callout).foregroundStyle(.secondary)
                googleConnect
            case .revocationPending:
                Text(model.googleStatus?.reason ?? ConnectorCopy.googleDisconnectUnconfirmed)
                    .font(.callout).foregroundStyle(.secondary)
                Button(ConnectorCopy.googleFinishDisconnectTitle) { Task { await model.disconnectGoogle() } }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("connectors.google.retry-disconnect")
            case nil:
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Checking the OpenBots Google account")
            }
            // What the button the user just pressed did, under it. Selectable, so a
            // page address in the sentence can be copied.
            if let notice = model.googleNotice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("connectors.google.notice")
            }
            if let page = model.googleSwitchPage {
                Link("Open this switch in Google Cloud", destination: page)
                    .accessibilityIdentifier("connectors.google.switch-page")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
    }

    /// What bots can and cannot do, the exact permissions behind a disclosure,
    /// then the button.
    @ViewBuilder
    private var googleConnect: some View {
        Text(ConnectorCopy.googleSummary)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("connectors.google.summary")
        DisclosureGroup(ConnectorCopy.googleDetailsTitle) {
            Text(ConnectorCopy.googleAuthorizationDisclosure)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("connectors.google.disclosure")
        }
        .font(.callout)
        Button(ConnectorCopy.googleConnectTitle) { Task { await model.connectGoogle() } }
            .disabled(!model.canConnectGoogle)
            .accessibilityIdentifier("connectors.google.connect")
    }

    @ViewBuilder
    private var googleClientConfiguration: some View {
        switch model.googleClientConfigurationStatus?.state {
        case .ready:
            Text(ConnectorCopy.googleSignInFileReady)
                .font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("connectors.google.client-configuration-ready")
        case .missing:
            Text(ConnectorCopy.googleSignInFileMissing)
                .font(.callout).foregroundStyle(.secondary)
        case .invalid:
            Text(model.googleClientConfigurationStatus?.reason ?? ConnectorCopy.googleSignInFileMissing)
                .font(.callout).foregroundStyle(.secondary)
        case nil:
            ProgressView().controlSize(.small)
                .accessibilityLabel("Checking the Google sign-in file")
        }
        if model.googleClientConfigurationStatus != nil {
            Button(ConnectorCopy.googleClientConfigurationImportTitle(
                isReady: model.googleClientConfigurationStatus?.isReady == true)) {
                choosesGoogleClientConfiguration = true
            }
            .disabled(!model.canImportGoogleClientConfiguration)
            .accessibilityIdentifier("connectors.google.import-client-configuration")
        }
    }
}

/// The app-wide connector list, inside Settings.
///
/// The model is owned here rather than built in the caller's `body`: a model
/// rebuilt on every render starts empty — no rows, `isAvailable` false — and
/// its `.task` has already run for the instance that was replaced. The pane
/// then shows "no compatible local connector configurations" with a dead
/// master switch, which is exactly what happens the moment the first toggle
/// publishes a change and SwiftUI re-evaluates the settings scene. A bot's own
/// connector switches sit on its Access sheet (`BotAccessSheet.swift`), over
/// this same model.
public struct AppConnectorControl: View {
    @StateObject private var model: ConnectorSettingsModel

    public init(store: ConnectorAccessStore,
                googleAuthorization: GoogleWorkspaceAuthorizationService? = nil) {
        _model = StateObject(wrappedValue: ConnectorSettingsModel(
            store: store, googleAuthorization: googleAuthorization))
    }

    public var body: some View {
        ConnectorSettingsView(model: model)
    }
}
