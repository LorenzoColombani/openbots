import Foundation
import OpenBotsDomain

/// One connector a turn was launched with: a frozen, transient selection that
/// Services resolved and verified. It is never a persisted grant and never a
/// general MCP configuration imported from the account.
///
/// Everything the launch can say is spelled by a type here rather than by a
/// validated string. The browser server accepts options that would attach it to
/// the user's own running Chrome — `--browserUrl`, `--wsEndpoint`,
/// `--autoConnect` — and a validator that only checks an argument's *shape*
/// would pass every one of them. A closed option list means those cannot be
/// expressed at all, so no catalog entry, however it was written, can reach
/// them.
public struct ClaudeTextConnectorServer: Equatable, Sendable {
    /// The server's name in the launch configuration, which is also the middle
    /// segment of every tool name it announces (`mcp__<name>__<tool>`).
    public let name: String
    /// Which connector this is. The name is a hash, so nothing downstream could
    /// tell a browser call from a mail call without being told; the card's
    /// words depend on knowing, and a card that describes the wrong thing is
    /// worse than no card.
    public let role: ClaudeTextConnectorRole
    /// What is actually started, and how. A closed set of two spellings, both
    /// resolved to absolute paths by Services: nothing here can name a program
    /// to be looked up on a `PATH` the child does not have.
    public let program: ClaudeTextConnectorProgram
    /// Everything else the server is launched with, in fixed declaration order.
    public let options: [ClaudeTextConnectorOption]
    /// The allow-listed child environment; nothing else is passed through.
    public let environment: [String: String]
    /// The chats a Messages server was launched to read, kept so a turn can
    /// tell when one was taken away while it ran. Nil on every other server.
    public let chatScope: AppleMessagesChatScope?

    /// The program the launch configuration runs.
    public var executableURL: URL { program.executableURL }

    /// The full argument vector, the program's own leading arguments first, in
    /// one fixed order so the same selection always produces identical bytes.
    public var arguments: [String] {
        program.leadingArguments + options.flatMap(\.arguments)
    }

    /// The namespace every tool this server announces must sit in. The server
    /// announces its whole tool set and a selection cannot narrow that, so the
    /// turn admits by namespace and refuses everything outside it; which of
    /// those tools may actually be *called* is the deny list's and the approval
    /// card's question, not this one.
    public var toolNamespace: String { "mcp__\(name)__" }

    public init(name: String, role: ClaudeTextConnectorRole, program: ClaudeTextConnectorProgram,
                options: [ClaudeTextConnectorOption], environment: [String: String],
                chatScope: AppleMessagesChatScope? = nil) throws {
        // The vocabulary below is the fence; the count is only a sanity bound
        // over it. Control this Mac needs nine keys, and a server over the
        // bound throws here, which the launch service turns into a connector
        // silently missing from the turn — so it keeps room above the largest.
        guard Self.isServerName(name), program.isWellFormed,
              options.count <= 8, Set(options.map(\.key)).count == options.count,
              options.allSatisfy(\.isWellFormed),
              environment.count <= 12,
              environment.allSatisfy({ Self.environmentKeys.contains($0.key) && Self.isPlain($0.value) }),
              environment["PATH"].map({ $0 == Self.systemSearchPath && Self.runsBareOsascript(role) }) ?? true
        else { throw ClaudeTextConnectorAccessError.invalidServer }
        self.name = name
        self.role = role
        self.program = program
        self.options = options.sorted { $0.key < $1.key }
        self.environment = environment
        self.chatScope = chatScope
    }

    /// The node spelling, written out: an absolute interpreter and the server's
    /// own `.js` entry point, resolved from the configured package version
    /// rather than left to a package manager to fetch.
    public init(name: String, role: ClaudeTextConnectorRole, executableURL: URL,
                entryPointURL: URL, options: [ClaudeTextConnectorOption],
                environment: [String: String], chatScope: AppleMessagesChatScope? = nil) throws {
        try self.init(name: name, role: role,
                      program: .node(interpreterURL: executableURL, entryPointURL: entryPointURL),
                      options: options, environment: environment, chatScope: chatScope)
    }

