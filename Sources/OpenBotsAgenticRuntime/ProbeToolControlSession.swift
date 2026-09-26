import OpenBotsExecutionRules
import ClaudeRuntimeProbeCore
import CoreFoundation
import Foundation

public enum ProbeToolControlError: Error, Equatable, Sendable {
    case malformed, limitExceeded, wrongSession, unexpectedFrame, closed
    case unknownInput, duplicateIdentity, invalidApproval, unwrittenDecision
    /// A well-formed tool input that the granted capability does not cover
    /// (for example a fetch of a private or credentialed address).
    case forbiddenInput
}

/// Fixed protocol categories only. No provider text, account fields, IDs,
/// arguments, or message contents may enter this diagnostic.
public struct ProbeToolControlDiagnostic: Equatable, Sendable, CustomStringConvertible {
    public enum Stage: String, Sendable { case preparing, awaitingControl, awaitingInitialization, active, completed, stopped }
    public enum Frame: String, Sendable {
        case keepAlive, commandLifecycle
        case controlSuccess, controlError, systemInit, systemStatus
        case systemHookStarted, systemHookProgress, systemHookResponse, systemThinkingTokens, otherSystem
        case assistant, user, controlRequest, controlCancel, result, unknown, invalidJSON
    }
    public let stage: Stage
    public let frame: Frame
    public let error: ProbeToolControlError
    public let discriminatorDigest: String
    public var description: String { "\(stage.rawValue)/\(frame.rawValue)/\(error)/kind:\(discriminatorDigest)" }

    init(stage: Stage, data: Data, error: ProbeToolControlError) {
        self.stage = stage; self.error = error
        guard let object = try? ProbeControlJSON.object(data) else {
            frame = .invalidJSON
            discriminatorDigest = PayloadDigest.sha256(of: Data("invalid-json".utf8)).rawValue
            return
        }
        // Hash only the discriminator names, not the frame/payload. Unknown
        // future types can be matched to published protocol names without
        // logging their arbitrary strings or any account/message content.
        // A control_request carries its subtype inside "request"; naming it lets a
        // rejection distinguish a permission callback from a hook callback.
        let request = object["request"] as? [String: Any]
        let names = [object["type"] as? String ?? "",
                     object["subtype"] as? String ?? request?["subtype"] as? String ?? ""]
        discriminatorDigest = PayloadDigest.sha256(of: Data(names.joined(separator: "\u{0}").utf8)).rawValue
        switch object["type"] as? String {
        case "keep_alive": frame = .keepAlive
        case "command_lifecycle": frame = .commandLifecycle
        case "control_response":
            switch (object["response"] as? [String: Any])?["subtype"] as? String {
            case "success": frame = .controlSuccess
            case "error": frame = .controlError
            default: frame = .unknown
            }
        case "system":
            switch object["subtype"] as? String {
            case "init": frame = .systemInit
            case "status": frame = .systemStatus
            case "hook_started": frame = .systemHookStarted
            case "hook_progress": frame = .systemHookProgress
            case "hook_response": frame = .systemHookResponse
            case "thinking_tokens": frame = .systemThinkingTokens
            default: frame = .otherSystem
            }
        case "assistant": frame = .assistant
        case "user": frame = .user
        case "control_request": frame = .controlRequest
        case "control_cancel_request": frame = .controlCancel
        case "result": frame = .result
        default: frame = .unknown
        }
    }
}

public struct ProbeToolInvocation: Equatable, Sendable {
    enum Origin: Sendable { case permission, preToolHook }
    public let requestID: String
    public let toolUseID: String
    /// The exact tool the CLI named; always one of the tools the plan launched.
    public let toolName: String
    public let inputJSON: Data
    /// User input acknowledged when parsed; buffered old requests retain this
    /// binding instead of being relabeled as following a later correction.
    public let acknowledgedInputID: UUID
    /// Binds the exact tool, input and invocation; never a semantic shell classifier.
    public let payloadDigest: PayloadDigest
    let origin: Origin
}

public enum ProbeToolControlEvent: Equatable, Sendable {
    case transportMetadata
    case controlInitialized
    case initialized
    case assistantMessage
    case inputAcknowledged(UUID)
    case approvalRequired(ProbeToolInvocation)
    /// A second callback for an already decided tool use: the CLI consults its
    /// ask rule after a PreToolUse decision (or the hook after a permission
    /// decision). The decision is prepared and must be sent; never re-prompted.
    case approvalReconfirmed(String)
    case approvalCancelled(String)
    case decisionEcho
    case toolResult(String, failed: Bool)
    /// One input's turn ended successfully while a later input is recorded
    /// (queued or being replayed). The process stays active for that input.
    case turnCompleted
    case completed(failed: Bool)
}

