import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

private let serverName = "openbots_" + String(repeating: "9f3a2b01", count: 8)

func connectorServerFixture(name: String = serverName,
                            profile: String = "/private/tmp/openbots-turn.noindex/profile") throws -> ClaudeTextConnectorServer {
    try ClaudeTextConnectorServer(
        name: name, role: .browser,
        executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/node"),
        entryPointURL: URL(fileURLWithPath: "/private/tmp/cache.noindex/chrome-devtools-mcp.js"),
        options: [.headless, .userDataDirectory(URL(fileURLWithPath: profile)),
                  .executablePath(URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))],
        environment: ["CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS": "1",
                      "CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS": "1"])
}

func connectorAccessFixture() throws -> ClaudeTextConnectorAccess {
    try ClaudeTextConnectorAccess(servers: [connectorServerFixture()])
}

/// What each launchable connector announces. Messages is the three tools of
/// `apple-messages.js` (read_messages, check_message_service, send_message),
/// which `AppleMessagesScriptTests` holds to the script's own list. The table
/// must name every role: a role missing here would contribute zero tools to the
/// budget below and the budget would say nothing about it.
private let launchableConnectorToolCounts: [(ClaudeTextConnectorRole, Int)] = [
    (.browser, 29), (.appleMailRead, 10), (.appleMailSend, 5),
    (.appleContactsRead, 2), (.appleCalendarRead, 3),
    (.googleGmailReadDraft, 5), (.googleGmailSend, 2), (.googleCalendarRead, 3), (.googleDriveRead, 3),
    (.appleMessages, 3),
    (.macControl, 20),
    (.appleNotes, 4),
    (.chromeControl, 10),
]

private func launchableConnectorFixtures() throws -> [ClaudeTextConnectorServer] {
    try launchableConnectorToolCounts.enumerated().map { index, entry in
        try ClaudeTextConnectorServer(
            name: "openbots_limit_fixture_\(index)", role: entry.0,
            program: .installedTool(URL(fileURLWithPath: "/private/tmp/openbots-limit-fixture-\(index)")),
            options: [], environment: [:])
    }
}

private func value(_ arguments: [String], _ flag: String) -> String? {
    arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
}

@Test("A browser turn asks the host, keeps no safe mode, and grants no file or shell")
func connectorCommandContract() throws {
    let request = try textOnlyTestRequest(connectorAccess: try connectorAccessFixture())
    #expect(request.grantsConnectors && request.requiresPermissionControl && request.grantsTools)
    #expect(!request.grantsWork)
    // A connector's own tools are not built-ins and are not named here: probed
    // on 2.1.267, `--tools` gates built-ins only and the server's tools arrive
    // whatever it says. The one built-in a connector turn does carry is the
    // question tool — how it puts a choice to the user rather than typing the
    // question into the chat.
    #expect(request.grantedToolNames == [ClaudeTextOnlyRequest.questionToolName])
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
    #expect(value(arguments, "--tools") == ClaudeTextOnlyRequest.questionToolName)
    #expect(value(arguments, "--permission-mode") == "default")
    #expect(value(arguments, "--permission-prompt-tool") == "stdio")
    #expect(value(arguments, "--max-turns") == "16")
    #expect(value(arguments, "--mcp-config")
        == ClaudeTextConnectorConfigurationFile.configurationURL(for: request).path)
    // Safe mode disables MCP servers outright, so it cannot be kept. Every
    // other fence is still here, each enforced on its own.
    #expect(!arguments.contains("--safe-mode"))
    for kept in ["--restricted", "--strict-mcp-config", "--setting-sources", "--disable-slash-commands",
                 "--no-session-persistence", "--no-chrome"] {
        #expect(arguments.contains(kept), "missing \(kept)")
    }
    // Browsing is not working on the Mac: no folders, no helpers, no shell.
    for forbidden in ["--add-dir", "--agents", "--allowedTools", "--resume", "--continue",
                      "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions"] {
        #expect(!arguments.contains(forbidden), "unexpected \(forbidden)")
    }
    let deniedValue = try #require(value(arguments, "--disallowedTools"))
    let denied = deniedValue.split(separator: ",").map(String.init)
    // The blanket deny would shadow the grant; the wildcard over the granted
    // namespace would too. Everything else stays denied by name.
    #expect(!denied.contains("*"))
    #expect(!denied.contains("mcp__*"))
    for name in ["Bash", "Edit", "Read", "Write", "WebSearch", "WebFetch", "Skill", "Task", "Workflow"] {
        #expect(denied.contains(name), "missing deny \(name)")
    }
}

