import Darwin
import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

// A bot working on the Mac: the command it is launched with, the
// questions the CLI asks over the control channel, and the transport that
// carries the answers back on the child's stdin.

private func workAccessFixture(extra: [String] = [], protected: [String] = ["/private/tmp/protected-root.noindex"]) throws -> ClaudeTextWorkAccess {
    try ClaudeTextWorkAccess(
        workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/bot-desk.noindex/Yogurt"),
        additionalDirectoryURLs: extra.map { URL(fileURLWithPath: $0) },
        protectedPaths: protected)
}

@Test("Work access refuses relative, dotted, duplicate and self-denying paths")
func workAccessShape() throws {
    _ = try workAccessFixture()
    #expect(throws: ClaudeTextWorkAccessError.self) {
        try ClaudeTextWorkAccess(workingDirectoryURL: URL(fileURLWithPath: "/"), protectedPaths: [])
    }
    #expect(throws: ClaudeTextWorkAccessError.self) {
        try ClaudeTextWorkAccess(workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/a/../b"), protectedPaths: [])
    }
    #expect(throws: ClaudeTextWorkAccessError.self) {
        try workAccessFixture(extra: ["/Users/x/Documents", "/Users/x/Documents"])
    }
    #expect(throws: ClaudeTextWorkAccessError.self) { try workAccessFixture(protected: ["relative/path"]) }
    #expect(throws: ClaudeTextWorkAccessError.self) { try workAccessFixture(protected: ["/private/tmp/bot-desk.noindex"]) }
    #expect(throws: ClaudeTextWorkAccessError.self) { try workAccessFixture(protected: ["/private/tmp/x/"]) }
}

@Test("The team's shared folder rides a work turn as its own --add-dir after the user's folders, never counted against them")
func sharedFolderRidesTheWorkTurn() throws {
    let sixteen = (1...16).map { "/Users/x/Documents/Folder \($0)" }
    let shared = URL(fileURLWithPath: "/Users/x/OpenBots Next Preview Content/Shared")
    let desk = URL(fileURLWithPath: "/private/tmp/bot-desk.noindex/Yogurt")
    let access = try ClaudeTextWorkAccess(workingDirectoryURL: desk,
        additionalDirectoryURLs: sixteen.map { URL(fileURLWithPath: $0) }, sharedDirectoryURL: shared,
        protectedPaths: ["/private/tmp/protected-root.noindex"])
    #expect(access.sharedDirectoryURL == shared)
    #expect(access.grantedDirectoryURLs.map(\.path) == sixteen + [shared.path])
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: try textOnlyTestRequest(workAccess: access))
    let folders = arguments.indices.filter { arguments[$0] == "--add-dir" }.map { arguments[$0 + 1] }
    #expect(folders == sixteen + [shared.path])
    // The shared folder is refused wherever any other folder would be.
    #expect(throws: ClaudeTextWorkAccessError.self) {
        try ClaudeTextWorkAccess(workingDirectoryURL: shared, sharedDirectoryURL: shared, protectedPaths: [])
    }
    #expect(throws: ClaudeTextWorkAccessError.self) {
        try ClaudeTextWorkAccess(workingDirectoryURL: desk, additionalDirectoryURLs: [shared], sharedDirectoryURL: shared, protectedPaths: [])
    }
    #expect(throws: ClaudeTextWorkAccessError.self) {
        try ClaudeTextWorkAccess(workingDirectoryURL: desk, sharedDirectoryURL: URL(fileURLWithPath: "/Users/x/.ssh/shared"),
                                 protectedPaths: ["/Users/x/.ssh"])
    }
    #expect(throws: ClaudeTextWorkAccessError.self) {
        try ClaudeTextWorkAccess(workingDirectoryURL: desk, sharedDirectoryURL: URL(fileURLWithPath: "/Users/x/a/../Shared"), protectedPaths: [])
    }
    // A work turn without one launches exactly as before.
    let plain = try workAccessFixture(extra: ["/Users/x/Documents/Invoices 2026"])
    #expect(plain.sharedDirectoryURL == nil && plain.grantedDirectoryURLs.map(\.path) == ["/Users/x/Documents/Invoices 2026"])
}

@Test("A bot's skills folder rides a work turn read-only: its own --add-dir last, every write tool denied there by rule, the shell by the sandbox")
func skillsFolderIsReadOnly() throws {
    let desk = URL(fileURLWithPath: "/private/tmp/bot-desk.noindex/Yogurt")
    let skills = URL(fileURLWithPath: "/Users/x/OpenBots Next Preview Content/Skills/Yogurt")
    let shared = URL(fileURLWithPath: "/Users/x/OpenBots Next Preview Content/Shared")
    let pickup = ClaudeTextWorkSkill(name: "pickup", summary: "Resume a paused project")
    let access = try ClaudeTextWorkAccess(workingDirectoryURL: desk, additionalDirectoryURLs: [URL(fileURLWithPath: "/Users/x/Documents")],
        sharedDirectoryURL: shared, skillsDirectoryURL: skills, skills: [pickup], protectedPaths: ["/private/tmp/protected-root.noindex"])
    #expect(access.grantedDirectoryURLs.map(\.path) == ["/Users/x/Documents", shared.path, skills.path])
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: try textOnlyTestRequest(workAccess: access))
    #expect(arguments.indices.filter { arguments[$0] == "--add-dir" }.map { arguments[$0 + 1] }
            == ["/Users/x/Documents", shared.path, skills.path])
    let settings = try #require(arguments.firstIndex(of: "--settings").map { arguments[$0 + 1] })
    let object = try #require(try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])
    let deny = try #require((object["permissions"] as? [String: Any])?["deny"] as? [String])
    for tool in ["Write", "Edit", "MultiEdit", "NotebookEdit"] { #expect(deny.contains("\(tool)(/\(skills.path)/**)")) }
    for tool in ["Read", "Glob", "Grep"] { #expect(!deny.contains("\(tool)(/\(skills.path)/**)")) }
    let filesystem = try #require((object["sandbox"] as? [String: Any])?["filesystem"] as? [String: Any])
    #expect((filesystem["denyWrite"] as? [String])?.contains(skills.path) == true)
    #expect((filesystem["denyRead"] as? [String])?.contains(skills.path) == false)
    // Skills need their folder; names stay plain; summaries stay one bounded line.
    #expect(throws: ClaudeTextWorkAccessError.self) {
        try ClaudeTextWorkAccess(workingDirectoryURL: desk, skills: [pickup], protectedPaths: [])
    }
    for bad in [ClaudeTextWorkSkill(name: "../pickup", summary: ""), ClaudeTextWorkSkill(name: ".hidden", summary: ""),
                ClaudeTextWorkSkill(name: "pickup", summary: "two\nlines"), ClaudeTextWorkSkill(name: "pickup", summary: String(repeating: "a", count: 301))] {
        #expect(throws: ClaudeTextWorkAccessError.self) {
            try ClaudeTextWorkAccess(workingDirectoryURL: desk, skillsDirectoryURL: skills, skills: [bad], protectedPaths: [])
        }
    }
    #expect(throws: ClaudeTextWorkAccessError.self) {
        try ClaudeTextWorkAccess(workingDirectoryURL: desk, sharedDirectoryURL: skills, skillsDirectoryURL: skills, skills: [pickup], protectedPaths: [])
    }
}

