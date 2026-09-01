import Foundation
import OpenBotsDomain

public typealias ClaudeTextOnlyDiagnosticCode = TextTurnDiagnosticCode

/// One app-authored text turn. Construction is inert; Services must freshly
/// verify the installation, Pro/Max subscription and managed-policy admission.
public struct ClaudeTextOnlyRequest: Equatable, Sendable {
    public static let maximumTextBytes = 65_536
    public static let maximumSystemPromptBytes = 98_304
    public static let maximumModelBytes = 200
    /// Reviewed first-party choices. Unknown saved values stay in storage but
    /// cannot start an unreviewed model. The legacy alias retains its exact argv.
    public static let supportedModels: Set<String> = [
        "sonnet", "claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-opus-5", "claude-fable-5",
        "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6",
        "claude-opus-4-5-20251101", "claude-sonnet-4-5-20250929"
    ]
    public let target: ClaudeConnectionTarget
    public let runID: UUID
    public let sessionID: UUID
    public let messageID: UUID
    public let text: String
    public let systemPrompt: String
    /// Frozen for this run. A later saved bot choice cannot alter these arguments.
    public let model: String
    /// Nil preserves the provider's documented default by omitting --effort.
    public let effort: String?
    /// Requested CLI configuration, never proof of the actual context capacity.
    public let contextWindow: String
    public var executionSelection: ClaudeExecutionSelection {
        ClaudeExecutionSelection(model: model, effort: effort ?? "default", contextWindow: contextWindow)
    }
    public var expectedResolvedModel: String { executionSelection.expectedResolvedModel }
    public var launchModel: String { executionSelection.launchModel }
    /// Persistable selectors only: no prompt, path, environment or account data.
    /// This is a prepared request, not evidence that the process started.
    public var executionRequest: ClaudeExecutionRequest {
        ClaudeExecutionRequest(sessionID: sessionID, selection: executionSelection, launchModel: launchModel)
    }

    public init(target: ClaudeConnectionTarget, runID: UUID, sessionID: UUID,
                messageID: UUID, text: String, systemPrompt: String, model: String = "sonnet",
                effort: String? = nil, contextWindow: String = "default") throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= Self.maximumTextBytes else { throw ClaudeTextOnlyRequestError.invalidText }
        guard !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              systemPrompt.utf8.count <= Self.maximumSystemPromptBytes,
              !systemPrompt.utf8.contains(0) else { throw ClaudeTextOnlyRequestError.invalidSystemPrompt }
        guard Self.isValidModelToken(model), Self.supportedModels.contains(model) else {
            throw ClaudeTextOnlyRequestError.invalidModel
        }
        if let effort, !ClaudeEffortPolicy.supportedValues(for: model).contains(effort) {
            throw ClaudeTextOnlyRequestError.invalidEffort
        }
        guard ClaudeContextWindowPolicy.supportedValues(for: model).contains(contextWindow) else {
            throw ClaudeTextOnlyRequestError.invalidContextWindow
        }
        self.target = target
        self.runID = runID
        self.sessionID = sessionID
        self.messageID = messageID
        self.text = text
        self.systemPrompt = systemPrompt
        self.model = model
        self.effort = effort
        self.contextWindow = contextWindow
    }

    /// Literal aliases/names only, never flags, paths, whitespace or shell syntax.
    /// Shape validation is not a claim that an account can use this model.
    static func isValidModelToken(_ value: String) -> Bool {
        let bytes = value.utf8
        func alphanumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        guard let first = bytes.first, alphanumeric(first), bytes.count <= maximumModelBytes else { return false }
        return bytes.allSatisfy { alphanumeric($0) || [45, 95, 46, 91, 93].contains($0) }
    }

    /// Only the documented long-context suffix on these exact pinned models is
    /// normalized. It establishes model identity, not accepted context capacity.
    static func normalizedReportedModel(_ value: String) -> String? {
        guard let normalized = ClaudeExecutionSelection.normalizedReportedModel(value),
              supportedModels.contains(normalized) else { return nil }
        return normalized
    }
}

public enum ClaudeTextOnlyRequestError: Error, Equatable, Sendable {
    case invalidText, invalidSystemPrompt, invalidModel, invalidEffort, invalidContextWindow
}