    /// A server name is one namespace segment, so it can carry no `__`: that
    /// sequence is the tool-name separator and a name containing it could make
    /// one server's tool read as another's.
    static func isServerName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.contains("__")
            && value.utf8.allSatisfy { byte in
                (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                    || (byte >= 48 && byte <= 57) || byte == 95 || byte == 45
            }
    }

    static func isAbsoluteFileURL(_ url: URL) -> Bool {
        url.isFileURL && url.baseURL == nil && url.path.hasPrefix("/") && url.path.utf8.count > 1
            && !url.pathComponents.contains("..") && !url.pathComponents.contains(".")
            && isPlain(url.path)
    }

    /// No substitution syntax, no control characters, nothing that a shell or a
    /// JSON encoder would have to interpret.
    static func isPlain(_ value: String, maximum: Int = 4_096) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && !value.contains("${") && !value.contains("`")
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }

    /// The one search path a connector may be given: the system's own
    /// programs, and nothing a user or a package manager installed.
    public static let systemSearchPath = "/usr/bin:/bin"

    /// The pinned extensions that run `osascript` by its bare name through
    /// node's `execFile`, and so need `systemSearchPath`: Apple Notes and
    /// Control Chrome.
    static func runsBareOsascript(_ role: ClaudeTextConnectorRole) -> Bool {
        role == .appleNotes || role == .chromeControl
    }

    /// Deliberately short. `CHROME_PATH` is not here: the 1.8.0 server never
    /// reads it, and Chrome is chosen by the `executablePath` option. The two
    /// Chrome DevTools variables are containment, not courtesy — without the
    /// usage-statistics one the server spawns a telemetry watchdog into its own
    /// process group, where a `kill(-pid)` can never reach it.
    static let environmentKeys: Set<String> = [
        "HOME", "TMPDIR", "LANG",
        // The search path, for the one server that runs a program by its bare
        // name: the Apple Notes and Control Chrome extensions run `osascript`
        // through node's `execFile`, and they are pinned, so they cannot be told
        // an absolute path. Only those roles may carry it, and only as
        // `systemSearchPath`.
        "PATH",
        "CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS", "CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS",
        "DO_NOT_TRACK", "NO_UPDATE_NOTIFIER",
        // The mail reader's own documented home override. Its `~` is already
        // app-owned by inheritance — the CLI child runs with `HOME` set to the
        // app profile — but the reader writes templates, drafts and IMAP
        // overrides under that home, so naming it here states the assumption
        // instead of resting on it.
        "APPLE_MAIL_MCP_HOME",
        // The app's own name, so the sender's permission hint names the app the
        // user will actually find in System Settings rather than a guess.
        "OPENBOTS_APP_NAME",
        // Which Contacts the reader drives, resolved on the Swift side so the
        // row's badge and the launch cannot disagree about which copy is meant.
        "OPENBOTS_CONTACTS_APP",
        // The absolute path to the calendar reader the bundle carries, resolved
        // on the Swift side for the same reason. A key that is NOT on this list
        // throws `invalidServer` at init — which fails only in the app, never
        // in a test that builds the server by hand — so the calendar row could
        // not launch at all without this line.
        "OPENBOTS_CALENDAR_HELPER",
        // The Google MCP server gets only a non-secret client identifier, a
        // closed service selector, and the same-bundle helper path. OAuth
        // tokens never enter this environment or the transient MCP file.
        "OPENBOTS_GOOGLE_CLIENT_ID", "OPENBOTS_GOOGLE_HELPER", "OPENBOTS_GOOGLE_SERVICE",
        // A short-lived signed proof bound to the issuing app process, the
        // current Google connection and one service. It contains no provider
        // token and is usable only by a helper whose ancestor chain includes
        // that still-running app process.
        "OPENBOTS_GOOGLE_CAPABILITY",
        // Where the user's Messages history is, and which Messages to start hidden,
        // both resolved on the Swift side. The CLI child's HOME is the app
        // profile, so the server cannot build the database path itself; and
        // like the calendar key above, a key missing here throws at init in
        // the app and in no test that builds the server by hand.
        "OPENBOTS_MESSAGES_DB", "OPENBOTS_MESSAGES_APP",
        // The chats the bot may read, as a JSON array in base64
        // (`AppleMessagesChatScope.environmentValue`), always plain.
        AppleMessagesChatScope.environmentKey,
        // Control this Mac (Peekaboo 4.0.0), each read in its own source at the
        // v4.0.0 tag. PEEKABOO_NO_REMOTE: the command
        // runtime never looks for a bridge host, so no other app's permissions
        // are borrowed (RuntimeHostResolver.swift). PEEKABOO_ALLOW_TOOLS: only
        // the reviewed tools are exposed (ToolFiltering.swift), which is what
        // keeps the agent tool out of `mcp serve`. PEEKABOO_DISABLE_AGENT: "1"
        // or "true" refuses the `peekaboo agent` command (AgentCommand.swift);
        // nothing showed it read on the `mcp serve` path. PEEKABOO_DISABLE_MCP_
        // AUTOCONNECT: Tachikoma's auto-connect policy turns off only on the
        // exact value "true"; whether `mcp serve` would auto-connect at all was
        // not traced. PEEKABOO_CONFIG_DIR: the config folder, where credentials
        // would live, inside the turn's own folder (ConfigurationManager.swift).
        // Its bridge socket, forced auto-connect and visualizer switches stay
        // unspellable.
        "PEEKABOO_NO_REMOTE", "PEEKABOO_DISABLE_AGENT", "PEEKABOO_DISABLE_MCP_AUTOCONNECT",
        "PEEKABOO_ALLOW_TOOLS", "PEEKABOO_CONFIG_DIR",
        // Where Foundation finds the home: HOME is ignored in favour of the
        // account's own record, and only this moves homeDirectoryForCurrentUser,
        // NSHomeDirectory and `~` expansion. Peekaboo
        // keeps a copy of every screenshot under that home's .peekaboo.
        "CFFIXED_USER_HOME",
        // Peekaboo copies ~/.config/peekaboo/config.json into its config folder
        // on start and prints a line about it on stdout, the MCP channel.
        "PEEKABOO_CONFIG_DISABLE_MIGRATION",
    ]
}