/// Probe-only, serial state machine. It grants no filesystem/network authority
/// and launches nothing. Its owner serializes calls, sends records through
/// ProbeToolSession. Stop may independently terminate that transport during a
/// blocked write; the write then fails closed before another state operation.
/// Official-CLI compatibility and OS containment require separate live evidence.
public struct ProbeToolControlSession {
    public static let maximumInputBytes = 48_000
    private typealias Phase = ProbeToolControlDiagnostic.Stage
    private struct Input { let text: String; var written = false; var acknowledged = false }
    private struct Decision { let bytes: Data; let allowed: Bool; var written = false; var echoed = false }
    public let sessionID: UUID
    public let teammateID: TeammateID
    public let runID: RunID
    public private(set) var lastAssistantText: String?
    public private(set) var lastResultText: String?
    public private(set) var lastProviderFailureSummary: String?
    public private(set) var lastRejection: ProbeToolControlDiagnostic?
    private let role: FirstToolJobProcessRole
    /// Web tools granted at admission; the tool set below is derived from them.
    private let webCapabilities: Set<AgenticWebCapability>
    /// Exactly the tools the plan launched. Any other tool name, in an init
    /// announcement, a tool_use block or a callback, closes the connection.
    private let expectedTools: Set<String>
    private var phase = Phase.preparing
    private var initializationID: String?
    private var initializationWritten = false
    private static let hookID = "openbots-first-job-bash"
    private var inputs: [UUID: Input] = [:]
    private var lastAcknowledgedInputID: UUID?
    private var invocations: [String: ProbeToolInvocation] = [:]
    private var toolIDs: [String: String] = [:]
    private var announcedTools: [String: (tool: String, input: Data)] = [:]
    private var cancelled = Set<String>()
    private var results = Set<String>()
    private var completedTurns = 0
    private var decisions: [String: Decision] = [:]
    private var generation: UInt64
    private var receivedBytes = 0
    private let ledger: ApprovalLedger

    public init(sessionID: UUID, teammateID: TeammateID, runID: RunID,
                policyGeneration: UInt64, ledger: ApprovalLedger,
                role: FirstToolJobProcessRole = .worker,
                webCapabilities: Set<AgenticWebCapability> = []) {
        self.sessionID = sessionID; self.teammateID = teammateID; self.runID = runID
        generation = policyGeneration; self.ledger = ledger; self.role = role
        self.webCapabilities = role == .worker ? webCapabilities : []
        expectedTools = role == .worker ? Set(["Bash"] + AgenticWebCapability.toolNames(self.webCapabilities)) : []
    }

    public mutating func inputRecord(id: UUID, text: String) throws -> Data {
        // Claude may emit system/init only after receiving the first user input.
        guard phase == .active || phase == .awaitingInitialization else { throw ProbeToolControlError.closed }
        guard !text.isEmpty, text.utf8.count <= Self.maximumInputBytes, inputs.count < 8 else {
            throw ProbeToolControlError.limitExceeded
        }
        guard inputs[id] == nil else { throw ProbeToolControlError.duplicateIdentity }
        let bytes = try Self.encode(["type": "user", "uuid": id.uuidString.lowercased(),
            "session_id": sessionID.uuidString.lowercased(),
            "message": ["role": "user", "content": text]])
        guard bytes.count <= 65_536 else { throw ProbeToolControlError.limitExceeded }
        inputs[id] = Input(text: text)
        return bytes
    }

    public mutating func markInputWritten(_ id: UUID) throws {
        guard phase == .active || phase == .awaitingInitialization,
              var input = inputs[id], !input.written else {
            throw ProbeToolControlError.unknownInput
        }
        input.written = true; inputs[id] = input
    }

    /// Request a PreToolUse callback for every exposed tool invocation (Bash and
    /// each granted web tool), rather than relying only on CLI permission
    /// prompts. This configures control handling, not an OS sandbox or launch authority.
    public mutating func initializeAndSend(transport: ProbeToolSession, timeout: TimeInterval = 1) throws {
        let record = try initializationRecord(id: UUID().uuidString.lowercased())
        do {
            try transport.sendRecord(record, timeout: timeout)
            try markInitializationWritten()
        } catch { stop(); throw error }
    }

    mutating func initializationRecord(id: String) throws -> Data {
        guard phase == .preparing, Self.identifier(id) else { throw ProbeToolControlError.closed }
        initializationID = id; phase = .awaitingControl
        var entries: [[String: Any]] = []
        if role == .worker {
            entries.append(["matcher": "Bash", "hookCallbackIds": [Self.hookID]])
            for capability in AgenticWebCapability.allCases where webCapabilities.contains(capability) {
                entries.append(["matcher": capability.toolName, "hookCallbackIds": [capability.hookCallbackID]])
            }
        }
        let hooks: [String: Any] = entries.isEmpty ? [:] : ["PreToolUse": entries]
        return try Self.encode(["type": "control_request", "request_id": id,
            "request": ["subtype": "initialize", "hooks": hooks]])
    }