@Test("Every bot's skills stay read-only on a work turn: the whole skills root is denied to the writing tools by rule and to the shell by the sandbox, for a bot that holds no skill too")
func skillsRootIsReadOnly() throws {
    let desk = URL(fileURLWithPath: "/Users/x/OpenBots Next Preview Content/Bots/Yogurt")
    let root = URL(fileURLWithPath: "/Users/x/OpenBots Next Preview Content/Skills")
    func fence(_ access: ClaudeTextWorkAccess) throws -> (deny: [String], denyWrite: [String], denyRead: [String]) {
        let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: try textOnlyTestRequest(workAccess: access))
        let settings = try #require(arguments.firstIndex(of: "--settings").map { arguments[$0 + 1] })
        let object = try #require(try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])
        let deny = try #require((object["permissions"] as? [String: Any])?["deny"] as? [String])
        let filesystem = try #require((object["sandbox"] as? [String: Any])?["filesystem"] as? [String: Any])
        return (deny, try #require(filesystem["denyWrite"] as? [String]), try #require(filesystem["denyRead"] as? [String]))
    }
    // No skill of its own, and the whole content root added by hand: every other bot's skills sit inside it.
    let bare = try ClaudeTextWorkAccess(workingDirectoryURL: desk,
        additionalDirectoryURLs: [URL(fileURLWithPath: "/Users/x/OpenBots Next Preview Content")],
        skillsRootURL: root, protectedPaths: [])
    let expectedRules = ["Edit(//Users/x/OpenBots Next Preview Content/Skills/**)", "Write(//Users/x/OpenBots Next Preview Content/Skills/**)",
                         "MultiEdit(//Users/x/OpenBots Next Preview Content/Skills/**)", "NotebookEdit(//Users/x/OpenBots Next Preview Content/Skills/**)"]
    let bareFence = try fence(bare)
    #expect(bareFence.deny.filter { $0.contains("/Skills") }.sorted() == expectedRules.sorted())
    #expect(bareFence.denyWrite == ["/Users/x/OpenBots Next Preview Content/Skills"] && bareFence.denyRead.isEmpty)
    // With skills of its own the root still is the fence, the bot's own folder inside it.
    let pickup = ClaudeTextWorkSkill(name: "pickup", summary: "Resume a paused project")
    let holding = try ClaudeTextWorkAccess(workingDirectoryURL: desk, skillsDirectoryURL: root.appending(path: "Yogurt"),
        skills: [pickup], skillsRootURL: root, protectedPaths: [])
    let holdingFence = try fence(holding)
    #expect(holdingFence.deny.filter { $0.contains("/Skills") }.sorted() == expectedRules.sorted())
    #expect(holdingFence.denyWrite == ["/Users/x/OpenBots Next Preview Content/Skills"])
    // A skills folder outside the root, or a desk inside it, is not a work turn's shape.
    #expect(throws: ClaudeTextWorkAccessError.self) {
        try ClaudeTextWorkAccess(workingDirectoryURL: desk, skillsDirectoryURL: URL(fileURLWithPath: "/Users/x/Elsewhere/Yogurt"),
                                 skills: [pickup], skillsRootURL: root, protectedPaths: [])
    }
    #expect(throws: ClaudeTextWorkAccessError.self) {
        try ClaudeTextWorkAccess(workingDirectoryURL: root.appending(path: "Yogurt/desk"), skillsRootURL: root, protectedPaths: [])
    }
}