@Test("A browser turn's settings pre-approve nothing of its own, so every page action asks")
func connectorSettingsContract() throws {
    let request = try textOnlyTestRequest(connectorAccess: try connectorAccessFixture())
    let settings = try #require(JSONSerialization.jsonObject(
        with: Data(ClaudeTextOnlyCommandBuilder.settingsJSON(for: request).utf8)) as? [String: Any])
    #expect(settings["disableAllHooks"] as? Bool == true)
    #expect(settings["disableClaudeAiConnectors"] as? Bool == true)
    #expect(settings["syncClaudeAiSkills"] as? Bool == false)
    // No sandbox block: that belongs to a shell, and this turn has none.
    #expect(settings["sandbox"] == nil)
    let permissions = try #require(settings["permissions"] as? [String: Any])
    #expect(permissions["defaultMode"] as? String == "default")
    #expect(permissions["allow"] as? [String] == [])
    // Nothing is pre-approved and nothing is listed to ask: under the default
    // mode a tool in neither list prompts, and the prompt goes to the app.
    #expect(permissions["ask"] == nil)
    let deny = try #require(permissions["deny"] as? [String])
    #expect(!deny.contains("mcp__*"))
    #expect(!deny.contains("*"))
    #expect(deny.contains("Bash") && deny.contains("WebFetch"))
    // The granted namespace survives the settings encoder. A name filter that
    // dropped digits would break it, since every server key is hex.
    #expect(ClaudeTextOnlyCommandBuilder.isJSONSafeName("mcp__\(serverName)__navigate_page"))
}

@Test("Work and a browser together keep both grants, and the helper inherits the browser")
func connectorWithWorkKeepsBoth() throws {
    let work = try ClaudeTextWorkAccess(
        workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/desk.noindex"),
        protectedPaths: ["/Users/x/.ssh"])
    let request = try textOnlyTestRequest(allowedTools: [.webSearch], workAccess: work,
                                          connectorAccess: try connectorAccessFixture())
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
    #expect(arguments.contains("--agents"))
    #expect(value(arguments, "--permission-prompt-tool") == "stdio")
    #expect(value(arguments, "--mcp-config")
        == ClaudeTextConnectorConfigurationFile.configurationURL(for: request).path)
    let deniedValue = try #require(value(arguments, "--disallowedTools"))
    let denied = deniedValue.split(separator: ",").map(String.init)
    #expect(!denied.contains("mcp__*"))
    #expect(denied.contains("Skill"))
    // A concrete `mcp__server__tool` does not cancel the `mcp__*` wildcard, so
    // leaving it in the helper's deny list would deny the helper the servers
    // its parent was granted.
    let agentsJSON = try #require(value(arguments, "--agents"))
    let agents = try #require(JSONSerialization.jsonObject(with: Data(agentsJSON.utf8)) as? [String: Any])
    let helper = try #require(agents[ClaudeTextHelperPolicy.agentType] as? [String: Any])
    let helperDenied = try #require(helper["disallowedTools"] as? [String])
    #expect(!helperDenied.contains("mcp__*"))
    // The helper inherits the frozen selection, never a configuration of its own.
    for key in ["mcpServers", "hooks", "skills", "isolation", "memory"] { #expect(helper[key] == nil) }
}

@Test("A turn with no connector is byte-for-byte the shipped command")
func noConnectorIsUnchanged() throws {
    let plain = try textOnlyTestRequest()
    let withNil = try textOnlyTestRequest(connectorAccess: nil)
    #expect(ClaudeTextOnlyCommandBuilder.arguments(for: plain)
        == ClaudeTextOnlyCommandBuilder.arguments(for: withNil))
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: plain)
    #expect(arguments.contains("--safe-mode"))
    #expect(value(arguments, "--mcp-config") == "{\"mcpServers\":{}}")
    #expect(value(arguments, "--permission-mode") == "dontAsk")
    #expect(value(arguments, "--disallowedTools") == "*")
    #expect(!arguments.contains("--permission-prompt-tool"))
}

@Test("The configuration file names the selected server and nothing else")
func configurationFileIsSelectedOnly() throws {
    let access = try connectorAccessFixture()
    let json = try ClaudeTextConnectorConfigurationFile.configurationJSON(for: access)
    #expect(json.count <= ClaudeTextConnectorConfigurationFile.maximumBytes)
    let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
    let servers = try #require(object["mcpServers"] as? [String: Any])
    #expect(Array(servers.keys) == [serverName])
    let server = try #require(servers[serverName] as? [String: Any])
    #expect(server["type"] as? String == "stdio")
    #expect(server["command"] as? String == "/opt/homebrew/bin/node")
    let arguments = try #require(server["args"] as? [String])
    #expect(arguments.first == "/private/tmp/cache.noindex/chrome-devtools-mcp.js")
    #expect(arguments.contains("--headless"))
    #expect(arguments.contains("--userDataDir"))
    for forbidden in ["--browserUrl", "--wsEndpoint", "--autoConnect", "--proxyServer"] {
        #expect(!arguments.contains(forbidden))
    }
    let environment = try #require(server["env"] as? [String: String])
    #expect(environment["CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS"] == "1")
    // The same selection always produces the same bytes.
    #expect(try ClaudeTextConnectorConfigurationFile.configurationJSON(for: access) == json)
}