public enum ClaudeTextOnlyEvent: Equatable, Sendable {
    case initialized(sessionID: UUID, actualModel: String)
    /// The complete JSON record was accepted by the local pipe, not a provider acknowledgment.
    case inputSubmitted(messageID: UUID)
    /// Exact UUID, session, role and text were replayed by the official CLI.
    case inputAcknowledged(messageID: UUID)
    case textSnapshot(String)
    /// One fixed diagnostic category on failure. Never provider text or values.
    case diagnostic(ClaudeTextOnlyDiagnosticCode)
}

public struct ClaudeTextOnlyReply: Equatable, Sendable {
    public let sessionID: UUID
    /// Reported response model, falling back to init only for compatible streams
    /// without result metadata. Use confirmedActualModel for confirmation claims.
    public let actualModel: String
    public let text: String
    /// Present only when successful result.modelUsage identifies one actual model.
    /// Missing metadata in compatible inert/older streams never gains confirmation.
    public let confirmedActualModel: String?
    public init(sessionID: UUID, actualModel: String, text: String, confirmedActualModel: String? = nil) {
        self.sessionID = sessionID
        self.actualModel = actualModel
        self.text = text
        self.confirmedActualModel = confirmedActualModel
    }
}

public enum ClaudeTextOnlyFailure: String, Equatable, Sendable {
    case launchRejected, launchFailed, unsafeInitialization, invalidStream
    case inputRejected, timedOut, outputLimitExceeded, providerFailed, processFailed
}

public enum ClaudeTextOnlyResult: Equatable, Sendable {
    case success(ClaudeTextOnlyReply)
    case failed(ClaudeTextOnlyFailure)
    case cancelled
}

public protocol ClaudeTextOnlyRunning: Sendable {
    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult
}

/// A fixed command, not a caller-extensible executor. Arguments are passed
/// directly to posix_spawn; neither the prompt nor a path is shell evaluated.
public enum ClaudeTextOnlyCommandBuilder {
    public static func arguments(for request: ClaudeTextOnlyRequest) -> [String] {
        var arguments = ["--print", "--input-format", "stream-json", "--output-format", "stream-json",
         "--include-partial-messages", "--replay-user-messages", "--verbose",
         "--safe-mode", "--restricted", "--no-session-persistence", "--no-chrome",
         "--disable-slash-commands", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
         "--settings", "{\"disableAllHooks\":true,\"disableClaudeAiConnectors\":true,\"enableArtifact\":false,\"syncClaudeAiSkills\":false,\"switchModelsOnFlag\":false,\"permissions\":{\"defaultMode\":\"dontAsk\",\"deny\":[\"*\"]}}",
         "--setting-sources", "", "--permission-mode", "dontAsk", "--tools", "",
         "--disallowedTools", "*", "--model", request.launchModel, "--max-turns", "1",
         "--session-id", request.sessionID.uuidString.lowercased(),
         "--system-prompt-file", systemPromptFileURL(for: request).path]
        if let effort = request.effort { arguments += ["--effort", effort] }
        return arguments
    }

    public static func environment(for target: ClaudeConnectionTarget) -> [String: String] {
        var environment = ClaudeConnectionCommandBuilder.environment(for: target)
        environment["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"] = "1"
        environment["CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING"] = "1"
        environment["CLAUDE_CODE_DISABLE_ATTACHMENTS"] = "1"
        return environment
    }

    public static func environment(for request: ClaudeTextOnlyRequest) -> [String: String] {
        var environment = environment(for: request.target)
        if request.contextWindow == "standard" { environment["CLAUDE_CODE_DISABLE_1M_CONTEXT"] = "1" }
        return environment
    }

    /// A path only, never the prompt contents or a caller-selected filename.
    /// The native runner must exclusively create and verify this file first.
    static func systemPromptFileURL(for request: ClaudeTextOnlyRequest) -> URL {
        request.target.temporaryDirectoryURL.appendingPathComponent(
            "openbots-system-prompt-\(request.runID.uuidString.lowercased()).txt")
    }

    static func input(for request: ClaudeTextOnlyRequest) throws -> Data {
        struct Block: Encodable { let type = "text"; let text: String }
        struct Message: Encodable { let role = "user"; let content: [Block] }
        struct Envelope: Encodable {
            let type = "user"
            let uuid: String
            let session_id: String
            let message: Message
        }
        var data = try JSONEncoder().encode(Envelope(
            uuid: request.messageID.uuidString.lowercased(), session_id: request.sessionID.uuidString.lowercased(),
            message: Message(content: [Block(text: request.text)])))
        data.append(0x0a)
        return data
    }
}
