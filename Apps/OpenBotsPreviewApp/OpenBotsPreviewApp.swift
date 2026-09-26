import Combine
import Darwin
import AppKit
import OpenBotsContent
import OpenBotsDomain
import OpenBotsPersistence
import OpenBotsServices
import OpenBotsUI
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct OpenBotsPreviewApp: App {
    @NSApplicationDelegateAdaptor(PreviewApplicationDelegate.self) private var applicationDelegate
    @StateObject private var composition = AppCompositionRoot()
    @StateObject private var settingsNavigation = WorkspaceSettingsNavigation()
    @StateObject private var appearance = WorkspaceAppearanceModel()

    var body: some Scene {
        // Non-private view types keep the window's restoration identifier the
        // same across builds. A private type's name carries an address that
        // changes with every binary; restoration then fails and SwiftUI opens
        // no window at all. An explicit scene id is
        // not used: with one, the launch window did not open at all.
        WindowGroup("OpenBots") {
            PreviewWindow(composition: composition, appearance: appearance, showClaudeSetup: {
                settingsNavigation.selection = .general
            }, showSettingsSection: { section in
                settingsNavigation.selection = section
            })
                .background(WorkspaceWindowReporter { window in
                    applicationDelegate.observeWorkspaceWindow(window)
                    composition.workspaceWindow = window
                })
                .onAppear {
                    applyAppearance()
                    applicationDelegate.beginShutdown = { [weak composition] in composition?.beginShutdown() }
                    applicationDelegate.saveAvailableState = { [weak composition] in
                        await composition?.saveAvailableStateForShutdown() ?? true
                    }
                    applicationDelegate.finishShutdown = { [weak composition] in composition?.workspace?.finishShutdown() }
                }
                .onChange(of: appearance.selection) { _, _ in applyAppearance() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Bot") {
                    composition.beginTeammateCreation()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(composition.workspace == nil)
            }

            #if DEBUG
            if composition.usesReviewFixtures {
            CommandMenu("Preview") {
                Button("Not Configured") {
                    composition.reviewLaunchState(.notConfigured)
                }
                .keyboardShortcut("1", modifiers: [.command, .option])

                Button("Checking Local State") {
                    composition.reviewLaunchState(.opening)
                }
                .keyboardShortcut("2", modifiers: [.command, .option])

                Button("Ready") {
                    composition.reviewLaunchState(.ready)
                }
                .keyboardShortcut("3", modifiers: [.command, .option])

                Menu("Recovery") {
                    Button("Installation Receipt") {
                        composition.reviewLaunchState(
                            .recovery(.installationReceiptUnavailable)
                        )
                    }
                    Button("Protected Root") {
                        composition.reviewLaunchState(
                            .recovery(.ownedRootVerificationFailed)
                        )
                    }
                    Button("Database Protection") {
                        composition.reviewLaunchState(
                            .recovery(.databaseProtectionUnavailable)
                        )
                    }
                    Button("Database Open") {
                        composition.reviewLaunchState(
                            .recovery(.databaseOpenFailed)
                        )
                    }
                    Button("Database Validation") {
                        composition.reviewLaunchState(
                            .recovery(.databaseValidationFailed)
                        )
                    }
                    Button("Newer Workspace") {
                        composition.reviewLaunchState(
                            .recovery(.workspaceNewerThanApplication)
                        )
                    }
                }

                Divider()

                Button("Representative Teammate Workspace") {
                    composition.enterWorkspace()
                }
                .keyboardShortcut("4", modifiers: [.command, .option])

                Menu("Selected Teammate Status") {
                    ForEach(TeammateActivityState.allCases, id: \.self) { activity in
                        Button(activity.visibleLabel) {
                            composition.reviewTeammateActivity(activity)
                        }
                    }
                }

                Menu("Appearance Review") {
                    Button("Follow App Preference") {
                        composition.reviewAppearance(nil)
                    }
                    Button("Light") {
                        composition.reviewAppearance(.light)
                    }
                    Button("Dark") {
                        composition.reviewAppearance(.dark)
                    }
                }
            }
            }
            #endif
        }

        Settings {
            PreviewSettingsWindow(composition: composition, navigation: settingsNavigation, appearance: appearance)
                .preferredColorScheme(appearance.selection.colorScheme)
                .onAppear { applyAppearance() }
                .onChange(of: appearance.selection) { _, _ in applyAppearance() }
        }
    }

    /// Native panels and all scenes share the app preference. Fixture-only
    /// workspace overrides remain confined to their SwiftUI window.
    private func applyAppearance() {
        switch appearance.selection {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
private struct PreviewSettingsWindow: View {
    @ObservedObject var composition: AppCompositionRoot
    @ObservedObject var navigation: WorkspaceSettingsNavigation
    @ObservedObject var appearance: WorkspaceAppearanceModel

    var body: some View {
        if let workspace = composition.workspace {
            PreviewWorkspaceSettings(composition: composition, workspace: workspace,
                                     sidebar: workspace.sidebar, navigation: navigation, appearance: appearance)
        } else {
            WorkspaceSettingsView(navigation: navigation, model: composition.claudeSetup,
                                  usesReviewFixtures: composition.usesReviewFixtures,
                                  textRepliesEnabled: !composition.usesReviewFixtures,
                                  appearance: appearance)
        }
    }
}

@MainActor
private struct PreviewWorkspaceSettings: View {
    @ObservedObject var composition: AppCompositionRoot
    @ObservedObject var workspace: DurableWorkspaceModel
    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var navigation: WorkspaceSettingsNavigation
    @ObservedObject var appearance: WorkspaceAppearanceModel

    var body: some View {
        WorkspaceSettingsView(
            navigation: navigation, model: composition.claudeSetup,
            usesReviewFixtures: composition.usesReviewFixtures,
            textRepliesEnabled: !composition.usesReviewFixtures,
            agenticJobAccess: composition.usesReviewFixtures ? nil : composition.agenticJobAccess,
            appearance: appearance,
            exportBots: sidebar.rows.map { .init(id: $0.id, name: $0.name) },
            isExporting: workspace.isExporting,
            exportNotice: workspace.exportNotice,
            onExport: workspace.supportsConversationExport || workspace.isExporting ? chooseExportFolder : nil,
            backupSummary: composition.settingsBackupSummary,
            connectorsContent: composition.connectorAccess.map {
                AnyView(AppConnectorControl(store: $0,
                                            googleAuthorization: composition.googleAuthorization))
            },
            notificationsContent: composition.usesReviewFixtures ? nil : AnyView(BotNotificationSettingsView(model: composition.notifications))
        )
    }

    private func chooseExportFolder(teammateID: UUID) {
        guard workspace.supportsConversationExport,
              let bot = sidebar.rows.first(where: { $0.id == teammateID }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Choose where OpenBots creates a new export folder for \(bot.name)’s conversations."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await workspace.exportBotConversations(teammateID: teammateID, into: folder) }
    }
}

/// AppKit owns termination. Available state gets one three-second grace;
/// failed/stalled saving cannot veto Quit or leave a hidden running task.
@MainActor
private final class PreviewApplicationDelegate: NSObject, NSApplicationDelegate {
    var beginShutdown: (@MainActor () -> Void)?
    var saveAvailableState: (@MainActor () async -> Bool)?
    var finishShutdown: (@MainActor () -> Void)?
    private let draftQuitGuard = DraftQuitGuard()
    private var workspaceWindows: [ObjectIdentifier: NSObjectProtocol] = [:]

    func observeWorkspaceWindow(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard workspaceWindows[id] == nil else { return }
        #if DEBUG
        // A development launch may name where the window goes, in AppKit
        // screen coordinates (`--window-origin=x,y`), so it can be kept on a
        // second display without accessibility or activation.
        if let origin = Self.requestedWindowOrigin { window.setFrameOrigin(origin) }
        #endif
        workspaceWindows[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            // The observer is delivered on the main queue. Do not defer the
            // admission boundary to another task when Settings stays open.
            MainActor.assumeIsolated {
                guard let self, let observer = self.workspaceWindows.removeValue(forKey: id) else { return }
                NotificationCenter.default.removeObserver(observer)
                // Settings and preview sheets are not workspace windows. A
                // dismissed pane never enters this route.
                if self.workspaceWindows.isEmpty {
                    self.beginShutdown?()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    #if DEBUG
    static let requestedWindowOrigin: NSPoint? = {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--window-origin=") }) else { return nil }
        let parts = argument.dropFirst("--window-origin=".count).split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return NSPoint(x: parts[0], y: parts[1])
    }()
    #endif

    /// One running copy per workspace. Rollback and build folders hold other
    /// bundles with this identifier; a Dock tile or Spotlight can launch one of
    /// them while the installed app is open. The second copy
    /// brings the first forward and leaves before touching any storage, the way
    /// macOS treats a second click on a single bundle.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let current = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != current && !$0.isTerminated }
        guard let first = others.first else { return }
        first.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if draftQuitGuard.outcome != nil { return .terminateNow }
        guard let saveAvailableState else { beginShutdown?(); finishShutdown?(); return .terminateNow }
        guard draftQuitGuard.request(begin: { self.beginShutdown?() }, flush: saveAvailableState,
            finish: { self.finishShutdown?() }, reply: { _ in
                // This terminates the app, not just a Swift task. No alert or
                // waiting for a model to finish can keep it alive afterward.
                sender.reply(toApplicationShouldTerminate: true)
            }) else { return .terminateLater }
        return .terminateLater
    }
}

/// True while no other copy of the app is running: the launch sweep's whole proof
/// that a leased turn's owner process is gone (see `SoleInstanceTextTurnProcessAbsence`).
private func isSoleRunningInstanceOfThisApp() -> Bool {
    guard let identifier = Bundle.main.bundleIdentifier else { return false }
    let current = ProcessInfo.processInfo.processIdentifier
    return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        .allSatisfy { $0.processIdentifier == current || $0.isTerminated }
}

@MainActor
struct WorkspaceWindowReporter: NSViewRepresentable {
    let report: (NSWindow) -> Void
    func makeNSView(context: Context) -> Reporter { Reporter(report: report) }
    func updateNSView(_ nsView: Reporter, context: Context) {}
    final class Reporter: NSView {
        let report: (NSWindow) -> Void
        init(report: @escaping (NSWindow) -> Void) { self.report = report; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { report(window) } }
    }
}

@MainActor
final class AppCompositionRoot: ObservableObject {
    private static let knowledgeUnavailableNotice =
        "Local memory couldn't be opened. Your teammates and conversations are still available."

    /// Development scenarios require an explicit launch argument. Normal
    /// Finder/Dock launch never enables canned replies or simulated controls.
    let usesReviewFixtures: Bool
    private var chatMode: LocalChatMode { usesReviewFixtures ? .reviewFixture : .localOnly }

    private let layout: PreviewStorageLayout
    private var claudeSetupSupportRoot: VerifiedOwnedRoot?
    let agenticJobAccess = AgenticJobAccessStore()
    /// The connector grants, and the browser they let a bot drive. Unlike the
    /// web switches these cannot be built before the database is open: the
    /// store needs its repository, so both appear in `start()`.
    @Published private(set) var connectorAccess: ConnectorAccessStore?
    private var connectorLaunches: ConnectorLaunchService?
    @Published private(set) var googleAuthorization: GoogleWorkspaceAuthorizationService?
    let notifications = BotNotificationModel()
    weak var workspaceWindow: NSWindow?
    private var pendingNotificationConversationID: UUID?
    /// Settings owns a separate setup model; local chat/storage readiness never
    /// depends on a Claude connection. Constructing this model performs no I/O.
    lazy var claudeSetup = ClaudeSetupModel(
        service: OfficialClaudeConnectionService(
            inspector: NativeClaudeOfflineSetupInspector(
                layout: layout,
                applicationSupportRoot: { [weak self] in
                    await self?.claudeSetupSupportRoot
                }
            ),
            preparer: NativeClaudeConnectionPreparer(
                layout: layout,
                applicationSupportRoot: { [weak self] in await self?.claudeSetupSupportRoot }
            ),
            admission: UserInitiatedClaudeConnectionAdmission(),
            signInHandoff: NativeClaudeConnectionSignInHandoff(
                layout: layout,
                applicationSupportRoot: { [weak self] in await self?.claudeSetupSupportRoot },
                opener: NativeClaudeTerminalSignInOpener()
            )
        )
    )
    let launchReadiness = LaunchReadinessModel(
        inspector: FixedLaunchReadinessInspector(state: .notConfigured)
    )

    @Published private(set) var workspace: DurableWorkspaceModel?
    @Published private(set) var showsWorkspace = false
    @Published private(set) var reviewColorScheme: ColorScheme?
    @Published private(set) var startupDiagnosticCode: String?
    @Published private(set) var knowledgeAvailabilityNotice: String?
    @Published private(set) var isClosing = false
    @Published private(set) var sessionRecoveryNotice: String?
    @Published private(set) var memoryRecoveryNotice: String?
    /// Set only when the launch sweep could not close every turn a dead process left busy.
    @Published private(set) var textTurnRecoveryNotice: String?
    /// The lease owner every reply service of this process uses; the launch sweep
    /// treats any other owner as a process that is no longer running.
    private let replyServiceOwnerID = UUID()
    /// Verified local backups the recovery screen may offer, newest first.
    @Published private(set) var restoreOptions: [LaunchRecoveryRestoreOption] = []
    private var restoreCandidates: [String: VerifiedDatabaseBackup] = [:]
    private var sessionRecovery: LocalSessionRecoveryService?
    private var backups: ControlDatabaseBackupService?
    private var backupSchedule: Task<Void, Never>?
    var settingsBackupSummary: String? {
        guard backups != nil, backupSchedule != nil, !isClosing else { return nil }
        return "Local database backups are scheduled five minutes after launch, then hourly; a backup is also attempted during normal quit. If the database cannot open, launch recovery offers verified backups."
    }
    private var didStart = false
    /// The first scheduled backup waits this long after launch; later ones follow hourly.
    static let firstScheduledBackupDelay: Duration = .seconds(300)
    static let scheduledBackupInterval: Duration = .seconds(3_600)
    /// Quit waits this long at most for its backup; the close boundary itself is
    /// `DraftQuitGuard.maximumGrace`, and the session record must still land inside it.
    static let quitBackupBudget: Duration = .milliseconds(1_500)

    init(layout: PreviewStorageLayout = .live()) {
        self.layout = layout
        #if DEBUG
        usesReviewFixtures = CommandLine.arguments.contains("--review-fixtures")
        #else
        usesReviewFixtures = false
        #endif
        if !usesReviewFixtures {
            notifications.isConversationFrontmost = { [weak self] id in
                guard let self else { return false }
                return NSApplication.shared.isActive && self.workspaceWindow?.isKeyWindow == true
                    && self.workspace?.conversation.conversationID == id
                    && self.workspace?.hiringModel == nil
                    && self.workspace?.searchCoordinator?.isPresented != true
            }
            notifications.openConversation = { [weak self] id in
                self?.pendingNotificationConversationID = id
                self?.openPendingNotification()
            }
            notifications.start()
        }
    }

    private func openPendingNotification() {
        guard !isClosing, let id = pendingNotificationConversationID, let workspace else { return }
        pendingNotificationConversationID = nil
        guard workspace.openNotificationConversation(id: id) else { return }
        workspaceWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func beginShutdown() {
        guard !isClosing else { return }
        isClosing = true
        notifications.stop()
        backupSchedule?.cancel()
        backupSchedule = nil
        claudeSetup.beginShutdown()
        googleAuthorization?.cancel()
        claudeSetupSupportRoot = nil
        workspace?.beginShutdown()
    }

    /// One bounded local backup of the control database inside the app-owned
    /// backups folder: on a normal quit and, while running, five minutes after
    /// launch and hourly. It never blocks Quit beyond its budget and never
    /// touches anything outside `DatabaseBackups`.
    private func startBackupSchedule(_ service: ControlDatabaseBackupService) {
        backups = service
        backupSchedule?.cancel()
        backupSchedule = Task { [weak self] in
            var delay = Self.firstScheduledBackupDelay
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, !self.isClosing else { return }
                do {
                    let record = try await service.backupNow(reason: .scheduled)
                    AgenticDiagnosticsLog.note("backup", "scheduled backup written \(record.fileName) bytes=\(record.byteCount) pruned=\(record.prunedFileNames.count)")
                } catch {
                    AgenticDiagnosticsLog.note("backup", "scheduled backup failed: \(String(describing: error).prefix(160))")
                }
                delay = Self.scheduledBackupInterval
            }
        }
    }

    private func backupForQuitWithinBudget() async {
        guard let backups else { return }
        // Quit never waits past the budget. A backup still running then is
        // abandoned: it is cancelled, and a file without its manifest is
        // invisible to listing, restore and retention.
        let work = Task { try await backups.backupNow(reason: .quit) }
        switch await BudgetedWait.result(of: work, within: Self.quitBackupBudget) {
        case .finished(.success(let record)):
            AgenticDiagnosticsLog.note("backup", "quit backup written \(record.fileName) bytes=\(record.byteCount)")
        case .finished(.failure(let error)):
            AgenticDiagnosticsLog.note("backup", "quit backup skipped: \(String(describing: error).prefix(160))")
        case .budgetExceeded:
            AgenticDiagnosticsLog.note("backup", "quit backup abandoned after \(Self.quitBackupBudget)")
        }
    }

    /// Lists the verified local backups for a database that will not open, so the
    /// recovery screen can offer them. Read-only; nothing is changed.
    private func loadRestoreOptions() async {
        let layout = self.layout
        let options: [VerifiedDatabaseBackup] = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: layout.installationReceiptURL),
                  let receipt = try? JSONDecoder().decode(StorageInstallationReceipt.self, from: data) else { return [] }
            return DatabaseBackupCatalog(layout: layout, expectedDecisionID: receipt.protectionDecision.decisionID).verifiedBackups()
        }.value
        guard !isClosing else { return }
        restoreCandidates = Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0) })
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        restoreOptions = options.map { backup in
            LaunchRecoveryRestoreOption(
                id: backup.id,
                title: "Backup from \(formatter.string(from: backup.createdAt))",
                // Size and why it was made; the schema number is not the user's to read.
                detail: "\(ByteCountFormatter.string(fromByteCount: Int64(backup.byteCount), countStyle: .file)) · \(backup.reason)"
            )
        }
    }

    /// Restores one verified backup after the screen's confirmation, then tries the
    /// startup again. The current files move into a Damaged folder; nothing is deleted.
    func restoreBackup(_ option: LaunchRecoveryRestoreOption) {
        guard !isClosing, workspace == nil, launchReadiness.state != .opening,
              let backup = restoreCandidates[option.id] else { return }
        let layout = self.layout
        launchReadiness.setPreviewReviewState(.opening)
        Task { [weak self] in
            let outcome: Result<DatabaseBackupRestoreReceipt, any Error> = await Task.detached(priority: .userInitiated) {
                Result { try DatabaseBackupRestoreService(layout: layout).restore(backup) }
            }.value
            guard let self, !self.isClosing else { return }
            switch outcome {
            case .success(let receipt):
                AgenticDiagnosticsLog.note("backup", "restored \(receipt.restoredFrom); damaged files in \(receipt.damagedFolder)")
                self.restoreOptions = []
                self.restoreCandidates = [:]
                self.didStart = false
                await self.start()
            case .failure(let error):
                AgenticDiagnosticsLog.note("backup", "restore failed: \(String(describing: error).prefix(160))")
                self.launchReadiness.setPreviewReviewState(.recovery(.databaseOpenFailed))
            }
        }
    }

    private func requireOpen() throws {
        guard !isClosing, !Task.isCancelled else { throw CancellationError() }
    }

    /// The stuck-busy sweep. Runs once per launch before the reply
    /// service exists, so no lease in the journal can be this process's own.
    /// Brings back the connector grants the user left on, and the browser they allow.
    ///
    /// Order matters the way it does for the web switches: this runs before the
    /// reply service exists, so nothing can read a grant that has not been
    /// restored. A failure here leaves every connector off and the app
    /// otherwise whole — browsing is a capability, not a dependency.
    private func startConnectorAccess(_ context: StoragePersistenceContext) async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let browser = BrowserConnectorPreparation(npxCacheRootURL:
            BrowserConnectorPreparation.defaultNPXCacheRootURL(homeDirectoryURL: home))
        let mail = AppleMailConnectorPreparation(homeDirectoryURL: home)
        let mailSender = AppleMailSendPreparation()
        let contacts = AppleContactsConnectorPreparation()
        let calendar = AppleCalendarConnectorPreparation()
        // The user's history is read from the real home this app runs in; the CLI
        // child's HOME is the app profile, so the path is resolved here.
        let messages = AppleMessagesConnectorPreparation(
            databaseURL: AppOwnedConnectorCatalog.messagesDatabaseURL(homeDirectoryURL: home))
        let google = GoogleWorkspaceConnectorPreparation()
        // Control this Mac runs the Peekaboo already in the user's npx cache, never a fetch.
        let macControl = MacControlConnectorPreparation(npxCacheRootURL:
            BrowserConnectorPreparation.defaultNPXCacheRootURL(homeDirectoryURL: home))
        // The Claude Desktop extensions: each listed, and only a reviewed one,
        // as the exact copy reviewed, can run.
        let extensionsRoot = ClaudeExtensionConnectorPreparation.defaultExtensionsRootURL(homeDirectoryURL: home)
        let extensions = ClaudeExtensionConnectorPreparation(extensionsRootURL: extensionsRoot)
        let preparations: [any ConnectorLaunchPreparing] = [browser, mail, mailSender, contacts,
                                                            calendar, messages, macControl, google, extensions]
        let googleClientID = GoogleWorkspaceClientConfiguration.clientID()
        let googleHelper = AppOwnedConnectorCatalog.resolvedGoogleWorkspaceHelperURL()
        // All three sources, and the pane says what a turn would find: the same
        // resolution the launch does, read early, so a pinned version that is
        // not on the disk reads "needs setup" instead of a switch that turns on
        // and does nothing.
        let catalog = ConnectorCatalogAvailability(
            ConnectorCatalogNaming(ConnectorCatalogComposite([
                ClaudePluginConnectorCatalog(
                    configurationDirectory: home.appendingPathComponent(".claude", isDirectory: true)),
                AppOwnedConnectorCatalog(homeDirectoryURL: home, googleClientID: googleClientID),
                ClaudeExtensionConnectorCatalog(extensionsRootURL: extensionsRoot, preparation: extensions),
            ])),
            probes: preparations)
        // The app-wide "changed" line counts only the bots the workspace still
        // lists: archived bots and Delete's tombstones out, hidden bots in.
        let teammates = context.teammateRepository
        let store = ConnectorAccessStore(repository: context.connectorAccessRepository, catalog: catalog,
            listedTeammates: { Set(try await teammates.listTeammates(includingArchived: false).map(\.id)) })
        do { try await store.restore() }
        catch {
            AgenticDiagnosticsLog.error("connectors",
                "grants not restored, every connector starts off: \(String(describing: error).prefix(160))")
            return
        }
        let service = ConnectorLaunchService(
            store: store,
            preparations: preparations,
            profileRootURL: ConnectorLaunchService.defaultProfileRootURL(
                applicationSupportRoot: context.applicationSupportRoot.url),
            temporaryDirectoryURL: FileManager.default.temporaryDirectory)
        // A crash or a force quit can leave a turn's browser profile behind.
        // Nothing is granted yet, so this is the moment to clear them.
        await service.removeAbandonedProfiles()
        await agenticJobAccess.configureConnectors(service)
        googleAuthorization = GoogleWorkspaceAuthorizationService(
            helperURL: googleHelper, clientID: googleClientID)
        connectorAccess = store
        connectorLaunches = service
    }

    private func sweepTextTurnsLeftBusy(_ context: StoragePersistenceContext) async {
        let ownerID = replyServiceOwnerID
        let sweep = TextTurnRecoveryService(
            repository: context.textTurnRepository,
            appOwnerID: context.installationReceipt.installationID,
            absenceProver: SoleInstanceTextTurnProcessAbsence(
                ownersHeldByThisProcess: { [ownerID] },
                isSoleRunningInstance: { isSoleRunningInstanceOfThisApp() }))
        var report = await sweep.recover(limit: 25)
        var closed = report.interruptedCount
        var passes = 1
        while report.status == .completed, report.hasMore, passes < 8, !isClosing {
            report = await sweep.recover(limit: 25)
            closed += report.interruptedCount
            passes += 1
        }
        let unresolved = report.entries.filter { $0.disposition != .interrupted }.count
        AgenticDiagnosticsLog.note("recovery",
            "launch sweep closed \(closed) turn(s) left busy; status=\(report.status) unresolved=\(unresolved) more=\(report.hasMore)")
        textTurnRecoveryNotice = report.notice
    }

    func saveAvailableStateForShutdown() async -> Bool {
        let saved = await workspace?.flushForShutdown() ?? true
        guard !Task.isCancelled else { return false }
        // A switch flipped just before Quit lands before the backup copies the database.
        await agenticJobAccess.waitForPendingWrites()
        guard !Task.isCancelled else { return false }
        await backupForQuitWithinBudget()
        guard !Task.isCancelled else { return false }
        let recorded = await sessionRecovery?.finish(saved: saved) ?? false
        return saved && recorded
    }

    /// The user has read the recovery paragraphs at the top of the window:
    /// one OK clears all three. Nothing they describe is undone; the
    /// notices only stop showing until the next launch.
    func dismissRecoveryNotices() {
        sessionRecoveryNotice = nil
        memoryRecoveryNotice = nil
        textTurnRecoveryNotice = nil
    }

    func start() async {
        guard !didStart, !isClosing else { return }
        didStart = true
        launchReadiness.setPreviewReviewState(.opening)

        do {
            let context = try await openOrBootstrapPreviewInstallation()
            guard !isClosing, !Task.isCancelled else { return }
            claudeSetupSupportRoot = context.applicationSupportRoot
            // The web switches the user left on come back before anything reads them:
            // the reply service, the job driver and the workspace are all built
            // below this line, and an already-open Settings pane observes the
            // store, so it catches up.
            if !usesReviewFixtures {
                await agenticJobAccess.restore(from: context.agenticWebSwitchRepository)
                await startConnectorAccess(context)
            }
            try requireOpen()
            restoreOptions = []
            restoreCandidates = [:]
            startBackupSchedule(ControlDatabaseBackupService(
                layout: layout, applicationSupportRoot: context.applicationSupportRoot,
                protection: context.protectionPlan, executor: context.backupExecutor))
            let recovery = LocalSessionRecoveryService(repository: context.sessionRecoveryRepository)
            sessionRecovery = recovery
            let previousCloseNotice = await recovery.begin()
            try requireOpen()
            sessionRecoveryNotice = previousCloseNotice
            // A crash, a force-quit or a Mac that went down mid-reply leaves the
            // bot's turn open in the journal, and every later message to that bot
            // is refused as busy. This process is the only running copy and owns
            // no turn yet, so those turns are closed here, before any reply
            // service exists. Partial text is kept; nothing is sent again.
            if !usesReviewFixtures {
                await sweepTextTurnsLeftBusy(context)
                try requireOpen()
            }
            let attachmentService = await makeAttachmentService(context: context)
            try requireOpen()
            // Each bot's desk on the Mac: its own folder under the
            // content root plus the folders the user adds; the switch store
            // hands it to a work turn only when both work switches are on.
            let botWorkspaces: BotWorkspaceService? = usesReviewFixtures ? nil : BotWorkspaceService(
                layout: layout, repository: context.botWorkspaceRepository, teammates: context.teammateRepository)
            if let botWorkspaces { await agenticJobAccess.configureWorkspaces(botWorkspaces) }
            try requireOpen()
            let service = DurableTeammateChatService(
                mode: chatMode,
                teammateRepository: context.teammateRepository,
                conversationRepository: context.conversationRepository,
                messageRepository: context.messageRepository,
                provisioningRepository: context.directChatProvisioningRepository,
                selectionRepository: context.chatSelectionRepository,
                attachmentRepository: context.attachmentRepository,
                attachmentValidator: attachmentService
            )
            let hiringService = HiringConversationService(
                mode: chatMode,
                repository: context.hiringDraftRepository
            )
            let teamService = TeamChatService(
                teams: context.teamRepository, provisioning: context.teamProvisioningRepository,
                teamConversations: context.teamConversationRepository, teammates: context.teammateRepository,
                selection: context.chatSelectionRepository)
            // Bots that hire bots: a bot holding both hire
            // switches asks from its reply; this makes the bot, sealed, with its
            // desk and chat, and joins it to the team it was hired in.
            let teammateHiring = TeammateHiringService(
                access: agenticJobAccess, teammates: context.teammateRepository,
                conversations: context.conversationRepository, chats: service,
                desks: botWorkspaces, teamChats: teamService)
            // A new bot sets itself up: its own profile,
            // its own switches, its folder following its new name.
            let botSelfSetup: BotSelfSetupService? = usesReviewFixtures ? nil : BotSelfSetupService(
                repository: context.botSelfSetupRepository, teammates: context.teammateRepository,
                switches: agenticJobAccess, folders: botWorkspaces)
            let textLaunchPreparer = NativeClaudeTextLaunchPreparer(
                layout: layout,
                applicationSupportRoot: { [weak self] in await self?.claudeSetupSupportRoot },
                connection: NativeClaudeConnectionPreparer(
                    layout: layout,
                    applicationSupportRoot: { [weak self] in await self?.claudeSetupSupportRoot }
                )
            )
            // Throwaway workers: a bot holding the
            // workers switches starts one from its reply; this admits the call
            // and runs the worker, a blank reading turn on the same Claude setup.
            let teammateWorkers: TeammateWorkerService? = usesReviewFixtures ? nil : TeammateWorkerService(
                access: agenticJobAccess, teammates: context.teammateRepository,
                conversations: context.conversationRepository, preparer: textLaunchPreparer)
            let providerTextReplyService: (any ClaudeTextReplyServing)? = usesReviewFixtures ? nil :
                OfficialClaudeTextReplyService(
                    repository: context.textTurnRepository,
                    teammates: context.teammateRepository,
                    conversations: context.conversationRepository,
                    messages: context.messageRepository,
                    preparer: textLaunchPreparer,
                    appOwnerID: context.installationReceipt.installationID,
                    ownerID: replyServiceOwnerID,
                    context: context.conversationContextRepository,
                    contextReader: context.readContextRepository,
                    contextAssembler: ClaudeContextAssemblyService(memoryReader: { reference, maximumBytes in
                        // Verify and read only when an eligible document is selected.
                        // Missing/malformed optional memory never repairs or blocks chat startup.
                        let root = try AuthoritativeMarkdownRootVerifier().verify(
                            context.applicationSupportRoot.url.appending(
                                path: MemoryAuthorityContract.appOwnedMarkdownV1.relativeRoot,
                                directoryHint: .isDirectory),
                            inside: context.applicationSupportRoot)
                        return try await AuthoritativeMarkdownStore(maximumBytes: maximumBytes)
                            .read(reference, inside: root).markdown
                    }),
                    controlledMemory: ControlledMemoryReplyPreparation(
                        memory: context.memoryRepository, intents: context.memoryPublicationIntentRepository,
                        contexts: context.readContextRepository, publications: context.memoryConversationPublicationRepository,
                        messages: context.messageRepository, teammates: context.teammateRepository,
                        authority: {
                            try AuthoritativeMarkdownRootVerifier().verify(
                                context.applicationSupportRoot.url.appending(
                                    path: MemoryAuthorityContract.appOwnedMarkdownV1.relativeRoot,
                                    directoryHint: .isDirectory), inside: context.applicationSupportRoot)
                        }),
                    teams: context.teamRepository,
                    handoffs: context.handoffRepository,
                    // The same session-local switches the sample-folder job path
                    // reads, so one grant means one thing everywhere in the app.
                    webAccess: agenticJobAccess,
                    approvals: context.approvalRepository,
                    deliverables: attachmentService,
                    activity: context.runActivityRepository,
                    hiring: teammateHiring,
                    workers: teammateWorkers,
                    selfSetup: botSelfSetup,
                    // One session per bot, resumed from turn to turn.
                    sessions: context.claudeSessionRepository,
                    resumesSessions: true
                )
            let textReplyService: (any ClaudeTextReplyServing)?
            if let providerTextReplyService {
                textReplyService = await context.localMemoryConversationService(fallback: providerTextReplyService) { [weak self] report in
                    await MainActor.run {
                        self?.memoryRecoveryNotice = report.notice
                    }
                }
            } else {
                textReplyService = nil
            }
            try requireOpen()
            // Photo availability is local to the character surface. Missing or
            // unsafe assets must not turn healthy chat storage into global recovery.
            let photoService: ProfilePhotoService?
            let photoRootURL = layout.profileAssetsRoot
            let ownedSupportRoot = context.applicationSupportRoot
            let verifiedPhotoRoot = try? await Task.detached(priority: .userInitiated) {
                try ProfilePhotoRootVerifier().verify(photoRootURL, inside: ownedSupportRoot)
            }.value
            try requireOpen()
            if let photoRoot = verifiedPhotoRoot {
                let store = ProfilePhotoContentStore(root: photoRoot)
                photoService = ProfilePhotoService(
                    repository: context.profilePhotoRepository,
                    importer: { url, id in try await store.importPhoto(from: url, id: id) },
                    reader: { asset in try await store.read(asset) }
                )
            } else {
                photoService = nil
            }
            let photoPresentation = photoService.map { service in
                ProfilePhotoPresentation(loader: { id in try await service.imageData(id: id) })
            }
            let photoImporter: (@Sendable (URL) async throws -> ProfilePhotoAsset)?
            if let service = photoService {
                photoImporter = { [weak self] url in
                    guard let self else { throw CancellationError() }
                    try await self.requireOpen()
                    return try await service.importPhoto(from: url)
                }
            } else {
                photoImporter = nil
            }
            // Work Context is not part of chat. Do not construct its models:
            // a hidden Knowledge loader could quarantine Markdown or seed
            // review content merely because a conversation opens.
            let agenticJobService: (any AgenticJobServing)?
            if !usesReviewFixtures, let jobs = context.runJournalRepository as? any AgenticJobRepository {
                agenticJobService = AgenticJobService(repository: jobs,
                    teammates: context.teammateRepository, conversations: context.conversationRepository,
                    messages: context.messageRepository,
                    driver: NativeAgenticJobDriver(
                        preparation: NativeAgenticJobPreparation(layout: layout,
                            applicationSupportRoot: { [weak self] in await self?.claudeSetupSupportRoot }),
                        access: agenticJobAccess))
            } else { agenticJobService = nil }
            let workspace = DurableWorkspaceModel(
                mode: chatMode,
                service: service,
                textReplyService: textReplyService,
                agenticJobService: agenticJobService,
                agenticJobAccess: agenticJobAccess,
                connectorAccess: connectorAccess,
                // The user's own history, read by the app for the Access sheet's chat
                // picker; the app holds Full Disk Access, the bots do not.
                messagesChats: connectorAccess == nil ? nil : MessagesHistoryChatDirectory(),
                hiringService: hiringService,
                profileService: TeammateProfileService(
                    repository: context.teammateRepository, photoValidator: photoService
                ),
                // An archived bot's saved Claude sessions go with it: the CLI's
                // files under the app profile, then the rows.
                archiveService: TeammateArchiveService(repository: context.teammateArchiveRepository,
                    sessionRetention: ClaudeSessionRetentionService(sessions: context.claudeSessionRepository,
                                                                    profileURL: layout.claudeCLIProfileRoot)),
                teamArchiveService: TeamArchiveService(repository: context.teamArchiveRepository),
                navigationService: TeammateNavigationService(repository: context.teammateRepository),
                deletionService: TeammateDeletionService(repository: context.teammateDeletionRepository,
                    sessionRetention: ClaudeSessionRetentionService(sessions: context.claudeSessionRepository,
                                                                    profileURL: layout.claudeCLIProfileRoot),
                    connectorGrants: connectorAccess,
                    memoryRoot: layout.internalMemoryRoot),
                sidebarOrderService: BotSidebarOrderService(repository: context.botSidebarOrderRepository),
                draftService: ConversationDraftService(repository: context.conversationDraftRepository),
                searchService: ConversationSearchService(repository: context.conversationSearchRepository),
                photoImporter: photoImporter,
                photoPresentation: photoPresentation,
                attachmentDraftFactory: { conversationID in
                    AttachmentDraftModel(conversationID: conversationID,
                        load: { try await context.attachmentRepository.draft(conversationID: conversationID) },
                        importFile: { url, operationID in
                            guard let attachmentService else { throw ConversationAttachmentError.unavailable }
                            return try await attachmentService.importFile(url, operationID: operationID, conversationID: conversationID)
                        },
                        remove: { id in
                            try await context.attachmentRepository.removeDraftAttachment(id: id, conversationID: conversationID)
                        })
                },
                attachmentPresentation: AttachmentPresentation(
                    resolve: { messageID, partID, attachmentID in
                        guard let attachmentService else { throw ConversationAttachmentError.unavailable }
                        return try await attachmentService.attachment(messageID: MessageID(messageID),
                            partID: MessagePartID(partID), attachmentID: AttachmentID(attachmentID))
                    },
                    reveal: { [weak self] messageID, partID, attachmentID in
                        guard let self else { throw CancellationError() }
                        try self.requireOpen()
                        guard let attachmentService else { throw ConversationAttachmentError.unavailable }
                        let url = try await attachmentService.revealLocation(messageID: MessageID(messageID),
                            partID: MessagePartID(partID), attachmentID: AttachmentID(attachmentID))
                        try self.requireOpen()
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    },
                    preview: { messageID, partID, attachmentID, pageNumber in
                        guard let attachmentService else { throw ConversationAttachmentError.unavailable }
                        return try await attachmentService.preview(messageID: MessageID(messageID),
                            partID: MessagePartID(partID), attachmentID: AttachmentID(attachmentID),
                            pageNumber: pageNumber)
                    },
                    open: { [weak self] messageID, partID, attachmentID in
                        guard let self else { throw CancellationError() }
                        try self.requireOpen()
                        guard let attachmentService else { throw ConversationAttachmentError.unavailable }
                        let asset = try await attachmentService.attachment(messageID: MessageID(messageID),
                            partID: MessagePartID(partID), attachmentID: AttachmentID(attachmentID))
                        let url = try await attachmentService.revealLocation(messageID: MessageID(messageID),
                            partID: MessagePartID(partID), attachmentID: AttachmentID(attachmentID))
                        try self.requireOpen()
                        // Never run what a bot wrote: the chip hides Open for these,
                        // and this is the second fence, judged on the real type and name.
                        guard AttachmentOpenPolicy.mayOpen(typeIdentifier: asset.typeIdentifier, filename: asset.displayName) else {
                            throw ConversationAttachmentError.unavailable
                        }
                        // The owned copy is `<id>.blob`; the usual app gets a copy
                        // under the file's own name.
                        let copy = try AttachmentOpenPolicy.copyForOpening(of: url, named: asset.displayName, id: asset.id.persistedValue,
                            in: FileManager.default.temporaryDirectory.appending(path: "OpenBotsNext-Open", directoryHint: .isDirectory))
                        NSWorkspace.shared.open(copy)
                    },
                    save: { [weak self] messageID, partID, attachmentID in
                        guard let self else { throw CancellationError() }
                        try self.requireOpen()
                        guard let attachmentService else { throw ConversationAttachmentError.unavailable }
                        let asset = try await attachmentService.attachment(messageID: MessageID(messageID),
                            partID: MessagePartID(partID), attachmentID: AttachmentID(attachmentID))
                        let url = try await attachmentService.revealLocation(messageID: MessageID(messageID),
                            partID: MessagePartID(partID), attachmentID: AttachmentID(attachmentID))
                        try self.requireOpen()
                        // The native panel is the user's own choice of place and
                        // name; it asks before replacing, so a copy that lands on
                        // an existing file was their explicit say-so.
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = asset.displayName
                        panel.canCreateDirectories = true
                        panel.prompt = "Save"
                        panel.message = "Where should this go?"
                        guard panel.runModal() == .OK, let destination = panel.url else { return }
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.copyItem(at: url, to: destination)
                    }
                ),
                cardFixtureFactory: usesReviewFixtures ? PreviewCardFixture.make(conversationID:) : nil,
                exportService: ConversationExportService(
                    teammates: context.teammateRepository, conversations: context.conversationRepository,
                    messages: context.messageRepository),
                teamService: usesReviewFixtures ? nil : teamService,
                handoffService: usesReviewFixtures ? nil : HandoffService(repository: context.handoffRepository),
                botWorkspaces: botWorkspaces,
                workRecordService: usesReviewFixtures ? nil : ConversationWorkRecordService(
                    handoffs: context.handoffRepository, approvals: context.approvalRepository,
                    activity: context.runActivityRepository, messages: context.messageRepository,
                    teammates: context.teammateRepository),
                workerService: teammateWorkers
            )
            try requireOpen()
            try await workspace.loadInitialWorkspace(
                messageLimit: usesReviewFixtures ? 2 : 100
            )
            guard !isClosing, !Task.isCancelled else { workspace.beginShutdown(); workspace.finishShutdown(); return }
            self.workspace = workspace
            if !usesReviewFixtures { workspace.notifications = notifications }
            showsWorkspace = true
            openPendingNotification()
            startupDiagnosticCode = nil
            knowledgeAvailabilityNotice = nil
            launchReadiness.setPreviewReviewState(.ready)
        } catch {
            guard !isClosing, !Task.isCancelled else { return }
            workspace = nil
            showsWorkspace = false
            startupDiagnosticCode = Self.diagnosticCode(for: error)
            knowledgeAvailabilityNotice = nil
            launchReadiness.setPreviewReviewState(.recovery(Self.recoveryIssue(for: error)))
            if case .recovery(let issue) = launchReadiness.state,
               issue == .databaseOpenFailed || issue == .databaseValidationFailed {
                await loadRestoreOptions()
            }
        }
    }

    /// Explicit app-owned upgrade preparation, off the main actor. Failure is
    /// attachment-local; healthy text chats never enter global recovery for it.
    private func makeAttachmentService(context: StoragePersistenceContext) async -> ConversationAttachmentService? {
        guard let cache = context.storageReceipt.verifiedRoots.first(where: { $0.kind == .caches }) else { return nil }
        let support = context.applicationSupportRoot
        let ingestURL = layout.attachmentIngestRoot
        do {
            let (ingestRoot, contentRoot) = try await Task.detached(priority: .userInitiated) {
                let ingest = try AttachmentIngestRootVerifier().verify(ingestURL, inside: cache)
                let content = try AttachmentContentRootProvisioner().prepare(inside: support)
                return (ingest, content)
            }.value
            try requireOpen()
            let ingestor = AttachmentIngestor()
            let store = AttachmentContentStore(root: contentRoot)
            return ConversationAttachmentService(repository: context.attachmentRepository,
                messages: context.messageRepository,
                importer: { url, id in
                    let receipt = try await ingestor.ingest(AttachmentIngestionRequest(
                        sourceFileURL: url, ingestRoot: ingestRoot, operationID: id.rawValue))
                    do {
                        try Task.checkCancellation()
                        let published = try await store.publish(receipt: receipt, from: ingestRoot, id: id)
                        try Task.checkCancellation()
                        try await ingestor.discard(receipt, inside: ingestRoot)
                        return published
                    } catch {
                        // Only the ingestor's exact still-owned scratch may be
                        // removed. A published immutable file is never rolled back.
                        if !Task.isCancelled { try? await ingestor.discard(receipt, inside: ingestRoot) }
                        throw error
                    }
                },
                verifier: { asset in try await store.verify(id: asset.id, byteCount: asset.byteCount, sha256: asset.sha256) },
                location: { asset in try await store.verifiedURL(id: asset.id, byteCount: asset.byteCount, sha256: asset.sha256) },
                previewer: { asset, page in
                    try await store.preview(id: asset.id, byteCount: asset.byteCount, sha256: asset.sha256,
                        displayName: asset.displayName, typeIdentifier: asset.typeIdentifier, pageNumber: page)
                })
        } catch { return nil }
    }

    func beginTeammateCreation() {
        guard !isClosing, let workspace else { return }
        showsWorkspace = true
        workspace.beginTeammateCreation()
    }

    func reviewLaunchState(_ state: LaunchReadinessState) {
        guard usesReviewFixtures, !isClosing else { return }
        showsWorkspace = false
        launchReadiness.setPreviewReviewState(state)
    }

    func enterWorkspace() {
        guard !isClosing else { return }
        showsWorkspace = workspace != nil
    }

    func reviewTeammateActivity(_ activity: TeammateActivityState) {
        guard usesReviewFixtures, !isClosing, let workspace else { return }
        showsWorkspace = true
        workspace.setSelectedActivity(activity)
    }

    func reviewAppearance(_ colorScheme: ColorScheme?) {
        guard usesReviewFixtures, !isClosing else { return }
        reviewColorScheme = colorScheme
    }

    func retryStartup() {
        guard !isClosing, workspace == nil, launchReadiness.state != .opening else { return }
        didStart = false
        Task { await start() }
    }

    private func openOrBootstrapPreviewInstallation() async throws -> StoragePersistenceContext {
        try requireOpen()
        let roots = [
            layout.applicationSupportRoot.url,
            layout.cacheRoot.url,
            layout.temporaryRoot.url
        ]
        let presence = await Task.detached(priority: .userInitiated) {
            roots.map(Self.pathEntryExists)
        }.value
        try requireOpen()

        if presence.allSatisfy({ !$0 }) {
            let installationID = UUID()
            let rootIDs: [OwnedRootKind: UUID] = [
                .applicationSupport: UUID(),
                .caches: UUID(),
                .temporary: UUID()
            ]
            let plan = try PreviewRootCreationPlan(
                layout: layout,
                installationID: installationID,
                rootIDs: rootIDs
            )
            let composition = StoragePersistenceCompositionService(layout: layout)
            return try await composition.bootstrapAndOpen(
                using: plan,
                protection: PreviewDatabaseProtectionDecision.selection,
                decision: PreviewDatabaseProtectionDecision.receipt
            )
        }

        // Only an entirely absent installation may be created. Application
        // Support remains durable authority. The explicit recovery transition
        // may recreate a wholly absent cache or temporary root with the IDs in
        // the immutable receipt; any existing mismatch still fails closed.
        guard presence[0] else { throw PreviewStartupError.partialInstallation }
        let composition = StoragePersistenceCompositionService(layout: layout)
        return try await composition.recoverDisposableRootsAndReopenExisting()
    }

    nonisolated private static func pathEntryExists(_ url: URL) -> Bool {
        var information = stat()
        return url.path.withCString { lstat($0, &information) == 0 }
    }

    nonisolated private static func recoveryIssue(for error: any Error) -> LaunchRecoveryIssue {
        if error is StorageBootstrapError || error is PreviewStartupError {
            return .ownedRootVerificationFailed
        }
        guard let error = error as? StoragePersistenceCompositionError else {
            return .databaseOpenFailed
        }
        switch error {
        case .installationReceiptReadFailed:
            return .installationReceiptUnavailable
        case .invalidPlan, .invalidBootstrapReceipt, .ownedRootVerificationFailed,
             .existingRootVerificationFailed, .disposableRootRecoveryFailed,
             .installationReceiptPublicationFailed:
            return .ownedRootVerificationFailed
        case .databaseProtectionUnavailable:
            return .databaseProtectionUnavailable
        case .databaseOpenFailed:
            return .databaseOpenFailed
        case .databaseInspectionFailed, .databaseValidationFailed:
            return .databaseValidationFailed
        case .databaseNewerThanApplication:
            return .workspaceNewerThanApplication
        case .alreadyAttempted:
            return .databaseOpenFailed
        }
    }

    nonisolated private static func diagnosticCode(for error: any Error) -> String {
        if let error = error as? StorageBootstrapError {
            switch error {
            case .invalidPlan:
                return "storage-plan-invalid"
            case let .locationInspectionFailed(kind, _):
                return "storage-location-inspection-\(kind.rawValue)"
            case let .unsafeHighChurnLocation(kind, violation):
                return "storage-location-\(kind.rawValue)-\(String(describing: violation))"
            case let .filesystemPreflightFailed(kind, reason):
                return "storage-preflight-\(kind.rawValue)-\(Self.safeDiagnosticComponent(reason))"
            case let .stagingFailed(kind, _):
                return "storage-staging-\(kind.rawValue)"
            case let .publicationFailed(kind, _, _):
                return "storage-publication-\(kind.rawValue)"
            case let .verificationFailed(kind, _):
                return "storage-verification-\(kind.rawValue)"
            }
        }
        if let error = error as? PreviewStartupError {
            switch error {
            case .partialInstallation:
                return "storage-partial-installation"
            case .attachmentIngestUnavailable:
                return "storage-attachment-ingest-root"
            }
        }
        if let error = error as? StoragePersistenceCompositionError {
            switch error {
            case .alreadyAttempted: return "composition-already-attempted"
            case .invalidPlan: return "composition-plan-invalid"
            case .invalidBootstrapReceipt: return "composition-bootstrap-receipt"
            case let .ownedRootVerificationFailed(_, kind, _):
                return "composition-root-\(kind.rawValue)"
            case .installationReceiptPublicationFailed:
                return "composition-installation-receipt-publication"
            case .installationReceiptReadFailed:
                return "composition-installation-receipt-read"
            case let .existingRootVerificationFailed(_, kind, _):
                return "composition-existing-root-\(kind.rawValue)"
            case .disposableRootRecoveryFailed:
                return "composition-disposable-root-recovery"
            case .databaseProtectionUnavailable:
                return "composition-database-protection"
            case .databaseOpenFailed:
                return "composition-database-open"
            case .databaseNewerThanApplication:
                return "composition-database-newer-than-app"
            case .databaseInspectionFailed:
                return "composition-database-inspection"
            case .databaseValidationFailed:
                return "composition-database-validation"
            }
        }
        return "startup-unexpected"
    }

    nonisolated private static func safeDiagnosticComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
    }

    private static func unavailableKnowledgeModel() -> KnowledgeWorkspaceModel {
        KnowledgeWorkspaceModel(
            loader: { _ in throw PreviewKnowledgeUnavailableError.authorityVerificationFailed },
            revealer: { _, _ in
                throw PreviewKnowledgeUnavailableError.authorityVerificationFailed
            },
            chooseSnapshotDestination: { _ in nil },
            createSnapshot: { _, _ in
                throw PreviewKnowledgeUnavailableError.authorityVerificationFailed
            },
            releaseSnapshotDestination: { _ in }
        )
    }

    nonisolated private static func knowledgePresentation(
        _ snapshot: MemoryKnowledgeWorkspaceSnapshot,
        context: KnowledgeWorkspaceContext
    ) -> KnowledgeWorkspaceSnapshot {
        KnowledgeWorkspaceSnapshot(
            id: snapshot.id,
            context: context,
            documents: snapshot.documents.map { item in
                let scope: KnowledgeDocumentScopePresentation
                switch item.document.scope {
                case .user:
                    scope = .user
                case let .teammate(teammateID):
                    scope = .teammate(
                        id: teammateID.rawValue,
                        name: teammateID.rawValue == context.teammateID
                            ? context.teammateName
                            : "Teammate"
                    )
                case let .project(projectID):
                    scope = .project(
                        id: projectID.rawValue,
                        name: projectID.rawValue == context.selectedProjectID
                            ? (context.selectedProjectName ?? "Selected project")
                            : "Project"
                    )
                }

                let author: KnowledgeDocumentAuthorPresentation
                switch item.document.author {
                case .user:
                    author = .user(displayName: "Alex")
                case let .teammate(teammateID):
                    author = .teammate(
                        id: teammateID.rawValue,
                        name: teammateID.rawValue == context.teammateID
                            ? context.teammateName
                            : "Teammate"
                    )
                case .system:
                    author = .system(label: "OpenBots")
                }

                let recovery: KnowledgeDocumentRecoveryPresentation
                if let unavailableRevision = item.unavailableNewerRevision {
                    recovery = .lastKnownGood(
                        unavailableRevision: unavailableRevision,
                        explanation: "The current revision could not be verified, so OpenBots is showing the last known good revision."
                    )
                } else {
                    recovery = .current
                }
                return KnowledgeDocumentPresentation(
                    id: item.document.id.rawValue,
                    title: item.document.title,
                    scope: scope,
                    author: author,
                    revision: item.document.revision,
                    updatedAt: item.document.updatedAt,
                    markdown: item.markdown,
                    recovery: recovery
                )
            },
            excludedDocumentCount: snapshot.excludedDocumentCount
        )
    }

    private static func chooseKnowledgeSnapshotDestination(
        suggestedFileName: String
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Create Non-Authoritative Knowledge Snapshot"
        panel.message = "Choose one exact local file. OpenBots will create a new snapshot and never overwrite an existing item."
        panel.prompt = "Choose"
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.url : nil
    }
}