/// Which connector a selected server is, in the app's own terms. It decides
/// what the approval card says and which reads may be quiet, so a server the
/// app has no words for gets the careful treatment rather than the browser's.
// `CaseIterable` so a test can be exhaustive over the roles rather than over a
// list somebody has to remember to extend — which is exactly what went wrong
// when Contacts shipped and gained no fencing assertion.
public enum ClaudeTextConnectorRole: String, CaseIterable, Equatable, Sendable {
    case browser
    case appleMailRead
    /// The app's own sender: two verbs, Mail only, and every send named by its
    /// account. Its answers are the app's own words, so it is not fenced.
    case appleMailSend
    /// The app's own reader for Contacts.app: search a person, read a card, and
    /// no verb that could write one. It hands back what is written on the
    /// user's cards, so it is fenced like any other reader.
    case appleContactsRead
    /// The app's own reader for Calendar: list the calendars, read a window of
    /// time, read one event. No verb that could write one.
    ///
    /// Unlike the other three it sends no Apple Events — it reads through
    /// EventKit, in a small binary the bundle carries, because Apple Events
    /// cannot expand a recurring series at all and so miss most of a year's
    /// occurrences. An invitation's title and notes are written by whoever sent
    /// it, so it is fenced like any other reader.
    case appleCalendarRead
    /// Read/search Gmail plus creation of drafts. Google's compose scope is
    /// broader than the product surface, so the helper's closed endpoints and
    /// this role's policy are the enforcement boundary: no send tool exists on
    /// this role; sending is `googleGmailSend`.
    case googleGmailReadDraft
    /// Sending from the OpenBots Gmail account: its own
    /// row and switch, apart from reading and drafting, as Apple Mail's send is.
    /// Two tools: which account sends, and one send, each on a card with the
    /// whole message, bound to the exact bytes by a one-use approval.
    case googleGmailSend
    /// Calendar-list and event reads using Google's two narrow read-only
    /// scopes. No write scope or write tool exists.
    case googleCalendarRead
    /// Search, folder listing and file reads in the OpenBots account's Drive,
    /// under `drive.readonly`, which can write nothing. A file's name and its
    /// words are whoever wrote them, so it is fenced like any other reader.
    case googleDriveRead
    /// The app's own Messages server, ported from the old app: read the
    /// user's conversations, check which service reaches a person, and send a
    /// text from the user's own number — every send on a card showing the recipient, the
    /// service and the exact words. What it reads back was written by other
    /// people, so it is fenced like any other reader.
    case appleMessages
    /// Control this Mac: the old app's Peekaboo connector, carried over as a
    /// trial. It sees the screen and clicks and types in the user's apps; what
    /// it sees was written by anyone, so it is fenced,
    /// and taking control is asked once per reply.
    case macControl
    /// Apple Notes, through the Claude Desktop extension Anthropic ships: list
    /// notes, read one, add one, replace one's text. The first extension reviewed and
    /// pinned; its two writes ask on a card with the exact text. A note can hold
    /// anything pasted into it or shared by someone else, so it is fenced like any
    /// other reader.
    case appleNotes
    /// The user's own Chrome, through the Claude Desktop extension "Control
    /// Chrome": list tabs, read a page's words, open an address in a new tab,
    /// and close, reload or move a tab. Every call, reads included, waits on a
    /// card, and the script tool is not offered. A page is written by anyone,
    /// so it is fenced like any other reader.
    case chromeControl

