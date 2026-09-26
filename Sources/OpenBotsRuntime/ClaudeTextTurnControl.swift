import Foundation

/// The host's answer channel for one work turn. The CLI asks, over the
/// permission channel, whether a tool use may go ahead; the app shows its card
/// and answers here; the transport writes the answer to the child's stdin.
/// One answer per question: a question the child withdrew, or one already
/// answered, is refused, so a double click can never send two answers.
public final class ClaudeTextTurnControl: @unchecked Sendable {
    private let lock = NSLock()
    /// Questions the child is waiting on, by request id, with the exact input
    /// each asked about; an allow answers with that same input.
    private var inputs: [String: Data] = [:]
    private var settled: Set<String> = []
    private var pending: [Data] = []
    private var toolNames: [String: String] = [:]
    private var toolUseIDs: [String: String] = [:]
    private var approvedHelpers: Set<String> = []
    /// Questions about tools the turn never admitted: a no is the only answer.
    private var unadmitted: Set<String> = []

    public init() {}

    /// Called by the transport when the child asks; never by the host.
    public func register(_ request: ClaudeTextPermissionRequest) {
        lock.withLock {
            guard !settled.contains(request.requestID) else { return }
            inputs[request.requestID] = request.inputJSON
            toolNames[request.requestID] = request.toolName
            toolUseIDs[request.requestID] = request.toolUseID
            if !request.admitted { unadmitted.insert(request.requestID) }
        }
    }

    /// A question the child withdrew needs no answer, and can no longer get one.
    public func withdraw(requestID: String) {
        lock.withLock {
            inputs[requestID] = nil
            settled.insert(requestID)
        }
    }

    /// The questions the child is still waiting on.
    public var awaitingRequestIDs: [String] { lock.withLock { Array(inputs.keys).sorted() } }
    /// A question, or the renewal of the rounds, waits for the host; the
    /// transport pauses its silence budget meanwhile.
    public var isAwaitingDecision: Bool {
        lock.withLock {
            if case .offered = renewal { return true }
            return !inputs.isEmpty
        }
    }

    // MARK: Renewing the rounds

    private enum RenewalState { case none, offered, decided(ClaudeTextRoundsRenewalDecision) }
    private var renewal: RenewalState = .none

    /// Called by the transport when the stream reports the rounds ran out,
    /// before the host hears of it, so an answer is never early; never by the host.
    func offerRoundsRenewal() {
        lock.withLock { renewal = .offered }
    }

    /// The host's answer to the renewal card: more rounds, or the end of the
    /// reply. False when no renewal waits or it was already answered, so a
    /// double click can never renew twice.
    /// True while a renewal waits for the host's answer. The host saves the
    /// user's answer before handing it over, since a Deny ends the turn at once.
    public var isRoundsRenewalOffered: Bool {
        lock.withLock { if case .offered = renewal { true } else { false } }
    }

    @discardableResult
    public func decideRoundsRenewal(renew: Bool) -> Bool {
        lock.withLock {
            guard case .offered = renewal else { return false }
            renewal = .decided(renew ? .renew : .end)
            return true
        }
    }

    /// The transport takes the answer once. The renewal message is not queued
    /// with the answers: the transport tells the stream its id first and only
    /// then writes it, so nothing the CLI says about it can arrive unexpected.
    func takeRoundsRenewalDecision() -> ClaudeTextRoundsRenewalDecision? {
        lock.withLock {
            guard case .decided(let decision) = renewal else { return nil }
            renewal = .none
            return decision
        }
    }

    /// A helper's output is admitted only after the host actually approved its
    /// launch. A tool announcement or a provider echo is never approval.
    func isHelperApproved(toolUseID: String) -> Bool {
        lock.withLock { approvedHelpers.contains(toolUseID) }
    }

