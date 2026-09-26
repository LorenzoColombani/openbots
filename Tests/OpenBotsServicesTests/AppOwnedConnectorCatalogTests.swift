import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

private let googleCatalogConnectionID = UUID(uuidString: "7300ad79-0b68-4fd8-b165-b011c929d1c1")!

/// A real home directory with a real console script in it, laid out the way a
/// tool install actually writes one: the program under
/// `.local/share/uv/tools/<package>/bin/<package>`, and a symlink to it in
/// `.local/bin`. Tests built to a shape no Mac produces have let defects
/// through before, so nothing here is faked.
private struct MailFixture {
    let root: URL
    let home: URL
    let mailApplication: URL
    let contactsApplication: URL
    let messagesApplication: URL
    let calendarHelper: URL
    let googleHelper: URL

    init(installTool: Bool = true, throughSymlink: Bool = false, permissions: Int16 = 0o755,
         installMail: Bool = true, installContacts: Bool = true, installMessages: Bool = true,
         installCalendarHelper: Bool = true,
         googleStatus: GoogleWorkspaceConnectionStatus = .init(state: .connected,
             accountEmail: "openbots@example.com", connectionID: googleCatalogConnectionID)) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("openbots-mail-catalog-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        mailApplication = root.appendingPathComponent("Applications/Mail.app", isDirectory: true)
        // Named here rather than left to the real Mac: a row whose badge is
        // decided by whatever happens to be installed on the machine running
        // the suite is a row nobody can assert on.
        contactsApplication = root.appendingPathComponent("Applications/Contacts.app", isDirectory: true)
        messagesApplication = root.appendingPathComponent("Applications/Messages.app", isDirectory: true)
        // The calendar row's badge is about the READER, not about Calendar.app:
        // it reads the store through EventKit and drives no application, so a
        // Mac with no Calendar.app would still answer.
        calendarHelper = root.appendingPathComponent(AppOwnedConnectorCatalog.appleCalendarHelperName)
        googleHelper = root.appendingPathComponent(GoogleWorkspaceConnectorPreparation.helperName)
        let manager = FileManager()
        let package = AppOwnedConnectorCatalog.appleMailPackage
        let binDirectory = home.appendingPathComponent(".local/share/uv/tools/\(package)/bin", isDirectory: true)
        try manager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: home.appendingPathComponent(".local/bin", isDirectory: true),
                                    withIntermediateDirectories: true)
        if installMail { try manager.createDirectory(at: mailApplication, withIntermediateDirectories: true) }
        if installContacts {
            try manager.createDirectory(at: contactsApplication, withIntermediateDirectories: true)
        }
        if installMessages {
            try manager.createDirectory(at: messagesApplication, withIntermediateDirectories: true)
        }
        if installCalendarHelper {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: calendarHelper)
            try manager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))],
                                      ofItemAtPath: calendarHelper.path)
        }
        let status = try JSONEncoder().encode(googleStatus)
        let statusJSON = String(decoding: status, as: UTF8.self)
            .replacingOccurrences(of: "'", with: "'\\''")
        try Data("#!/bin/sh\nprintf '%s\\n' '\(statusJSON)'\n".utf8).write(to: googleHelper)
        try manager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))],
                                  ofItemAtPath: googleHelper.path)
        guard installTool else { return }
        // A console script is a text file whose first line names its own
        // interpreter — there is no extension and nothing of ours in front.
        let script = binDirectory.appendingPathComponent(package)
        let body = "#!\(home.path)/.local/share/uv/python/bin/python3\nprint('mcp')\n"
        try Data(body.utf8).write(to: script)
        try manager.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: script.path)
        if throughSymlink {
            try manager.removeItem(at: script)
            let real = root.appendingPathComponent("elsewhere-\(package)")
            try Data(body.utf8).write(to: real)
            try manager.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: real.path)
            try manager.createSymbolicLink(at: script, withDestinationURL: real)
        }
    }

    func catalog() -> AppOwnedConnectorCatalog {
        AppOwnedConnectorCatalog(homeDirectoryURL: home, mailApplicationCandidateURLs: [mailApplication],
                                 contactsApplicationCandidateURLs: [contactsApplication],
                                 messagesApplicationCandidateURLs: [messagesApplication],
                                 calendarHelperCandidateURLs: [calendarHelper],
                                 googleHelperCandidateURLs: [googleHelper],
                                 googleClientID: "openbots-test.apps.googleusercontent.com")
    }

    func remove() { try? FileManager().removeItem(at: root) }
}