    /// Whether the connector's tools hand back pictures: Control this Mac's
    /// looks at the screen and the browser's screenshots. A turn carrying one
    /// reads the CLI's picture-sized frames (`ClaudeTextOnlyStream`).
    public var handsBackPictures: Bool {
        switch self {
        case .browser, .macControl: true
        case .appleMailRead, .appleMailSend, .appleContactsRead, .appleCalendarRead, .googleGmailReadDraft,
             .googleGmailSend, .googleCalendarRead, .googleDriveRead, .appleMessages, .appleNotes, .chromeControl: false
        }
    }
}

/// The only two ways a connector server can be started. Both are absolute and
/// resolved before the launch is minted; adding a case is a reviewed decision.
///
/// There is deliberately no "run it through a package manager" case: an
/// uncached version reads as "needs setup" and the app never fetches anything.
public enum ClaudeTextConnectorProgram: Equatable, Sendable {
    /// An absolute interpreter running the server's own `.js` entry point —
    /// the browser's shape, and the shape of every server the app bundles.
    case node(interpreterURL: URL, entryPointURL: URL)
    /// A console script installed as a tool and run directly: its interpreter
    /// is its own first line, and the path is the one a tool installer wrote,
    /// resolved through its symlink. The app never installs it; when it is
    /// absent the connector's row says so.
    case installedTool(URL)
    /// A third-party server run *through* the app's own fence proxy, which is
    /// the only way one of them is ever launched: the proxy sits between the
    /// CLI and the server, wraps every tool result in the untrusted-material
    /// markers, and strips the one server-authored string the CLI would put in
    /// the system prompt. The label is what the markers name as the source.
    indirect case fenced(interpreterURL: URL, proxyURL: URL, label: String,
                         server: ClaudeTextConnectorProgram)

    /// The program the launch configuration runs.
    public var executableURL: URL {
        switch self {
        case .node(let interpreterURL, _): interpreterURL
        case .installedTool(let url): url
        case .fenced(let interpreterURL, _, _, _): interpreterURL
        }
    }

    /// What the program needs before the connector's own options: the entry
    /// point for node, nothing for a console script that *is* the entry point.
    var leadingArguments: [String] {
        switch self {
        case .node(_, let entryPointURL): [entryPointURL.path]
        case .installedTool: []
        case .fenced(_, let proxyURL, let label, let server):
            // `node fence-proxy.js <label> <real command> [real leading args…]`,
            // and the connector's own options follow, so the server sees the
            // argument vector it would have had.
            [proxyURL.path, label, server.executableURL.path] + server.leadingArguments
        }
    }