@Test("No path the rules or the sandbox would read as a pattern fences a work turn: a skills root, or a skills folder standing in for one, carrying ( ) [ ] { } * or ? is refused; inside a plain root a bot's odd folder name is no rule at all")
func readOnlyPathsAreRuleSafe() throws {
    let desk = URL(fileURLWithPath: "/Users/x/OpenBots Next Preview Content/Bots/Bot [EU] (draft)")
    let root = URL(fileURLWithPath: "/Users/x/OpenBots Next Preview Content/Skills")
    let odd = root.appending(path: "Bot [EU] (draft)")
    let pickup = ClaudeTextWorkSkill(name: "pickup", summary: "Resume a paused project")
    // Inside a plain root the odd name only rides as --add-dir: every rule and sandbox path names plain folders.
    let access = try ClaudeTextWorkAccess(workingDirectoryURL: desk, skillsDirectoryURL: odd, skills: [pickup],
                                          skillsRootURL: root, protectedPaths: ["/Users/x/.ssh"])
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: try textOnlyTestRequest(workAccess: access))
    #expect(arguments.indices.filter { arguments[$0] == "--add-dir" }.map { arguments[$0 + 1] } == [odd.path])
    let settings = try #require(arguments.firstIndex(of: "--settings").map { arguments[$0 + 1] })
    let object = try #require(try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])
    let deny = try #require((object["permissions"] as? [String: Any])?["deny"] as? [String])
    let filesystem = try #require((object["sandbox"] as? [String: Any])?["filesystem"] as? [String: Any])
    let patternCharacters: Set<Character> = ["(", ")", "[", "]", "{", "}", "*", "?"]
    let rulePaths = deny.filter { $0.hasSuffix("/**)") }.compactMap { rule -> String? in
        guard let open = rule.firstIndex(of: "(") else { return nil }
        return String(rule[rule.index(after: open)..<rule.index(rule.endIndex, offsetBy: -4)])
    }
    #expect(rulePaths.contains("//Users/x/OpenBots Next Preview Content/Skills") && rulePaths.contains("//Users/x/.ssh"))
    let sandboxPaths = (filesystem["denyRead"] as? [String] ?? []) + (filesystem["denyWrite"] as? [String] ?? [])
    for path in rulePaths + sandboxPaths { #expect(!path.contains(where: patternCharacters.contains), "\(path)") }
    // Without a root the skills folder would be the rule and the sandbox path itself: refused.
    for name in ["Bot [EU]", "Bot (draft)", "Bot {x}", "Bot*", "Bot?"] {
        #expect(throws: ClaudeTextWorkAccessError.self, "\(name)") {
            try ClaudeTextWorkAccess(workingDirectoryURL: desk, skillsDirectoryURL: root.appending(path: name), skills: [pickup], protectedPaths: [])
        }
    }
    #expect(throws: ClaudeTextWorkAccessError.self) {
        try ClaudeTextWorkAccess(workingDirectoryURL: desk, skillsRootURL: URL(fileURLWithPath: "/Users/x (old)/Content/Skills"), protectedPaths: [])
    }
}

@Test("A work turn is launched with Claude Code's file and shell tools, the host as its permission prompt, and the user's folders")
func workCommandContract() throws {
    let access = try workAccessFixture(extra: ["/Users/x/Documents/Invoices 2026"])
    let request = try textOnlyTestRequest(allowedTools: [.webSearch], workAccess: access)
    #expect(request.grantsWork && request.grantsTools)
    #expect(request.grantedToolNames == ["Bash", "Edit", "Glob", "Grep", "NotebookEdit", "Read", "Write", "AskUserQuestion", "Agent", "WebSearch"])
    #expect(request.expectedPermissionMode == "default")
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
    let tools = try #require(arguments.firstIndex(of: "--tools").map { arguments[$0 + 1] })
    #expect(tools == "Bash,Edit,Glob,Grep,NotebookEdit,Read,Write,AskUserQuestion,Agent,WebSearch")
    let mode = try #require(arguments.firstIndex(of: "--permission-mode").map { arguments[$0 + 1] })
    #expect(mode == "default")
    let prompt = try #require(arguments.firstIndex(of: "--permission-prompt-tool").map { arguments[$0 + 1] })
    #expect(prompt == "stdio")
    let addDir = try #require(arguments.firstIndex(of: "--add-dir").map { arguments[$0 + 1] })
    #expect(addDir == "/Users/x/Documents/Invoices 2026")
    // Only the web grant is pre-approved; every file and shell use asks.
    let allowed = try #require(arguments.firstIndex(of: "--allowedTools").map { arguments[$0 + 1] })
    #expect(allowed == "WebSearch")
    let denied = try #require(arguments.firstIndex(of: "--disallowedTools").map { arguments[$0 + 1] })
        .split(separator: ",").map(String.init)
    for name in ["mcp__*", "WebFetch", "SendMessage", "EndConversation", "MultiEdit", "LSP", "BashOutput"] {
        #expect(denied.contains(name))
    }
    for name in request.grantedToolNames { #expect(!denied.contains(name)) }
    let cap = try #require(arguments.firstIndex(of: "--max-turns").map { arguments[$0 + 1] })
    #expect(cap == "16")
    // Work now grants the explicit custom helper, which safe mode suppresses.
    #expect(!arguments.contains("--safe-mode"))
    for kept in ["--restricted", "--strict-mcp-config", "--no-session-persistence"] {
        #expect(arguments.contains(kept))
    }
    for forbidden in ["--allow-dangerously-skip-permissions", "--dangerously-skip-permissions", "--resume", "--continue"] {
        #expect(!arguments.contains(forbidden))
    }
}

@Test("A work turn's settings deny the protected roots to every file tool and to the sandboxed shell, and never auto-allow a command")
func workSettingsContract() throws {
    let access = try workAccessFixture(protected: ["/Users/x/Library/Keychains", "/Users/x/.ssh"])
    let request = try textOnlyTestRequest(allowedTools: [.webFetch], workAccess: access)
    let settings = try #require(JSONSerialization.jsonObject(
        with: Data(ClaudeTextOnlyCommandBuilder.settingsJSON(for: request).utf8)) as? [String: Any])
    #expect(settings["disableAllHooks"] as? Bool == true)
    #expect(settings["disableClaudeAiConnectors"] as? Bool == true)
    let permissions = try #require(settings["permissions"] as? [String: Any])
    #expect(permissions["defaultMode"] as? String == "default")
    #expect(permissions["allow"] as? [String] == ["WebFetch"])
    let deny = try #require(permissions["deny"] as? [String])
    // The CLI's rule grammar: `//` is a filesystem-absolute path, a single `/`
    // is relative to the project root (probed on 2.1.263: only the `//` form
    // refuses "File is in a directory that is denied by your permission settings").
    for rule in ["Read(//Users/x/Library/Keychains/**)", "Write(//Users/x/.ssh/**)", "Edit(//Users/x/.ssh/**)",
                 "Grep(//Users/x/.ssh/**)", "Glob(//Users/x/.ssh/**)",
                 "mcp__*", "WebSearch"] {
        #expect(deny.contains(rule), "missing deny rule \(rule)")
    }
    #expect(!deny.contains("Read(/Users/x/.ssh/**)"), "a single leading slash is project-relative and never matches")
    for name in request.grantedToolNames { #expect(!deny.contains(name)) }
    let sandbox = try #require(settings["sandbox"] as? [String: Any])
    #expect(sandbox["enabled"] as? Bool == true)
    #expect(sandbox["failIfUnavailable"] as? Bool == true)
    #expect(sandbox["autoAllowBashIfSandboxed"] as? Bool == false)
    #expect(sandbox["allowUnsandboxedCommands"] as? Bool == false)
    let filesystem = try #require(sandbox["filesystem"] as? [String: Any])
    #expect(filesystem["denyRead"] as? [String] == ["/Users/x/Library/Keychains", "/Users/x/.ssh"])
    #expect(filesystem["denyWrite"] as? [String] == ["/Users/x/Library/Keychains", "/Users/x/.ssh"])
}