/// A work turn's CLI runs with TMPDIR in the
/// shell's own folder, which the turn's commands can read. A connector server
/// inherits the CLI's environment, and the Google server hands TMPDIR to its
/// Keychain-backed sign-in helper. Every server is pinned to the run's own
/// temporary folder unless it names one itself.
@Test("Every connector server's temporary folder is the run's own, never the shell's")
func connectorServersPinTheRunTemporaryFolder() throws {
    let mail = try ClaudeTextConnectorServer(
        name: "openbots_" + String(repeating: "1c4d5e6f", count: 8), role: .appleMailRead,
        program: .installedTool(URL(fileURLWithPath: "/Users/somebody/.local/bin/apple-mail-fast-mcp")),
        options: [.readOnly], environment: [:])
    let access = try ClaudeTextConnectorAccess(servers: [mail])
    let run = URL(fileURLWithPath: "/private/tmp/run.noindex/Temp.noindex")
    let json = try ClaudeTextConnectorConfigurationFile.configurationJSON(for: access, temporaryDirectory: run)
    let root = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
    let servers = try #require(root["mcpServers"] as? [String: Any])
    let entry = try #require(servers[mail.name] as? [String: Any])
    #expect((entry["env"] as? [String: String])?["TMPDIR"] == run.path)
    // A server that names its own keeps it, as the browser and Control this Mac do.
    let own = "/private/tmp/own.noindex/tmp"
    let named = try ClaudeTextConnectorServer(
        name: "openbots_" + String(repeating: "2d5e6f70", count: 8), role: .appleMailRead,
        program: .installedTool(URL(fileURLWithPath: "/Users/somebody/.local/bin/apple-mail-fast-mcp")),
        options: [.readOnly], environment: ["TMPDIR": own])
    let pinned = try ClaudeTextConnectorConfigurationFile.configurationJSON(
        for: try ClaudeTextConnectorAccess(servers: [named]), temporaryDirectory: run)
    let namedRoot = try #require(JSONSerialization.jsonObject(with: pinned) as? [String: Any])
    let namedEntry = try #require((namedRoot["mcpServers"] as? [String: Any])?[named.name] as? [String: Any])
    #expect((namedEntry["env"] as? [String: String])?["TMPDIR"] == own)
}

@Test("Control this Mac launches Peekaboo's own binary with mcp serve, through the fence, with only its reviewed environment")
func macControlLaunchShape() throws {
    let program = ClaudeTextConnectorProgram.fenced(
        interpreterURL: URL(fileURLWithPath: "/opt/homebrew/bin/node"),
        proxyURL: URL(fileURLWithPath: "/Applications/OpenBots Next.app/Contents/Resources/fence-proxy.js"),
        label: "mac-control", server: .installedTool(URL(fileURLWithPath: "/Users/x/.npm/_npx/abc/node_modules/@steipete/peekaboo/peekaboo")))
    // Nine keys: the home three, the four switches, the tool list and the
    // config folder with its migration off.
    let server = try ClaudeTextConnectorServer(name: "openbots_mac", role: .macControl, program: program,
        options: [.mcpServe], environment: [
            "HOME": "/private/tmp/run", "TMPDIR": "/private/tmp/run", "CFFIXED_USER_HOME": "/private/tmp/run",
            "PEEKABOO_NO_REMOTE": "1", "PEEKABOO_DISABLE_AGENT": "1", "PEEKABOO_DISABLE_MCP_AUTOCONNECT": "true",
            "PEEKABOO_ALLOW_TOOLS": "see,click", "PEEKABOO_CONFIG_DIR": "/private/tmp/run/.peekaboo",
            "PEEKABOO_CONFIG_DISABLE_MIGRATION": "1"])
    #expect(server.arguments.suffix(2) == ["mcp", "serve"])
    #expect(server.arguments.contains("/Users/x/.npm/_npx/abc/node_modules/@steipete/peekaboo/peekaboo"))
    #expect(server.program.isFenced)
    // Its other switches are not spellable: a bridge socket or a forced auto-connect cannot be passed.
    #expect(throws: ClaudeTextConnectorAccessError.self) {
        try ClaudeTextConnectorServer(name: "openbots_mac", role: .macControl, program: program,
            options: [.mcpServe], environment: ["PEEKABOO_BRIDGE_SOCKET": "/tmp/s"])
    }
    #expect(throws: ClaudeTextConnectorAccessError.self) {
        try ClaudeTextConnectorServer(name: "openbots_mac", role: .macControl, program: program,
            options: [.mcpServe], environment: ["PEEKABOO_FORCE_MCP_AUTOCONNECT": "1"])
    }
}