    /// True when this program's results reach the model already wrapped.
    public var isFenced: Bool {
        if case .fenced = self { return true }
        return false
    }

    var isWellFormed: Bool {
        switch self {
        case .node(let interpreterURL, let entryPointURL):
            ClaudeTextConnectorServer.isAbsoluteFileURL(interpreterURL)
                && ClaudeTextConnectorServer.isAbsoluteFileURL(entryPointURL)
                && entryPointURL.pathExtension == "js"
        case .installedTool(let url):
            // No extension rule: a console script carries whatever name its
            // installer wrote. What makes it safe is checked before the launch
            // is minted — Services resolves the symlink and requires a regular,
            // executable file this user or root owns and no one else can write
            // to — and the name it must match is that connector's own.
            ClaudeTextConnectorServer.isAbsoluteFileURL(url)
        case .fenced(let interpreterURL, let proxyURL, let label, let server):
            // One layer only: a fence around a fence would put a second label
            // on the same material and make the markers meaningless.
            ClaudeTextConnectorServer.isAbsoluteFileURL(interpreterURL)
                && ClaudeTextConnectorServer.isAbsoluteFileURL(proxyURL)
                && proxyURL.pathExtension == "js"
                && ClaudeTextConnectorServer.isServerName(label)
                && !server.isFenced && server.isWellFormed
        }
    }
}

/// The only options a connector launch can carry. Adding a case is a reviewed
/// decision; nothing else can be spelled. Each case names the server it belongs
/// to: only the app's own preparation code builds these, never catalog data.
public enum ClaudeTextConnectorOption: Equatable, Sendable {
    /// No visible window. A visible browser is a separate feature this
    /// option does not cover.
    case headless
    /// The profile this launch owns. It is also how the app tells its own
    /// Chrome from the user's: app-launched Chrome is the Chrome whose argument
    /// vector carries this path. Chrome runs in its own process group, so the
    /// turn's group kill cannot reach it and the path is the only honest token.
    case userDataDirectory(URL)
    /// The exact Chrome to drive, so the server never has to search for one.
    case executablePath(URL)
    /// Apple Mail's reader, held to its read-only tool set by the flag its
    /// package documents: with it the server exposes its nine read tools and
    /// no send or delete tool exists to be called. The grant is what allows
    /// reading at all; this is what makes reading the only thing on offer.
    case readOnly
    /// Peekaboo's own binary started as an MCP server on stdio, never its node
    /// wrapper, which restarts a crashed server behind the turn's back.
    case mcpServe
    /// A folder this launch owns and hands the server as its home through the
    /// environment, so it adds nothing to the arguments. It is made before the
    /// launch and taken away with the turn by the same code as a browser
    /// profile; Control this Mac keeps Peekaboo's screenshot copies in it.
    case ownedHome(URL)

    var key: String {
        switch self {
        case .headless: "headless"
        case .userDataDirectory: "userDataDir"
        case .executablePath: "executablePath"
        case .readOnly: "readOnly"
        case .mcpServe: "mcpServe"
        case .ownedHome: "ownedHome"
        }
    }

    var arguments: [String] {
        switch self {
        case .headless: ["--headless"]
        case .userDataDirectory(let url): ["--userDataDir", url.path]
        case .executablePath(let url): ["--executablePath", url.path]
        case .readOnly: ["--read-only"]
        case .mcpServe: ["mcp", "serve"]
        case .ownedHome: []
        }
    }

    /// The directory this launch owns, when it declares one.
    public var ownedProfileURL: URL? {
        switch self {
        case .userDataDirectory(let url), .ownedHome(let url): url
        default: nil
        }
    }

    var isWellFormed: Bool {
        switch self {
        case .headless, .readOnly, .mcpServe: true
        case .userDataDirectory(let url), .executablePath(let url), .ownedHome(let url):
            ClaudeTextConnectorServer.isAbsoluteFileURL(url)
        }
    }
}

