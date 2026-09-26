import Foundation
import OpenBotsDomain
import OpenBotsRuntime
import Testing
@testable import OpenBotsServices

private func calendarLaunch(command: String = AppleCalendarConnectorPreparation.command,
                            transport: ConnectorTransport = .stdio) -> ConnectorLaunchConfiguration {
    ConnectorLaunchConfiguration(serverKey: "openbots_" + String(repeating: "d", count: 64),
        transport: transport, command: command, arguments: [])
}

private func calendarQuestion(_ tool: String, _ input: [String: Any]) throws -> ClaudeTextPermissionRequest {
    ClaudeTextPermissionRequest(requestID: "req-4", toolUseID: "toolu_04",
        toolName: "mcp__openbots_" + String(repeating: "d", count: 64) + "__" + tool,
        inputJSON: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
}

/// A directory holding a fake reader binary, so a badge is decided by the
/// fixture rather than by whatever this machine happens to have built.
private struct CalendarHelperFixture {
    let root: URL
    let helper: URL

    init(install: Bool = true, executable: Bool = true) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("openbots-calendar-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: true)
        helper = root.appendingPathComponent(AppOwnedConnectorCatalog.appleCalendarHelperName)
        if install {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
            if executable {
                try FileManager().setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))],
                                                ofItemAtPath: helper.path)
            }
        }
    }

    func remove() { try? FileManager().removeItem(at: root) }
}

@Suite("Reading the user's calendar")
struct AppleCalendarPreparationTests {
    @Test("The server ships in the bundle and its launch is node running that script, fenced")
    func theServerShipsFenced() throws {
        let script = try #require(AppOwnedConnectorCatalog.appleCalendarScriptURL)
        #expect(script.lastPathComponent == "apple-calendar.js")
        let fixture = try CalendarHelperFixture(); defer { fixture.remove() }
        let preparation = AppleCalendarConnectorPreparation(
            scriptURL: script, helperCandidateURLs: [fixture.helper],
            interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")])
        let fence = FenceProxyResource(interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")])
        let server = try preparation.server(for: calendarLaunch(), profileURL: nil,
            temporaryDirectoryURL: FileManager().temporaryDirectory, fence: fence)
        #expect(server.role == .appleCalendarRead)
        // Whoever sent the invitation wrote these words, so they arrive wrapped.
        #expect(server.program.isFenced)
        #expect(ClaudeTextConnectorRole.appleCalendarRead.handsBackUntrustedMaterial)
        #expect(server.arguments.contains("apple-calendar"))
        #expect(server.arguments.last == script.standardizedFileURL.path)
        // The binary it reads through is the one THIS side resolved, so the
        // badge and the launch cannot point at two different copies.
        #expect(server.environment["OPENBOTS_CALENDAR_HELPER"]
            == fixture.helper.standardizedFileURL.path)
        #expect(server.environment["OPENBOTS_APP_NAME"] == "OpenBots Next")
        #expect(server.options.isEmpty)
        #expect(!preparation.needsOwnedProfile)
    }

    /// `ClaudeTextConnectorServer` throws `invalidServer` for any environment
    /// key not on its closed allow-list, and that failure happens at launch —
    /// in the app, never in a test that builds a server by hand. So the key is
    /// asserted to be reachable, not merely spelled the same in two files.
    @Test("The helper's environment key is on the allow-list, so the row can launch at all")
    func theEnvironmentKeyIsAllowed() throws {
        let fixture = try CalendarHelperFixture(); defer { fixture.remove() }
        let preparation = AppleCalendarConnectorPreparation(
            scriptURL: AppOwnedConnectorCatalog.appleCalendarScriptURL,
            helperCandidateURLs: [fixture.helper],
            interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")])
        let fence = FenceProxyResource(interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")])
        // The throw is the assertion: it does not throw only because
        // OPENBOTS_CALENDAR_HELPER is named in `environmentKeys`.
        #expect(throws: Never.self) {
            _ = try preparation.server(for: calendarLaunch(), profileURL: nil,
                temporaryDirectoryURL: FileManager().temporaryDirectory, fence: fence)
        }
    }

    @Test("It prepares its own row and nobody else's")
    func itPreparesOnlyItsOwnRow() throws {
        let preparation = AppleCalendarConnectorPreparation()
        #expect(preparation.prepares(calendarLaunch()))
        #expect(!preparation.prepares(calendarLaunch(command: "apple-contacts")))
        #expect(!preparation.prepares(calendarLaunch(command: "apple-mail-send")))
        #expect(preparation.availability(for: calendarLaunch(command: "apple-contacts")) == nil)
    }

    @Test("A build without the server says so, and cannot be switched on")
    func aMissingServerIsUnavailable() throws {
        let fixture = try CalendarHelperFixture(); defer { fixture.remove() }
        let preparation = AppleCalendarConnectorPreparation(
            scriptURL: nil, helperCandidateURLs: [fixture.helper])
        #expect(throws: AppleCalendarConnectorPreparation.Failure.scriptMissing) {
            _ = try preparation.resolve(calendarLaunch())
        }
        #expect(preparation.availability(for: calendarLaunch())
            == .unavailable("This build is missing the calendar reader. Reinstall the app."))
    }