@Test("Every launchable connector fits the server cap and the tool bound together, and one server past the cap is rejected")
func connectorServerSelectionBound() throws {
    // The invariant is the role set, not a number: every role this build can
    // launch fits under the cap at once, and the tool table covers every role.
    #expect(Set(launchableConnectorToolCounts.map(\.0)) == Set(ClaudeTextConnectorRole.allCases))
    #expect(launchableConnectorToolCounts.count == ClaudeTextConnectorRole.allCases.count)
    #expect(ClaudeTextConnectorRole.allCases.count <= ClaudeTextConnectorAccess.maximumServerCount)
    let fixtures = try launchableConnectorFixtures()
    #expect(fixtures.count == ClaudeTextConnectorRole.allCases.count)

    let five = try ClaudeTextConnectorAccess(servers: Array(fixtures.prefix(5)))
    let fiveJSON = try ClaudeTextConnectorConfigurationFile.configurationJSON(for: five)
    let fiveRoot = try #require(JSONSerialization.jsonObject(with: fiveJSON) as? [String: Any])
    #expect((fiveRoot["mcpServers"] as? [String: Any])?.count == 5)

    let everyRole = try ClaudeTextConnectorAccess(servers: fixtures)
    let everyJSON = try ClaudeTextConnectorConfigurationFile.configurationJSON(for: everyRole)
    let everyRoot = try #require(JSONSerialization.jsonObject(with: everyJSON) as? [String: Any])
    #expect((everyRoot["mcpServers"] as? [String: Any])?.count == fixtures.count)
    #expect(everyJSON.count <= ClaudeTextConnectorConfigurationFile.maximumBytes)

    // The thirteen launchable connectors announce 99 tools together (Messages
    // adds 3, Control this Mac the 20 PEEKABOO_ALLOW_TOOLS leaves on now that
    // capture is out, Google Drive 3, Apple Notes 4, Gmail send 2, and Control
    // Chrome all ten it announces). That total stays under the stream's own
    // bound on declared connector tools, and a start-up announcing all of them
    // flows through the stream. Word and PowerPoint are not offered.
    let tools = everyRole.servers.flatMap { server in
        let count = launchableConnectorToolCounts.first { $0.0 == server.role }?.1 ?? 0
        return (0..<count).map { "\(server.toolNamespace)tool_\($0)" }
    }
    #expect(tools.count == 99)
    #expect(tools.count <= ClaudeTextOnlyStream.maximumDeclaredConnectorTools)
    let connected: [[String: Any]] = everyRole.servers.map { ["name": $0.name, "status": "connected"] }
    let request = try textOnlyTestRequest(connectorAccess: everyRole)
    var stream = ClaudeTextOnlyStream(request: request)
    #expect(throws: Never.self) {
        _ = try stream.consume(try connectorInit(request, tools: tools, servers: connected))
    }

    // Exactly the cap is admitted and one more is not, computed from the cap so
    // the next raise does not have to rewrite this.
    let roles = ClaudeTextConnectorRole.allCases
    let atCap = try (0..<ClaudeTextConnectorAccess.maximumServerCount).map { index in
        try ClaudeTextConnectorServer(
            name: "openbots_cap_fixture_\(index)", role: roles[index % roles.count],
            program: .installedTool(URL(fileURLWithPath: "/private/tmp/openbots-cap-fixture-\(index)")),
            options: [], environment: [:])
    }
    #expect(throws: Never.self) { try ClaudeTextConnectorAccess(servers: atCap) }
    let pastCap = try ClaudeTextConnectorServer(
        name: "openbots_cap_fixture_past", role: .browser,
        program: .installedTool(URL(fileURLWithPath: "/private/tmp/openbots-cap-fixture-past")),
        options: [], environment: [:])
    #expect(throws: ClaudeTextConnectorAccessError.invalidSelection) {
        try ClaudeTextConnectorAccess(servers: atCap + [pastCap])
    }
}

