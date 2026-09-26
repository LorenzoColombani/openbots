import Foundation
import OpenBotsDomain
import OpenBotsRuntime
import Testing
@testable import OpenBotsServices

private func contactsLaunch(command: String = AppleContactsConnectorPreparation.command,
                            transport: ConnectorTransport = .stdio) -> ConnectorLaunchConfiguration {
    ConnectorLaunchConfiguration(serverKey: "openbots_" + String(repeating: "c", count: 64),
        transport: transport, command: command, arguments: [])
}

private func contactsQuestion(_ tool: String, _ input: [String: Any]) throws -> ClaudeTextPermissionRequest {
    ClaudeTextPermissionRequest(requestID: "req-3", toolUseID: "toolu_03",
        toolName: "mcp__openbots_" + String(repeating: "c", count: 64) + "__" + tool,
        inputJSON: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
}

/// A directory holding a fake Contacts.app, so a badge is decided by the
/// fixture and not by whatever this Mac happens to have installed.
private struct ContactsApplicationFixture {
    let root: URL
    let application: URL

    init(install: Bool = true) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("openbots-contacts-app-\(UUID().uuidString)", isDirectory: true)
        application = root.appendingPathComponent("Applications/Contacts.app", isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: true)
        if install {
            try FileManager().createDirectory(at: application, withIntermediateDirectories: true)
        }
    }

    func remove() { try? FileManager().removeItem(at: root) }
}

@Suite("Looking someone up in the user's Contacts")
struct AppleContactsPreparationTests {
    @Test("The reader ships in the bundle and its launch is node running that script, fenced")
    func theReaderShipsFenced() throws {
        let script = try #require(AppOwnedConnectorCatalog.appleContactsScriptURL)
        #expect(script.lastPathComponent == "apple-contacts.js")
        let application = try ContactsApplicationFixture(); defer { application.remove() }
        let preparation = AppleContactsConnectorPreparation(
            scriptURL: script, applicationCandidateURLs: [application.application],
            interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")])
        let fence = FenceProxyResource(interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")])
        let server = try preparation.server(for: contactsLaunch(), profileURL: nil,
            temporaryDirectoryURL: FileManager().temporaryDirectory, fence: fence)
        #expect(server.role == .appleContactsRead)
        // Whoever wrote the card wrote these words, so they arrive wrapped —
        // the shim runs first and the reader is its argument.
        #expect(server.program.isFenced)
        #expect(ClaudeTextConnectorRole.appleContactsRead.handsBackUntrustedMaterial)
        #expect(server.arguments.contains("apple-contacts"))
        #expect(server.arguments.contains(script.standardizedFileURL.path))
        #expect(server.arguments.last == script.standardizedFileURL.path)
        // The Contacts it will start is the one THIS side resolved, so the
        // badge and the launch cannot point at two different copies.
        #expect(server.environment["OPENBOTS_CONTACTS_APP"]
            == application.application.standardizedFileURL.path)
        #expect(server.environment["OPENBOTS_APP_NAME"] == "OpenBots Next")
        #expect(server.options.isEmpty)
        #expect(!preparation.needsOwnedProfile)
    }

    @Test("A build without the reader says so, and cannot be switched on")
    func aMissingReaderIsUnavailable() throws {
        let preparation = AppleContactsConnectorPreparation(scriptURL: nil)
        #expect(throws: AppleContactsConnectorPreparation.Failure.scriptMissing) {
            try preparation.resolve(contactsLaunch())
        }
        let availability = try #require(preparation.availability(for: contactsLaunch()))
        #expect(!availability.canBeEnabled)
        #expect(try #require(availability.reason).contains("missing the contacts reader"))
    }