    @Test("A build without the reader binary says the same thing, and it is not a setup step")
    func aMissingHelperIsUnavailable() throws {
        let fixture = try CalendarHelperFixture(install: false); defer { fixture.remove() }
        let preparation = AppleCalendarConnectorPreparation(
            scriptURL: AppOwnedConnectorCatalog.appleCalendarScriptURL,
            helperCandidateURLs: [fixture.helper])
        #expect(throws: AppleCalendarConnectorPreparation.Failure.helperMissing) {
            _ = try preparation.resolve(calendarLaunch())
        }
        // Which half of the reader is missing is a fact about the build, not
        // something the user can act on differently.
        #expect(preparation.availability(for: calendarLaunch())
            == .unavailable("This build is missing the calendar reader. Reinstall the app."))
    }

    @Test("A file that is there but cannot be run is not a reader")
    func anUnrunnableHelperIsMissing() throws {
        let fixture = try CalendarHelperFixture(executable: false); defer { fixture.remove() }
        let preparation = AppleCalendarConnectorPreparation(
            scriptURL: AppOwnedConnectorCatalog.appleCalendarScriptURL,
            helperCandidateURLs: [fixture.helper])
        #expect(throws: AppleCalendarConnectorPreparation.Failure.helperMissing) {
            _ = try preparation.resolve(calendarLaunch())
        }
    }

    @Test("Without node the row says what to do rather than dying")
    func aMissingInterpreterNeedsSetup() throws {
        let fixture = try CalendarHelperFixture(); defer { fixture.remove() }
        let preparation = AppleCalendarConnectorPreparation(
            scriptURL: AppOwnedConnectorCatalog.appleCalendarScriptURL,
            helperCandidateURLs: [fixture.helper],
            interpreterCandidateURLs: [URL(fileURLWithPath: "/nowhere/node")])
        #expect(throws: AppleCalendarConnectorPreparation.Failure.interpreterMissing) {
            _ = try preparation.resolve(calendarLaunch())
        }
        guard case .needsSetup(let sentence)? = preparation.availability(for: calendarLaunch()) else {
            Issue.record("a missing node is something the user can fix"); return
        }
        #expect(sentence.contains("Node is not installed"))
    }

    @Test("Only a stdio server resolves to a local program")
    func onlyStdioResolves() throws {
        let preparation = AppleCalendarConnectorPreparation()
        #expect(throws: AppleCalendarConnectorPreparation.Failure.unsupportedTransport) {
            _ = try preparation.resolve(calendarLaunch(transport: .http))
        }
    }
}

@Suite("What a card says when a bot reads the user's calendar")
struct AppleCalendarApprovalPolicyTests {
    @Test("The three reads are quiet, and the sheet says which days were read")
    func theThreeReadsAreQuiet() throws {
        let decision = ClaudeTextConnectorApprovalPolicy.decide(
            try calendarQuestion("search_events", ["from": "2026-09-14", "to": "2026-09-18"]),
            botName: "Kite", role: .appleCalendarRead)
        guard case .allowQuietly(let activity) = decision else {
            Issue.record("reading the user's own calendar is what the row is for"); return
        }
        // A quiet decision IS the deed, so it is written in the past tense.
        #expect(activity == "Read your calendar from 2026-09-14 to 2026-09-18")
    }

    @Test("Listing the calendars and reading one event have their own lines")
    func eachReadHasItsOwnLine() throws {
        let listing = ClaudeTextConnectorApprovalPolicy.decide(
            try calendarQuestion("list_calendars", [:]), botName: "Kite", role: .appleCalendarRead)
        guard case .allowQuietly(let listed) = listing else {
            Issue.record("listing calendars is a read"); return
        }
        #expect(listed == "Listed your calendars")

        let one = ClaudeTextConnectorApprovalPolicy.decide(
            try calendarQuestion("read_event", ["id": "E1"]), botName: "Kite", role: .appleCalendarRead)
        guard case .allowQuietly(let read) = one else {
            Issue.record("reading one event is a read"); return
        }
        // An id is not a date and printing one would fill the sheet with
        // something unreadable.
        #expect(read == "Read one event in your calendar")
    }

    @Test("A search with no window still says something the user can read")
    func aBareSearchStillReads() throws {
        let decision = ClaudeTextConnectorApprovalPolicy.decide(
            try calendarQuestion("search_events", [:]), botName: "Kite", role: .appleCalendarRead)
        guard case .allowQuietly(let activity) = decision else {
            Issue.record("a bare search is still a read"); return
        }
        #expect(activity == "Read the week ahead in your calendar")
    }

    @Test("Anything that is not one of the three asks, which is what a write verb would hit")
    func anythingElseAsks() throws {
        let decision = ClaudeTextConnectorApprovalPolicy.decide(
            try calendarQuestion("create_event", ["summary": "Lunch"]),
            botName: "Kite", role: .appleCalendarRead)
        guard case .ask(let card) = decision else {
            Issue.record("a verb this build does not ship must not be quiet"); return
        }
        #expect(card.title == "Do something in your calendar")
        #expect(card.detail.contains("read and nothing else"))
        // A card's activity is written when the card goes up, so it says what
        // was ASKED, not what happened.
        #expect(card.activity.hasPrefix("Asked to"))
    }

    @Test("The quiet set is exactly the three the server announces")
    func theQuietSetMatchesTheServer() {
        #expect(ClaudeTextAppleCalendarApprovalPolicy.quietReads
            == ["list_calendars", "search_events", "read_event"])
    }
}