@Test("A launch can carry only the reviewed options, and only sane paths")
func theLaunchVocabularyIsClosed() throws {
    // A relative path, a traversal, or the root are not launches.
    for bad in [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/a/../b")] {
        #expect(throws: ClaudeTextConnectorAccessError.invalidServer, "\(bad)") {
            try ClaudeTextConnectorServer(name: serverName, role: .browser, executableURL: bad,
                entryPointURL: URL(fileURLWithPath: "/x/y.js"), options: [.headless], environment: [:])
        }
    }
    // The entry point must be the server's own script.
    #expect(throws: ClaudeTextConnectorAccessError.invalidServer) {
        try ClaudeTextConnectorServer(name: serverName, role: .browser, executableURL: URL(fileURLWithPath: "/opt/node"),
            entryPointURL: URL(fileURLWithPath: "/x/y.sh"), options: [.headless], environment: [:])
    }
    // A name that could impersonate another server's namespace.
    for bad in ["", "has__separator", "has space", "has/slash"] {
        #expect(throws: ClaudeTextConnectorAccessError.invalidServer, "\(bad)") {
            try ClaudeTextConnectorServer(name: bad, role: .browser, executableURL: URL(fileURLWithPath: "/opt/node"),
                entryPointURL: URL(fileURLWithPath: "/x/y.js"), options: [.headless], environment: [:])
        }
    }
    // An environment key nobody reviewed, including a credential-shaped one.
    for bad in ["ANTHROPIC_API_KEY", "PATH", "CHROME_PATH", "NODE_OPTIONS"] {
        #expect(throws: ClaudeTextConnectorAccessError.invalidServer, "\(bad)") {
            try ClaudeTextConnectorServer(name: serverName, role: .browser, executableURL: URL(fileURLWithPath: "/opt/node"),
                entryPointURL: URL(fileURLWithPath: "/x/y.js"), options: [.headless], environment: [bad: "1"])
        }
    }
    // The one search path, only as the system's own and only for Apple Notes,
    // whose pinned extension runs `osascript` by its bare name.
    let notesServer = { (path: String, role: ClaudeTextConnectorRole) in
        try ClaudeTextConnectorServer(name: serverName, role: role, executableURL: URL(fileURLWithPath: "/opt/node"),
            entryPointURL: URL(fileURLWithPath: "/x/y.js"), options: [], environment: ["PATH": path])
    }
    #expect(throws: Never.self) { try notesServer("/usr/bin:/bin", .appleNotes) }
    for (path, role) in [("/usr/bin:/bin", ClaudeTextConnectorRole.browser), ("/opt/homebrew/bin:/usr/bin:/bin", .appleNotes),
                         ("/usr/bin", .appleNotes)] {
        #expect(throws: ClaudeTextConnectorAccessError.invalidServer, "\(path) \(role)") { try notesServer(path, role) }
    }
    // The same option twice is not a launch either.
    #expect(throws: ClaudeTextConnectorAccessError.invalidServer) {
        try ClaudeTextConnectorServer(name: serverName, role: .browser, executableURL: URL(fileURLWithPath: "/opt/node"),
            entryPointURL: URL(fileURLWithPath: "/x/y.js"), options: [.headless, .headless], environment: [:])
    }
    #expect(throws: ClaudeTextConnectorAccessError.invalidSelection) {
        try ClaudeTextConnectorAccess(servers: [])
    }
    let duplicate = try connectorServerFixture()
    #expect(throws: ClaudeTextConnectorAccessError.invalidSelection) {
        try ClaudeTextConnectorAccess(servers: [duplicate, duplicate])
    }
}

// MARK: - What the stream will accept from a connector turn

private func connectorInit(_ request: ClaudeTextOnlyRequest, tools: [String],
                           servers: [[String: Any]]) throws -> Data {
    // The CLI announces the built-ins it was launched with alongside the
    // server's own tools, so a frame that omits the question tool is not the
    // frame this turn produces.
    try textOnlyTestInit(request, override: [
        "tools": request.grantedToolNames + request.appServerToolNames + tools,
        "mcp_servers": servers + appServerEntries(request), "permissionMode": "default"])
}

private func browserTools(_ count: Int) -> [String] {
    (0..<count).map { "mcp__\(serverName)__tool_\($0)" }
}

private func connectedServer() -> [[String: Any]] { [["name": serverName, "status": "connected"]] }

private extension ClaudeTextOnlyStream {
    @discardableResult
    mutating func consume(_ bytes: Data) throws -> [ClaudeTextOnlyEvent] {
        var events: [ClaudeTextOnlyEvent] = []
        // The stream wraps its failure with the diagnostic code; the tests
        // assert the failure, as the other stream suites do.
        do { try consume(bytes) { events.append($0) } }
        catch let rejection as ClaudeTextOnlyRejection { throw rejection.failure }
        return events
    }
}

