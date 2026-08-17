import XCTest
@testable import AgencyKit

/// His report 2026-08-13: "my iMessage connector can't differentiate between
/// iMessage and RCS or texts and sends iMessages by default, which fails for
/// Android users."
///
/// LIVE DATA, OPT-IN: a few tests below answer questions that only a real
/// Messages database can answer (which service a handle actually uses). They
/// read `~/Library/Messages/chat.db` READ-ONLY and never transmit anything —
/// but they touch personal data, so they are SKIPPED unless
/// `AGENCY_LIVE_MESSAGES_TESTS=1` is set. Everything else here is synthetic
/// and always runs. Any value derived from that database is passed through
/// `redacted()` before it can reach a failure message.
///
/// Anthropic's Desktop extension hardcodes `service type = iMessage` in its
/// send script. Two live findings shape everything asserted here:
///  - `buddy "<anything>" of <any service>` ALWAYS resolves in Messages, so a
///    wrong service raises NO error — the failure is silent by construction and
///    no try/fallback chain can exist.
///  - chat.db is the only usable signal, and it has three tiers: `message`,
///    `chat` and `handle`. Message-level evidence covers only a small fraction
///    of known handles (Messages prunes old bodies), so on a real install all
///    three tiers must be consulted.
final class MessagesServiceTests: XCTestCase {

    // MARK: the script itself