@Test("A folder that holds a protected root is added whole, the root inside it denied by rule and by the sandbox")
func folderHoldingAProtectedRootKeepsItFenced() throws {
    let pictures = "/Users/x/Pictures", library = "/Users/x/Pictures/Photos Library.photoslibrary"
    let access = try workAccessFixture(extra: [pictures], protected: [library])
    let request = try textOnlyTestRequest(workAccess: access)
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
    #expect(arguments.indices.contains { arguments[$0] == "--add-dir" && arguments.indices.contains($0 + 1) && arguments[$0 + 1] == pictures })
    let settings = try #require(JSONSerialization.jsonObject(
        with: Data(ClaudeTextOnlyCommandBuilder.settingsJSON(for: request).utf8)) as? [String: Any])
    let deny = try #require((settings["permissions"] as? [String: Any])?["deny"] as? [String])
    for tool in ["Read", "Glob", "Grep", "Edit", "Write"] { #expect(deny.contains("\(tool)(/\(library)/**)"), "\(tool)") }
    let filesystem = try #require((settings["sandbox"] as? [String: Any])?["filesystem"] as? [String: Any])
    #expect((filesystem["denyRead"] as? [String])?.contains(library) == true)
    // A folder inside the root is still refused at the access.
    #expect(throws: ClaudeTextWorkAccessError.self) { try workAccessFixture(extra: [library + "/originals"], protected: [library]) }
}

@Test("A protected root that would break the rule grammar is refused at the access")
func protectedRootsMustSpellARule() throws {
    for bad in ["/Users/x/a(b)", "/Users/x/*", "/Users/x/why?", "/Users/x/[a]", "/Users/x/{a,b}"] {
        #expect(throws: ClaudeTextWorkAccessError.self, "\(bad)") {
            try ClaudeTextWorkAccess(workingDirectoryURL: URL(fileURLWithPath: "/Users/x/Bots/Zed"), protectedPaths: [bad])
        }
    }
    #expect(throws: Never.self) {
        try ClaudeTextWorkAccess(workingDirectoryURL: URL(fileURLWithPath: "/Users/x/Bots/Zed"), protectedPaths: ["/Users/x/Library/Group Containers"])
    }
}

@Test("A turn without work is byte-for-byte the shipped command")
func noWorkIsUnchanged() throws {
    let request = try textOnlyTestRequest(allowedTools: [.webSearch, .webFetch])
    #expect(!request.grantsWork && request.expectedPermissionMode == "dontAsk")
    #expect(request.grantedToolNames == ["WebSearch", "WebFetch"])
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
    #expect(!arguments.contains("--permission-prompt-tool") && !arguments.contains("--add-dir"))
    #expect(ClaudeTextOnlyCommandBuilder.settingsJSON(for: request).contains("\"defaultMode\":\"dontAsk\""))
}

@Test("A failed result's words are read from text or text blocks, without the CLI's error wrapper; none, none sent")
func failureReasonWords() {
    #expect(ClaudeTextOnlyStream.failureReason("<tool_use_error>File does not exist.</tool_use_error>") == "File does not exist.")
    #expect(ClaudeTextOnlyStream.failureReason([["type": "text", "text": "Exit code 2"], ["type": "image"],
                                                ["type": "text", "text": "grep: nope"]]) == "Exit code 2 grep: nope")
    #expect(ClaudeTextOnlyStream.failureReason("  \n ") == nil)
    #expect(ClaudeTextOnlyStream.failureReason(nil) == nil)
    #expect(ClaudeTextOnlyStream.failureReason(["not": "text"]) == nil)
    let long = String(repeating: "é", count: 5_000)
    let read = ClaudeTextOnlyStream.failureReason(long)
    #expect(read.map { $0.utf8.count <= ClaudeTextOnlyStream.maximumFailureReasonBytes && $0.allSatisfy { $0 == "é" } } == true)
}

@Test("A work stream reports each tool result, with whether it failed")
func workStreamReportsToolResults() throws {
    let request = try textOnlyTestRequest(workAccess: workAccessFixture())
    var stream = ClaudeTextOnlyStream(request: request)
    stream.expectControlInitialization(requestID: "init-1")
    try stream.consume(textOnlyTestLine(["type": "control_response",
        "response": ["subtype": "success", "request_id": "init-1", "response": [String: Any]()]])) { _ in }
    try stream.consume(textOnlyTestInit(request, override: ["tools": request.grantedToolNames, "permissionMode": "default"])) { _ in }
    try stream.consume(textOnlyTestReplay(request)) { _ in }
    try stream.consume(textOnlyTestLine(["type": "assistant", "session_id": request.sessionID.uuidString,
        "message": ["role": "assistant", "model": request.expectedResolvedModel,
                    "content": [["type": "tool_use", "id": "toolu_1", "name": "Read", "input": ["file_path": "notes.md"]],
                                ["type": "tool_use", "id": "toolu_2", "name": "Bash", "input": ["command": "ls"]]]]])) { _ in }
    var events: [ClaudeTextOnlyEvent] = []
    try stream.consume(textOnlyTestLine(["type": "user", "session_id": request.sessionID.uuidString, "uuid": UUID().uuidString,
        "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "toolu_1", "content": "tea", "is_error": false],
            ["type": "tool_result", "tool_use_id": "toolu_2", "content": "Exit code 1", "is_error": true]]]])) { events.append($0) }
    // A failed result's words come just before it, for the record.
    #expect(events == [.toolFinished(toolUseID: "toolu_1", failed: false),
                       .toolFailureReason(toolUseID: "toolu_2", reason: "Exit code 1"),
                       .toolFinished(toolUseID: "toolu_2", failed: true)])
    // A flag the stream cannot read as a boolean is not proof the call ran: the frame is refused.
    #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .replayDuplicate)) {
        try stream.consume(textOnlyTestLine(["type": "user", "session_id": request.sessionID.uuidString, "uuid": UUID().uuidString,
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "x", "is_error": "yes"]]]])) { _ in }
    }
}