private enum PreviewStartupError: Error {
    case partialInstallation
    case attachmentIngestUnavailable
}

private actor PreviewKnowledgeSeeder {
    private let repository: any MemoryRepository

    init(repository: any MemoryRepository) {
        self.repository = repository
    }

    func ensureSampleKnowledge(
        for context: KnowledgeWorkspaceContext,
        using service: MemoryKnowledgeService
    ) async throws {
        if try await repository.documents(scope: .user).isEmpty {
            _ = try await service.publishRevision(
                title: "How Alex likes updates",
                scope: .user,
                author: .user,
                markdown: """
                # How Alex likes updates

                This is preview sample knowledge stored in the real app-owned Markdown authority.

                Prefer short, plain-English milestone updates with verified outcomes and honest limitations.
                """
            )
        }

        let teammateID = TeammateID(context.teammateID)
        let teammateScope = MemoryScope.teammate(teammateID)
        if try await repository.documents(scope: teammateScope).isEmpty {
            _ = try await service.publishRevision(
                title: "\(context.teammateName)’s working approach",
                scope: teammateScope,
                author: .teammate(teammateID),
                markdown: """
                # \(context.teammateName)’s working approach

                This is preview sample knowledge stored in the real app-owned Markdown authority.

                Keep evidence traceable, surface blockers early, and return finished work in the active conversation.
                """
            )
        }

        if let selectedProjectID = context.selectedProjectID,
           context.activeProjectMembershipIDs.contains(selectedProjectID) {
            let projectID = ProjectID(selectedProjectID)
            let projectScope = MemoryScope.project(projectID)
            if try await repository.documents(scope: projectScope).isEmpty {
                let projectName = context.selectedProjectName ?? "Selected project"
                _ = try await service.publishRevision(
                    title: "\(projectName) brief",
                    scope: projectScope,
                    author: .user,
                    markdown: """
                    # \(projectName) brief

                    This is preview sample knowledge stored in the real app-owned Markdown authority.

                    Project memory is available only while the teammate is an active member of this selected project.
                    """
                )
            }
        }
    }
}