@Test("A browser turn accepts exactly its own server and its own namespace")
func connectorInitIsAccepted() throws {
    let request = try textOnlyTestRequest(connectorAccess: try connectorAccessFixture())
    var stream = ClaudeTextOnlyStream(request: request)
    // The server announces its whole tool set — twenty-nine for the browser on
    // 2.1.267 — and the turn cannot narrow that, only refuse what is outside
    // its namespace.
    #expect(throws: Never.self) {
        _ = try stream.consume(try connectorInit(request, tools: browserTools(29), servers: connectedServer()))
    }
}

@Test("A browser turn refuses a server it did not select, or one that did not connect")
func connectorInitRefusesTheWrongServer() throws {
    let request = try textOnlyTestRequest(connectorAccess: try connectorAccessFixture())
    let cases: [(String, [[String: Any]], [String])] = [
        ("another server's name", [["name": "openbots_deadbeef", "status": "connected"]], browserTools(3)),
        ("a server that failed", [["name": serverName, "status": "failed"]], browserTools(3)),
        ("no server at all", [], browserTools(3)),
        ("a second, unselected server", connectedServer() + [["name": "openbots_extra", "status": "connected"]],
         browserTools(3)),
    ]
    for (label, servers, tools) in cases {
        var stream = ClaudeTextOnlyStream(request: request)
        #expect(throws: ClaudeTextOnlyFailure.unsafeInitialization, "\(label)") {
            _ = try stream.consume(try connectorInit(request, tools: tools, servers: servers))
        }
    }
}

@Test("A browser turn refuses a tool outside its namespace, an extra built-in, or a flood of them")
func connectorInitRefusesTheWrongTools() throws {
    let request = try textOnlyTestRequest(connectorAccess: try connectorAccessFixture())
    let cases: [(String, [String])] = [
        ("another server's tool", ["mcp__openbots_deadbeef__click"]),
        ("a built-in it was never granted", browserTools(2) + ["Bash"]),
        ("a nested namespace", ["mcp__\(serverName)__a__b"]),
        ("a repeated name", ["mcp__\(serverName)__click", "mcp__\(serverName)__click"]),
        ("more than a turn may announce", browserTools(ClaudeTextOnlyStream.maximumDeclaredConnectorTools + 1)),
        ("nothing at all", []),
    ]
    for (label, tools) in cases {
        var stream = ClaudeTextOnlyStream(request: request)
        #expect(throws: ClaudeTextOnlyFailure.unsafeInitialization, "\(label)") {
            _ = try stream.consume(try connectorInit(request, tools: tools, servers: connectedServer()))
        }
    }
}

@Test("A turn with no connector still refuses any server at all")
func ungrantedTurnStillRefusesServers() throws {
    let request = try textOnlyTestRequest()
    var stream = ClaudeTextOnlyStream(request: request)
    #expect(throws: ClaudeTextOnlyFailure.unsafeInitialization) {
        _ = try stream.consume(try textOnlyTestInit(request, override: ["mcp_servers": connectedServer()]))
    }
    // And a connector tool name is not admitted just because a server claimed it.
    var granted = ClaudeTextOnlyStream(request: request)
    #expect(throws: ClaudeTextOnlyFailure.unsafeInitialization) {
        _ = try granted.consume(try textOnlyTestInit(request, override: ["tools": browserTools(1)]))
    }
}