    mutating func markInitializationWritten() throws {
        guard phase == .awaitingControl, !initializationWritten else { throw ProbeToolControlError.unwrittenDecision }
        initializationWritten = true
    }

    public mutating func receive(_ data: Data) throws -> ProbeToolControlEvent {
        let stage = phase
        do { return try receiveChecked(data) }
        catch {
            lastRejection = ProbeToolControlDiagnostic(stage: stage, data: data,
                error: (error as? ProbeToolControlError) ?? .malformed)
            stop(); throw error
        }
    }

    private mutating func receiveChecked(_ data: Data) throws -> ProbeToolControlEvent {
        guard phase != .stopped else { throw ProbeToolControlError.closed }
        receivedBytes += data.count
        guard receivedBytes <= 2_097_152 else { throw ProbeToolControlError.limitExceeded }
        let frame = try ProbeControlJSON.object(data)
        try Self.requireMainOrigin(frame)
        if let rawSession = frame["session_id"] {
            guard let text = rawSession as? String, UUID(uuidString: text) == sessionID else {
                throw ProbeToolControlError.wrongSession
            }
        }
        let type = frame["type"] as? String
        // Raw CLI transport metadata is also handled by ClaudeTextOnlyStream.
        // It proves neither initialization nor input acknowledgement and never
        // changes the job, tool ledger, or startup deadline.
        if type == "keep_alive" {
            guard frame.count == 1 else { throw ProbeToolControlError.unexpectedFrame }
            return .transportMetadata
        }
        if type == "command_lifecycle" {
            guard let command = frame["command_uuid"] as? String,
                  let id = UUID(uuidString: command), inputs[id]?.written == true,
                  let rawSession = frame["session_id"] as? String, UUID(uuidString: rawSession) == sessionID,
                  let eventID = frame["uuid"] as? String, UUID(uuidString: eventID) != nil,
                  let state = frame["state"] as? String,
                  ["queued", "started", "completed"].contains(state) else {
                throw ProbeToolControlError.unknownInput
            }
            return .transportMetadata
        }
        if phase == .awaitingControl {
            guard initializationWritten, type == "control_response",
                  let response = frame["response"] as? [String: Any],
                  response["request_id"] as? String == initializationID,
                  response["subtype"] as? String == "success",
                  response["response"] is [String: Any] else { throw ProbeToolControlError.unexpectedFrame }
            phase = .awaitingInitialization
            return .controlInitialized
        }
        guard phase != .preparing else { throw ProbeToolControlError.unexpectedFrame }
        if type == "control_response" {
            guard let response = frame["response"] as? [String: Any],
                  let id = response["request_id"] as? String,
                  var decision = decisions[id], decision.written, !decision.echoed,
                  try Self.encode(frame) == decision.bytes else {
                throw ProbeToolControlError.unwrittenDecision
            }
            decision.echoed = true; decisions[id] = decision
            return .decisionEcho
        }
        guard phase != .completed else { throw ProbeToolControlError.closed }
        if type == "system", frame["subtype"] as? String == "status" {
            // The raw CLI can report requesting or compaction before init or
            // replay. Status cannot initialize a process or acknowledge input.
            guard Self.uuid(frame["session_id"]) == sessionID,
                  let status = frame["status"],
                  status is NSNull || ["compacting", "requesting"].contains(status as? String ?? "") else {
                throw ProbeToolControlError.unexpectedFrame
            }
            if let eventID = frame["uuid"], Self.uuid(eventID) == nil { throw ProbeToolControlError.unexpectedFrame }
            if let mode = frame["permissionMode"], mode as? String != "default" { throw ProbeToolControlError.unexpectedFrame }
            return .transportMetadata
        }
        if type == "system", frame["subtype"] as? String == "thinking_tokens" {
            // Headless turns stream a live thinking-token estimate (observed with
            // CLI 2.1.261 right after the first command approval). It is progress
            // metadata only: bounded, flat, scalar, and never a decision, tool,
            // input or output. Anything shaped otherwise closes the connection.
            guard phase == .active, Self.uuid(frame["session_id"]) == sessionID, frame.count <= 12 else {
                throw ProbeToolControlError.unexpectedFrame
            }
            for (key, value) in frame where !["type", "subtype", "session_id"].contains(key) {
                guard key.utf8.count <= 64, key.utf8.allSatisfy({ $0 == 0x5f || ($0 >= 0x61 && $0 <= 0x7a) }),
                      value is NSNull || value is NSNumber || (value as? String).flatMap(UUID.init(uuidString:)) != nil else {
                    throw ProbeToolControlError.unexpectedFrame
                }
            }
            return .transportMetadata
        }
        if type == "user", let message = frame["message"] as? [String: Any],
           let text = Self.replayText(message["content"]) {
            guard let id = Self.uuid(frame["uuid"]), var input = inputs[id],
                  input.written, !input.acknowledged,
                  Self.uuid(frame["session_id"]) == sessionID,
                  message["role"] as? String == "user",
                  text.utf8.elementsEqual(input.text.utf8) else {
                throw ProbeToolControlError.unknownInput
            }
            // The marker is optional on raw CLI output. An explicitly false,
            // numeric or null marker contradicts replay proof.
            if let marker = frame["isReplay"], Self.boolean(marker) != true { throw ProbeToolControlError.unknownInput }
            input.acknowledged = true; inputs[id] = input
            lastAcknowledgedInputID = id
            // This may precede system/init, but leaves awaitingInitialization
            // intact: a replay grants delivery proof, never tool authority.
            return .inputAcknowledged(id)
        }
        if phase == .active, type == "system", frame["subtype"] as? String == "init" {
            // The CLI re-announces its session when a later queued input starts a
            // new turn. An identical announcement
            // changes nothing; any difference in session, tools or mode closes.
            guard Self.uuid(frame["session_id"]) == sessionID,
                  Self.sameTools(frame["tools"], expectedTools),
                  (frame["mcp_servers"] as? [Any])?.isEmpty == true,
                  Self.absentOrEmpty(frame["mcp_server_errors"]),
                  (frame["plugins"] as? [Any])?.isEmpty == true,
                  Self.absentOrEmpty(frame["plugin_errors"]),
                  frame["apiKeySource"] as? String == "none",
                  frame["permissionMode"] as? String == "default" else {
                throw ProbeToolControlError.unexpectedFrame
            }
            return .transportMetadata
        }
        if phase == .awaitingInitialization {
            guard type == "system", frame["subtype"] as? String == "init",
                  Self.uuid(frame["session_id"]) == sessionID,
                  Self.sameTools(frame["tools"], expectedTools),
                  (frame["mcp_servers"] as? [Any])?.isEmpty == true,
                  Self.absentOrEmpty(frame["mcp_server_errors"]),
                  (frame["plugins"] as? [Any])?.isEmpty == true,
                  Self.absentOrEmpty(frame["plugin_errors"]),
                  frame["apiKeySource"] as? String == "none",
                  frame["permissionMode"] as? String == "default" else {
                throw ProbeToolControlError.unexpectedFrame
            }
            phase = .active
            return .initialized
        }
        if type == "rate_limit_event" {
            guard phase == .active, Self.uuid(frame["session_id"]) == sessionID,
                  let info = frame["rate_limit_info"] as? [String: Any],
                  let status = info["status"] as? String,
                  ["allowed", "allowed_warning"].contains(status) else {
                throw ProbeToolControlError.unexpectedFrame
            }
            return .transportMetadata
        }
        if type == "control_cancel_request" {
            guard let id = frame["request_id"] as? String, invocations[id] != nil,
                  decisions[id]?.written != true, cancelled.insert(id).inserted else {
                throw ProbeToolControlError.unexpectedFrame
            }
            decisions.removeValue(forKey: id)
            return .approvalCancelled(id)
        }
        if type == "control_request" {
            guard role == .worker, let acknowledgedInputID = lastAcknowledgedInputID, invocations.count < 32,
                  let id = frame["request_id"] as? String, Self.identifier(id), id != initializationID,
                  let request = frame["request"] as? [String: Any],
                  let toolID = request["tool_use_id"] as? String, Self.identifier(toolID) else {
                throw ProbeToolControlError.unexpectedFrame
            }
            try Self.requireMainOrigin(request)
            let input: [String: Any]
            let origin: ProbeToolInvocation.Origin
            let toolName: String
            switch request["subtype"] as? String {
            case "can_use_tool":
                guard let name = request["tool_name"] as? String, expectedTools.contains(name),
                      let value = request["input"] as? [String: Any] else { throw ProbeToolControlError.unexpectedFrame }
                toolName = name; input = value; origin = .permission
            case "hook_callback":
                // The callback identity names the tool before any input is read;
                // the hook's own tool_name must agree with it.
                guard let callback = request["callback_id"] as? String,
                      let name = Self.toolName(forHookCallback: callback), expectedTools.contains(name),
                      let hook = request["input"] as? [String: Any],
                      hook["hook_event_name"] as? String == "PreToolUse",
                      hook["session_id"] as? String == sessionID.uuidString.lowercased(),
                      hook["tool_name"] as? String == name,
                      hook["tool_use_id"] as? String == toolID,
                      let value = hook["tool_input"] as? [String: Any] else { throw ProbeToolControlError.unexpectedFrame }
                try Self.requireMainOrigin(hook)
                toolName = name; input = value; origin = .preToolHook
            default: throw ProbeToolControlError.unexpectedFrame
            }
            try Self.validateInput(tool: toolName, input)
            guard invocations[id] == nil else { throw ProbeToolControlError.duplicateIdentity }
            let inputJSON = try Self.encode(input)
            if let firstID = toolIDs[toolID] {
                // One tool use legitimately arrives twice under different request
                // IDs: the PreToolUse hook first, then the permission callback once
                // the ask rule is evaluated (or the reverse). Only the other origin,
                // only after the first decision was written, only with identical
                // tool and input. Anything else is a replay and closes the connection.
                guard let first = invocations[firstID], first.origin != origin,
                      let decision = decisions[firstID], decision.written,
                      !cancelled.contains(firstID) else {
                    throw ProbeToolControlError.duplicateIdentity
                }
                guard first.toolName == toolName, first.inputJSON == inputJSON else { throw ProbeToolControlError.invalidApproval }
                let invocation = ProbeToolInvocation(requestID: id, toolUseID: toolID, toolName: toolName, inputJSON: inputJSON,
                    acknowledgedInputID: first.acknowledgedInputID, payloadDigest: first.payloadDigest, origin: origin)
                invocations[id] = invocation
                _ = try prepareDecision(id, allowed: decision.allowed,
                    body: try Self.decisionBody(for: invocation, allowed: decision.allowed))
                return .approvalReconfirmed(id)
            }
            if let announced = announcedTools[toolID], announced.tool != toolName || announced.input != inputJSON {
                throw ProbeToolControlError.invalidApproval
            }
            let digest = PayloadDigest.sha256(of: try Self.encode([
                "session_id": sessionID.uuidString.lowercased(),
                "acknowledged_input_id": acknowledgedInputID.uuidString.lowercased(),
                "tool": toolName, "tool_use_id": toolID, "input": input]))
            let invocation = ProbeToolInvocation(requestID: id, toolUseID: toolID, toolName: toolName,
                inputJSON: inputJSON, acknowledgedInputID: acknowledgedInputID, payloadDigest: digest, origin: origin)
            invocations[id] = invocation; toolIDs[toolID] = id
            return .approvalRequired(invocation)
        }
        if type == "assistant" {
            guard frame["session_id"] as? String == sessionID.uuidString.lowercased(),
                  let message = frame["message"] as? [String: Any], message["role"] as? String == "assistant",
                  let content = message["content"] as? [[String: Any]], !content.isEmpty else {
                throw ProbeToolControlError.unexpectedFrame
            }
            var visibleText: [String] = []
            for unit in content {
                switch unit["type"] as? String {
                case "text":
                    guard let text = unit["text"] as? String else { throw ProbeToolControlError.malformed }
                    visibleText.append(text)
                case "thinking":
                    guard unit["thinking"] is String, unit["signature"] is String else { throw ProbeToolControlError.malformed }
                case "tool_use":
                    guard role == .worker, let id = unit["id"] as? String, Self.identifier(id),
                          let name = unit["name"] as? String, expectedTools.contains(name),
                          let input = unit["input"] as? [String: Any], announcedTools[id] == nil,
                          announcedTools.count < 32 else { throw ProbeToolControlError.unexpectedFrame }
                    try Self.validateInput(tool: name, input)
                    let bytes = try Self.encode(input)
                    if let requestID = toolIDs[id], let known = invocations[requestID],
                       known.toolName != name || known.inputJSON != bytes {
                        throw ProbeToolControlError.invalidApproval
                    }
                    announcedTools[id] = (name, bytes)
                default: throw ProbeToolControlError.unexpectedFrame
                }
            }
            lastAssistantText = visibleText.isEmpty ? nil : visibleText.joined(separator: "\n")
            return .assistantMessage
        }
        if type == "user", let message = frame["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]], content.count == 1 {
            let unit = content[0]
            guard frame["session_id"] as? String == sessionID.uuidString.lowercased(),
                  message["role"] as? String == "user", unit["type"] as? String == "tool_result",
                  let toolID = unit["tool_use_id"] as? String, let requestID = toolIDs[toolID],
                  let decision = decisions[requestID], decision.written,
                  !cancelled.contains(requestID), results.insert(toolID).inserted,
                  let failed = unit["is_error"] == nil ? false : Self.boolean(unit["is_error"]),
                  decision.allowed || failed else {
                throw ProbeToolControlError.unexpectedFrame
            }
            return .toolResult(toolID, failed: failed)
        }
        if type == "result" {
            // The CLI emits one result per user input. A result may only close
            // an acknowledged turn, and every announced tool and pending
            // invocation must be settled first. Later recorded inputs (a
            // correction sent while the worker was busy) keep the process
            // active; the CLI replays them next. A failed turn always ends it.
            let acknowledged = inputs.values.filter(\.acknowledged).count
            guard frame["session_id"] as? String == sessionID.uuidString.lowercased(),
                  acknowledged > completedTurns,
                  announcedTools.keys.allSatisfy({ toolIDs[$0] != nil }),
                  invocations.values.allSatisfy({ cancelled.contains($0.requestID) || results.contains($0.toolUseID) }),
                  let failed = Self.boolean(frame["is_error"]) else {
                throw ProbeToolControlError.unexpectedFrame
            }
            completedTurns += 1
            // The CLI may replay a queued input mid-turn (one result for both)
            // or after this result (a new turn follows). The process is done
            // only when nothing recorded is still waiting to be replayed; a
            // superseded turn may end badly and the correction is still owed.
            if inputs.values.contains(where: { !$0.acknowledged }) {
                lastResultText = failed ? nil : frame["result"] as? String
                return .turnCompleted
            }
            phase = .completed
            lastResultText = failed ? nil : frame["result"] as? String
            lastProviderFailureSummary = failed ? ProbeProviderFailureSummary.read(frame) : nil
            return .completed(failed: failed)
        }
        throw ProbeToolControlError.unexpectedFrame
    }