    /// Queues the decision for the transport. False when the question is
    /// unknown, withdrawn or already answered. An allow carries the input back
    /// unchanged unless `updatedInput` says otherwise: the question tool's
    /// answers travel that way.
    @discardableResult
    public func respond(requestID: String, allow: Bool, reason: String = "The action was not approved.",
                        updatedInput: Data? = nil) -> Bool {
        lock.withLock {
            // An unadmitted question stays open until it is denied.
            if allow, unadmitted.contains(requestID) { return false }
            if allow, toolNames[requestID] == ClaudeTextHelperPolicy.toolName {
                guard updatedInput == nil, let original = inputs[requestID],
                      let input = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
                      ClaudeTextHelperPolicy.accepts(input) else { return false }
            }
            guard let input = inputs.removeValue(forKey: requestID), settled.insert(requestID).inserted,
                  let frame = Self.frame(requestID: requestID, allow: allow, input: updatedInput ?? input, reason: reason) else { return false }
            if allow, toolNames[requestID] == ClaudeTextHelperPolicy.toolName, let id = toolUseIDs[requestID] {
                approvedHelpers.insert(id)
            }
            pending.append(frame)
            return true
        }
    }

    /// The transport drains the queued answers to write them; a fake transport in a test does the same.
    public func takePending() -> [Data] {
        lock.withLock {
            let value = pending
            pending.removeAll()
            return value
        }
    }

    // MARK: The app's hire server

    /// Calls the service has not answered yet: control request id → JSON-RPC id.
    private var pendingHireCalls: [String: ClaudeTextJSONRPCID] = [:]
    /// Worker calls the service has not answered yet, kept apart from hires so
    /// neither answer can close the other tool's call.
    private var pendingWorkerCalls: [String: ClaudeTextJSONRPCID] = [:]
    /// Setup calls the service has not answered yet, kept apart too.
    private var pendingSetupCalls: [String: ClaudeTextJSONRPCID] = [:]
    /// Handoff calls the user handed the screen back for, by tool use: the only ones
    /// the server answers "handed back", whatever the CLI does ahead of asking.
    private var handedBack: Set<String> = []

    /// The user pressed Hand back on this call's card.
    public func handBackScreen(toolUseID: String) {
        lock.withLock { _ = handedBack.insert(toolUseID) }
    }