private enum PreviewKnowledgeUnavailableError: Error {
    case authorityVerificationFailed
}

struct PreviewWindow: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var composition: AppCompositionRoot
    @ObservedObject var appearance: WorkspaceAppearanceModel
    let showClaudeSetup: @MainActor () -> Void
    /// Selects one Settings pane before Settings opens (the Access sheet's
    /// Open Settings).
    let showSettingsSection: @MainActor (WorkspaceSettingsSection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if composition.usesReviewFixtures {
                reviewFixtureBanner
            }
            if composition.isClosing {
                Text("Closing OpenBots. Saving available local changes briefly…")
                    .font(.callout).padding(8).accessibilityAddTraits(.updatesFrequently)
            } else if let notice = composition.sessionRecoveryNotice {
                Text(notice).font(.callout).padding(8).fixedSize(horizontal: false, vertical: true)
            }
            if !composition.isClosing, let notice = composition.memoryRecoveryNotice {
                Text(notice).font(.callout).padding(8).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Local memory recovery. " + notice)
            }
            if !composition.isClosing, let notice = composition.textTurnRecoveryNotice {
                Text(notice).font(.callout).padding(8).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Saved reply recovery. " + notice)
            }
            if !composition.isClosing, composition.sessionRecoveryNotice != nil
                || composition.memoryRecoveryNotice != nil || composition.textTurnRecoveryNotice != nil {
                // One OK for all of them: they are news, not a standing state.
                HStack {
                    Spacer()
                    Button("OK") { composition.dismissRecoveryNotices() }
                        .help("Hide these notes. Nothing they describe is undone.")
                        .accessibilityIdentifier("window.recoveryNotices.ok")
                }
                .padding(.horizontal, 8).padding(.bottom, 6)
            }
            if composition.usesReviewFixtures || composition.isClosing
                || composition.sessionRecoveryNotice != nil || composition.memoryRecoveryNotice != nil
                || composition.textTurnRecoveryNotice != nil {
                Divider()
            }
            content
                .disabled(composition.isClosing)
        }
        .preferredColorScheme(composition.reviewColorScheme ?? appearance.selection.colorScheme)
        .task {
            await composition.start()
        }
    }

    @ViewBuilder
    private var content: some View {
        if composition.showsWorkspace {
            if let workspace = composition.workspace {
                DurableWorkspaceView(
                    model: workspace,
                    openSettings: { openSettings() },
                    openClaudeSetup: {
                        showClaudeSetup()
                        openSettings()
                    },
                    openSettingsPane: { section in
                        showSettingsSection(section)
                        openSettings()
                    }
                )
            }
        } else {
            LaunchStatusView(
                model: composition.launchReadiness,
                performsAutomaticRefresh: false,
                isApplicationStartup: !composition.usesReviewFixtures,
                retryAction: composition.retryStartup,
                restoreOptions: composition.restoreOptions,
                restoreAction: composition.restoreBackup,
                continueAction: composition.enterWorkspace
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var reviewFixtureBanner: some View {
        Label(
            reviewFixtureDisclosure,
            systemImage: "externaldrive.badge.checkmark"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .accessibilityLabel(reviewFixtureDisclosure)
    }

    private var reviewFixtureDisclosure: String {
        let base: String
        if composition.showsWorkspace {
            base = "Durable local preview — teammates and conversations use protected ordinary SQLite. Replies, hiring guidance, and inline cards remain local fixtures. The app runtime, real Keychain client, provider authentication, and network remain disabled."
        } else {
            base = "Local preview startup — app-owned storage may be verified or created. The app runtime, real Keychain client, and network remain disabled."
        }
        return base
            + (composition.startupDiagnosticCode.map { " Recovery code: \($0)." } ?? "")
    }
}