@Test("A rule refusal is a frame the work stream admits: the call it names is refused and the turn goes on; elsewhere it is rejected")
func workStreamAdmitsRuleRefusal() throws {
    func readyWorkStream() throws -> (ClaudeTextOnlyStream, ClaudeTextOnlyRequest) {
        let request = try textOnlyTestRequest(workAccess: workAccessFixture())
        var stream = ClaudeTextOnlyStream(request: request)
        stream.expectControlInitialization(requestID: "init-1")
        try stream.consume(textOnlyTestLine(["type": "control_response",
            "response": ["subtype": "success", "request_id": "init-1", "response": [String: Any]()]])) { _ in }
        try stream.consume(textOnlyTestInit(request, override: ["tools": request.grantedToolNames, "permissionMode": "default"])) { _ in }
        try stream.consume(textOnlyTestReplay(request)) { _ in }
        try stream.consume(textOnlyTestLine(["type": "assistant", "session_id": request.sessionID.uuidString,
            "message": ["role": "assistant", "model": request.expectedResolvedModel,
                        "content": [["type": "tool_use", "id": "toolu_1", "name": "Read", "input": ["file_path": "/Users/x/.ssh/config"]]]]])) { _ in }
        return (stream, request)
    }
    // The shape 2.1.263 sent when a protected-root rule refused a Read.
    func refusal(_ request: ClaudeTextOnlyRequest) -> [String: Any] {
        ["type": "system", "subtype": "permission_denied", "session_id": request.sessionID.uuidString,
         "uuid": UUID().uuidString, "tool_name": "Read", "tool_use_id": "toolu_1",
         "decision_reason": "Permission denied by rule Read(//Users/x/.ssh/**)", "decision_reason_type": "rules",
         "message": String(repeating: "x", count: 173), "attempt": 1, "is_error": true]
    }
    var (stream, request) = try readyWorkStream()
    var events: [ClaudeTextOnlyEvent] = []
    try stream.consume(textOnlyTestLine(refusal(request))) { events.append($0) }
    #expect(events == [.toolRefused(toolUseID: "toolu_1", toolName: "Read")])
    // Still a live turn: the result closes it normally.
    try stream.consume(textOnlyTestDelta(request, text: "Could not read it.")) { _ in }
    try stream.consume(textOnlyTestResult(request, override: ["result": "Could not read it."])) { _ in }
    #expect(stream.hasCompleted)
    // A call this turn never announced, another session, and a tool it was not launched with are each rejected.
    for (key, value) in [("tool_use_id", "toolu_9"), ("session_id", UUID().uuidString), ("tool_name", "Agent")] {
        var (fresh, freshRequest) = try readyWorkStream()
        var frame = refusal(freshRequest); frame[key] = value
        #expect(throws: ClaudeTextOnlyRejection.self, "\(key)") { try fresh.consume(textOnlyTestLine(frame)) { _ in } }
    }
    // A turn without work has no rules to be refused by: the frame is not admitted.
    let plain = try textOnlyTestRequest()
    var plainStream = ClaudeTextOnlyStream(request: plain)
    try plainStream.consume(textOnlyTestInit(plain)) { _ in }
    #expect(throws: ClaudeTextOnlyRejection.self) { try plainStream.consume(textOnlyTestLine(refusal(plain))) { _ in } }
}