    @Test("No Contacts on the Mac is unavailable rather than a launch that fails inside a turn")
    func noContactsIsUnavailable() throws {
        let application = try ContactsApplicationFixture(install: false); defer { application.remove() }
        let preparation = AppleContactsConnectorPreparation(
            applicationCandidateURLs: [application.application])
        #expect(throws: AppleContactsConnectorPreparation.Failure.applicationMissing) {
            try preparation.resolve(contactsLaunch())
        }
        let availability = try #require(preparation.availability(for: contactsLaunch()))
        #expect(availability.badge == "unavailable")
        #expect(!availability.canBeEnabled)
    }

    @Test("No node is a needs-setup answer, and so is a fence that cannot run")
    func noNodeAndNoFenceAreNeedsSetup() throws {
        let application = try ContactsApplicationFixture(); defer { application.remove() }
        let preparation = AppleContactsConnectorPreparation(
            applicationCandidateURLs: [application.application], interpreterCandidateURLs: [])
        #expect(throws: AppleContactsConnectorPreparation.Failure.interpreterMissing) {
            try preparation.resolve(contactsLaunch())
        }
        #expect(try #require(preparation.availability(for: contactsLaunch())).badge == "needs setup")
        // Fail closed: no shim means the row does not launch at all, rather
        // than launching unfenced while the prompt promises fenced.
        let noFence = AppleContactsConnectorPreparation(
            applicationCandidateURLs: [application.application],
            interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")],
            fence: FenceProxyResource(scriptURL: nil))
        #expect(try #require(noFence.availability(for: contactsLaunch())).canBeEnabled == false)
        #expect(throws: AppleContactsConnectorPreparation.Failure
            .fenceUnavailable(.scriptMissing)) {
            try noFence.server(for: contactsLaunch(), profileURL: nil,
                temporaryDirectoryURL: FileManager().temporaryDirectory,
                fence: FenceProxyResource(scriptURL: nil))
        }
    }

    @Test("Another connector's row is not the reader's to answer")
    func anotherRowIsNotItsOwn() throws {
        let preparation = AppleContactsConnectorPreparation()
        let sender = ConnectorLaunchConfiguration(serverKey: "openbots_x", transport: .stdio,
            command: AppleMailSendPreparation.command, arguments: [])
        #expect(!preparation.prepares(sender))
        #expect(preparation.availability(for: sender) == nil)
        #expect(throws: AppleContactsConnectorPreparation.Failure.notTheContactsReader) {
            try preparation.resolve(sender)
        }
        #expect(throws: AppleContactsConnectorPreparation.Failure.unsupportedTransport) {
            try preparation.resolve(contactsLaunch(transport: .http))
        }
    }
}

@Suite("What the record says about a contacts lookup")
struct AppleContactsApprovalPolicyTests {
    @Test("A search is quiet and the sheet says who was looked up")
    func aSearchIsQuietAndNamed() throws {
        let decision = ClaudeTextConnectorApprovalPolicy.decide(
            try contactsQuestion("search_contacts", ["query": "Charles Dupont"]),
            botName: "Kite", role: .appleContactsRead)
        guard case .allowQuietly(let activity) = decision else {
            Issue.record("a lookup should be quiet, got \(decision)"); return
        }
        #expect(activity.contains("Charles Dupont"))
        #expect(activity.contains("contacts"))
        // A quiet decision IS the deed, so it is written in the past tense
        // rather than as something that was asked for.
        #expect(activity.hasPrefix("Looked up"))
    }

    @Test("Reading one card is quiet, and the sheet does not print an id at the user")
    func readingACardIsQuiet() throws {
        let decision = ClaudeTextConnectorApprovalPolicy.decide(
            try contactsQuestion("read_contact", ["id": "ABCDEF01-2345-6789-ABCD-EF0123456789:ABPerson"]),
            botName: "Kite", role: .appleContactsRead)
        guard case .allowQuietly(let activity) = decision else {
            Issue.record("reading a card should be quiet, got \(decision)"); return
        }
        #expect(activity == "Read a card in your contacts")
    }

    @Test("A search whose words carry something invisible is folded before it reaches the user")
    func theSheetIsFoldedAndBounded() throws {
        let decision = ClaudeTextConnectorApprovalPolicy.decide(
            try contactsQuestion("search_contacts",
                                 ["query": "Char\u{200B}les\n\nDupont" + String(repeating: "x", count: 400)]),
            botName: "Kite", role: .appleContactsRead)
        guard case .allowQuietly(let activity) = decision else {
            Issue.record("a lookup should be quiet, got \(decision)"); return
        }
        #expect(!activity.contains("\u{200B}"))
        #expect(!activity.contains("\n"))
        #expect(activity.count <= 200)
    }

    @Test("Anything that is not one of the two reads asks, which is what a write verb would hit")
    func anUnknownToolAsks() throws {
        let decision = ClaudeTextConnectorApprovalPolicy.decide(
            try contactsQuestion("create_contact", ["name": "Someone New"]),
            botName: "Kite", role: .appleContactsRead)
        guard case .ask(let card) = decision else {
            Issue.record("an unknown contacts tool must ask, got \(decision)"); return
        }
        #expect(card.title == "Do something in your contacts")
        #expect(card.kind == .send)
        #expect(card.detail.contains("read and nothing else"))
        #expect(card.activity.hasPrefix("Asked to"))
    }
}