    /// Validation and dispatch are one serial owner operation. Callers cannot
    /// prepare an allow response, process cancellation, then accidentally send it.
    public mutating func approveAndSend(_ requestID: String, action: FrozenAction,
                                       receipt: ApprovalReceipt, currentPolicyGeneration: UInt64,
                                       now: Date, transport: ProbeToolSession, timeout: TimeInterval = 1) throws {
        let bytes = try approve(requestID, action: action, receipt: receipt,
            currentPolicyGeneration: currentPolicyGeneration, now: now)
        try dispatchDecision(requestID, bytes: bytes) { try transport.sendRecord($0, timeout: timeout) }
    }

    public mutating func denyAndSend(_ requestID: String, transport: ProbeToolSession, timeout: TimeInterval = 1) throws {
        let bytes = try deny(requestID)
        try dispatchDecision(requestID, bytes: bytes) { try transport.sendRecord($0, timeout: timeout) }
    }

    /// Send the already-made decision for a second-leg callback. It cannot
    /// send a first-leg decision; those need approve/deny with a receipt.
    public mutating func reconfirmAndSend(_ requestID: String, transport: ProbeToolSession, timeout: TimeInterval = 1) throws {
        guard let decision = decisions[requestID], !decision.written,
              let invocation = invocations[requestID], toolIDs[invocation.toolUseID] != requestID else {
            throw ProbeToolControlError.unwrittenDecision
        }
        try dispatchDecision(requestID, bytes: decision.bytes) { try transport.sendRecord($0, timeout: timeout) }
    }