/// Foundation drops one U+FEFF from the start of every string it reads, keys
/// included, and keeps the first of two keys that then match; the CLI and a
/// node server keep both and read the last. This
/// checks the stream's flag only; the refusal is `aQuestionNotReadAsSentIsDenied`.
@Test("A question whose input opens a string with an invisible mark is handed over as not read as sent")
func aHiddenMarkAtTheStartOfAStringIsFlagged() throws {
    let request = try textOnlyTestRequest(connectorAccess: try connectorAccessFixture())
    var stream = ClaudeTextOnlyStream(request: request)
    stream.expectControlInitialization(requestID: "init-1")
    var events: [ClaudeTextOnlyEvent] = []
    func feed(_ data: Data) throws { try stream.consume(data) { events.append($0) } }
    try feed(try textOnlyTestLine(["type": "control_response",
        "response": ["subtype": "success", "request_id": "init-1", "response": [String: Any]()]]))
    try feed(try connectorInit(request, tools: browserTools(29), servers: connectedServer()))
    try feed(try textOnlyTestReplay(request))
    let tool = "mcp__\(serverName)__tool_0"
    // Written by hand, byte for byte, as the CLI writes a line: an encoder
    // would escape nothing here, but it would also never write the escaped form.
    func ask(_ id: String, _ input: String) throws -> ClaudeTextPermissionRequest? {
        let line = "{\"type\":\"control_request\",\"request_id\":\"\(id)\",\"session_id\":\"\(request.sessionID.uuidString)\","
            + "\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"\(tool)\",\"tool_use_id\":\"toolu_\(id)\","
            + "\"input\":\(input)}}\n"
        try feed(Data(line.utf8))
        if case .permissionRequested(let value) = events.last { return value }
        return nil
    }
    let rawKey = try #require(try ask("r1", "{\"\u{FEFF}url\":\"https://example.com\",\"url\":\"https://elsewhere.example\"}"))
    #expect(!rawKey.inputReadsAsSent)
    let escapedKey = try #require(try ask("r2", "{\"\\uFEFFurl\":\"https://example.com\",\"url\":\"https://elsewhere.example\"}"))
    #expect(!escapedKey.inputReadsAsSent)
    let escapedValue = try #require(try ask("r3", "{\"url\":\"\\ufeffhttps://example.com\"}"))
    #expect(!escapedValue.inputReadsAsSent)
    // Inside a string, and after an escaped quote, both sides keep the mark.
    let inside = try #require(try ask("r4", "{\"url\":\"https://example.com/\u{FEFF}x\"}"))
    #expect(inside.inputReadsAsSent)
    let afterQuote = try #require(try ask("r5", "{\"url\":\"a\\\"\u{FEFF}b\"}"))
    #expect(afterQuote.inputReadsAsSent)
    let plain = try #require(try ask("r6", "{\"url\":\"https://example.com\"}"))
    #expect(plain.inputReadsAsSent)
}

@Test("A connector turn with no Work on the Mac still opens its control channel and asks its own card")
func connectorOnlyTurnAnswersItsOwnCard() throws {
    let request = try textOnlyTestRequest(connectorAccess: try connectorAccessFixture())
    // The command and the transport arm the channel for a connector alone; the
    // stream has to accept the frames that channel then carries, or a bot with
    // a connector and no Work can never be asked anything.
    #expect(request.requiresPermissionControl && !request.grantsWork)
    var stream = ClaudeTextOnlyStream(request: request)
    stream.expectControlInitialization(requestID: "init-1")
    var events: [ClaudeTextOnlyEvent] = []
    func feed(_ data: Data) throws { try stream.consume(data) { events.append($0) } }
    try feed(try textOnlyTestLine(["type": "control_response",
        "response": ["subtype": "success", "request_id": "init-1", "response": [String: Any]()]]))
    #expect(events == [.controlReady])
    #expect(stream.hasOpenControlChannel)
    try feed(try connectorInit(request, tools: browserTools(29), servers: connectedServer()))
    try feed(try textOnlyTestReplay(request))
    let tool = "mcp__\(serverName)__tool_0"
    let input: [String: Any] = ["url": "https://example.com"]
    try feed(try textOnlyTestLine(["type": "control_request", "request_id": "req-1",
        "session_id": request.sessionID.uuidString,
        "request": ["subtype": "can_use_tool", "tool_name": tool, "tool_use_id": "toolu_1", "input": input]]))
    let question = try #require(events.last.flatMap { event -> ClaudeTextPermissionRequest? in
        if case .permissionRequested(let value) = event { return value }; return nil })
    #expect(question.requestID == "req-1" && question.toolUseID == "toolu_1" && question.toolName == tool)
    let decoded = try #require(JSONSerialization.jsonObject(with: question.inputJSON) as? [String: String])
    #expect(decoded == ["url": "https://example.com"])
    // A cancel withdraws the card, and the host's own answer echoes back harmlessly.
    try feed(try textOnlyTestLine(["type": "control_cancel_request", "request_id": "req-1"]))
    #expect(events.last == .permissionCancelled(requestID: "req-1"))
    try feed(try textOnlyTestLine(["type": "control_response",
        "response": ["subtype": "success", "request_id": "req-1", "response": ["behavior": "deny"]]]))
    // A question about a tool the turn was never granted is handed to the host
    // marked unadmitted, so it can only be answered no; the turn goes on
    // (ending the turn instead would kill a team leg on a sandbox network
    // question).
    try feed(try textOnlyTestLine(["type": "control_request", "request_id": "req-2",
        "session_id": request.sessionID.uuidString,
        "request": ["subtype": "can_use_tool", "tool_name": "Bash", "tool_use_id": "toolu_2",
                    "input": ["command": "ls"]]]))
    if case .permissionRequested(let refused) = try #require(events.last) {
        #expect(refused.toolName == "Bash" && !refused.admitted && refused.requestID == "req-2")
    } else { Issue.record("the ungranted question was not surfaced") }
    try feed(textOnlyTestDelta(request, text: "Still here."))
    #expect(events.last == .textSnapshot("Still here."))
}