@Test("The control channel: the handshake opens it, a question becomes an event with its input, a cancel withdraws it, denials end nothing")
func workStreamControlChannel() throws {
    let request = try textOnlyTestRequest(workAccess: workAccessFixture())
    var stream = ClaudeTextOnlyStream(request: request)
    stream.expectControlInitialization(requestID: "init-1")
    var events: [ClaudeTextOnlyEvent] = []
    func feed(_ data: Data) throws { try stream.consume(data) { events.append($0) } }
    try feed(textOnlyTestLine(["type": "control_response",
        "response": ["subtype": "success", "request_id": "init-1", "response": [String: Any]()]]))
    #expect(events == [.controlReady])
    #expect(stream.hasOpenControlChannel)
    try feed(textOnlyTestInit(request, override: ["tools": request.grantedToolNames, "permissionMode": "default"]))
    try feed(textOnlyTestReplay(request))
    let input: [String: Any] = ["command": "mv notes.txt Archive/notes.txt", "description": "Move the notes"]
    try feed(textOnlyTestLine(["type": "control_request", "request_id": "req-1", "session_id": request.sessionID.uuidString,
        "request": ["subtype": "can_use_tool", "tool_name": "Bash", "tool_use_id": "toolu_1", "input": input]]))
    let question = try #require(events.last.flatMap { event -> ClaudeTextPermissionRequest? in
        if case .permissionRequested(let value) = event { return value }; return nil })
    #expect(question.requestID == "req-1" && question.toolUseID == "toolu_1" && question.toolName == "Bash")
    let decoded = try #require(JSONSerialization.jsonObject(with: question.inputJSON) as? [String: String])
    #expect(decoded == ["command": "mv notes.txt Archive/notes.txt", "description": "Move the notes"])
    // The same question twice is a replay; a tool the turn was not launched with is refused.
    #expect(throws: ClaudeTextOnlyRejection.self) {
        try feed(textOnlyTestLine(["type": "control_request", "request_id": "req-1",
            "request": ["subtype": "can_use_tool", "tool_name": "Bash", "tool_use_id": "toolu_1", "input": input]]))
    }
    var fresh = ClaudeTextOnlyStream(request: request)
    fresh.expectControlInitialization(requestID: "init-2")
    var freshEvents: [ClaudeTextOnlyEvent] = []
    try fresh.consume(textOnlyTestInit(request, override: ["tools": request.grantedToolNames, "permissionMode": "default"])) { freshEvents.append($0) }
    #expect(throws: ClaudeTextOnlyRejection.self) {
        try fresh.consume(textOnlyTestLine(["type": "control_request", "request_id": "req-9",
            "request": ["subtype": "can_use_tool", "tool_name": "Agent", "tool_use_id": "toolu_9", "input": [String: Any]()]])) { freshEvents.append($0) }
    }
    // A cancel names a question that was asked.
    try feed(textOnlyTestLine(["type": "control_cancel_request", "request_id": "req-1"]))
    #expect(events.last == .permissionCancelled(requestID: "req-1"))
    // The host's own answer comes back as an echo and changes nothing.
    try feed(textOnlyTestLine(["type": "control_response",
        "response": ["subtype": "success", "request_id": "req-1", "response": ["behavior": "deny"]]]))
    // A completed tool call is announced once, with its input, for the activity line.
    try feed(textOnlyTestLine(["type": "assistant", "session_id": request.sessionID.uuidString,
        "message": ["role": "assistant", "model": request.expectedResolvedModel,
                    "content": [["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": input]]]]))
    let use = try #require(events.last.flatMap { event -> ClaudeTextToolUse? in
        if case .toolUse(let value) = event { return value }; return nil })
    #expect(use.id == "toolu_1" && use.toolName == "Bash")
    try feed(textOnlyTestLine(["type": "user", "session_id": request.sessionID.uuidString, "parent_tool_use_id": NSNull(),
        "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "denied"]]]]))
    try feed(textOnlyTestDelta(request, text: "Done."))
    try feed(textOnlyTestResult(request, override: ["result": "Done.",
        "permission_denials": [["tool_name": "Bash", "tool_use_id": "toolu_1"]]]))
    #expect(stream.hasCompleted)
    let result = stream.finish(exitCode: 0)
    guard case .success(let reply) = result else { Issue.record("work turn did not finish: \(result)"); return }
    #expect(reply.text == "Done.")
}

@Test("An ungranted turn refuses the control frames, and a permission mode that could act or plan; the CLI's forced default is not one of those")
func noWorkRefusesControlFrames() throws {
    let request = try textOnlyTestRequest()
    var stream = ClaudeTextOnlyStream(request: request)
    #expect(throws: ClaudeTextOnlyRejection.self) {
        try stream.consume(textOnlyTestLine(["type": "control_response",
            "response": ["subtype": "success", "request_id": "x", "response": [String: Any]()]])) { _ in }
    }
    var another = ClaudeTextOnlyStream(request: request)
    #expect(throws: ClaudeTextOnlyRejection.self) {
        try another.consume(textOnlyTestInit(request, override: ["permissionMode": "acceptEdits"])) { _ in }
    }
    // 2.1.272 forces "default" under the app's environment scrub; an ungranted
    // turn has no tools and a blanket deny, so that mode grants it nothing.
    var forced = ClaudeTextOnlyStream(request: request)
    var forcedEvents: [ClaudeTextOnlyEvent] = []
    try forced.consume(textOnlyTestInit(request, override: ["permissionMode": "default"])) { forcedEvents.append($0) }
    #expect(forcedEvents == [.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel)])
    // A turn that must be asked is refused a mode that would never ask.
    let work = try textOnlyTestRequest(workAccess: workAccessFixture())
    var silent = ClaudeTextOnlyStream(request: work)
    #expect(throws: ClaudeTextOnlyRejection(failure: .unsafeInitialization, code: .initializationPermissionMismatch)) {
        try silent.consume(textOnlyTestInit(work, override: ["tools": work.grantedToolNames, "permissionMode": "dontAsk"])) { _ in }
    }
}

@Test("The host's answers: an allow carries the input back, a deny carries its sentence, each question is answered once")
func controlAnswers() throws {
    let control = ClaudeTextTurnControl()
    let input = try JSONSerialization.data(withJSONObject: ["command": "ls"], options: [.sortedKeys])
    control.register(ClaudeTextPermissionRequest(requestID: "r1", toolUseID: "t1", toolName: "Bash", inputJSON: input))
    control.register(ClaudeTextPermissionRequest(requestID: "r2", toolUseID: "t2", toolName: "Write", inputJSON: input))
    #expect(control.isAwaitingDecision && control.awaitingRequestIDs == ["r1", "r2"])
    #expect(control.respond(requestID: "r1", allow: true))
    #expect(!control.respond(requestID: "r1", allow: false))
    #expect(control.respond(requestID: "r2", allow: false, reason: "Not now."))
    #expect(!control.respond(requestID: "r3", allow: true))
    #expect(!control.isAwaitingDecision)
    let frames = control.takePending()
    #expect(frames.count == 2 && control.takePending().isEmpty)
    let first = try #require(JSONSerialization.jsonObject(with: frames[0].dropLast()) as? [String: Any])
    let firstResponse = try #require((first["response"] as? [String: Any])?["response"] as? [String: Any])
    #expect(first["type"] as? String == "control_response")
    #expect((first["response"] as? [String: Any])?["request_id"] as? String == "r1")
    #expect(firstResponse["behavior"] as? String == "allow")
    #expect(firstResponse["updatedInput"] as? [String: String] == ["command": "ls"])
    let second = try #require(JSONSerialization.jsonObject(with: frames[1].dropLast()) as? [String: Any])
    let secondResponse = try #require((second["response"] as? [String: Any])?["response"] as? [String: Any])
    #expect(secondResponse["behavior"] as? String == "deny" && secondResponse["message"] as? String == "Not now.")
    // A withdrawn question can no longer be answered.
    control.register(ClaudeTextPermissionRequest(requestID: "r4", toolUseID: "t4", toolName: "Bash", inputJSON: input))
    control.withdraw(requestID: "r4")
    #expect(!control.respond(requestID: "r4", allow: true))
}