    mutating func denyIfPending(_ requestID: String, transport: ProbeToolSession, timeout: TimeInterval) throws {
        guard phase == .active, !cancelled.contains(requestID), decisions[requestID] == nil,
              invocations[requestID] != nil else { return }
        try denyAndSend(requestID, transport: transport, timeout: timeout)
    }

    // Internal split seams exist for fault-injection tests only. Public callers
    // use the owned approve/deny-and-send operations above.
    mutating func approve(_ requestID: String, action: FrozenAction,
                                 receipt: ApprovalReceipt, currentPolicyGeneration: UInt64,
                                 now: Date) throws -> Data {
        let invocation = try pending(requestID, generation: currentPolicyGeneration)
        guard action.teammateID == teammateID, action.runID == runID,
              action.payloadDigest == invocation.payloadDigest else { throw ProbeToolControlError.invalidApproval }
        _ = try ledger.consume(receipt, for: action, at: now)
        return try prepareDecision(requestID, allowed: true, body: try Self.decisionBody(for: invocation, allowed: true))
    }

    mutating func deny(_ requestID: String) throws -> Data {
        let invocation = try pending(requestID, generation: generation)
        return try prepareDecision(requestID, allowed: false, body: try Self.decisionBody(for: invocation, allowed: false))
    }