@Test("A server can also be a console script the tool installer wrote, run with no interpreter of ours")
func theLaunchCanBeAnInstalledTool() throws {
    let script = URL(fileURLWithPath: "/Users/somebody/.local/share/uv/tools/apple-mail-fast-mcp/bin/apple-mail-fast-mcp")
    let server = try ClaudeTextConnectorServer(
        name: "openbots_" + String(repeating: "1c4d5e6f", count: 8), role: .appleMailRead,
        program: .installedTool(script), options: [.readOnly], environment: [:])
    // The script is the command; there is no entry point in front of it, and
    // the read-only flag is the only thing the launch says.
    #expect(server.executableURL == script)
    #expect(server.arguments == ["--read-only"])
    let access = try ClaudeTextConnectorAccess(servers: [server])
    // Nothing owns a profile, so nothing has to be reaped by path.
    #expect(access.ownedProfileURLs.isEmpty)
    let json = try ClaudeTextConnectorConfigurationFile.configurationJSON(for: access)
    let root = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
    let servers = try #require(root["mcpServers"] as? [String: Any])
    let entry = try #require(servers[server.name] as? [String: Any])
    #expect(entry["command"] as? String == script.path)
    #expect(entry["args"] as? [String] == ["--read-only"])
    #expect(entry["type"] as? String == "stdio")
    // A relative path is not a program, whichever spelling asks for it.
    #expect(throws: ClaudeTextConnectorAccessError.invalidServer) {
        try ClaudeTextConnectorServer(name: serverName, role: .appleMailRead,
            program: .installedTool(URL(fileURLWithPath: "/a/../b")), options: [], environment: [:])
    }
}

@Test("A connector turn refuses an init frame that does not announce the question tool")
func connectorInitRefusesAFrameMissingTheQuestionTool() throws {
    let request = try textOnlyTestRequest(connectorAccess: try connectorAccessFixture())
    var stream = ClaudeTextOnlyStream(request: request)
    // The turn is launched with the question tool, so a child announcing only
    // the server's tools is not the child this turn started — the same exact
    // match that refuses an extra built-in refuses a missing one.
    #expect(throws: ClaudeTextOnlyFailure.unsafeInitialization) {
        _ = try stream.consume(try textOnlyTestInit(request, override: [
            "tools": browserTools(3), "mcp_servers": connectedServer(),
            "permissionMode": "default"]))
    }
}

/// A mail call the
/// server never answers says so. Claude Code 2.1.282 waits 1e8 ms (27 hours) for
/// a tool call by default and reads a per-server `timeout` in milliseconds; the
/// Apple Mail sender's longest call is two `osascript` runs of 60 s each.
@Test("The Apple Mail sender is launched with a tool-call time limit; other servers keep the CLI's own")
func theMailSenderHasATimeLimit() throws {
    let program = ClaudeTextConnectorProgram.installedTool(URL(fileURLWithPath: "/usr/local/bin/node"))
    let send = try ClaudeTextConnectorServer(name: "openbots_" + String(repeating: "3e6f7081", count: 8),
                                             role: .appleMailSend, program: program, options: [], environment: [:])
    let read = try ClaudeTextConnectorServer(name: "openbots_" + String(repeating: "4f708192", count: 8),
                                             role: .appleMailRead, program: program, options: [.readOnly], environment: [:])
    let json = try ClaudeTextConnectorConfigurationFile.configurationJSON(
        for: try ClaudeTextConnectorAccess(servers: [send, read]))
    let servers = try #require((JSONSerialization.jsonObject(with: json) as? [String: Any])?["mcpServers"] as? [String: Any])
    #expect((servers[send.name] as? [String: Any])?["timeout"] as? Int == ClaudeTextConnectorConfigurationFile.mailSendCallLimitMilliseconds)
    // Above the script's own ceiling: a reply is two osascript runs, each killed at 60 s.
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/OpenBotsServices/Resources/apple-mail-send.js")
    let source = try String(contentsOf: script, encoding: .utf8)
    #expect(source.components(separatedBy: "timeout: 60000").count == 2, "one osascript time limit, of 60 s")
    #expect(ClaudeTextConnectorConfigurationFile.mailSendCallLimitMilliseconds > 2 * 60_000)
    #expect((servers[read.name] as? [String: Any])?["timeout"] == nil)
}
