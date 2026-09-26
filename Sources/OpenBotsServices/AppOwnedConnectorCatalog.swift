import CryptoKit
import Darwin
import Foundation
import OpenBotsDomain

/// The connectors the app itself pins, listed beside the ones Claude Code has
/// configured on this Mac.
///
/// Why a second source at all: the connector catalog contains rows no
/// plugin provides — Apple Mail and its sender, Messages — and a row imported
/// from a plugin may carry no environment of its own by design, which the app's
/// own servers need. So these entries are written here, in the app, pinned to
/// an exact version, and they say plainly what they drive and what they need.
///
/// Like the plugin catalog, this reads and never runs: it checks whether the
/// program is on the disk and whether the app it drives is installed, and turns
/// that into the row's badge. It never launches a server, a package manager or
/// an Apple Event, so opening Settings costs nothing and asks nobody for
/// permission. Whether an Apple Event will actually be *allowed* cannot be
/// known without sending one, so that answer belongs to the turn, not here.
public struct AppOwnedConnectorCatalog: ConnectorCatalogReading {
    /// The pinned reader for Apple Mail. With `--read-only` the package
    /// registers only its reading tools; no send or delete tool exists to be
    /// called.
    ///
    /// It normally reads through AppleScript, which stores no password
    /// anywhere. It also carries an IMAP fast path that it takes *first* when a
    /// Keychain item named `apple-mail-mcp.imap.<account>` exists — created by
    /// the package's own `setup-imap`, never by this app. Where that item
    /// exists, a read reaches the mail provider over the network, outside the
    /// web switches, which are otherwise the only door out. This app cannot
    /// interpose on it: the host and port come from Mail itself and the
    /// password from the login Keychain, so neither an app-owned home nor the
    /// environment allow-list closes it. Recorded here as a known gap rather
    /// than assumed away.
    public static let appleMailPackage = "apple-mail-fast-mcp"
    public static let appleMailVersion = "0.10.2"
    /// The console script a tool install writes, and the two places it writes
    /// it. The app never installs it: absent, the row says so.
    public static func appleMailToolURLs(homeDirectoryURL: URL) -> [URL] {
        [homeDirectoryURL.appendingPathComponent(".local/share/uv/tools/\(appleMailPackage)/bin/\(appleMailPackage)"),
         homeDirectoryURL.appendingPathComponent(".local/bin/\(appleMailPackage)")]
    }
    public static let mailApplicationURLs = [
        URL(fileURLWithPath: "/System/Applications/Mail.app"),
        URL(fileURLWithPath: "/Applications/Mail.app"),
    ]
    public static let contactsApplicationURLs = [
        URL(fileURLWithPath: "/System/Applications/Contacts.app"),
        URL(fileURLWithPath: "/Applications/Contacts.app"),
    ]
    public static let messagesApplicationURLs = [
        URL(fileURLWithPath: "/System/Applications/Messages.app"),
        URL(fileURLWithPath: "/Applications/Messages.app"),
    ]