/// The whole connector selection a turn is launched with.
public struct ClaudeTextConnectorAccess: Equatable, Sendable {
    /// The ten app-owned servers in this build (mail read and send, Contacts,
    /// Calendar, Messages, Control this Mac, Gmail read and draft, Gmail send,
    /// Google Calendar, Google Drive), its one launchable Chrome server and the
    /// two reviewed Claude Desktop extensions (Apple Notes and Control Chrome)
    /// make thirteen, which is every role at once. Together they announce 99
    /// connector tools (Gmail send's two and Control Chrome's ten among
    /// them), within the stream's separate declared-tool bound
    /// (`ClaudeTextOnlyStream.maximumDeclaredConnectorTools`, 100). Word and
    /// PowerPoint are not offered. Keep this finite when the catalog grows: over it, the launch service hands back no
    /// connectors at all, and the per-bot switch refuses the grant that would
    /// get there.
    public static let maximumServerCount = 13

    public let servers: [ClaudeTextConnectorServer]

    /// Every namespace this turn admits, in fixed order.
    public var toolNamespaces: [String] { servers.map(\.toolNamespace) }

    /// The profile directories this turn owns and must leave nothing running
    /// in, whatever ends it.
    public var ownedProfileURLs: [URL] {
        servers.flatMap { $0.options.compactMap(\.ownedProfileURL) }
    }

    public init(servers: [ClaudeTextConnectorServer]) throws {
        guard !servers.isEmpty, servers.count <= Self.maximumServerCount,
              Set(servers.map(\.name)).count == servers.count
        else { throw ClaudeTextConnectorAccessError.invalidSelection }
        self.servers = servers.sorted { $0.name < $1.name }
    }

    /// Which connector announced this tool, when the turn admits it at all.
    public func role(forToolNamed name: String) -> ClaudeTextConnectorRole? {
        guard admitsToolName(name) else { return nil }
        return servers.first { name.hasPrefix($0.toolNamespace) }?.role
    }

    /// True when the name is one this turn's selection admits: the exact
    /// namespace of one selected server, followed by one plain tool token.
    public func admitsToolName(_ name: String) -> Bool {
        guard let namespace = toolNamespaces.first(where: name.hasPrefix) else { return false }
        let tool = String(name.dropFirst(namespace.utf8.count))
        return !tool.isEmpty && tool.utf8.count <= 64 && !tool.contains("__")
            && tool.utf8.allSatisfy { byte in
                (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                    || (byte >= 48 && byte <= 57) || byte == 95 || byte == 45
            }
    }
}

public enum ClaudeTextConnectorAccessError: Error, Equatable, Sendable {
    case invalidServer, invalidSelection
}

extension ClaudeTextConnectorRole {
    /// Whether a call of this connector reads something private of the user's:
    /// their mail, contacts, calendars, notes, Google files, texts or Chrome.
    /// After one, every web search and fetch in the session asks the user.
    /// Control this Mac reads the user's screen when it looks (and the card
    /// shows the screenshot as well); the reply service marks it only on a
    /// call that brings the screen back. The
    /// two senders only send, and the Browser connector is the web itself.
    public var readsPrivately: Bool {
        switch self {
        case .appleMailRead, .appleContactsRead, .appleCalendarRead, .googleGmailReadDraft, .googleCalendarRead,
             .googleDriveRead, .appleNotes, .appleMessages, .chromeControl, .macControl: true
        case .browser, .appleMailSend, .googleGmailSend: false
        }
    }

    /// What was read, in the user's words for a card ("your contacts"); empty
    /// for a role that reads nothing of the user's.
    public var privateReadNoun: String {
        switch self {
        case .appleMailRead: "your Mail"
        case .appleContactsRead: "your contacts"
        case .appleCalendarRead: "your calendar"
        case .googleGmailReadDraft: "your Gmail"
        case .googleCalendarRead: "your Google Calendar"
        case .googleDriveRead: "your Drive"
        case .appleNotes: "your notes"
        case .appleMessages: "your texts"
        case .chromeControl: "your Chrome"
        case .macControl: "your screen"
        case .browser, .appleMailSend, .googleGmailSend: ""
        }
    }
}