    /// The response shape depends on which callback asked, never on which leg it is.
    private static func decisionBody(for invocation: ProbeToolInvocation, allowed: Bool) throws -> [String: Any] {
        if allowed {
            let input = try ProbeControlJSON.object(invocation.inputJSON)
            return invocation.origin == .preToolHook
                ? ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": input]]
                : ["behavior": "allow", "updatedInput": input]
        }
        return invocation.origin == .preToolHook
            ? ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny",
                "permissionDecisionReason": "The action was not approved."]]
            : ["behavior": "deny", "message": "The action was not approved."]
    }

    mutating func dispatchDecision(_ requestID: String, bytes: Data,
                                  send: (Data) throws -> Void) throws {
        guard phase == .active, !cancelled.contains(requestID), let decision = decisions[requestID],
              !decision.written, bytes == decision.bytes else { throw ProbeToolControlError.unwrittenDecision }
        do {
            try send(bytes)
            try markDecisionWritten(requestID, bytes: bytes)
        } catch {
            stop()
            throw error
        }
    }

    mutating func markDecisionWritten(_ requestID: String, bytes: Data) throws {
        guard phase == .active, !cancelled.contains(requestID), var decision = decisions[requestID],
              !decision.written, bytes == decision.bytes else { throw ProbeToolControlError.unwrittenDecision }
        decision.written = true; decisions[requestID] = decision
    }

    /// Revocation never revives old queued decisions on regrant.
    public mutating func revoke() { generation &+= 1; stop() }
    public mutating func stop() { phase = .stopped; decisions.removeAll() }

    private func pending(_ id: String, generation current: UInt64) throws -> ProbeToolInvocation {
        guard phase == .active, current == generation, !cancelled.contains(id),
              decisions[id] == nil, let invocation = invocations[id] else {
            throw ProbeToolControlError.invalidApproval
        }
        return invocation
    }

    private mutating func prepareDecision(_ id: String, allowed: Bool, body: [String: Any]) throws -> Data {
        let bytes = try Self.encode(["type": "control_response", "response": [
            "subtype": "success", "request_id": id, "response": body]])
        decisions[id] = Decision(bytes: bytes, allowed: allowed)
        return bytes
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { $0 >= 33 && $0 <= 126 }
    }
    private static func uuid(_ value: Any?) -> UUID? {
        (value as? String).flatMap(UUID.init(uuidString:))
    }
    private static func absentOrEmpty(_ value: Any?) -> Bool {
        guard let value else { return true }
        return (value as? [Any])?.isEmpty == true
    }
    private static func replayText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]], blocks.count == 1,
              blocks[0]["type"] as? String == "text" else { return nil }
        return blocks[0]["text"] as? String
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    /// The exact launched tool set, as a list without duplicates, in any order.
    private static func sameTools(_ value: Any?, _ expected: Set<String>) -> Bool {
        guard let tools = value as? [String] else { return false }
        return tools.count == expected.count && Set(tools) == expected
    }

    private static func toolName(forHookCallback callback: String) -> String? {
        if callback == hookID { return "Bash" }
        return AgenticWebCapability(hookCallbackID: callback)?.toolName
    }

    /// Every tool's input has a fixed shape. A web input outside the granted
    /// read-only public-web boundary is `forbiddenInput`, distinct from a
    /// malformed frame, so the diagnostic names the refusal.
    private static func validateInput(tool: String, _ input: [String: Any]) throws {
        switch tool {
        case "Bash": try validateBash(input)
        case AgenticWebCapability.search.toolName: try validateWebSearch(input)
        case AgenticWebCapability.fetch.toolName: try validateWebFetch(input)
        default: throw ProbeToolControlError.unexpectedFrame
        }
    }

    private static func validateWebSearch(_ input: [String: Any]) throws {
        guard Set(input.keys).isSubset(of: ["query", "allowed_domains", "blocked_domains"]),
              let query = input["query"] as? String else { throw ProbeToolControlError.unexpectedFrame }
        do { try AgenticWebInputPolicy.validateQuery(query) } catch { throw ProbeToolControlError.forbiddenInput }
        for key in ["allowed_domains", "blocked_domains"] {
            guard let value = input[key] else { continue }
            guard let list = value as? [String] else { throw ProbeToolControlError.malformed }
            do { try AgenticWebInputPolicy.validateDomainList(list) } catch { throw ProbeToolControlError.forbiddenInput }
        }
    }

    private static func validateWebFetch(_ input: [String: Any]) throws {
        guard Set(input.keys).isSubset(of: ["url", "prompt"]),
              let url = input["url"] as? String, let prompt = input["prompt"] as? String,
              prompt.utf8.count <= 4_096 else { throw ProbeToolControlError.unexpectedFrame }
        do { try AgenticWebInputPolicy.validatedPublicURL(url) } catch { throw ProbeToolControlError.forbiddenInput }
    }

    private static func requireMainOrigin(_ object: [String: Any]) throws {
        // This single-bot session has no admitted subagent identity or lifecycle.
        // A shared session ID cannot attribute its worker traffic to the main run.
        for key in ["parent_tool_use_id", "agent_id", "agent_type"] {
            if let value = object[key], !(value is NSNull) { throw ProbeToolControlError.wrongSession }
        }
    }

    private static func validateBash(_ input: [String: Any]) throws {
        guard Set(input.keys).isSubset(of: ["command", "description", "timeout", "run_in_background"]),
              let command = input["command"] as? String, !command.isEmpty, command.utf8.count <= 8_192 else {
            throw ProbeToolControlError.unexpectedFrame
        }
        if let value = input["description"] {
            guard let text = value as? String, text.utf8.count <= 4_096 else { throw ProbeToolControlError.malformed }
        }
        if let value = input["timeout"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue >= 1, number.doubleValue <= 120_000,
                  number.doubleValue.rounded() == number.doubleValue else { throw ProbeToolControlError.malformed }
        }
        if let value = input["run_in_background"], Self.boolean(value) != false {
            // Background jobs need their own lifecycle proof; this session runs
            // foreground commands only.
            throw ProbeToolControlError.unexpectedFrame
        }
    }
}