@Test("A synthetic work child gets the handshake first, then the message, asks one question on stdout and reads the host's answer on its still-open stdin")
func workProcessRoundTrip() async throws {
    let access = try workAccessFixture()
    let template = try textOnlyTestRequest(workAccess: access)
    let initFrame = try textOnlyTestInit(template, override: ["tools": template.grantedToolNames, "permissionMode": "default"])
    let question = try textOnlyTestLine(["type": "control_request", "request_id": "req-1",
        "session_id": template.sessionID.uuidString,
        "request": ["subtype": "can_use_tool", "tool_name": "Bash", "tool_use_id": "toolu_1",
                    "input": ["command": "mv a.txt b.txt"]]])
    let announcement = try textOnlyTestLine(["type": "assistant", "session_id": template.sessionID.uuidString,
        "message": ["role": "assistant", "model": template.expectedResolvedModel,
                    "content": [["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "mv a.txt b.txt"]]]]])
    let toolResult = try textOnlyTestLine(["type": "user", "session_id": template.sessionID.uuidString,
        "parent_tool_use_id": NSNull(),
        "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"]]]])
    // The child runs in the bot's own folder, which must exist; here that is
    // the fixture's work directory, so the observations land where the
    // fixture reads them.
    let fixture = try ClaudeConnectionFixture(body: """
    printf '%s\\n' "$@" > argv-observed
    IFS= read -r handshake
    printf '%s\\n' "$handshake" > handshake-observed
    case "$handshake" in *'"subtype":"initialize"'*) ;; *) exit 41 ;; esac
    request_id=$(printf '%s' "$handshake" | /usr/bin/sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
    printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\\n' "$request_id"
    IFS= read -r line
    \(try textProcessEmitWork(initFrame))
    printf '{"isReplay":true,"parent_tool_use_id":null,%s\\n' "${line#?}"
    \(try textProcessEmitWork(question))
    IFS= read -r answer
    printf '%s\\n' "$answer" > answer-observed
    case "$answer" in *'"behavior":"allow"'*) ;; *) exit 42 ;; esac
    case "$answer" in *'"request_id":"req-1"'*) ;; *) exit 43 ;; esac
    \(try textProcessEmitWork(announcement))
    \(try textProcessEmitWork(toolResult))
    \(try textProcessEmitWork(textOnlyTestDelta(template, text: "Moved it.")))
    \(try textProcessEmitWork(textOnlyTestResult(template, override: ["result": "Moved it."])))
    if IFS= read -r extra; then exit 44; fi
    """)
    defer { fixture.remove() }
    let desk = try ClaudeTextWorkAccess(workingDirectoryURL: fixture.target.workingDirectoryURL,
        additionalDirectoryURLs: [], protectedPaths: access.protectedPaths)
    let request = try textOnlyTestRequest(target: fixture.target, workAccess: desk)
    let control = ClaudeTextTurnControl()
    let events = WorkProcessEvents()
    let result = await NativeClaudeTextOnlyRunner().run(request: request, control: control) { event in
        await events.append(event)
        if case .permissionRequested(let question) = event {
            #expect(question.toolName == "Bash" && question.requestID == "req-1")
            #expect(control.isAwaitingDecision)
            control.respond(requestID: question.requestID, allow: true)
        }
    }
    #expect(result == .success(.init(sessionID: request.sessionID, actualModel: "claude-sonnet-5",
        text: "Moved it.", confirmedActualModel: "claude-sonnet-5")))
    let observed = await events.snapshot()
    #expect(observed.contains(.controlReady))
    #expect(observed.contains(.inputAcknowledged(messageID: request.messageID)))
    #expect(observed.contains { if case .permissionRequested = $0 { return true }; return false })
    #expect(observed.contains { if case .toolUse(let use) = $0 { return use.toolName == "Bash" }; return false })
    #expect(!control.isAwaitingDecision)
    let answer = try fixture.readWorkingFile("answer-observed")
    #expect(answer.contains("\"updatedInput\":{\"command\":\"mv a.txt b.txt\"}"))
    let arguments = try fixture.readWorkingFile("argv-observed")
    #expect(arguments.contains("--permission-prompt-tool\nstdio"))
    #expect(arguments.contains("--permission-mode\ndefault"))
}

@Test("A work turn handed to a runner without a channel is refused before launch")
func workWithoutChannelIsRefused() async throws {
    let request = try textOnlyTestRequest(workAccess: workAccessFixture())
    let result = await NativeClaudeTextOnlyRunner().run(request: request) { _ in }
    #expect(result == .failed(.launchRejected))
}

private func textProcessEmitWork(_ data: Data) throws -> String {
    let text = try #require(String(data: data, encoding: .utf8))
    return "/bin/cat <<'OPENBOTS_SYNTHETIC_EVENT'\n" + text + "OPENBOTS_SYNTHETIC_EVENT"
}

private actor WorkProcessEvents {
    private var values: [ClaudeTextOnlyEvent] = []
    func append(_ event: ClaudeTextOnlyEvent) { values.append(event) }
    func snapshot() -> [ClaudeTextOnlyEvent] { values }
}

