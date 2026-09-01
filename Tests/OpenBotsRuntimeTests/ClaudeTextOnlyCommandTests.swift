import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

@Test("Text command is a fixed tool-free Sonnet invocation with no user-text argument")
func claudeTextCommandContract() throws {
    let request = try textOnlyTestRequest(text: "USER-TEXT $(touch never)", systemPrompt: "You are a teammate. ' ; $(touch never)")
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
    #expect(arguments == [
        "--print", "--input-format", "stream-json", "--output-format", "stream-json",
        "--include-partial-messages", "--replay-user-messages", "--verbose", "--safe-mode", "--restricted",
        "--no-session-persistence", "--no-chrome", "--disable-slash-commands", "--strict-mcp-config",
        "--mcp-config", "{\"mcpServers\":{}}", "--settings",
        "{\"disableAllHooks\":true,\"disableClaudeAiConnectors\":true,\"enableArtifact\":false,\"syncClaudeAiSkills\":false,\"switchModelsOnFlag\":false,\"permissions\":{\"defaultMode\":\"dontAsk\",\"deny\":[\"*\"]}}",
        "--setting-sources", "", "--permission-mode", "dontAsk", "--tools", "", "--disallowedTools", "*",
        "--model", "sonnet", "--max-turns", "1", "--session-id", request.sessionID.uuidString.lowercased(),
        "--system-prompt-file", ClaudeTextOnlyCommandBuilder.systemPromptFileURL(for: request).path])
    #expect(!arguments.contains(request.text))
    #expect(!arguments.contains(request.systemPrompt))
    for forbidden in ["--system-prompt", "--bare", "--resume", "--continue", "--add-dir", "--fallback-model", "--effort", "--fast", "--plugin-dir"] {
        #expect(!arguments.contains(forbidden))
    }
}

@Test("Text environment has no ambient credential, shell startup, model or integration inputs")
func claudeTextEnvironmentContract() throws {
    let target = try textOnlyTestRequest().target
    let environment = ClaudeTextOnlyCommandBuilder.environment(for: target)
    #expect(environment["HOME"] == target.homeDirectoryURL.path)
    #expect(environment["CLAUDE_CONFIG_DIR"] == target.profileURL.path)
    #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    #expect(environment["NETRC"] == "/dev/null")
    #expect(environment["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"] == "1")
    #expect(environment["CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING"] == "1")
    #expect(environment["CLAUDE_CODE_DISABLE_ATTACHMENTS"] == "1")
    #expect(ClaudeConnectionCommandBuilder.environment(for: target)["CLAUDE_CODE_DISABLE_ATTACHMENTS"] == nil)
    for poison in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
                   "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                   "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "BASH_ENV", "ENV", "ZDOTDIR",
                   "NODE_OPTIONS", "DYLD_INSERT_LIBRARIES", "HTTP_PROXY", "HTTPS_PROXY", "AWS_PROFILE"] {
        #expect(environment[poison] == nil)
    }
}

@Test("Text encoding preserves Unicode and injection text in exactly one correlated JSON record")
func claudeTextInputRoundTrip() throws {
    let request = try textOnlyTestRequest(text: "Quotes \" \\ newline\n𝄞 😀\u{0} $(touch never); /login")
    let data = try ClaudeTextOnlyCommandBuilder.input(for: request)
    #expect(data.filter { $0 == 10 }.count == 1)
    #expect(data.last == 10)
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(root["type"] as? String == "user")
    #expect(root["uuid"] as? String == request.messageID.uuidString.lowercased())
    #expect(root["session_id"] as? String == request.sessionID.uuidString.lowercased())
    let message = try #require(root["message"] as? [String: Any])
    #expect(message["role"] as? String == "user")
    #expect((message["content"] as? [[String: String]])?.first?["text"] == request.text)
}

@Test("Text and system-prompt limits count UTF8 bytes and reject unusable values")
func claudeTextInputLimits() throws {
    _ = try textOnlyTestRequest(text: String(repeating: "x", count: 65_536),
                               systemPrompt: String(repeating: "😀", count: 24_576))
    #expect(throws: ClaudeTextOnlyRequestError.invalidText) { try textOnlyTestRequest(text: " \n\t ") }
    #expect(throws: ClaudeTextOnlyRequestError.invalidText) { try textOnlyTestRequest(text: String(repeating: "x", count: 65_537)) }
    #expect(throws: ClaudeTextOnlyRequestError.invalidSystemPrompt) { try textOnlyTestRequest(systemPrompt: "") }
    #expect(throws: ClaudeTextOnlyRequestError.invalidSystemPrompt) { try textOnlyTestRequest(systemPrompt: "x\u{0}y") }
    #expect(throws: ClaudeTextOnlyRequestError.invalidSystemPrompt) {
        try textOnlyTestRequest(systemPrompt: String(repeating: "😀", count: 24_577))
    }
}