    func testServerScriptShipsWithTheProject() throws {
        let path = try XCTUnwrap(MessagesServer.scriptPath(),
                                 "Resources/mcp/\(MessagesServer.scriptName) must be findable "
                                 + "from the test bundle, the CLI and Agency.app alike")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: path))
    }

    func testSupersededToolsAreNamedFromTheManifestNotHardcoded() {
        // Everything chat.db-derived is agency's now — its sender forces
        // iMessage and its readers return hex dumps. Contact lookup goes
        // through the Contacts app and stays with the first-party extension.
        // Fail CLOSED: an unrecognised future tool is superseded, not trusted.
        let tools: [[String: Any]] = [
            ["name": "send_imessage"], ["name": "read_imessages"],
            ["name": "search_contacts"], ["name": "get_unread_imessages"],
            ["name": "some_future_tool"],
        ]
        XCTAssertEqual(MessagesServer.supersededTools(inManifestTools: tools),
                       ["send_imessage", "read_imessages", "get_unread_imessages", "some_future_tool"])
    }

    // MARK: catalog wiring

    func testBuiltinConnectorCarriesAgencysOwnSender() throws {
        let builtin = try XCTUnwrap(Connector.builtins.first { $0.id == "imessage" },
                                    "the imessage placeholder is gone")
        let server = try XCTUnwrap(builtin.mcpServers["messages"],
                                   "agency ships a sender even when the Desktop extension is absent")
        XCTAssertEqual(server["args"] as? [String], [Connector.messagesServerToken],
                       "the path is a token, resolved per-install at generation time")
        XCTAssertTrue(builtin.allowedTools.contains("mcp__messages"))
        XCTAssertTrue(builtin.needsAppleEvents,
                      "sending drives Messages over Apple Events — the runner must skip the sandbox")
        XCTAssertFalse(builtin.needsNetwork, "local mechanism; a network-fenced agent keeps it")
    }

    /// Review finding I-3 — this test previously ASSERTED the hole. With no
    /// readable `tools` array (it is optional in the manifest spec) both the
    /// narrowing AND the deny were skipped, so the iMessage-only sender came
    /// back pre-approved. The allow must fail SAFE (keep reads working); the
    /// DENY must fail CLOSED.
    func testManifestWithoutAToolListStillDeniesTheBrokenSender() throws {
        let manifest: [String: Any] = [
            "display_name": "Read and Send iMessages",
            "author": ["name": "Anthropic"],
            "server": ["mcp_config": ["command": "node", "args": ["${__dirname}/server/index.js"]]],
        ]
        let c = try XCTUnwrap(AnthropicExtensions.connector(manifest: manifest, extensionPath: "/ext"))
        XCTAssertTrue(c.allowedTools.contains("mcp__imessage"),
                      "an unreadable tool list must not strip the agent's contact lookup")
        XCTAssertTrue(c.disallowedTools.contains("mcp__imessage__send_imessage"),
                      "the sender we KNOW is broken stays denied whatever the manifest says")
        XCTAssertNotNil(c.mcpServers["messages"], "agency's sender is wired regardless")
    }

    /// The same floor, from the other direction: a renamed tool list must not
    /// let the known-bad names back in.
    func testSupersededFloorHoldsWhenTheManifestNamesNothingFamiliar() {
        let superseded = MessagesServer.supersededTools(
            inManifestTools: [["name": "totally_new_tool"]])
        XCTAssertTrue(superseded.contains("send_imessage"))
        XCTAssertTrue(superseded.contains("read_imessages"))
        XCTAssertTrue(superseded.contains("totally_new_tool"), "unknown tools are superseded too")
    }

    // MARK: the fence reaches the agent

    func testSupersededSenderIsRemovedFromTheAgentsContext() throws {
        var agent = Agent(name: "hermes", emoji: "📨", role: "messenger", model: nil, sessionID: nil)
        agent.connectors = ["imessage"]
        let args = SessionRunner.arguments(for: agent, prompt: "hi", vaultPath: "/v")
        let disallowed = args[args.firstIndex(of: "--disallowedTools")! + 1]
            .split(separator: ",").map(String.init)
        let allowed = args[args.firstIndex(of: "--allowedTools")! + 1]
            .split(separator: ",").map(String.init)

        XCTAssertTrue(allowed.contains("mcp__messages"),
                      "the service-aware sender is pre-approved — headless runs auto-deny anything else")
        guard let extensionInstalled = Connector.byID("imessage")?.mcpServers["imessage"] else {
            return   // Desktop extension absent: nothing to supersede
        }
        XCTAssertNotNil(extensionInstalled)
        XCTAssertTrue(disallowed.contains("mcp__imessage__send_imessage"),
                      "the iMessage-only sender must not exist in the agent's context")
        XCTAssertTrue(disallowed.contains("mcp__imessage__read_imessages"),
                      "its reader returns a hex dump for ~90% of messages — supersede it too")
        XCTAssertFalse(allowed.contains("mcp__imessage__send_imessage"))
        XCTAssertTrue(allowed.contains("mcp__imessage__search_contacts"),
                      "contact lookup is the one job the extension still owns")
    }

    func testGrantWritesAnAbsoluteScriptPathWithNoLeftoverToken() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-msg-\(UUID().uuidString)")
        let store = AgentStore(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.createAgent(name: "hermes", emoji: "📨", role: "messenger")
        _ = try store.setConnectors(["imessage"], for: "hermes")

        let mcp = root.appendingPathComponent("agents/hermes/.claude/mcp.json")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: mcp)) as? [String: Any])
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        let messages = try XCTUnwrap(servers["messages"] as? [String: Any])
        let scriptArgs = try XCTUnwrap(messages["args"] as? [String])

        XCTAssertFalse(scriptArgs.contains { $0.contains(Connector.messagesServerToken) },
                       "an unresolved token would be spawned as a literal filename")
        XCTAssertTrue(scriptArgs[0].hasPrefix("/"), "absolute — a GUI app has no useful cwd")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: scriptArgs[0]),
                      "the wired path must actually exist, or the server never starts")
        XCTAssertEqual(messages["command"] as? String, Executables.resolve("node"),
                       "a bundled .app inherits no PATH — bare \"node\" is unfindable")
    }

    // MARK: the Apple-Mail sender (2026-08-13: replaces the mac-control
    // workaround — mail-app is read-only by construction, so sending through
    // Mail.app previously required driving the whole Mac)

    func testMailSendConnectorShape() throws {
        let c = try XCTUnwrap(Connector.byID("mail-app-send"))
        XCTAssertEqual(c.mcpServers["apple-mail-send"]?["args"] as? [String],
                       [Connector.appleMailSendToken], "path token resolved per install")
        XCTAssertTrue(c.needsAppleEvents, "drives Mail.app — the runner must skip the sandbox")
        XCTAssertFalse(c.needsNetwork, "local mechanism; Mail itself does the sending")
        XCTAssertTrue(c.personaNote.contains("the account has no default")
                        || c.personaNote.contains("account has no default"),
                      "his rule: several accounts, several identities, no default")
    }

    func testMailSendGrantResolvesToAnExistingScript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-mail-\(UUID().uuidString)")
        let store = AgentStore(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.createAgent(name: "poster", emoji: "📮", role: "mail")
        _ = try store.setConnectors(["mail-app-send"], for: "poster")
        let mcp = root.appendingPathComponent("agents/poster/.claude/mcp.json")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: mcp)) as? [String: Any])
        let server = try XCTUnwrap(((json["mcpServers"] as? [String: Any])?["apple-mail-send"])
            as? [String: Any])
        let args = try XCTUnwrap(server["args"] as? [String])
        XCTAssertFalse(args[0].contains("{"), "no unresolved token")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: args[0]),
                      "the wired path must exist or the server never starts")
    }

    /// The server's own guards, driven over stdio. No Mail interaction — every
    /// probe here is refused BEFORE any AppleScript runs.
    func testMailSendServerRefusesUnsafeInput() throws {
        let node = Executables.resolve("node")
        guard FileManager.default.isExecutableFile(atPath: node) else {
            throw XCTSkip("node not installed")
        }
        let script = try XCTUnwrap(MessagesServer.scriptPath(named: "apple-mail-send.js"))
        // No account: his rule — several accounts, no default.
        let noAccount = try Self.callTool("send_mail",
            ["to": "a@b.co", "subject": "s", "body": "b"], node: node, script: script)
        XCTAssertTrue(noAccount.contains("NO default"), Self.redacted(noAccount))
        // Name-form address: Mail would accept it and mis-send.
        let badAddr = try Self.callTool("send_mail",
            ["account": "iCloud", "to": "Bob <bob@x.co>", "subject": "s", "body": "b"],
            node: node, script: script)
        XCTAssertTrue(badAddr.contains("not an email address"), Self.redacted(badAddr))
        // Empty body.
        let noBody = try Self.callTool("draft_mail",
            ["account": "iCloud", "to": "a@b.co", "subject": "s", "body": " "],
            node: node, script: script)
        XCTAssertTrue(noBody.contains("body is required"), Self.redacted(noBody))
    }

    // MARK: the server answers MCP

    /// Drives the real server over stdio, exactly as Claude Code does. No model
    /// call, no network, and no message is ever sent.
    func testServerSpeaksMCPAndOffersTheServiceAwareTools() throws {
        let node = Executables.resolve("node")
        guard FileManager.default.isExecutableFile(atPath: node) else {
            throw XCTSkip("node not installed on this machine")
        }
        let script = try XCTUnwrap(MessagesServer.scriptPath())

        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [script]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        try p.run()
        let requests = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        {"jsonrpc":"2.0","id":2,"method":"tools/list"}

        """
        stdin.fileHandleForWriting.write(Data(requests.utf8))
        try? stdin.fileHandleForWriting.close()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()

        let lines = out.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "a notification carries no id and MUST NOT be answered")

        let handshake = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let result = try XCTUnwrap(handshake["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18",
                       "echo the client's version — disagreeing is why servers silently never appear")

        let listed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }.sorted()
        XCTAssertEqual(names, ["check_message_service", "read_messages", "send_message"])
    }

    /// Apple keeps most message bodies in an archived attributed string, not in
    /// `message.text`. A reader that gives up and hex-dumps the blob is why
    /// Hermes saw stray letters and missing em dashes in its own sent messages.
    func testReadReturnsRealTextNotAHexDumpOfTheDatabaseBlob() throws {
        let node = Executables.resolve("node")
        try Self.requireLiveMessagesOptIn()
        let db = "\(NSHomeDirectory())/Library/Messages/chat.db"
        guard FileManager.default.isExecutableFile(atPath: node),
              FileManager.default.isReadableFile(atPath: db) else {
            throw XCTSkip("needs node + Full Disk Access to the Messages database")
        }
        let script = try XCTUnwrap(MessagesServer.scriptPath())

        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [script]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        try p.run()
        let call: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                   "params": ["name": "read_messages",
                                              "arguments": ["limit": 25]]]
        var line = try JSONSerialization.data(withJSONObject: call)
        line.append(0x0A)
        stdin.fileHandleForWriting.write(line)
        try? stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        let obj = try JSONSerialization.jsonObject(with: out) as? [String: Any]
        let text = try XCTUnwrap((((obj?["result"] as? [String: Any])?["content"]
                                   as? [[String: Any]])?.first?["text"]) as? String)
        guard !text.hasPrefix("No message") else { throw XCTSkip("no message history to read") }
        XCTAssertFalse(text.contains("streamtyped"),
                       "the raw archive header leaked — the body was not decoded")
        // A hex dump is a long unbroken run of [0-9A-F]; real prose is not.
        XCTAssertNil(text.range(of: "[0-9A-F]{60,}", options: .regularExpression),
                     "a hex dump of attributedBody reached the agent instead of the message")
        XCTAssertTrue(text.contains("UNTRUSTED MATERIAL"),
                      "other people's text must arrive fenced, like every other inbound channel")
    }

    /// The detection itself, against a real Messages database — the only place
    /// the answer exists. Opt-in; see the LIVE-DATA note at the top of this file.
    func testDetectsTheServiceFromTheRealDatabase() throws {
        let node = Executables.resolve("node")
        try Self.requireLiveMessagesOptIn()
        let db = "\(NSHomeDirectory())/Library/Messages/chat.db"
        guard FileManager.default.isExecutableFile(atPath: node),
              FileManager.default.isReadableFile(atPath: db) else {
            throw XCTSkip("needs node + Full Disk Access to the Messages database")
        }
        let script = try XCTUnwrap(MessagesServer.scriptPath())

        func check(_ recipient: String) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: node)
            p.arguments = [script]
            let stdin = Pipe(), stdout = Pipe()
            p.standardInput = stdin; p.standardOutput = stdout
            p.standardError = FileHandle.nullDevice
            try p.run()
            let call: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                       "params": ["name": "check_message_service",
                                                  "arguments": ["recipient": recipient]]]
            var line = try JSONSerialization.data(withJSONObject: call)
            line.append(0x0A)
            stdin.fileHandleForWriting.write(line)
            try? stdin.fileHandleForWriting.close()
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let obj = try JSONSerialization.jsonObject(with: out) as? [String: Any]
            let content = ((obj?["result"] as? [String: Any])?["content"] as? [[String: Any]])
            return (content?.first?["text"] as? String) ?? ""
        }

        // An unknown number cannot be guessed — and guessing iMessage is the
        // bug. SMS is the only choice that reaches every phone.
        let unknown = try check("+19995550123")
        XCTAssertTrue(unknown.contains("Would send as: SMS"), Self.redacted(unknown))
        XCTAssertTrue(unknown.contains("Nothing known"), Self.redacted(unknown))

        // A number this Mac has only ever texted must NEVER be offered iMessage.
        guard let android = try Self.aNonAppleHandle() else {
            throw XCTSkip("no non-iMessage handle in this message database")
        }
        let detected = try check(android)
        XCTAssertFalse(detected.contains("Would send as: iMessage"),
                       "a number with no iMessage address must never be sent as iMessage: \(Self.redacted(detected))")
        XCTAssertTrue(detected.contains("NO iMessage address"), Self.redacted(detected))
    }

    /// Found by probing during /dod, 2026-08-13. The junk recipient
    /// `' OR 1=1--` reduced to the digits "11", and the last-9-digits suffix
    /// match (`id LIKE '%11'`) resolved it to an unrelated real handle. SQL escaping had
    /// held — nothing had stopped it addressing the wrong person, and
    /// send_message texts whatever handle detection resolves.
    func testAShortOrJunkRecipientCannotResolveToSomeoneElse() throws {
        let node = Executables.resolve("node")
        try Self.requireLiveMessagesOptIn()
        let db = "\(NSHomeDirectory())/Library/Messages/chat.db"
        guard FileManager.default.isExecutableFile(atPath: node),
              FileManager.default.isReadableFile(atPath: db) else {
            throw XCTSkip("needs node + Full Disk Access to the Messages database")
        }
        for junk in ["' OR 1=1--", "11", "1"] {
            let out = try Self.callTool("check_message_service", ["recipient": junk],
                                        node: node, script: try XCTUnwrap(MessagesServer.scriptPath()))
            XCTAssertTrue(out.contains("Nothing known"),
                          "\"\(junk)\" must match nobody — it matched an existing contact by digit suffix: \(Self.redacted(out))")
            XCTAssertFalse(out.contains("known to Messages as"),
                           "no canonical handle may be inferred from \"\(junk)\"")
        }
        // And the send path refuses outright rather than handing junk to
        // Messages, which accepts any recipient string without complaining.
        let refused = try Self.callTool("send_message",
                                        ["recipient": "' OR 1=1--", "text": "must never go out"],
                                        node: node, script: try XCTUnwrap(MessagesServer.scriptPath()))
        XCTAssertTrue(refused.contains("is not a phone number or email address"), Self.redacted(refused))
    }

    /// Review finding I-1: `addressable` tested for a bare "@", so prose and
    /// display-name forms were accepted and handed to Messages — which never
    /// rejects a recipient.
    func testProseContainingAnAtSignIsNotAnAddress() throws {
        let node = Executables.resolve("node")
        guard FileManager.default.isExecutableFile(atPath: node) else {
            throw XCTSkip("node not installed")
        }
        let script = try XCTUnwrap(MessagesServer.scriptPath())
        for junk in ["ask bob@work about it", "Sarah <sarah@example.com>", "@"] {
            let out = try Self.callTool("send_message", ["recipient": junk, "text": "no"],
                                        node: node, script: script)
            XCTAssertTrue(out.contains("is not a phone number or email address"),
                          "\"\(junk)\" must be refused, not sent: \(Self.redacted(out))")
        }
        // …while a real address still passes the gate (it fails later, at the
        // detection step, without sending — we assert only that it got past
        // the address check).
        let ok = try Self.callTool("check_message_service",
                                   ["recipient": "someone@example.com"],
                                   node: node, script: script)
        XCTAssertFalse(ok.contains("is not a phone number"), Self.redacted(ok))
    }

    /// Drives one tool over stdio and returns its text content.
    private static func callTool(_ name: String, _ args: [String: String],
                                 node: String, script: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [script]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        try p.run()
        var line = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name, "arguments": args]])
        line.append(0x0A)
        stdin.fileHandleForWriting.write(line)
        try? stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let obj = try JSONSerialization.jsonObject(with: out) as? [String: Any]
        let content = ((obj?["result"] as? [String: Any])?["content"] as? [[String: Any]])
        return (content?.first?["text"] as? String) ?? ""
    }

    /// Masks digit runs so a real handle can never reach a test log. Failure
    /// messages still show the SHAPE of what came back, which is what makes
    /// them diagnostic, without printing someone's phone number into CI
    /// output, a shared terminal, or a pasted log.
    private static func redacted(_ s: String) -> String {
        s.replacingOccurrences(of: "[0-9]{3,}", with: "<digits>",
                               options: .regularExpression)
    }

    /// The live-data gate. Off unless explicitly opted in, so cloning this
    /// repo and running `swift test` never touches your message history.
    private static func requireLiveMessagesOptIn() throws {
        guard ProcessInfo.processInfo.environment["AGENCY_LIVE_MESSAGES_TESTS"] == "1" else {
            throw XCTSkip("live Messages-database tests are opt-in: set AGENCY_LIVE_MESSAGES_TESTS=1")
        }
    }

    /// A handle registered on SMS/RCS and never on iMessage — i.e. a device
    /// with no iMessage address.
    private static func aNonAppleHandle() throws -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", "\(NSHomeDirectory())/Library/Messages/chat.db",
                       "SELECT id FROM handle WHERE service IN ('SMS','RCS') AND id LIKE '+%' "
                       + "AND id NOT IN (SELECT id FROM handle WHERE service='iMessage') LIMIT 1;"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}