    /// One message of the app's hire server, already checked by the stream.
    /// The handshake, a notification, the tool list and anything unknown are
    /// answered here and now, before the init frame if that is when they come:
    /// the CLI waits for its server before it starts the turn. A call to the
    /// hire or worker tool is kept open and handed back, for the service to answer.
    func receiveHireServerMessage(_ message: ClaudeTextHireServerMessage,
                                  offering tools: [String] = [ClaudeTextHirePolicy.qualifiedToolName]) -> ClaudeTextAppServerCall? {
        let offersHire = tools.contains(ClaudeTextHirePolicy.qualifiedToolName)
        let offersWorker = tools.contains(ClaudeTextWorkerPolicy.qualifiedToolName)
        let offersHandoff = tools.contains(ClaudeTextScreenHandoffPolicy.qualifiedToolName)
        let offersSetup = tools.contains(ClaudeTextSelfSetupPolicy.qualifiedToolName)
        return lock.withLock { () -> ClaudeTextAppServerCall? in
            let reply: [String: Any]
            switch message.kind {
            case .initialize(let protocolVersion):
                // A handshake starts a connection, and its JSON-RPC ids start
                // again (the CLI does this on its second round). A
                // call from before it is one the CLI no longer waits for, and
                // left here it could meet a later cancellation or answer that
                // means the new connection's call with the same id.
                pendingHireCalls.removeAll()
                pendingWorkerCalls.removeAll()
                pendingSetupCalls.removeAll()
                reply = Self.result(message.id, [
                    "protocolVersion": protocolVersion ?? ClaudeTextHirePolicy.defaultProtocolVersion,
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": ClaudeTextHirePolicy.serverName, "version": ClaudeTextHirePolicy.serverVersion]
                ])
            case .toolsList:
                reply = Self.result(message.id, ["tools": (offersHire ? [ClaudeTextHirePolicy.toolDefinition] : [])
                    + (offersWorker ? [ClaudeTextWorkerPolicy.toolDefinition] : [])
                    + (offersHandoff ? [ClaudeTextScreenHandoffPolicy.toolDefinition] : [])
                    + (offersSetup ? [ClaudeTextSelfSetupPolicy.toolDefinition] : [])])
            case .notification(let cancelled):
                // A call the CLI gave up on (its timeout) gets no late answer.
                if let cancelled, let requestID = pendingHireCalls.first(where: { $0.value == cancelled })?.key {
                    pendingHireCalls[requestID] = nil
                }
                if let cancelled, let requestID = pendingWorkerCalls.first(where: { $0.value == cancelled })?.key {
                    pendingWorkerCalls[requestID] = nil
                }
                if let cancelled, let requestID = pendingSetupCalls.first(where: { $0.value == cancelled })?.key {
                    pendingSetupCalls[requestID] = nil
                }
                // What the Agent SDK's own host answers every notification with.
                reply = ["jsonrpc": "2.0", "result": [String: Any](), "id": 0]
            case .call(let name, let toolUseID, let argumentsJSON, let isOwnCall):
                // The handoff's call comes only after the app allowed it, which
                // it does when the user hands the screen back: answered here and now.
                if offersHandoff, name == ClaudeTextScreenHandoffPolicy.toolName {
                    reply = handedBack.remove(toolUseID) != nil
                        ? Self.toolResult(message.id, text: ClaudeTextScreenHandoffPolicy.handedBackResult, isError: false)
                        : Self.toolResult(message.id, text: ClaudeTextScreenHandoffPolicy.notHandedOverResult, isError: true)
                    break
                }
                if let id = message.id, offersWorker, name == ClaudeTextWorkerPolicy.toolName {
                    pendingWorkerCalls[message.requestID] = id
                    return .worker(ClaudeTextWorkerCall(requestID: message.requestID, toolUseID: toolUseID,
                                                        argumentsJSON: argumentsJSON, isOwnCall: isOwnCall))
                }
                if let id = message.id, offersSetup, name == ClaudeTextSelfSetupPolicy.toolName {
                    pendingSetupCalls[message.requestID] = id
                    return .selfSetup(ClaudeTextSelfSetupCall(requestID: message.requestID, toolUseID: toolUseID,
                                                              argumentsJSON: argumentsJSON, isOwnCall: isOwnCall))
                }
                guard let id = message.id, offersHire, name == ClaudeTextHirePolicy.toolName else {
                    let offered = tools.map { $0.replacingOccurrences(of: "mcp__\(ClaudeTextHirePolicy.serverName)__", with: "") }
                    reply = Self.toolResult(message.id, text: "No such tool: the OpenBots server has only \(offered.joined(separator: " and ")).", isError: true)
                    break
                }
                pendingHireCalls[message.requestID] = id
                return .hire(ClaudeTextHireCall(requestID: message.requestID, toolUseID: toolUseID,
                                                argumentsJSON: argumentsJSON, isOwnCall: isOwnCall))
            case .otherMethod:
                reply = ["jsonrpc": "2.0", "id": message.id?.json ?? 0,
                         "error": ["code": -32601, "message": "Method not found"]]
            }
            if let frame = Self.mcpFrame(requestID: message.requestID, reply: reply) { pending.append(frame) }
            return nil
        }
    }

    /// The service's answer to one hire call: the sentence the model reads,
    /// flagged as an error when the hire was refused. False when the call is
    /// unknown, already answered, or was given up on by the CLI.
    @discardableResult
    public func answerHire(requestID: String, text: String, refused: Bool) -> Bool {
        lock.withLock {
            guard let id = pendingHireCalls.removeValue(forKey: requestID),
                  let frame = Self.mcpFrame(requestID: requestID, reply: Self.toolResult(id, text: text, isError: refused)) else {
                return false
            }
            pending.append(frame)
            return true
        }
    }

    /// The service's answer to one worker call, as `answerHire` answers a hire.
    @discardableResult
    public func answerWorker(requestID: String, text: String, refused: Bool) -> Bool {
        lock.withLock {
            guard let id = pendingWorkerCalls.removeValue(forKey: requestID),
                  let frame = Self.mcpFrame(requestID: requestID, reply: Self.toolResult(id, text: text, isError: refused)) else {
                return false
            }
            pending.append(frame)
            return true
        }
    }