/// Display-only data from explicit failed-result text fields. Never inspect
/// account/usage objects, stderr, or arbitrary provider fields for a reason.
/// Reject oversized/malformed details before redacting the complete accepted
/// text; clipping is the final operation, never a raw-input shortcut.
private enum ProbeProviderFailureSummary {
    private static let maximumRawBytes = 8_192
    private static let replacement = "[redacted]"

    static func read(_ frame: [String: Any]) -> String? {
        let raw: String
        if let value = frame["errors"] {
            guard let errors = value as? [String], errors.count <= 8,
                  errors.reduce(0, { $0 + $1.utf8.count }) <= maximumRawBytes else { return nil }
            let usable = errors.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !usable.isEmpty { raw = usable.joined(separator: "\n") }
            else {
                guard let result = frame["result"] as? String else { return nil }
                raw = result
            }
        } else {
            guard let result = frame["result"] as? String else { return nil }
            raw = result
        }
        guard !raw.isEmpty, raw.utf8.count <= maximumRawBytes else { return nil }
        var text = raw.precomposedStringWithCompatibilityMapping
        guard text.utf8.count <= maximumRawBytes else { return nil }
        // Ordinary multiline errors become one plain line. Other control or
        // formatting characters make the detail unusable rather than escaping
        // into terminal/UI output or splitting a credential label/value.
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format {
                guard [9, 10, 13].contains(scalar.value) else { return nil }
            }
        }
        let label = #"(?:[a-z][a-z0-9_-]*)?(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|id[_ -]?token|auth(?:orization|entication)?|oauth|bearer|token|password|passwd|secret|client[_ -]?secret|credentials?|cookies?|set[_-]?cookie|session[_ -]?(?:id|key|token))"#
        let patterns = [
            // Remove complete URLs/query-bearing tokens, not just known keys.
            #"(?i)\b[a-z][a-z0-9+.-]{1,15}://[^\s<>"']+"#,
            #"(?i)\bwww\.[^\s<>"']+"#,
            #"[^\s<>"']*[?&][^\s<>"']+"#,
            #"(?i)\bbearer\s+["']?[^\s,"';]+"#,
            #"(?i)\b(?:sk-(?:ant-|proj-)?|gh[pousr]_|xox[baprs]-|AIza)[a-z0-9_-]{4,}"#,
            #"(?i)[\p{L}\p{N}.!#$%&'*+/=?^_`{|}~-]+@[\p{L}\p{N}](?:[\p{L}\p{N}.-]*[\p{L}\p{N}])?"#,
            // Conservatively drop the rest of a credential-labelled detail,
            // including quoted, spaced or multiline values and continuations.
            #"(?is)["']?\b"# + label + #"\b["']?(?:\s*(?:[:=]|\bis\b)\s*|\s+).+"#,
            #"(?i)\b"# + label + #"\b"#,
            #"[\p{L}\p{N}_+/.=\-]{24,}"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: replacement)
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return text.count <= 512 ? text : String(text.prefix(511)) + "…"
    }
}