@Test("Reviewed model choices are passed literally without changing the tool or fallback policy",
      arguments: ClaudeTextOnlyRequest.supportedModels.sorted())
func claudeTextRequestedModelIsLiteral(_ model: String) throws {
    let request = try textOnlyTestRequest(model: model)
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
    let modelIndex = try #require(arguments.firstIndex(of: "--model"))
    #expect(arguments[modelIndex + 1] == model)
    #expect(request.model == model)
    #expect(request.expectedResolvedModel == (model == "sonnet" ? "claude-sonnet-5" : model))
    #expect(!arguments.contains("--fallback-model"))
    let settingsIndex = try #require(arguments.firstIndex(of: "--settings"))
    let settings = try #require(JSONSerialization.jsonObject(with: Data(arguments[settingsIndex + 1].utf8)) as? [String: Any])
    #expect(settings["switchModelsOnFlag"] as? Bool == false)
    #expect(settings["disableAllHooks"] as? Bool == true)
    #expect(settings["disableClaudeAiConnectors"] as? Bool == true)
}

@Test("Unknown, retired or unsafe model tokens are refused without falling back",
      arguments: ["", "opus", "claude-sonnet-retired", "sonnet[1m]", "best", "--model", "sonnet --tools Bash",
                  "claude/sonnet", "sonnet\n", "sonnet\u{0}", "$(touch never)", String(repeating: "a", count: 201)])
func claudeTextRejectsUnavailableModel(_ model: String) throws {
    #expect(throws: ClaudeTextOnlyRequestError.invalidModel) { try textOnlyTestRequest(model: model) }
}

@Test("Effort is explicit only for supported levels; Default omits the flag",
      arguments: ClaudeTextOnlyRequest.supportedModels.sorted())
func claudeTextEffortArguments(_ model: String) throws {
    let defaultRequest = try textOnlyTestRequest(model: model)
    #expect(defaultRequest.effort == nil)
    #expect(!ClaudeTextOnlyCommandBuilder.arguments(for: defaultRequest).contains("--effort"))
    for effort in ClaudeEffortPolicy.supportedValues(for: model) {
        let request = try textOnlyTestRequest(model: model, effort: effort)
        let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
        let index = try #require(arguments.firstIndex(of: "--effort"))
        #expect(arguments[index + 1] == effort)
        #expect(request.model == model && request.effort == effort)
    }
}

@Test("Incompatible and undocumented effort cannot be silently downgraded or enable dynamic workflows")
func claudeTextRejectsUnavailableEffort() throws {
    for (model, effort) in [("claude-sonnet-4-6", "xhigh"), ("claude-opus-4-6", "xhigh"),
                           ("claude-haiku-4-5-20251001", "high"), ("claude-opus-4-5-20251101", "low"),
                           ("claude-sonnet-5", "default"), ("claude-sonnet-5", "auto"),
                           ("claude-opus-5", "ultracode"), ("sonnet", "high --tools Bash")] {
        #expect(throws: ClaudeTextOnlyRequestError.invalidEffort) { try textOnlyTestRequest(model: model, effort: effort) }
    }
}

@Test("Context configuration changes only the documented model suffix or per-run budget cap",
      arguments: ClaudeTextOnlyRequest.supportedModels.sorted())
func claudeTextContextWindowArguments(_ model: String) throws {
    for context in ClaudeContextWindowPolicy.supportedValues(for: model) {
        let request = try textOnlyTestRequest(model: model, contextWindow: context)
        let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
        let index = try #require(arguments.firstIndex(of: "--model"))
        let needsSuffix = context == "long" && ["claude-opus-4-6", "claude-sonnet-4-6"].contains(model)
        #expect(arguments[index + 1] == (needsSuffix ? model + "[1m]" : model))
        #expect(request.model == model && request.contextWindow == context)
        let environment = ClaudeTextOnlyCommandBuilder.environment(for: request)
        #expect(environment["CLAUDE_CODE_DISABLE_1M_CONTEXT"] == (context == "standard" ? "1" : nil))
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["ANTHROPIC_MODEL"] == nil)
        #expect(ClaudeTextOnlyCommandBuilder.environment(for: request.target)["CLAUDE_CODE_DISABLE_1M_CONTEXT"] == nil)
    }
}

@Test("Unsupported or unknown context selections are refused without mutating the model")
func claudeTextRejectsUnavailableContext() throws {
    for (model, context) in [("claude-haiku-4-5-20251001", "long"), ("claude-opus-4-5-20251101", "long"),
                             ("claude-sonnet-4-5-20250929", "long"), ("claude-sonnet-5", "auto"),
                             ("claude-opus-5", "1m"), ("sonnet", "standard --tools Bash")] {
        #expect(throws: ClaudeTextOnlyRequestError.invalidContextWindow) {
            try textOnlyTestRequest(model: model, contextWindow: context)
        }
    }
}