    /// The service's answer to one setup call, as `answerHire` answers a hire.
    @discardableResult
    public func answerSelfSetup(requestID: String, text: String, refused: Bool) -> Bool {
        lock.withLock {
            guard let id = pendingSetupCalls.removeValue(forKey: requestID),
                  let frame = Self.mcpFrame(requestID: requestID, reply: Self.toolResult(id, text: text, isError: refused)) else {
                return false
            }
            pending.append(frame)
            return true
        }
    }

    private static func result(_ id: ClaudeTextJSONRPCID?, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id?.json ?? 0, "result": result]
    }

    private static func toolResult(_ id: ClaudeTextJSONRPCID?, text: String, isError: Bool) -> [String: Any] {
        var body: [String: Any] = ["content": [["type": "text", "text": text]]]
        if isError { body["isError"] = true }
        return result(id, body)
    }

    /// Every server answer carries `mcp_response`: a success answer without it
    /// is silence to the CLI, which then waits for its own timeout.
    static func mcpFrame(requestID: String, reply: [String: Any]) -> Data? {
        let frame: [String: Any] = [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": requestID, "response": ["mcp_response": reply]]
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        data.append(0x0a)
        return data
    }

    /// The control_response the CLI expects: an allow carries the input back
    /// unchanged, a deny carries one plain sentence the model is shown.
    static func frame(requestID: String, allow: Bool, input: Data, reason: String) -> Data? {
        let body: [String: Any]
        if allow {
            guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return nil }
            body = ["behavior": "allow", "updatedInput": object]
        } else {
            body = ["behavior": "deny", "message": reason]
        }
        let frame: [String: Any] = [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": requestID, "response": body]
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        data.append(0x0a)
        return data
    }
}

/// What the host decided when a turn's rounds ran out.
public enum ClaudeTextRoundsRenewalDecision: Equatable, Sendable {
    /// Another allowance of rounds: one more message on the open pipe.
    case renew
    /// The reply ends here, as the turn limit, keeping what it wrote.
    case end
}

/// The renewal of a Control this Mac turn's rounds: each approval gives the
/// command's own allowance again, since the CLI counts `--max-turns` afresh for
/// every message it reads (seen on 2.1.281), with the earlier rounds still in
/// context.
public enum ClaudeTextRoundsRenewal {
    public static let rounds = ClaudeTextOnlyCommandBuilder.maximumMacControlTurns
    /// What the bot can spend on tools of those rounds: `--max-turns` counts
    /// the round that answers too, so sixty-four leaves sixty-three, the
    /// number the prompt gives (`grantedToolRounds`). The card still says
    /// "64 more rounds".
    public static let toolRounds = rounds - 1
    /// The message an approval writes. Fixed words, never the user's or the bot's.
    public static let message = "You have \(toolRounds) more rounds of tool calls on this Mac. Carry on where you left off."
}

/// A JSON-RPC id as the CLI sends one: an integer, or a string.
enum ClaudeTextJSONRPCID: Equatable, Sendable {
    case number(Int64)
    case string(String)

    var json: Any {
        switch self {
        case .number(let value): value
        case .string(let value): value
        }
    }
}

/// A call on the app's server that waits for the service's answer.
enum ClaudeTextAppServerCall: Equatable, Sendable {
    case hire(ClaudeTextHireCall)
    case worker(ClaudeTextWorkerCall)
    case selfSetup(ClaudeTextSelfSetupCall)
}

/// One `mcp_message` for the app's hire server, as the stream admitted it.
struct ClaudeTextHireServerMessage: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The CLI's `initialize`, with the protocol version it asked for when plain.
        case initialize(protocolVersion: String?)
        case toolsList
        /// A message with no id; `notifications/cancelled` names the call it gave up on.
        case notification(cancelled: ClaudeTextJSONRPCID?)
        case call(name: String, toolUseID: String, argumentsJSON: Data, isOwnCall: Bool)
        /// Any other method that expects an answer.
        case otherMethod
    }

    let requestID: String
    let id: ClaudeTextJSONRPCID?
    let kind: Kind
}