/// Bound shape and reject duplicate keys at every depth before Foundation picks
/// a value. Foundation still performs all JSON grammar/UTF-8 validation.
enum ProbeControlJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= 65_536 else { throw ProbeToolControlError.limitExceeded }
        struct Container { let object: Bool; var wantsKey: Bool; var keys = Set<String>() }
        let bytes = Array(data)
        var stack: [Container] = [], start: Int?, escaped = false, key = false, members = 0
        for (index, byte) in bytes.enumerated() {
            if let lower = start {
                if escaped { escaped = false; continue }
                if byte == 92 { escaped = true; continue }
                if byte == 34 {
                    if key {
                        guard index - lower <= 258, !stack.isEmpty,
                              let name = try? JSONDecoder().decode(String.self, from: Data(bytes[lower...index])),
                              stack[stack.count - 1].keys.insert(name).inserted else {
                            throw ProbeToolControlError.malformed
                        }
                        stack[stack.count - 1].wantsKey = false
                    }
                    start = nil
                }
                continue
            }
            switch byte {
            case 34: start = index; key = stack.last?.wantsKey == true
            case 123, 91:
                guard stack.count < 16 else { throw ProbeToolControlError.limitExceeded }
                stack.append(Container(object: byte == 123, wantsKey: byte == 123))
            case 125, 93:
                guard let last = stack.popLast(), last.object == (byte == 125) else {
                    throw ProbeToolControlError.malformed
                }
            case 44:
                members += 1
                guard members <= 1_024 else { throw ProbeToolControlError.limitExceeded }
                if !stack.isEmpty { stack[stack.count - 1].wantsKey = stack.last?.object == true }
            default: break
            }
        }
        guard stack.isEmpty, start == nil,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeToolControlError.malformed
        }
        return result
    }
}