@Test("Persistable execution request exactly matches selectors passed to the fresh process")
func claudeTextFrozenExecutionRequest() throws {
    for (model, effort, window) in [("sonnet", Optional<String>.none, "default"),
                                    ("claude-sonnet-5", "low", "standard"),
                                    ("claude-opus-4-6", "max", "long")] {
        let request = try textOnlyTestRequest(model: model, effort: effort, contextWindow: window)
        let frozen = request.executionRequest
        #expect(try frozen.validated() == frozen)
        #expect(frozen.sessionID == request.sessionID)
        #expect(frozen.selection == ClaudeExecutionSelection(model: model, effort: effort ?? "default", contextWindow: window))
        let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
        let modelIndex = try #require(arguments.firstIndex(of: "--model"))
        #expect(arguments[modelIndex + 1] == frozen.launchModel)
        if let effort {
            let effortIndex = try #require(arguments.firstIndex(of: "--effort"))
            #expect(arguments[effortIndex + 1] == effort)
        } else { #expect(!arguments.contains("--effort")) }
        #expect(ClaudeTextOnlyCommandBuilder.environment(for: request)["CLAUDE_CODE_DISABLE_1M_CONTEXT"]
            == (frozen.selection.contextWindow == "standard" ? "1" : nil))
        let encoded = try JSONEncoder().encode(frozen)
        #expect(try JSONDecoder().decode(ClaudeExecutionRequest.self, from: encoded) == frozen)
        let text = String(decoding: encoded, as: UTF8.self)
        for privateValue in [request.text, request.systemPrompt, request.target.profileURL.path,
                             request.target.executableURL.path, request.target.homeDirectoryURL.path] {
            #expect(!text.contains(privateValue))
        }
    }
}

func textOnlyTestRequest(target: ClaudeConnectionTarget? = nil, text: String = "Hello",
                         systemPrompt: String = "You are a text-only teammate.", model: String = "sonnet",
                         effort: String? = nil, contextWindow: String = "default") throws -> ClaudeTextOnlyRequest {
    let fallback = try ClaudeConnectionTarget(
        executableURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/claude"),
        expectedExecutableSHA256: String(repeating: "a", count: 64),
        profileURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/profile"),
        workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/work"),
        temporaryDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/temp"),
        homeDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/home"))
    return try ClaudeTextOnlyRequest(target: target ?? fallback,
        runID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
        sessionID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
        messageID: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!, text: text, systemPrompt: systemPrompt,
        model: model, effort: effort, contextWindow: contextWindow)
}

func textOnlyTestLine(_ value: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    data.append(10)
    return data
}

func textOnlyTestInit(_ request: ClaudeTextOnlyRequest, override: [String: Any] = [:]) throws -> Data {
    var value: [String: Any] = ["type": "system", "subtype": "init", "session_id": request.sessionID.uuidString,
        "tools": [], "mcp_servers": [], "plugins": [], "permissionMode": "dontAsk", "apiKeySource": "none",
        "model": request.expectedResolvedModel, "email": "must-not-be-exposed@example.invalid"]
    value.merge(override) { _, new in new }
    return try textOnlyTestLine(value)
}

func textOnlyTestResult(_ request: ClaudeTextOnlyRequest, override: [String: Any] = [:]) throws -> Data {
    var value: [String: Any] = ["type": "result", "subtype": "success", "session_id": request.sessionID.uuidString,
        "is_error": false, "result": "Hello back", "modelUsage": [request.expectedResolvedModel: [:]]]
    value.merge(override) { _, new in new }
    return try textOnlyTestLine(value)
}

func textOnlyTestDelta(_ request: ClaudeTextOnlyRequest, text: String) throws -> Data {
    try textOnlyTestLine(["type": "stream_event", "session_id": request.sessionID.uuidString,
        "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": text]]])
}

func textOnlyTestReplay(_ request: ClaudeTextOnlyRequest, stringContent: Bool = false,
                       override: [String: Any] = [:]) throws -> Data {
    let content: Any
    if stringContent { content = request.text }
    else { content = [["type": "text", "text": request.text]] }
    var value: [String: Any] = ["type": "user", "uuid": request.messageID.uuidString,
        "session_id": request.sessionID.uuidString, "parent_tool_use_id": NSNull(),
        "isReplay": true, "message": ["role": "user", "content": content]]
    value.merge(override) { _, new in new }
    return try textOnlyTestLine(value)
}

func textOnlyTestCommandLifecycle(_ request: ClaudeTextOnlyRequest, state: String,
                                  override: [String: Any] = [:]) throws -> Data {
    var value: [String: Any] = ["type": "command_lifecycle", "command_uuid": request.messageID.uuidString,
        "state": state, "uuid": UUID().uuidString, "session_id": request.sessionID.uuidString]
    value.merge(override) { _, new in new }
    return try textOnlyTestLine(value)
}