@Suite("The connectors the app pins itself")
struct AppOwnedConnectorCatalogTests {
    @Test("Apple Mail's reader is a row of its own, read-only, with the app as its source")
    func appleMailIsARow() async throws {
        let fixture = try MailFixture(); defer { fixture.remove() }
        let snapshot = try await fixture.catalog().loadConnectorCatalog()
        // Ten rows now: reading the user's mailbox and sending as them are
        // different powers with different grants, as they were in the old app;
        // the address book is a third, the calendar a fourth, Messages — one row,
        // as the old app had it — the fifth, and Control this Mac the sixth;
        // then the OpenBots Google account's Gmail, Gmail send (its own grant,
        // for the same reason as Mail's), Calendar and Drive.
        #expect(snapshot.connectors.map(\.definition.id)
            == ["openbots:apple-mail:apple-mail", "openbots:apple-mail-send:apple-mail-send",
                "openbots:apple-contacts:apple-contacts", "openbots:apple-calendar:apple-calendar",
                "openbots:apple-messages:apple-messages", "openbots:mac-control:peekaboo",
                "openbots:google-gmail:google-gmail", "openbots:google-gmail-send:google-gmail-send",
                "openbots:google-calendar:google-calendar", "openbots:google-drive:google-drive"])
        #expect(snapshot.excludedCount == 0)
        let connector = try #require(snapshot.connectors.first { $0.definition.identity.id
            == "openbots:apple-mail:apple-mail" })
        #expect(connector.definition.identity.id == "openbots:apple-mail:apple-mail")
        #expect(connector.definition.identity.source == .appOwned)
        #expect(connector.definition.identity.isValid)
        #expect(connector.definition.title == "Apple Mail (read-only)")
        #expect(connector.definition.summary.contains("no send or delete tool"))
        #expect(connector.definition.availability == .ready)
        // The Control this Mac row says a sign-in is handed to the user,
        // no longer only that the bot is told to stop.
        let mac = try #require(snapshot.connectors.first { $0.definition.identity.id == "openbots:mac-control:peekaboo" })
        #expect(mac.definition.summary.contains("hands you the screen with a card"))
        #expect(mac.definition.summary.contains("nothing of it runs until you hand it back"))
        #expect(!mac.definition.summary.contains("stop and ask before a purchase"))
        // The namespace key is a hash of the identity, so it is stable, opaque
        // and survives the settings encoder that once dropped digits.
        #expect(connector.launch.serverKey.hasPrefix("openbots_"))
        #expect(connector.launch.serverKey.count == "openbots_".count + 64)
        #expect(connector.launch.command == AppOwnedConnectorCatalog.appleMailPackage)
        #expect(connector.launch.arguments == ["--read-only"])
        #expect(connector.launch.pinnedPackage == "apple-mail-fast-mcp==0.10.2")
        #expect(connector.launch.transport == .stdio)
    }

    @Test("Calendar is a row of its own, read-only, and it says which permission pane it needs")
    func appleCalendarIsARow() async throws {
        let fixture = try MailFixture(); defer { fixture.remove() }
        let snapshot = try await fixture.catalog().loadConnectorCatalog()
        let connector = try #require(snapshot.connectors.first { $0.definition.identity.id
            == "openbots:apple-calendar:apple-calendar" })
        #expect(connector.definition.identity.source == .appOwned)
        #expect(connector.definition.identity.isValid)
        #expect(connector.definition.title == "Calendar (read-only)")
        #expect(connector.definition.summary.contains("Nothing can be added, changed or deleted"))
        // Repeating events are the whole reason this reader is not JXA, and the
        // row says so, because "what is on Thursday" quietly missing every
        // weekly meeting is the failure the user would never see.
        #expect(connector.definition.summary.contains("Repeating events"))
        // The user is sent to the RIGHT pane. Naming Automation here once sent
        // them looking where they were told, to find nothing.
        #expect(connector.definition.summary.contains("Calendars pane in Privacy & Security"))
        #expect(connector.definition.summary.contains("not the Automation one"))
        #expect(connector.definition.availability == .ready)
        #expect(connector.launch.command == AppleCalendarConnectorPreparation.command)
        #expect(connector.launch.arguments.isEmpty)
        #expect(connector.launch.transport == .stdio)
        #expect(connector.launch.serverKey.hasPrefix("openbots_"))
    }

    @Test("Google rows are separate grants and say exactly where Gmail's provider authority is wider")
    func googleRowsAreSeparateAndHonest() async throws {
        let fixture = try MailFixture(); defer { fixture.remove() }
        let snapshot = try await fixture.catalog().loadConnectorCatalog()
        let gmail = try #require(snapshot.connectors.first {
            $0.definition.id == "openbots:google-gmail:google-gmail"
        })
        let calendar = try #require(snapshot.connectors.first {
            $0.definition.id == "openbots:google-calendar:google-calendar"
        })
        #expect(gmail.definition.title.contains("read and draft"))
        #expect(gmail.definition.summary.contains("technically permits sending"))
        #expect(gmail.definition.summary.contains("does not expose a send tool or send endpoint"))
        #expect(gmail.launch.command == GoogleWorkspaceConnectorPreparation.gmailCommand)
        #expect(gmail.launch.arguments == ["--client-id", "openbots-test.apps.googleusercontent.com"])
        #expect(calendar.definition.title.contains("read-only"))
        #expect(calendar.definition.summary.contains("Nothing can be added, changed or deleted"))
        #expect(calendar.launch.command == GoogleWorkspaceConnectorPreparation.calendarCommand)
        #expect(gmail.definition.identity != calendar.definition.identity)
        let drive = try #require(snapshot.connectors.first {
            $0.definition.id == "openbots:google-drive:google-drive"
        })
        #expect(drive.definition.title == "Google Drive (OpenBots account, read-only)")
        #expect(drive.definition.summary.contains("Nothing can be created, changed, shared or deleted"))
        #expect(drive.definition.summary.contains("Docs, Sheets and Slides"))
        #expect(drive.launch.command == GoogleWorkspaceConnectorPreparation.driveCommand)
        #expect(drive.launch.arguments == ["--client-id", "openbots-test.apps.googleusercontent.com"])
        #expect(Set([gmail, calendar, drive].map(\.definition.identity)).count == 3)
    }

    /// The same words sit under the row in Settings, where the account section
    /// is above the rows, and on a bot's Access sheet, where there is none: "the
    /// Google account connected below" was false in both. A
    /// row's words are not part of its identity, so changing them switches no
    /// grant off (`googleIdentityBindsTheConnection`, the digest test).
    @Test("Each Google row says where its account is connected, true wherever the row is shown")
    func googleRowsSayWhereTheAccountIs() async throws {
        let fixture = try MailFixture(); defer { fixture.remove() }
        let snapshot = try await fixture.catalog().loadConnectorCatalog()
        let rows = snapshot.connectors.filter { $0.definition.id.hasPrefix("openbots:google-") }
        #expect(rows.count == 4)
        for row in rows {
            #expect(row.definition.summary.contains(
                "Uses the OpenBots Google account connected in Settings → Connectors & Skills."),
                "\(row.definition.id)")
            #expect(!row.definition.summary.contains("below"), "\(row.definition.id)")
            #expect(!row.definition.summary.contains("this app-wide switch"), "\(row.definition.id)")
        }
    }

    @Test("Every authorization instance changes both Google digests and leaves their row ids stable")
    func googleIdentityBindsTheConnection() async throws {
        let firstID = UUID(uuidString: "45ddbe75-230a-49e6-a5dc-ce65ae3c5425")!
        let secondID = UUID(uuidString: "6fba2a62-c528-459b-b536-a3934e8ec54e")!
        let first = try MailFixture(googleStatus: .init(state: .connected,
            accountEmail: "same@example.com", connectionID: firstID))
        let second = try MailFixture(googleStatus: .init(state: .connected,
            accountEmail: "same@example.com", connectionID: secondID))
        defer { first.remove(); second.remove() }
        let a = try await first.catalog().loadConnectorCatalog().connectors
            .filter { $0.definition.id.hasPrefix("openbots:google-") }
        let b = try await second.catalog().loadConnectorCatalog().connectors
            .filter { $0.definition.id.hasPrefix("openbots:google-") }
        #expect(a.map(\.definition.id) == b.map(\.definition.id))
        #expect(zip(a, b).allSatisfy { pair in
            pair.0.definition.identity.digest != pair.1.definition.identity.digest
        })

        let disconnected = try MailFixture(googleStatus: .init(state: .disconnected))
        defer { disconnected.remove() }
        let c = try await disconnected.catalog().loadConnectorCatalog().connectors
            .filter { $0.definition.id.hasPrefix("openbots:google-") }
        #expect(zip(a, c).allSatisfy { pair in
            pair.0.definition.identity.digest != pair.1.definition.identity.digest
        })
        #expect(c.allSatisfy { $0.definition.availability.badge == "needs setup" })
    }

    @Test("Only a definite answer about the Google account may move its rows' identity")
    func googleRowsHoldTheirIdentityWhenTheAnswerIsUnsure() async throws {
        func googleRows(_ fixture: MailFixture, clientID: String? = "openbots-test.apps.googleusercontent.com")
            async throws -> [ConfiguredConnector] {
            let catalog = AppOwnedConnectorCatalog(homeDirectoryURL: fixture.home,
                mailApplicationCandidateURLs: [fixture.mailApplication],
                contactsApplicationCandidateURLs: [fixture.contactsApplication],
                calendarHelperCandidateURLs: [fixture.calendarHelper],
                googleHelperCandidateURLs: [fixture.googleHelper], googleClientID: clientID)
            let rows = try await catalog.loadConnectorCatalog().connectors
                .filter { $0.definition.id.hasPrefix("openbots:google-") }
            #expect(rows.count == 4)
            return rows
        }
        let definite: [GoogleWorkspaceConnectionStatus] = [
            .init(state: .connected, accountEmail: "openbots@example.com", connectionID: googleCatalogConnectionID),
            .init(state: .disconnected),
            .init(state: .revocationPending, accountEmail: "openbots@example.com")
        ]
        for status in definite {
            let fixture = try MailFixture(googleStatus: status); defer { fixture.remove() }
            #expect(try await googleRows(fixture).allSatisfy { !$0.holdsPriorIdentity }, "\(status.state)")
        }
        // The helper's own "cannot read it" and a connection with no identity.
        for status in [GoogleWorkspaceConnectionStatus(state: .invalid, reason: "Keychain would not open."),
                       .init(state: .connected, accountEmail: "openbots@example.com")] {
            let fixture = try MailFixture(googleStatus: status); defer { fixture.remove() }
            #expect(try await googleRows(fixture).allSatisfy(\.holdsPriorIdentity), "\(status.state)")
        }
        // A helper that does not answer at all.
        let silent = try MailFixture(); defer { silent.remove() }
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: silent.googleHelper)
        #expect(try await googleRows(silent).allSatisfy(\.holdsPriorIdentity))
        // A build with no Google client baked in says nothing about the account.
        let unconfigured = try MailFixture(); defer { unconfigured.remove() }
        #expect(try await googleRows(unconfigured, clientID: nil).allSatisfy(\.holdsPriorIdentity))
        // Nothing else is ever unsure.
        let fixture = try MailFixture(googleStatus: .init(state: .invalid)); defer { fixture.remove() }
        #expect(try await fixture.catalog().loadConnectorCatalog().connectors
            .filter { !$0.definition.id.hasPrefix("openbots:google-") }.allSatisfy { !$0.holdsPriorIdentity })
    }

    @Test("A Google helper that goes quiet and comes back leaves a bot's Google switch on; a disconnect still turns it off")
    func aQuietHelperDoesNotCostTheGrant() async throws {
        let fixture = try MailFixture(); defer { fixture.remove() }
        let connected = try Data(contentsOf: fixture.googleHelper)
        let store = ConnectorAccessStore(repository: GoogleGrantMemoryRepository(), catalog: fixture.catalog())
        try await store.restore()
        let gmail = try #require(await store.current().definitions.first { $0.id == "openbots:google-gmail:google-gmail" })
        let bot = TeammateID(UUID())
        try await store.setAppEnabled(true)
        try await store.setBotEnabled(true, identity: gmail.identity, teammateID: bot)
        #expect(await store.current(teammateID: bot).selectedIDs == [gmail.id])

        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: fixture.googleHelper)
        try await store.refreshCatalog()
        #expect(await store.current(teammateID: bot).selectedIDs == [gmail.id], "A silent helper is not a change")

        try connected.write(to: fixture.googleHelper)
        try await store.refreshCatalog()
        #expect(await store.current(teammateID: bot).selectedIDs == [gmail.id], "Back, and still on")

        let status = String(decoding: try JSONEncoder().encode(GoogleWorkspaceConnectionStatus(state: .disconnected)),
                            as: UTF8.self)
        try Data("#!/bin/sh\nprintf '%s\\n' '\(status)'\n".utf8).write(to: fixture.googleHelper)
        try await store.refreshCatalog()
        #expect(await store.current(teammateID: bot).selectedIDs.isEmpty, "A disconnect is an answer, and revokes")
    }

    @Test("Without the reader binary only the calendar row dies")
    func withoutTheCalendarReaderOnlyThatRowDies() async throws {
        let fixture = try MailFixture(installCalendarHelper: false); defer { fixture.remove() }
        let snapshot = try await fixture.catalog().loadConnectorCatalog()
        let calendar = try #require(snapshot.connectors.first { $0.definition.identity.id
            == "openbots:apple-calendar:apple-calendar" })
        #expect(calendar.definition.availability
            == .unavailable("This build is missing the calendar reader. Reinstall the app."))
        #expect(!calendar.definition.availability.canBeEnabled)
        // And nothing else is touched: one missing piece takes one row.
        for other in snapshot.connectors
        where other.definition.identity.id != "openbots:apple-calendar:apple-calendar" {
            #expect(other.definition.availability == .ready,
                    "\(other.definition.id) must not die with the calendar reader")
        }
    }

    @Test("A Mac with no Calendar.app still has the row, because it drives no application")
    func theCalendarRowDoesNotNeedCalendarApp() async throws {
        // Contacts is the contrast: its row dies without Contacts.app, because
        // it really does send that app Apple Events. This one reads the store.
        let fixture = try MailFixture(installContacts: false); defer { fixture.remove() }
        let snapshot = try await fixture.catalog().loadConnectorCatalog()
        let calendar = try #require(snapshot.connectors.first { $0.definition.identity.id
            == "openbots:apple-calendar:apple-calendar" })
        #expect(calendar.definition.availability == .ready)
        let contacts = try #require(snapshot.connectors.first { $0.definition.identity.id
            == "openbots:apple-contacts:apple-contacts" })
        #expect(!contacts.definition.availability.canBeEnabled)
    }

    @Test("Not installed yet reads as needs setup and names the one command that fixes it")
    func withoutTheToolTheRowSaysSo() async throws {
        let fixture = try MailFixture(installTool: false); defer { fixture.remove() }
        let connector = try #require(try await fixture.catalog().loadConnectorCatalog().connectors
            .first { $0.definition.identity.id == "openbots:apple-mail:apple-mail" })
        let availability = connector.definition.availability
        #expect(availability.badge == "needs setup")
        #expect(availability.canBeEnabled)
        let reason = try #require(availability.reason)
        #expect(reason.contains("uv tool install apple-mail-fast-mcp==0.10.2"))
    }

    @Test("A tool anyone on the Mac could rewrite is not installed as far as this row is concerned")
    func aWorldWritableToolIsRefused() async throws {
        let fixture = try MailFixture(permissions: 0o777); defer { fixture.remove() }
        let connector = try #require(try await fixture.catalog().loadConnectorCatalog().connectors
            .first { $0.definition.identity.id == "openbots:apple-mail:apple-mail" })
        #expect(connector.definition.availability.badge == "needs setup")
    }

    @Test("The tool is found through the symlink an installer leaves behind")
    func aSymlinkedToolIsFound() async throws {
        let fixture = try MailFixture(throughSymlink: true); defer { fixture.remove() }
        let connector = try #require(try await fixture.catalog().loadConnectorCatalog().connectors
            .first { $0.definition.identity.id == "openbots:apple-mail:apple-mail" })
        #expect(connector.definition.availability == .ready)
    }

    @Test("No Mail on the Mac is unavailable, and its switch is dead rather than merely unset")
    func withoutMailTheSwitchIsDead() async throws {
        let fixture = try MailFixture(installMail: false); defer { fixture.remove() }
        let connector = try #require(try await fixture.catalog().loadConnectorCatalog().connectors
            .first { $0.definition.identity.id == "openbots:apple-mail:apple-mail" })
        #expect(connector.definition.availability.badge == "unavailable")
        #expect(!connector.definition.availability.canBeEnabled)
    }

    @Test("Contacts is a row of its own, read-only, and says which permission macOS will ask for")
    func contactsIsARow() async throws {
        let fixture = try MailFixture(); defer { fixture.remove() }
        let connector = try #require(try await fixture.catalog().loadConnectorCatalog().connectors
            .first { $0.definition.identity.id == "openbots:apple-contacts:apple-contacts" })
        #expect(connector.definition.identity.source == .appOwned)
        #expect(connector.definition.identity.isValid)
        #expect(connector.definition.title == "Contacts (read-only)")
        // The two things the row has to say: nothing can be written, and the
        // permission is Contacts' own rather than the one Mail already has.
        #expect(connector.definition.summary.contains("no tool for that exists"))
        #expect(connector.definition.summary.contains("control Contacts"))
        #expect(connector.definition.availability == .ready)
        #expect(connector.launch.command == AppleContactsConnectorPreparation.command)
        #expect(connector.launch.arguments.isEmpty)
        #expect(connector.launch.pinnedPackage == nil)
        #expect(connector.launch.transport == .stdio)
        #expect(connector.launch.serverKey.hasPrefix("openbots_"))
    }

    @Test("Messages is a row of its own that names both permissions it needs")
    func messagesIsARow() async throws {
        let fixture = try MailFixture(); defer { fixture.remove() }
        let connector = try #require(try await fixture.catalog().loadConnectorCatalog().connectors
            .first { $0.definition.identity.id == "openbots:apple-messages:apple-messages" })
        #expect(connector.definition.identity.source == .appOwned)
        #expect(connector.definition.identity.isValid)
        // The row's own name.
        #expect(connector.definition.title == "Messages (iMessage, RCS, SMS)")
        // What it is for: the right service, so an Android phone receives it.
        #expect(connector.definition.summary.contains("Android"))
        #expect(connector.definition.summary.contains("card first"))
        // Two different panes, and the user has to be told both: macOS never asks for
        // Full Disk Access, so a row that named only Automation would send them
        // looking for a prompt that will never come.
        #expect(connector.definition.summary.contains("Full Disk Access"))
        #expect(connector.definition.summary.contains("control Messages"))
        #expect(connector.definition.availability == .ready)
        #expect(connector.launch.command == AppleMessagesConnectorPreparation.command)
        #expect(connector.launch.arguments.isEmpty)
        #expect(connector.launch.pinnedPackage == nil)
        #expect(connector.launch.transport == .stdio)
        #expect(connector.launch.serverKey.hasPrefix("openbots_"))
    }

    @Test("No Messages on the Mac makes only that row unavailable")
    func withoutMessagesOnlyThatRowDies() async throws {
        let fixture = try MailFixture(installMessages: false); defer { fixture.remove() }
        let snapshot = try await fixture.catalog().loadConnectorCatalog()
        let messages = try #require(snapshot.connectors
            .first { $0.definition.identity.id == "openbots:apple-messages:apple-messages" })
        #expect(messages.definition.availability == .unavailable("Messages is not installed on this Mac."))
        #expect(!messages.definition.availability.canBeEnabled)
        for other in snapshot.connectors
        where other.definition.identity.id != "openbots:apple-messages:apple-messages" {
            #expect(other.definition.availability.canBeEnabled,
                    "\(other.definition.id) must not die with Messages")
        }
    }

    @Test("No Contacts on the Mac makes that row unavailable and leaves the mail rows alone")
    func withoutContactsOnlyThatRowDies() async throws {
        let fixture = try MailFixture(installContacts: false); defer { fixture.remove() }
        let snapshot = try await fixture.catalog().loadConnectorCatalog()
        let contacts = try #require(snapshot.connectors
            .first { $0.definition.identity.id == "openbots:apple-contacts:apple-contacts" })
        #expect(contacts.definition.availability.badge == "unavailable")
        #expect(!contacts.definition.availability.canBeEnabled)
        let mail = try #require(snapshot.connectors
            .first { $0.definition.identity.id == "openbots:apple-mail:apple-mail" })
        #expect(mail.definition.availability == .ready)
    }

    @Test("The same row is the same identity twice, and the digest is not just the id hashed")
    func theIdentityIsStable() async throws {
        let fixture = try MailFixture(); defer { fixture.remove() }
        let connector = try #require(try await fixture.catalog().loadConnectorCatalog().connectors
            .first { $0.definition.identity.id == "openbots:apple-mail:apple-mail" })
        // Same inputs, same identity: the pane does not reshuffle and grants
        // survive a reload.
        let again = try #require(try await fixture.catalog().loadConnectorCatalog().connectors
            .first { $0.definition.identity.id == "openbots:apple-mail:apple-mail" })
        #expect(connector.definition.identity == again.definition.identity)
        #expect(connector.definition.identity.digest
            != connector.launch.serverKey.replacingOccurrences(of: "openbots_", with: ""))
    }

    @Test("A changed pin is a changed definition, which is what revokes an old grant")
    func aChangedPinChangesTheDigest() throws {
        // The digest the store compares is minted from what the launch would
        // actually do, so this varies exactly that and nothing else.
        func digest(pinned: String, arguments: [String]) -> String {
            var canonical: [String: Any] = ["namespace": "openbots:apple-mail:apple-mail",
                                            "type": "stdio",
                                            "command": AppOwnedConnectorCatalog.appleMailPackage,
                                            "args": arguments]
            canonical["package"] = pinned
            let data = (try? JSONSerialization.data(withJSONObject: canonical,
                options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return AppOwnedConnectorCatalog.digestForTesting(data)
        }
        let shipped = digest(pinned: "apple-mail-fast-mcp==0.10.2", arguments: ["--read-only"])
        #expect(shipped != digest(pinned: "apple-mail-fast-mcp==0.11.0", arguments: ["--read-only"]))
        #expect(shipped != digest(pinned: "apple-mail-fast-mcp==0.10.2", arguments: []))
        #expect(shipped == digest(pinned: "apple-mail-fast-mcp==0.10.2", arguments: ["--read-only"]))
    }
}

private struct StubCatalog: ConnectorCatalogReading {
    let snapshot: ConnectorCatalogSnapshot?
    func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot {
        guard let snapshot else { throw ConnectorCatalogError.unavailable }
        return snapshot
    }
}

private func stubConnector(_ id: String) throws -> ConfiguredConnector {
    let identity = try ConnectorIdentity(id: id, digest: String(repeating: "a", count: 64))
    return ConfiguredConnector(
        definition: .init(identity: identity, serverName: "s", pluginName: "p", transport: .stdio),
        launch: .init(serverKey: "openbots_x", transport: .stdio, command: "node"))
}

@Suite("One catalog made of several")
struct ConnectorCatalogCompositeTests {
    @Test("Both sources appear, in one stable order")
    func bothSourcesAppear() async throws {
        let composite = ConnectorCatalogComposite([
            StubCatalog(snapshot: .init(connectors: [try stubConnector("claude-plugin:z@o:s")], excludedCount: 1)),
            StubCatalog(snapshot: .init(connectors: [try stubConnector("openbots:apple-mail:apple-mail")])),
        ])
        let snapshot = try await composite.loadConnectorCatalog()
        #expect(snapshot.connectors.map(\.definition.id)
            == ["claude-plugin:z@o:s", "openbots:apple-mail:apple-mail"])
        #expect(snapshot.excludedCount == 1)
    }

    @Test("One source failing never hides the other, and is counted rather than swallowed")
    func oneFailureIsCounted() async throws {
        let composite = ConnectorCatalogComposite([
            StubCatalog(snapshot: nil),
            StubCatalog(snapshot: .init(connectors: [try stubConnector("openbots:apple-mail:apple-mail")])),
        ])
        let snapshot = try await composite.loadConnectorCatalog()
        #expect(snapshot.connectors.count == 1 && snapshot.excludedCount == 1)
    }

    @Test("Every source failing is a failure, because losing the catalog loses the authority")
    func everyFailureThrows() async throws {
        let composite = ConnectorCatalogComposite([StubCatalog(snapshot: nil), StubCatalog(snapshot: nil)])
        await #expect(throws: ConnectorCatalogError.unavailable) {
            _ = try await composite.loadConnectorCatalog()
        }
    }

    @Test("Two sources claiming one identity drop it, rather than one quietly winning")
    func aDuplicateIdentityIsDropped() async throws {
        let same = try stubConnector("openbots:apple-mail:apple-mail")
        let composite = ConnectorCatalogComposite([
            StubCatalog(snapshot: .init(connectors: [same])),
            StubCatalog(snapshot: .init(connectors: [same])),
        ])
        let snapshot = try await composite.loadConnectorCatalog()
        #expect(snapshot.connectors.isEmpty && snapshot.excludedCount == 2)
    }
}

private actor GoogleGrantMemoryRepository: ConnectorAccessRepository {
    private var state = ConnectorAccessState()
    func loadConnectorAccess() async throws -> ConnectorAccessState { state }
    func saveConnectorAccess(_ next: ConnectorAccessState, expectedRevision: Int64) async throws {
        guard state.revision == expectedRevision else { throw ConnectorAccessError.staleRevision }
        state = next
    }
}