    /// The user's Messages history. Always built from the real home the app runs in,
    /// never from the CLI child's HOME, which is the app's own profile.
    public static func messagesDatabaseURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent("Library/Messages/chat.db", isDirectory: false)
    }

    private let homeDirectoryURL: URL
    private let mailApplicationCandidateURLs: [URL]
    private let contactsApplicationCandidateURLs: [URL]
    private let messagesApplicationCandidateURLs: [URL]
    private let calendarHelperCandidateURLs: [URL]
    private let googleHelperCandidateURLs: [URL]
    private let googleClientID: String?
    private let tools: InstalledToolResolution

    public init(homeDirectoryURL: URL,
                mailApplicationCandidateURLs: [URL] = AppOwnedConnectorCatalog.mailApplicationURLs,
                contactsApplicationCandidateURLs: [URL] = AppOwnedConnectorCatalog.contactsApplicationURLs,
                messagesApplicationCandidateURLs: [URL] = AppOwnedConnectorCatalog.messagesApplicationURLs,
                calendarHelperCandidateURLs: [URL] = AppOwnedConnectorCatalog.appleCalendarHelperURLs,
                googleHelperCandidateURLs: [URL] = GoogleWorkspaceConnectorPreparation.helperURLs,
                googleClientID: String? = GoogleWorkspaceClientConfiguration.clientID(),
                ownerUID: uid_t = getuid()) {
        self.homeDirectoryURL = homeDirectoryURL
        self.mailApplicationCandidateURLs = mailApplicationCandidateURLs
        self.contactsApplicationCandidateURLs = contactsApplicationCandidateURLs
        self.messagesApplicationCandidateURLs = messagesApplicationCandidateURLs
        self.calendarHelperCandidateURLs = calendarHelperCandidateURLs
        self.googleHelperCandidateURLs = googleHelperCandidateURLs
        self.googleClientID = googleClientID
        self.tools = InstalledToolResolution(ownerUID: ownerUID)
    }

    /// The sender the app ships itself: `Resources/apple-mail-send.js`.
    public static var appleMailSendScriptURL: URL? {
        ServicesResourceBundle.url(forResource: "apple-mail-send", withExtension: "js")
    }

    /// The contacts reader the app ships itself: `Resources/apple-contacts.js`.
    public static var appleContactsScriptURL: URL? {
        ServicesResourceBundle.url(forResource: "apple-contacts", withExtension: "js")
    }

    /// The calendar server the app ships itself: `Resources/apple-calendar.js`.
    public static var appleCalendarScriptURL: URL? {
        ServicesResourceBundle.url(forResource: "apple-calendar", withExtension: "js")
    }

    /// The identity id of the app's own Messages row, the one row whose bots
    /// read only the chats the user chose.
    public static let messagesConnectorID = "openbots:apple-messages:apple-messages"
    /// The app's own Contacts reader, which a bot given Messages needs to find
    /// people's numbers by name.
    public static let contactsConnectorID = "openbots:apple-contacts:apple-contacts"

    /// The Messages server the app ships itself: `Resources/apple-messages.js`.
    public static var appleMessagesScriptURL: URL? {
        ServicesResourceBundle.url(forResource: "apple-messages", withExtension: "js")
    }

    /// The MCP surface shared by the Gmail, Google Calendar and Drive rows. The launch
    /// selects one closed tool table; tokens stay in the helper below.
    public static var googleWorkspaceScriptURL: URL? {
        GoogleWorkspaceConnectorPreparation.scriptURL
    }

    public static var googleWorkspaceHelperURLs: [URL] {
        GoogleWorkspaceConnectorPreparation.helperURLs
    }

    /// The name of the binary that does the actual reading.
    public static let appleCalendarHelperName = "openbots-calendar-read"

    /// Where that binary is, and it is the one app-owned connector that needs a
    /// program of its own rather than a script.
    ///
    /// Why a binary at all is argued in `apple-calendar.js`: Apple Events
    /// cannot expand a recurring series, so no JavaScript reader can be
    /// correct. EventKit can, and EventKit is not reachable from node.
    ///
    /// In the installed app it sits in `Contents/MacOS`, beside the app's own
    /// executable — `project.yml` copies it there with `destination:
    /// executables` — so it is inside the bundle and signed with the app, and
    /// macOS attributes its calendar access to the app rather than to the
    /// helper. Proved on a real Mac: one prompt, answered once, covered it. A
    /// helper signed separately would be asked about separately, which on the
    /// user's screen looks exactly like a prompt they never answered.
    ///
    /// `Contents/Helpers` is looked at first anyway. Nothing puts it there
    /// today; it is the conventional location and costs one `stat`. Under
    /// `swift test` there is no bundle at all, so the last candidate is whatever
    /// directory the running program sits in, which is where SwiftPM puts an
    /// executable product.
    public static var appleCalendarHelperURLs: [URL] {
        var candidates: [URL] = []
        if let helpers = Bundle.main.builtInPlugInsURL?
            .deletingLastPathComponent().appendingPathComponent("Helpers") {
            candidates.append(helpers.appendingPathComponent(appleCalendarHelperName))
        }
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executable.appendingPathComponent(appleCalendarHelperName))
        }
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent(appleCalendarHelperName))
        return candidates
    }

    /// The first of those that is actually there and runnable.
    public static func resolvedAppleCalendarHelperURL(
        candidates: [URL] = AppOwnedConnectorCatalog.appleCalendarHelperURLs) -> URL? {
        candidates.first { FileManager().isExecutableFile(atPath: $0.path) }?.standardizedFileURL
    }

    public static func resolvedGoogleWorkspaceHelperURL(
        candidates: [URL] = AppOwnedConnectorCatalog.googleWorkspaceHelperURLs,
        ownerUID: uid_t = getuid()) -> URL? {
        InstalledToolResolution(ownerUID: ownerUID).firstResolved(of: candidates)
    }

    public func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot {
        try Task.checkCancellation()
        let google = googleCatalogState()
        return ConnectorCatalogSnapshot(
            connectors: [appleMailReadOnly(), appleMailSend(), appleContactsReadOnly(),
                         appleCalendarReadOnly(), appleMessages(), macControl(), googleGmailReadAndDraft(google),
                         googleGmailSend(google), googleCalendarReadOnly(google), googleDriveReadOnly(google)],
            excludedCount: 0)
    }

    /// Where the one OpenBots Google account is connected. The same words sit
    /// under a Google row in Settings, where the account section is above the
    /// rows, and on a bot's Access sheet, where there is none, so they name the
    /// place rather than a direction ("connected below" was false in both).
    static let googleAccountLine = "Uses the OpenBots Google account connected in Settings → Connectors & Skills."

    /// The separate OpenBots account's Gmail. Google has no draft-only OAuth
    /// scope: `gmail.compose` technically authorizes sends at Google's API even
    /// though this connector contains no send tool or endpoint. The row says
    /// that plainly rather than presenting the provider grant as narrower than
    /// it is.
    private func googleGmailReadAndDraft(_ state: GoogleCatalogState) -> ConfiguredConnector {
        row(connector: "google-gmail", server: "google-gmail",
            title: "Gmail — read and draft (OpenBots account)",
            summary: "Reads and searches the separate OpenBots Gmail account, and saves new drafts. "
                + "Nothing in this connector can send, delete or organise mail; saving a draft asks first.\n"
                + "Google's narrowest draft-capable permission also technically permits sending at "
                + "Google's API. OpenBots does not expose a send tool or send endpoint in this row; "
                + "sending is the Gmail send row, with its own switch.\n"
                + Self.googleAccountLine,
            availability: state.availability,
            launch: .init(serverKey: "", transport: .stdio,
                          command: GoogleWorkspaceConnectorPreparation.gmailCommand,
                          arguments: ["--client-id", googleClientID ?? "not-configured"]),
            identityBinding: state.identityBinding, holdsPriorIdentity: state.holdsPriorIdentity)
    }

    /// Sending from the OpenBots Gmail account, in its own row and grant:
    /// reading and sending are different powers, as they are for Apple
    /// Mail. It uses the permission the account already holds, so turning it on
    /// asks for no new sign-in.
    private func googleGmailSend(_ state: GoogleCatalogState) -> ConfiguredConnector {
        row(connector: "google-gmail-send", server: "google-gmail-send",
            title: "Gmail — send (OpenBots account)",
            summary: "Sends a new email from the separate OpenBots Gmail account. Every message is shown "
                + "to you as a card first — the account, every recipient, the subject and the whole "
                + "text — and only that exact message can go. It cannot read mail; that is the row above.\n"
                + Self.googleAccountLine,
            availability: state.availability,
            launch: .init(serverKey: "", transport: .stdio,
                          command: GoogleWorkspaceConnectorPreparation.gmailSendCommand,
                          arguments: ["--client-id", googleClientID ?? "not-configured"]),
            identityBinding: state.identityBinding, holdsPriorIdentity: state.holdsPriorIdentity)
    }

    /// Google Calendar is a separate row and grant even though it shares the
    /// one OAuth account. Its two scopes can list calendars and read events;
    /// neither can create, edit or delete one.
    private func googleCalendarReadOnly(_ state: GoogleCatalogState) -> ConfiguredConnector {
        row(connector: "google-calendar", server: "google-calendar",
            title: "Google Calendar (OpenBots account, read-only)",
            summary: "Reads calendars and events belonging to the separate OpenBots Google account. "
                + "Nothing can be added, changed or deleted; no tool or write scope for that exists.\n"
                + Self.googleAccountLine,
            availability: state.availability,
            launch: .init(serverKey: "", transport: .stdio,
                          command: GoogleWorkspaceConnectorPreparation.calendarCommand,
                          arguments: ["--client-id", googleClientID ?? "not-configured"]),
            identityBinding: state.identityBinding, holdsPriorIdentity: state.holdsPriorIdentity)
    }

    /// Google Drive is a third row and grant on the same OAuth account. Its
    /// permission is Drive's read-only one; the tools read, and nothing else.
    private func googleDriveReadOnly(_ state: GoogleCatalogState) -> ConfiguredConnector {
        row(connector: "google-drive", server: "google-drive",
            title: "Google Drive (OpenBots account, read-only)",
            summary: "Searches and reads files in the separate OpenBots Google account's Drive: Docs, Sheets "
                + "and Slides as text, and plain-text files. Nothing can be created, changed, shared or deleted; "
                + "no tool or write permission for that exists.\n"
                + Self.googleAccountLine,
            availability: state.availability,
            launch: .init(serverKey: "", transport: .stdio,
                          command: GoogleWorkspaceConnectorPreparation.driveCommand,
                          arguments: ["--client-id", googleClientID ?? "not-configured"]),
            identityBinding: state.identityBinding, holdsPriorIdentity: state.holdsPriorIdentity)
    }

    private struct GoogleCatalogState {
        let availability: ConnectorAvailability
        /// A connection instance, not an email address. It changes on every
        /// authorization, including a same-account reconnect, and therefore
        /// revokes old per-bot grants through the existing digest reconciliation.
        let identityBinding: String
        /// Whether this read said nothing definite about the account: the
        /// helper did not answer, the Keychain would not open, or this build
        /// cannot ask at all. Only connected, disconnected and cleanup-pending
        /// are answers; anything else keeps the identity the row already had.
        var holdsPriorIdentity = false
    }

    private func googleCatalogState() -> GoogleCatalogState {
        guard let googleClientID else {
            return .init(availability: .needsSetup(
                "This build needs a new Google Desktop OAuth client before the account can be connected."),
                identityBinding: "unconfigured", holdsPriorIdentity: true)
        }
        guard Self.googleWorkspaceScriptURL != nil,
              let helper = Self.resolvedGoogleWorkspaceHelperURL(candidates: googleHelperCandidateURLs) else {
            return .init(availability: .unavailable(
                "This build is missing the Google connector. Reinstall the app."),
                identityBinding: "unavailable", holdsPriorIdentity: true)
        }
        let preparation = GoogleWorkspaceConnectorPreparation(helperCandidateURLs: [helper])
        let status = preparation.connectionStatus(clientID: googleClientID, helperURL: helper)
        switch status.state {
        case .connected:
            guard let connectionID = status.connectionID else {
                return .init(availability: .needsSetup(
                    "The saved Google authorization has no connection identity. Disconnect and connect it again."),
                    identityBinding: "invalid", holdsPriorIdentity: true)
            }
            return .init(availability: .ready,
                         identityBinding: connectionID.uuidString.lowercased())
        case .disconnected:
            return .init(availability: .needsSetup(
                "Connect the separate OpenBots Google account below. OpenBots never sees its password."),
                identityBinding: "disconnected")
        case .revocationPending:
            return .init(availability: .needsSetup(status.reason
                ?? "Google access is disabled locally; finish provider cleanup below."),
                identityBinding: "revocation-pending")
        case .invalid:
            return .init(availability: .needsSetup(status.reason
                ?? "Reconnect the OpenBots Google account below."),
                identityBinding: "invalid", holdsPriorIdentity: true)
        }
    }

    /// The user's address book, read and nothing else.
    ///
    /// It comes before the rest of the catalog: without it the mail and
    /// Messages rows guess at addresses the user's Mac already holds, or
    /// interrupt the user for one they saved years ago.
    ///
    /// The row cannot say whether macOS will *allow* the lookup — Automation is
    /// asked for per target app and answered by the user at the first Apple event,
    /// and a Mac that already lets this app drive Mail has still never been
    /// asked about Contacts. So the badge answers only what can be known
    /// without sending one: Contacts is on the disk, and the reader is in the
    /// bundle. The permission itself is the turn's business, and the reader
    /// says so in plain words when it is refused.
    private func appleContactsReadOnly() -> ConfiguredConnector {
        let availability: ConnectorAvailability
        if !contactsApplicationCandidateURLs.contains(where: { FileManager().fileExists(atPath: $0.path) }) {
            availability = .unavailable("Contacts is not installed on this Mac.")
        } else if Self.appleContactsScriptURL == nil {
            availability = .unavailable("This build is missing the contacts reader. Reinstall the app.")
        } else {
            availability = .ready
        }
        return row(connector: "apple-contacts", server: "apple-contacts",
                   title: "Contacts (read-only)",
                   summary: "Looks people up in your own Contacts — email addresses, phone numbers, "
                       + "postal addresses and where they work — so a bot writing to someone uses the "
                       + "address you already saved instead of asking you for it. Nothing can be "
                       + "added, changed or deleted; no tool for that exists.\n"
                       + "Needs permission for OpenBots Next to control Contacts, which macOS asks "
                       + "for the first time a bot looks someone up.",
                   availability: availability,
                   launch: .init(serverKey: "", transport: .stdio,
                                 command: AppleContactsConnectorPreparation.command, arguments: []))
    }

    /// The user's calendar, read and nothing else.
    ///
    /// Note what is NOT checked here, and it is a difference from every other
    /// app-owned row: whether Calendar.app is installed. This reader does not
    /// drive Calendar — it reads the store through EventKit — so a Mac without
    /// Calendar.app would still answer, and a row saying "Calendar is not
    /// installed" would be naming the wrong cause. What it does need is the
    /// binary that does the reading, and that is what the badge is about.
    private func appleCalendarReadOnly() -> ConfiguredConnector {
        let availability: ConnectorAvailability
        if Self.appleCalendarScriptURL == nil {
            availability = .unavailable("This build is missing the calendar reader. Reinstall the app.")
        } else if Self.resolvedAppleCalendarHelperURL(candidates: calendarHelperCandidateURLs) == nil {
            availability = .unavailable("This build is missing the calendar reader. Reinstall the app.")
        } else {
            availability = .ready
        }
        return row(connector: "apple-calendar", server: "apple-calendar",
                   title: "Calendar (read-only)",
                   summary: "Reads your own calendars — what is on a given day or week, and one "
                       + "event in full with the people on it and their email addresses, so a bot "
                       + "can write to everyone in a meeting without asking you who was there. "
                       + "Repeating events are read as the days they actually fall on. Nothing can "
                       + "be added, changed or deleted; no tool for that exists.\n"
                       + "Needs permission for OpenBots Next to use your Calendars, which macOS asks "
                       + "for the first time a bot looks. That is the Calendars pane in Privacy & "
                       + "Security, not the Automation one the mail and contacts rows use.",
                   availability: availability,
                   launch: .init(serverKey: "", transport: .stdio,
                                 command: AppleCalendarConnectorPreparation.command, arguments: []))
    }

    /// Texts from the user's own number, and their conversations read back.
    ///
    /// Ported from the old app's own server. One row, because the old app had one: the reads
    /// are what a send needs (which service reaches this person), and every
    /// send is still a card of its own, recipient, service and words.
    ///
    /// The badge answers only what can be known here without asking anybody:
    /// Messages is on the disk and the server is in the bundle. Whether this
    /// app may read the user's history is Full Disk Access, and that is checked by
    /// the row's preparation by actually opening the database — a probe that
    /// sits beside this catalog and overrides a ready badge with needs setup.
    private func appleMessages() -> ConfiguredConnector {
        let availability: ConnectorAvailability
        if !messagesApplicationCandidateURLs.contains(where: { FileManager().fileExists(atPath: $0.path) }) {
            availability = .unavailable("Messages is not installed on this Mac.")
        } else if Self.appleMessagesScriptURL == nil {
            availability = .unavailable("This build is missing the Messages connector. Reinstall the app.")
        } else {
            availability = .ready
        }
        return row(connector: "apple-messages", server: "apple-messages",
                   title: "Messages (iMessage, RCS, SMS)",
                   summary: "Sends texts from your own number on the right service — Messages already "
                       + "knows who is on iMessage, RCS or SMS, so Android contacts receive them — and "
                       + "reads only the conversations you choose for each bot on its Access sheet. Every "
                       + "text is shown to you as a card first, with the recipient, the service and the "
                       + "exact words.\n"
                       + "Needs Full Disk Access for OpenBots Next to read your messages, and permission "
                       + "for OpenBots Next to control Messages, which macOS asks for at the first send.",
                   availability: availability,
                   launch: .init(serverKey: "", transport: .stdio,
                                 command: AppleMessagesConnectorPreparation.command, arguments: []))
    }

    /// Control this Mac: the old app's Peekaboo connector, carried over as a
    /// trial. The pinned package is part of the
    /// row's identity, so a different Peekaboo version revokes every grant.
    /// Whether the copy is on the disk and whether the app holds Accessibility
    /// and Screen Recording is the preparation's probe, beside this catalog.
    private func macControl() -> ConfiguredConnector {
        row(connector: "mac-control", server: "peekaboo",
            title: "Control this Mac",
            summary: "Lets a bot see your screen and click, type and press keys in your apps, as you, "
                + "through Peekaboo \(MacControlConnectorPreparation.pinnedVersion). The first action of "
                + "each reply is shown to you as a card, and Allow for this turn lets it keep going until "
                + "the reply ends. Peekaboo's own quit and open ask every time, but under that allowance "
                + "a click, a shortcut or a menu can still quit an app, lose unsaved work or open a link "
                + "or a file. For a sign-in, a password, a payment or a permission dialog the bot hands you "
                + "the screen with a card, and nothing of it runs until you hand it back; before a deletion "
                + "it is told to stop and ask. Stop ends it at once.\n"
                + "Needs Accessibility and Screen Recording for OpenBots Next.",
            availability: .ready,
            launch: .init(serverKey: "", transport: .stdio, command: MacControlConnectorPreparation.command,
                          arguments: [], pinnedPackage: "\(MacControlConnectorPreparation.packageName)@\(MacControlConnectorPreparation.pinnedVersion)"))
    }

    /// Sending as the user, in its own row and its own grant.
    ///
    /// Separate from reading on purpose: reading the user's mailbox and sending as them
    /// are different powers, and the old app kept them apart for the same
    /// reason. This one is the app's own node server, so its answers are the
    /// app's own words and it is not fenced; every send is shown to the user as a
    /// card naming the account, the recipient and the subject.
    private func appleMailSend() -> ConfiguredConnector {
        let availability: ConnectorAvailability
        if !mailApplicationCandidateURLs.contains(where: { FileManager().fileExists(atPath: $0.path) }) {
            availability = .unavailable("Mail is not installed on this Mac.")
        } else if Self.appleMailSendScriptURL == nil {
            availability = .unavailable("This build is missing the mail sender. Reinstall the app.")
        } else {
            availability = .ready
        }
        return row(connector: "apple-mail-send", server: "apple-mail-send",
                   title: "Apple Mail — send, as you",
                   summary: "Sends or drafts mail through your own Mail, as you. Every send names the "
                       + "account it goes from — there is no default — and each one is shown to you as "
                       + "a card first.\n"
                       + "Needs Mail running, and permission for OpenBots Next to control Mail.",
                   availability: availability,
                   launch: .init(serverKey: "", transport: .stdio, command: "apple-mail-send",
                                 arguments: []))
    }

    // MARK: - The rows

    private func appleMailReadOnly() -> ConfiguredConnector {
        let package = Self.appleMailPackage
        let pinned = "\(package)==\(Self.appleMailVersion)"
        let script = tools.firstResolved(of: Self.appleMailToolURLs(homeDirectoryURL: homeDirectoryURL))
        let availability: ConnectorAvailability
        if !mailApplicationCandidateURLs.contains(where: { FileManager().fileExists(atPath: $0.path) }) {
            availability = .unavailable("Mail is not installed on this Mac.")
        } else if script == nil {
            availability = .needsSetup("The mail reader is not installed yet. Install it once with "
                + "`uv tool install \(pinned)`.")
        } else {
            availability = .ready
        }
        return row(connector: "apple-mail", server: "apple-mail",
                   title: "Apple Mail (read-only)",
                   summary: "Reads and searches your own Mail.app — no send or delete tool exists to be "
                       + "called, and this app stores no mail password.\n"
                       + "Needs Mail running, and permission for OpenBots Next to control Mail.",
                   availability: availability,
                   launch: .init(serverKey: "", transport: .stdio, command: package,
                                 arguments: ["--read-only"], pinnedPackage: pinned))
    }

    // MARK: - Identity

    /// The same shape the plugin catalog mints, with the app as the source:
    /// `openbots:<connector>:<server>`, and a server key that is a hash of it
    /// so the tool namespace is stable, opaque and JSON-safe.
    ///
    /// The digest covers everything the launch would actually do, so changing a
    /// pin — a new version, a different flag — is a definition change, and the
    /// store revokes the grants that were given to the old one.
    private func row(connector: String, server: String, title: String, summary: String,
                     availability: ConnectorAvailability,
                     launch: ConnectorLaunchConfiguration,
                     identityBinding: String? = nil, holdsPriorIdentity: Bool = false) -> ConfiguredConnector {
        let id = "\(ConnectorSource.appOwned.rawValue):\(connector):\(server)"
        let serverKey = "openbots_" + Self.hash(Data(id.utf8))
        var canonical: [String: Any] = ["namespace": id, "type": launch.transport.rawValue,
                                        "command": launch.command ?? "", "args": launch.arguments]
        if let pinnedPackage = launch.pinnedPackage { canonical["package"] = pinnedPackage }
        if let identityBinding { canonical["connection"] = identityBinding }
        let digest = Self.hash((try? JSONSerialization.data(withJSONObject: canonical,
            options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data())
        // The identity's shape is checked by the domain; these are literals in
        // this file, so a throw here would be a programming error, not input.
        guard let identity = try? ConnectorIdentity(id: id, digest: digest) else {
            preconditionFailure("app-owned connector identity is malformed: \(id)")
        }
        return ConfiguredConnector(
            definition: .init(identity: identity, serverName: server, pluginName: "OpenBots Next",
                              transport: launch.transport, title: title, summary: summary,
                              availability: availability),
            launch: .init(serverKey: serverKey, transport: launch.transport, command: launch.command,
                          arguments: launch.arguments, url: launch.url, pinnedPackage: launch.pinnedPackage),
            holdsPriorIdentity: holdsPriorIdentity)
    }

    /// The same hash the rows are minted with, so a test can vary one input
    /// and compare rather than reimplementing the recipe.
    static func digestForTesting(_ data: Data) -> String { hash(data) }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