@Test("A question about a tool the turn was not launched with is handed to the host to deny, not the end of the turn")
func unadmittedQuestionIsSurfacedForDenial() throws {
    // Two team legs once died on exactly this frame:
    // a sandboxed shell command tried to reach a host, and the CLI asked about
    // the pseudo-tool it uses for that, which no turn ever grants. Captured on
    // 2.1.272 with the app's own flags, values substituted.
    let request = try textOnlyTestRequest(allowedTools: [.webSearch, .webFetch], workAccess: workAccessFixture())
    var stream = ClaudeTextOnlyStream(request: request)
    stream.expectControlInitialization(requestID: "init-1")
    var events: [ClaudeTextOnlyEvent] = []
    func feed(_ data: Data) throws { try stream.consume(data) { events.append($0) } }
    try feed(textOnlyTestLine(["type": "control_response",
        "response": ["subtype": "success", "request_id": "init-1", "response": [String: Any]()]]))
    try feed(textOnlyTestInit(request, override: ["tools": request.grantedToolNames, "permissionMode": "default"]))
    try feed(textOnlyTestReplay(request))
    try feed(textOnlyTestLine(["type": "control_request", "request_id": "5ddcfc07-1eb3-4ff8-bb4d-1f39feaf3f55",
        "request": ["subtype": "can_use_tool", "tool_name": "SandboxNetworkAccess", "display_name": "SandboxNetworkAccess",
                    "description": "Allow network connection to school.example?", "input": ["host": "school.example"],
                    "permission_suggestions": [["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                                "rules": [["toolName": "WebFetch", "ruleContent": "domain:school.example"]]]],
                    "tool_use_id": "70bc856b-0ec1-43ae-b2ff-070d690c9612"]]))
    let question = try #require(events.last.flatMap { event -> ClaudeTextPermissionRequest? in
        if case .permissionRequested(let value) = event { return value }; return nil })
    #expect(question.toolName == "SandboxNetworkAccess" && !question.admitted)
    #expect(question.requestID == "5ddcfc07-1eb3-4ff8-bb4d-1f39feaf3f55" && question.toolUseID == "70bc856b-0ec1-43ae-b2ff-070d690c9612")
    #expect(try JSONSerialization.jsonObject(with: question.inputJSON) as? [String: String] == ["host": "school.example"])
    // The turn goes on: the same id is still a replay, and text still lands.
    #expect(throws: ClaudeTextOnlyRejection.self) {
        try feed(textOnlyTestLine(["type": "control_request", "request_id": "5ddcfc07-1eb3-4ff8-bb4d-1f39feaf3f55",
            "request": ["subtype": "can_use_tool", "tool_name": "SandboxNetworkAccess", "input": ["host": "school.example"],
                        "tool_use_id": "70bc856b-0ec1-43ae-b2ff-070d690c9612"]]))
    }
    try feed(textOnlyTestDelta(request, text: "Using the web tools instead."))
    #expect(events.last == .textSnapshot("Using the web tools instead."))
    // Any other built-in the turn was not launched with is surfaced the same way;
    // a name that is not a plain tool name is still the end of the turn.
    try feed(textOnlyTestLine(["type": "control_request", "request_id": "req-2",
        "request": ["subtype": "can_use_tool", "tool_name": "Skill", "tool_use_id": "toolu_2", "input": ["skill": "x"]]]))
    if case .permissionRequested(let other) = try #require(events.last) {
        #expect(other.toolName == "Skill" && !other.admitted)
    } else { Issue.record("no question for Skill") }
    #expect(throws: ClaudeTextOnlyRejection(failure: .invalidStream, code: .unexpectedEvent)) {
        try feed(textOnlyTestLine(["type": "control_request", "request_id": "req-3",
            "request": ["subtype": "can_use_tool", "tool_name": "We ird\u{0}", "tool_use_id": "toolu_3", "input": [String: Any]()]]))
    }
}

@Test("A question the turn did not admit can only be denied")
func unadmittedQuestionCanOnlyBeDenied() throws {
    let control = ClaudeTextTurnControl()
    let input = try JSONSerialization.data(withJSONObject: ["host": "school.example"], options: [.sortedKeys])
    control.register(ClaudeTextPermissionRequest(requestID: "r1", toolUseID: "t1", toolName: "SandboxNetworkAccess",
                                                 inputJSON: input, admitted: false))
    #expect(!control.respond(requestID: "r1", allow: true))
    #expect(control.isAwaitingDecision)
    #expect(control.respond(requestID: "r1", allow: false, reason: "The shell cannot reach the network."))
    let frames = control.takePending()
    #expect(frames.count == 1)
    let frame = try #require(JSONSerialization.jsonObject(with: frames[0].dropLast()) as? [String: Any])
    let response = try #require((frame["response"] as? [String: Any])?["response"] as? [String: Any])
    #expect(response["behavior"] as? String == "deny" && response["message"] as? String == "The shell cannot reach the network.")
}

@Test("Every turn's settings switch off the built-in agents-md plugin")
func everySettingsShapeDisablesAgentsMd() throws {
    // Claude Code 2.1.281 ships a built-in plugin, agents-md, that loads a
    // folder's agent instruction files where CLAUDE.md would load and
    // hooks tool calls; even with --safe-mode and no setting sources it is
    // announced in the init frame, and every turn died there as
    // initializationPluginsInvalid. Only this setting leaves it out; the init
    // check still requires no plugin.
    let shapes: [(String, ClaudeTextOnlyRequest)] = [
        ("text", try textOnlyTestRequest()),
        ("web", try textOnlyTestRequest(allowedTools: [.webSearch, .webFetch])),
        ("read", try textOnlyTestRequest(readAccess: try ClaudeTextReadAccess(
            sharedDirectoryURL: URL(fileURLWithPath: "/private/tmp/shared.noindex"), protectedPaths: []))),
        ("hire", try textOnlyTestRequest(grantsHiring: true)),
        ("work", try textOnlyTestRequest(workAccess: workAccessFixture())),
    ]
    for (name, request) in shapes {
        let data = try #require(ClaudeTextOnlyCommandBuilder.settingsJSON(for: request).data(using: .utf8))
        let settings = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let plugins = settings["enabledPlugins"] as? [String: Bool]
        #expect(plugins == ["agents-md@builtin": false], "\(name)")
    }
}
