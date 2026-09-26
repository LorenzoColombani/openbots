import CoreFoundation
import Foundation
import OpenBotsDomain
import OSLog

/// Bounded, deliberately narrow stream dialect. Unknown executable/control
/// events fail closed. Flat, correlated frames whose labels and keys identify
/// them as information-only may be ignored within a small finite budget.
/// Provider diagnostics and account fields never escape.
struct ClaudeTextOnlyStream {
    private static let logger = Logger(
        subsystem: "com.lorenzocolombani.openbotsnext.preview",
        category: "ClaudeTextOnlyStream"
    )
    static let maximumOutputBytes = 2_097_152
    static let maximumLineBytes = 524_288
    /// A turn carrying a connector that hands back pictures (Control this Mac,
    /// the browser). Claude Code 2.1.272 writes each picture twice in the frame
    /// that finishes the call, in the result's content and in `tool_use_result`,
    /// and caps a picture at 5,242,880 base64 bytes, so a line holds two of the
    /// largest with room to spare; a turn holds a line that size for every
    /// call a picture turn may make, so its call budget, not a screenshot-heavy
    /// total, is what ends a long reply. Probed: a 600×500
    /// picture came back as one 727,896-byte line. Nothing of a line is kept
    /// once it is read (its parse drains its own autorelease pool, and a
    /// picture line's buffer is reserved in one step), so the total bounds a
    /// stream, not memory.
    static let maximumPictureLineBytes = 12 * 1_048_576
    static let maximumPictureOutputBytes = (maximumGrantedToolUses + maximumMacControlCalls) * maximumPictureLineBytes
    static let maximumReplyBytes = 262_144
    /// A short metadata burst can straddle several transport stages. Thirty-two
    /// leaves room for that drift while preventing an unbounded stream of
    /// unreviewed frames from hiding the absence of terminal proof.
    static let maximumIgnoredInformationalEvents = 32
    private let request: ClaudeTextOnlyRequest
    private var pending = Data()
    /// The bytes at the front of `pending` already searched for a newline. A
    /// long frame arrives 4,096 bytes a read, and searching it again from its
    /// first byte on every read made a frame cost the square of its size (a
    /// 2 MB picture frame took 2.9 s; the largest the CLI sends, over a minute).
    private var searchedBytes = 0
    private var totalBytes = 0
    private var model: String?
    private var responseModel: String?
    private var confirmedModel: String?
    private var acknowledged = false
    private var text = ""
    private var finalText: String?
    private var completed = false
    /// Set when the model declined this turn (a `refusal` stop reason of the
    /// turn's own message, never a helper's). The turn then ends as declined
    /// rather than being refused as a broken stream.
    private var declined = false
    private(set) var ignoredInformationalEventCount = 0
    /// Thinking-token progress frames accepted this turn (CLI 2.1.261+ streams
    /// one per estimate update); bounded far above any real turn.
    private(set) var thinkingTokenFrameCount = 0
    static let maximumThinkingTokenFrames = 20_000
    /// Rule refusals a work turn may report; each names a call it announced.
    static let maximumPermissionDeniedFrames = 64
    /// Tool-use identifiers this run's own granted tool calls announced. Only
    /// these correlate a tool result or a nested frame back to a granted call;
    /// an identifier we never saw announced belongs to something else.
    private var grantedToolUseIDs: Set<String> = []
    private var toolNamesByID: [String: String] = [:]
    private var toolParentsByID: [String: String] = [:]
    private var helperRequests: [String: Data] = [:]
    private var helperAnnouncementInputs: [String: Data] = [:]
    private var replayedHelperIDs: Set<String> = []
    private var helperTaskIDs: [String: String] = [:]
    private var nestedModels: [String: String] = [:]
    private var finishedToolUseIDs: Set<String> = []
    private var helperLifecycleFrameCount = 0
    private let control: ClaudeTextTurnControl?
    private var permissionDeniedFrameCount = 0
    private(set) var grantedToolUseCount = 0
    private(set) var grantedToolResultCount = 0
    /// A bounded round trip: the distinct tool calls one granted run may make.
    /// Not the command's turn cap: one assistant round carries several calls at
    /// once (five searches in one message, then five fetches), so a research
    /// that stays well inside sixteen rounds passes sixteen calls easily. A cap
    /// of sixteen once ended a member's research leg at its seventeenth call as
    /// an invalid stream (`responseMismatch`); a five-language research
    /// captured from the CLI made seventeen calls in fifty-nine seconds. Sixty-four is a research, not a runaway; past it the
    /// run ends as the app's own limit, keeping what streamed. A turn that
    /// carries Control this Mac has more (`maximumMacControlCalls`).
    static let maximumGrantedToolUses = 64
    static let maximumToolResultBlocks = 8
    /// The answering model plus the internal helpers a granted tool may use.
    static let maximumGrantedUsageModels = 4
    /// Set when a granted run starts a further assistant message after it has
    /// already spoken. The next text delta opens a new paragraph first, so the
    /// saved reply reads as prose and every snapshot still extends the last.
    private var pendingParagraphBreak = false
    /// Heartbeats the CLI's tool executor emits every thirty seconds while a
    /// granted call runs. Thirty per call over the transport's ceiling, for a
    /// handful of calls running at once, stays far below this.
    private(set) var toolProgressFrameCount = 0
    static let maximumToolProgressFrames = 256
    /// Notices the CLI emits while it retries a request the provider failed.
    /// It retries a bounded number of times per request; a turn that needs more
    /// than this many is not one that will finish.
    private(set) var apiRetryFrameCount = 0
    static let maximumAPIRetryFrames = 32
    private var grantsTools: Bool { request.grantsTools }
    private var grantedToolNames: Set<String> { Set(request.grantedToolNames) }
    /// True for a built-in this turn was granted, or for a tool in the exact
    /// namespace of one of its selected servers.
    ///
    /// A connector's tools cannot be an exact list. Probed on 2.1.267: the
    /// server announces its whole tool set — twenty-nine for the browser — and
    /// the selection cannot narrow what is announced, only what may be called.
    /// So the turn admits by namespace here, and the deny list and the approval
    /// card decide the rest.
    /// The app server's tools are admitted by their exact names, and only on a
    /// turn offered them.
    private func admitsToolName(_ name: String) -> Bool {
        grantedToolNames.contains(name) || request.appServerToolNames.contains(name)
            || (request.connectorAccess?.admitsToolName(name) ?? false)
    }
    /// Claude Code accepts Agent in --tools but can still announce Task on
    /// its wire. These are the documented names of one helper capability,
    /// never a version gate or a grant of any other Task-prefixed tool.
    private func canonicalToolName(_ value: Any?) -> String? {
        guard let name = value as? String else { return nil }
        return request.grantsWork && name == "Task" ? ClaudeTextHelperPolicy.toolName : name
    }
    /// The control channel of a work turn: the initialize request the transport
    /// wrote, acknowledged once by its own id; then bounded questions and echoes.
    private var controlInitializationID: String?
    private var controlReady = false
    private(set) var permissionRequestCount = 0
    private var permissionRequestIDs: Set<String> = []
    private var controlEchoCount = 0
    static let maximumPermissionRequests = 64
    static let maximumControlEchoes = 64
    /// Messages the app's hire server may receive in one turn: a handshake of
    /// three, then a call and at most one cancellation for each call. Its own
    /// budget, so hiring never eats the questions' room (one probed turn alone
    /// sent nine). Every answer is echoed, so the echo bound grows by it too.
    static let maximumHireServerMessages = 64
    private var hireServerMessageCount = 0
    private var hireServerMessageIDs: Set<String> = []
    private var maximumEchoes: Int {
        Self.maximumControlEchoes + (request.carriesAppServer ? Self.maximumHireServerMessages : 0)
            + (grantsMacControl ? Self.maximumMacControlCalls : 0)
    }
    /// The further calls a turn that carries Control this Mac may make, where a
    /// look, a click and a keystroke are each a call. Every one of its calls is
    /// asked and every answer echoed, so its questions and echoes grow by the
    /// same amount: grown alone, the calls would end the reply at its
    /// sixty-fifth question as a broken stream instead, and grown without the
    /// calls, the questions and echoes change nothing (both seen live). Such a
    /// turn has sixty-four rounds
    /// (`ClaudeTextOnlyCommandBuilder.maximumMacControlTurns`): a round usually
    /// carries one call, sometimes a look and an act together, so the calls are
    /// twice the rounds and the round cap still comes first. These are budgets
    /// of one window: an approved renewal of the rounds starts them again
    /// (`acceptRenewal`).
    static let maximumMacControlCalls = 128
    private var grantsMacControl: Bool {
        request.connectorAccess?.servers.contains { $0.role == .macControl } ?? false
    }
    /// A turn whose connector hands back pictures reads picture-sized lines and
    /// output; every other turn keeps the text-sized bounds.
    private var handsBackPictures: Bool {
        request.connectorAccess?.servers.contains { $0.role.handsBackPictures } ?? false
    }
    private var lineLimit: Int { handsBackPictures ? Self.maximumPictureLineBytes : Self.maximumLineBytes }
    private var outputLimit: Int { handsBackPictures ? Self.maximumPictureOutputBytes : Self.maximumOutputBytes }
    private var maximumToolUses: Int {
        Self.maximumGrantedToolUses + (grantsMacControl ? Self.maximumMacControlCalls : 0)
    }
    private var maximumQuestions: Int {
        Self.maximumPermissionRequests + (grantsMacControl ? Self.maximumMacControlCalls : 0)
    }
    /// Tool calls announced complete, so the activity line sees each one once.
    private var announcedToolUseIDs: Set<String> = []

    // MARK: Renewing the rounds

    /// The CLI ended a turn that renews by card at its round cap. The child
    /// waits on its open stdin; nothing it may say meanwhile proves anything,
    /// exactly as after a result.
    private var awaitingRenewal = false
    /// The message whose rounds are running: the turn's own, then the latest
    /// approved renewal's.
    private var windowMessageID: UUID
    /// Every message this turn has written. Only these have a queue lifecycle.
    private var sentMessageIDs: Set<UUID>
    /// An approved renewal whose second init frame (the CLI
    /// announces itself again for the new message) has not arrived yet, and
    /// whose replay has not. Its model output is refused until both have, in
    /// that order, as the wire showed them.
    private var renewalInitPending = false
    private var renewalReplayPending = false
    /// The words the renewal message carried, which its replay must repeat.
    private var renewalText = ""
    /// Approved renewals so far.
    private(set) var renewalCount = 0

    init(request: ClaudeTextOnlyRequest, control: ClaudeTextTurnControl? = nil) {
        self.request = request
        self.control = control
        windowMessageID = request.messageID
        sentMessageIDs = [request.messageID]
    }

    /// What the transport needs to keep a long turn's lease alive: whether the
    /// input has been acknowledged, whether the result has landed, and the text
    /// so far, which every checkpoint extends.
    var hasAcknowledgedInput: Bool { acknowledged }
    var hasCompleted: Bool { completed }
    var textSoFar: String { text }
    var hasOpenControlChannel: Bool { controlReady }
    var isAwaitingRenewal: Bool { awaitingRenewal }

    /// The handshake the transport wrote first on a work turn; its answer is
    /// the one control_response that opens the channel.
    mutating func expectControlInitialization(requestID: String) { controlInitializationID = requestID }

    /// The host approved more rounds, and the transport is about to write the
    /// renewal message with this id and these words (the app's are always
    /// `ClaudeTextRoundsRenewal.message`; a replayed capture brings its own).
    /// From now the stream admits exactly that
    /// message's queue lifecycle, one second init frame for the same session
    /// and model, its replay with the fixed words, and model output tagged
    /// with it; a second of any is refused as it always was. The budgets of
    /// one window start again: calls, their results, questions, echoes,
    /// heartbeats, rule refusals and output bytes. The helpers' do not (at
    /// most two a turn, which no renewal resets), nor does the reply's own
    /// size. False, and nothing changes, unless the rounds ran out on a turn
    /// that renews and the id is new.
    @discardableResult
    mutating func acceptRenewal(messageID: UUID, text: String = ClaudeTextRoundsRenewal.message) -> Bool {
        guard awaitingRenewal, request.renewsRoundsByCard, !sentMessageIDs.contains(messageID) else { return false }
        awaitingRenewal = false
        renewalText = text
        sentMessageIDs.insert(messageID)
        windowMessageID = messageID
        renewalInitPending = true
        renewalReplayPending = true
        renewalCount += 1
        grantedToolUseCount = 0
        grantedToolResultCount = 0
        permissionRequestCount = 0
        controlEchoCount = 0
        toolProgressFrameCount = 0
        permissionDeniedFrameCount = 0
        totalBytes = pending.count
        return true
    }

    /// Deliver each fully validated line immediately. A later line in the same
    /// read may fail, but cannot retract its already verified prefix. The caller
    /// must stop consuming after any error; offending data is never delivered.
    mutating func consume(_ bytes: Data, onEvent: (ClaudeTextOnlyEvent) -> Void) throws {
        let admittedCount = min(bytes.count, outputLimit - totalBytes)
        totalBytes += admittedCount
        if handsBackPictures, pending.count <= Self.maximumLineBytes, pending.count + admittedCount > Self.maximumLineBytes {
            // A picture line arrives 4,096 bytes a read. Doubling its way up to
            // ten megabytes, the buffer left the allocator every block it
            // outgrew, and the allocator kept them (a process 600 MB larger
            // after 64 screenshot calls, measured). Once a
            // line is longer than any text line, it gets the picture limit at once.
            pending.reserveCapacity(Self.maximumPictureLineBytes)
        }
        pending.append(bytes.prefix(admittedCount))
        while let newline = pending[(pending.startIndex + searchedBytes)...].firstIndex(of: 0x0a) {
            // Whatever follows this newline has not been searched yet.
            searchedBytes = 0
            if newline == pending.startIndex {
                // Empty framing lines carry no event. Consume a run together
                // rather than shifting the same bounded buffer once per byte.
                let next = pending.firstIndex(where: { $0 != 0x0a }) ?? pending.endIndex
                pending.removeSubrange(..<next)
                continue
            }
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            guard line.count <= lineLimit else { throw reject(.outputLimitExceeded, .outputLimitExceeded) }
            // A turn reads on a thread of its own with no autorelease pool, so
            // what Foundation autoreleases while parsing would otherwise live
            // until the turn ends: a screenshot's worth for every picture call
            // (666 MB over 128 of the largest, measured).
            for event in try autoreleasepool(invoking: { try parse(line) }) { onEvent(event) }
        }
        searchedBytes = pending.count
        guard pending.count <= lineLimit else { throw reject(.outputLimitExceeded, .outputLimitExceeded) }
        guard admittedCount == bytes.count else { throw reject(.outputLimitExceeded, .outputLimitExceeded) }
    }

    func finish(exitCode: Int32, onDiagnostic: (ClaudeTextOnlyDiagnosticCode) -> Void = { _ in }) -> ClaudeTextOnlyResult {
        // The child left while the user's renewal card waited: the turn ended at its
        // round cap, however it exited, and keeps what it wrote.
        if awaitingRenewal { onDiagnostic(.turnLimitReached); return .failed(.turnLimitReached) }
        guard exitCode == 0 else { onDiagnostic(.processFailed); return .failed(.processFailed) }
        // The model declined. There is no terminal reply to prove and nothing
        // went wrong, so no diagnostic is recorded; the text already delivered
        // is kept by the service exactly as a stopped turn's is.
        if declined { return .failed(.declined) }
        guard pending.isEmpty, completed, acknowledged, let model, let finalText,
              !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onDiagnostic(.incompleteResult)
            return .failed(.invalidStream)
        }
        // Keep the runtime's admitted metadata compatible with the durable
        // evidence contract; a request or init alone never supplies result proof.
        let evidence = ClaudeExecutionEvidence(request: request.executionRequest,
            initializedModel: model, resultModel: confirmedModel)
        guard (try? evidence.validated()) != nil else {
            onDiagnostic(.finalModelMismatch)
            return .failed(.invalidStream)
        }
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID,
            actualModel: confirmedModel ?? responseModel ?? model, text: finalText,
            confirmedActualModel: confirmedModel))
    }

    private mutating func parse(_ data: Data) throws -> [ClaudeTextOnlyEvent] {
        guard Self.boundedJSON(data), let decoded = try? JSONSerialization.jsonObject(with: data) else {
            throw reject(.invalidStream, .invalidJSON)
        }
        guard let root = decoded as? [String: Any], let type = root["type"] as? String else {
            throw reject(.invalidStream, .invalidEnvelope)
        }
        do {
            return try parseFrame(root, type: type, readsAsSent: !Self.opensAStringWithByteOrderMark(data))
        } catch let rejection as ClaudeTextOnlyRejection {
            // The shape of a refused frame, and only its shape: type, subtype,
            // key names and value kinds. No value ever leaves; this is what a
            // live turn's diagnostic code needs to become a fix.
            let shape = refusalShape(root)
            let code = String(describing: rejection.code)
            Self.logger.error("Refused a Claude stream frame; code \(code, privacy: .public); shape \(shape, privacy: .public)")
            throw rejection
        }
    }

    /// The shape, plus — for a control request, a frame that can end a team
    /// turn with nothing but "unexpectedEvent" in the log — the nested subtype, the tool's name, whether a helper sent
    /// it, and the stream's own state: how many questions it had taken, whether
    /// this id was already seen, and whether the turn was initialized or done.
    /// Names only; no input value, no id, no text leaves.
    func refusalShape(_ root: [String: Any]) -> String {
        var shape = Self.shapeDescription(root)
        // The same treatment for a stream event, which can end a turn with
        // nothing but "responseMismatch": the event kind, the
        // content block kind, the delta kind, the stop reason and the reported
        // model are all enumerations, and one of them is the answer.
        if root["type"] as? String == "stream_event", let event = root["event"] as? [String: Any] {
            func token(_ value: Any?) -> String {
                guard let value = value as? String else { return "-" }
                let safe = value.utf8.count <= 64 && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
                return safe ? value : "?"
            }
            let block = (event["content_block"] as? [String: Any])?["type"]
            let delta = event["delta"] as? [String: Any]
            let model = (event["message"] as? [String: Any])?["model"]
            shape += " event=[type:\(token(event["type"])) block:\(token(block)) delta:\(token(delta?["type"]))"
                + " stop_reason:\(token(delta?["stop_reason"])) model:\(token(model))]"
            return shape
        }
        guard root["type"] as? String == "control_request", let control = root["request"] as? [String: Any] else {
            return shape
        }
        func name(_ key: String) -> String {
            guard let value = control[key] as? String else { return "-" }
            let safe = value.utf8.count <= 64 && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            return safe ? value : "?"
        }
        let agent = control["agent_id"] == nil || control["agent_id"] is NSNull ? "none" : "set"
        let keys = control.keys.sorted().map { key in
            key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } ? key : "?"
        }.joined(separator: ",")
        let duplicate = (root["request_id"] as? String).map { permissionRequestIDs.contains($0) } ?? false
        shape += " request=[subtype:\(name("subtype")) tool_name:\(name("tool_name")) agent_id:\(agent) keys:\(keys)]"
        if control["subtype"] as? String == "mcp_message" {
            // The hire server's messages: which server and which method, names only.
            let method = ((control["message"] as? [String: Any])?["method"] as? String).map { value in
                value.utf8.count <= 64 && value.allSatisfy { $0.isLetter || $0.isNumber || "/_-.".contains($0) } ? value : "?"
            } ?? "-"
            shape += " mcp=[server:\(name("server_name")) method:\(method) messages:\(hireServerMessageCount)]"
        }
        shape += " questions=\(permissionRequestCount) duplicate=\(duplicate) initialized=\(model != nil) completed=\(completed)"
        return shape
    }

    static func shapeDescription(_ root: [String: Any]) -> String {
        let pairs = root.keys.sorted().map { key -> String in
            let value = root[key]
            let kind: String
            switch value {
            case is NSNull: kind = "null"
            case let number as NSNumber: kind = CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
            case let text as String: kind = "string(\(text.utf8.count))"
            case is [Any]: kind = "array"
            case is [String: Any]: kind = "object"
            default: kind = "other"
            }
            let safeKey = key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } ? key : "?"
            return "\(safeKey):\(kind)"
        }
        let type = (root["type"] as? String).map { $0.allSatisfy { $0.isLetter || $0 == "_" } ? $0 : "?" } ?? "?"
        let subtype = (root["subtype"] as? String).map { $0.allSatisfy { $0.isLetter || $0 == "_" } ? $0 : "?" } ?? "-"
        return "type=\(type) subtype=\(subtype) keys=[\(pairs.joined(separator: " "))]"
    }

    private mutating func parseFrame(_ root: [String: Any], type: String,
                                     readsAsSent: Bool) throws -> [ClaudeTextOnlyEvent] {
        // A set parent identifier is a frame produced underneath a tool call.
        // Without grants there is no such call, so it stays a rejection. With
        // grants it is admitted only when it names one of this run's own
        // granted calls; a helper also needs the host's explicit approval.
        var parentID: String?
        if let parent = root["parent_tool_use_id"], !(parent is NSNull) {
            guard grantsTools, let identifier = parent as? String,
                  grantedToolUseIDs.contains(identifier), !finishedToolUseIDs.contains(identifier) else {
                throw reject(.invalidStream, .nestedToolEvent)
            }
            if toolNamesByID[identifier] == ClaudeTextHelperPolicy.toolName {
                guard control?.isHelperApproved(toolUseID: identifier) == true else {
                    throw reject(.invalidStream, .nestedToolEvent)
                }
            }
            parentID = identifier
        }
        let isUnderneathAToolCall = parentID != nil
        // The official CLI's raw transport includes frames the SDK hides.
        // Neither heartbeat nor queue lifecycle proves initialization, input
        // acceptance or a completed reply, including when it follows a result.
        if type == "keep_alive" {
            guard root.count == 1 else { throw reject(.invalidStream, .invalidKeepAlive) }
            return []
        }
        if type == "command_lifecycle" {
            // The turn's own message, or a renewal the host approved and the
            // transport wrote; never any other id.
            guard let command = uuid(root["command_uuid"]), sentMessageIDs.contains(command),
                  uuid(root["session_id"]) == request.sessionID,
                  uuid(root["uuid"]) != nil, let state = root["state"] as? String,
                  ["queued", "started", "completed", "cancelled", "discarded", "refused"].contains(state) else {
                throw reject(.invalidStream, .invalidCommandLifecycle)
            }
            guard ["queued", "started", "completed"].contains(state) else {
                throw reject(.invalidStream, .commandLifecycleRejected)
            }
            return []
        }
        if type == "control_response" {
            // The child answers the handshake and echoes the host's own answers
            // back. Only a turn that carries the channel has one — work or a
            // connector, the same predicate the command and the transport use;
            // the handshake is acknowledged once, by its own request id; echoes
            // are bounded. None of it proves input, text or a result.
            guard request.requiresPermissionControl, let response = root["response"] as? [String: Any],
                  let id = response["request_id"] as? String else { throw reject(.invalidStream, .unexpectedEvent) }
            if !controlReady, id == controlInitializationID {
                guard response["subtype"] as? String == "success" else {
                    throw reject(.unsafeInitialization, .unexpectedEvent)
                }
                controlReady = true
                return [.controlReady]
            }
            guard controlEchoCount < maximumEchoes else { throw reject(.invalidStream, .unexpectedEvent) }
            controlEchoCount += 1
            return []
        }
        if type == "control_request", (root["request"] as? [String: Any])?["subtype"] as? String == "mcp_message" {
            return try hireServerMessage(root)
        }
        if type == "control_request" {
            // The CLI asks whether one tool use may go ahead. Only a turn that
            // carries the channel is asked — work or a connector, and a
            // connector's every call comes this way — only about a tool it was
            // launched with, only after initialization, each question once,
            // within a bound a real turn stays under. The complete input travels
            // with the question so the card can show exactly what would happen.
            guard request.requiresPermissionControl, model != nil, !completed, !awaitingRenewal,
                  root["session_id"] == nil || uuid(root["session_id"]) == request.sessionID,
                  let id = root["request_id"] as? String, Self.identifier(id), id != controlInitializationID,
                  let control = root["request"] as? [String: Any],
                  control["subtype"] as? String == "can_use_tool",
                  let name = canonicalToolName(control["tool_name"]), Self.isPlainToolName(name),
                  let toolUseID = control["tool_use_id"] as? String, Self.identifier(toolUseID),
                  let input = control["input"] as? [String: Any],
                  permissionRequestCount < maximumQuestions,
                  permissionRequestIDs.insert(id).inserted,
                  let inputJSON = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                throw reject(.invalidStream, .unexpectedEvent)
            }
            permissionRequestCount += 1
            // A question about a tool this turn was never launched with is not
            // the end of the turn: it is a question, and the only safe answer
            // is no. The CLI asks such questions on its own account — on
            // 2.1.272 a sandboxed shell command reaching for a host arrives as
            // `SandboxNetworkAccess`, which no turn grants and which once killed
            // two team legs. It is surfaced marked unadmitted;
            // the host can only deny it, and nothing here records it as a call.
            guard admitsToolName(name) else {
                return [.permissionRequested(ClaudeTextPermissionRequest(
                    requestID: id, toolUseID: toolUseID, toolName: name, inputJSON: inputJSON, admitted: false,
                    inputReadsAsSent: readsAsSent))]
            }
            if let agent = control["agent_id"], !(agent is NSNull) {
                guard let agentID = agent as? String, let helperID = helperTaskIDs[agentID],
                      self.control?.isHelperApproved(toolUseID: helperID) == true,
                      !finishedToolUseIDs.contains(helperID),
                      name != ClaudeTextHelperPolicy.toolName else { throw reject(.invalidStream, .nestedToolEvent) }
            }
            if name == ClaudeTextHelperPolicy.toolName {
                guard parentID == nil, ClaudeTextHelperPolicy.accepts(input),
                      helperRequests[toolUseID] == nil,
                      helperAnnouncementInputs[toolUseID] == nil || helperAnnouncementInputs[toolUseID] == inputJSON else {
                    throw reject(.invalidStream, .nestedToolEvent)
                }
                guard helperRequests.count < ClaudeTextHelperPolicy.maximumHelpers else {
                    throw reject(.turnLimitReached, .turnLimitReached)
                }
                helperRequests[toolUseID] = inputJSON
            }
            return [.permissionRequested(ClaudeTextPermissionRequest(
                requestID: id, toolUseID: toolUseID, toolName: name, inputJSON: inputJSON,
                inputReadsAsSent: readsAsSent))]
        }
        if type == "control_cancel_request" {
            guard request.requiresPermissionControl, let id = root["request_id"] as? String,
                  permissionRequestIDs.contains(id) else {
                throw reject(.invalidStream, .unexpectedEvent)
            }
            return [.permissionCancelled(requestID: id)]
        }
        // While the renewal card waits, the child has ended its message as
        // surely as with a result: the same frames pass, and no other.
        if completed || awaitingRenewal {
            guard Self.isInformationOnlyUnknown(root, type: type, request: request) else {
                throw reject(.invalidStream, .eventAfterResult)
            }
            try ignoreInformationalEvent(or: reject(.invalidStream, .eventAfterResult))
            return []
        }
        switch type {
        case "system":
            if ["task_started", "task_progress", "task_updated", "task_notification"].contains(root["subtype"] as? String ?? "") {
                return try helperLifecycle(root)
            }
            if root["subtype"] as? String == "api_retry" {
                // The CLI is retrying a request the provider failed and will go
                // on to finish the turn itself; this is the wire twin of its own
                // retry banner. Admitted after initialization, for this session,
                // in its reviewed shape and within a small budget. It proves
                // nothing about input, text or a result, and none of it leaves.
                guard model != nil, uuid(root["session_id"]) == request.sessionID,
                      Self.isAPIRetryFrame(root),
                      apiRetryFrameCount < Self.maximumAPIRetryFrames else {
                    throw reject(.providerFailed, .providerFailure)
                }
                apiRetryFrameCount += 1
                return []
            }
            if root["subtype"] as? String == "thinking_tokens" {
                // Headless turns on CLI 2.1.261+ stream a live thinking-token
                // estimate. Read as "unexpectedSystemEvent" it would fail every
                // text reply on the current CLI. Progress metadata only: after initialization,
                // own session, flat, at most twelve snake_case keys, values that
                // are numbers, null or UUIDs. It never proves input, a reply or a
                // result; anything shaped otherwise still closes the turn.
                guard model != nil, uuid(root["session_id"]) == request.sessionID, root.count <= 12,
                      Self.isThinkingTokenFrame(root) else {
                    throw reject(.unsafeInitialization, .unexpectedSystemEvent)
                }
                guard thinkingTokenFrameCount < Self.maximumThinkingTokenFrames else {
                    throw reject(.invalidStream, .unexpectedSystemEvent)
                }
                thinkingTokenFrameCount += 1
                return []
            }
            if root["subtype"] as? String == "permission_denied" {
                // A permissions rule the app wrote refused a tool call (seen live
                // on 2.1.263: a protected-root Read). The CLI
                // goes on with the turn and so does this stream; the refusal
                // becomes an event the record keeps. Turns that carry the
                // channel — work or a connector, whose tools are admitted
                // by their namespace rather than by name — and a turn that
                // reads without one, for its three read tools only: the CLI
                // itself refuses a Read outside its folders (--restricted), and
                // by rule a Glob or Grep with no path, which searches the run
                // folder under the app's own data (a 2.1.272
                // capture). Own session, a tool and a call
                // this turn announced, a small flat frame of bounded strings,
                // and a budget.
                guard model != nil, uuid(root["session_id"]) == request.sessionID,
                      let toolName = canonicalToolName(root["tool_name"]), admitsToolName(toolName),
                      request.requiresPermissionControl
                        || (request.grantsReading && ClaudeTextOnlyRequest.readToolNames.contains(toolName)),
                      let toolUseID = root["tool_use_id"] as? String, Self.identifier(toolUseID),
                      toolNamesByID[toolUseID] == toolName,
                      root.count <= 12, permissionDeniedFrameCount < Self.maximumPermissionDeniedFrames,
                      root.values.allSatisfy({ value in
                          value is NSNull || value is NSNumber || ((value as? String).map { $0.utf8.count <= 4_096 } ?? false)
                      }) else {
                    throw reject(.invalidStream, .unexpectedSystemEvent)
                }
                permissionDeniedFrameCount += 1
                return [.toolRefused(toolUseID: toolUseID, toolName: toolName)]
            }
            if root["subtype"] as? String == "status" {
                // Official status metadata is not initialization or input
                // acceptance. The CLI also emits requesting before a replay;
                // none of these statuses changes our proof.
                guard uuid(root["session_id"]) == request.sessionID,
                      let status = root["status"],
                      status is NSNull || ["compacting", "requesting"].contains(status as? String ?? "") else {
                    throw reject(.invalidStream, .invalidStatusMetadata)
                }
                if let eventID = root["uuid"], uuid(eventID) == nil {
                    throw reject(.invalidStream, .invalidStatusMetadata)
                }
                if let mode = root["permissionMode"],
                   !request.acceptedAnnouncedPermissionModes.contains(mode as? String ?? "") {
                    throw reject(.unsafeInitialization, .statusPermissionMismatch)
                }
                return []
            }
            // The model refused and no other model takes over: the CLI's own record of the decline, read as the decline it
            // is, with or without a refusal stop reason before it. Only the
            // keys its stream-json serializer writes, for this session, on
            // the main thread (the CLI writes it nowhere else).
            if root["subtype"] as? String == "model_refusal_no_fallback" {
                guard uuid(root["session_id"]) == request.sessionID,
                      Set(root.keys).isSubset(of: Self.refusalNoFallbackKeys),
                      root["content"] is String, root["original_model"] is String,
                      root.values.allSatisfy({ value in
                          value is NSNull || ((value as? String).map { $0.utf8.count <= 4_096 } ?? false)
                      }) else {
                    throw reject(.invalidStream, .unexpectedSystemEvent)
                }
                declined = true
                return []
            }
            // The model refused and the CLI hands the reply to another one.
            // The bot's words come from its own model or not at all, so the
            // turn ends here, as declined, and the child is stopped.
            if root["subtype"] as? String == "model_refusal_fallback" {
                guard uuid(root["session_id"]) == request.sessionID else { throw reject(.invalidStream, .unexpectedSystemEvent) }
                declined = true
                throw reject(.declined, .unexpectedSystemEvent)
            }
            if root["subtype"] as? String != "init" {
                guard Self.isInformationOnlyUnknown(root, type: type, request: request) else {
                    throw reject(.unsafeInitialization, .unexpectedSystemEvent)
                }
                try ignoreInformationalEvent(or: reject(.unsafeInitialization, .unexpectedSystemEvent))
                return []
            }
            // One init a turn, and one more for each approved renewal, before
            // its replay. The second passes every fence the first
            // did, below, and must name the same session and the same model.
            guard model == nil || (renewalInitPending && renewalReplayPending) else {
                throw reject(.unsafeInitialization, .duplicateInitialization)
            }
            guard uuid(root["session_id"]) == request.sessionID else { throw reject(.unsafeInitialization, .initializationSessionMismatch) }
            // The CLI reports the tools it actually has. Without grants that
            // must still be nothing; with grants it must be exactly what this
            // turn was granted, with no extra, missing or repeated name.
            // Without grants that must still be nothing. With grants it must be
            // exactly the built-ins this turn was granted, plus — for a
            // connector turn — tools that all sit in one of its own selected
            // namespaces, and no other.
            guard let tools = root["tools"] as? [Any],
                  tools.count == tools.compactMap({ canonicalToolName($0) }).count,
                  Self.declaredToolsMatch(tools.compactMap { canonicalToolName($0) },
                                          granted: grantedToolNames, request: request) else {
                // Only names from our fixed public tool vocabulary leave this
                // boundary. Unknown provider values remain redacted; a missing
                // granted tool can now be diagnosed without capturing a stream.
                let declared = (root["tools"] as? [Any] ?? []).compactMap { canonicalToolName($0) }
                let known = Set(ClaudeTextOnlyCommandBuilder.deniableToolNames)
                let missing = request.grantedToolNames.filter { !declared.contains($0) }.joined(separator: ",")
                let extra = declared.filter { known.contains($0) && !grantedToolNames.contains($0) }.joined(separator: ",")
                let unknown = declared.filter { !known.contains($0) }.count
                Self.logger.error("Tool declaration mismatch; missing [\(missing, privacy: .public)]; known extra [\(extra, privacy: .public)]; unknown names \(unknown, privacy: .public)")
                throw reject(.unsafeInitialization, .initializationToolsInvalid)
            }
            // No connector selection means no server, exactly as shipped. With
            // one, the announced servers must be precisely the selected ones,
            // each connected, and none may have failed: a server that is
            // present but broken is a fence question, not a degraded mode.
            guard let servers = root["mcp_servers"] as? [Any],
                  Self.declaredServersMatch(servers, request: request),
                  Self.absentOrEmpty(root["mcp_server_errors"]) else { throw reject(.unsafeInitialization, .initializationMCPInvalid) }
            guard let plugins = root["plugins"] as? [Any], plugins.isEmpty,
                  Self.absentOrEmpty(root["plugin_errors"]) else { throw reject(.unsafeInitialization, .initializationPluginsInvalid) }
            // Nothing loads from a folder. The command disables memory files,
            // settings sources, slash commands and the Skill tool, and defines
            // the one helper itself; a quiet write inside the bot's own folder
            // can still plant .claude/skills, .claude/commands or
            // .claude/agents there. So the CLI must announce no skill, no
            // slash command, the default output style and, on a work turn,
            // exactly the app's helper (2.1.272 captures).
            // A CLI that stops naming them is refused too: these keys are
            // fences, not information, and a fence that went quiet is a
            // fence that may have moved.
            let unloaded: [(String, Bool)] = [
                ("skills", (root["skills"] as? [Any])?.isEmpty == true),
                ("slash_commands", (root["slash_commands"] as? [Any])?.isEmpty == true),
                ("output_style", root["output_style"] as? String == "default"),
                ("agents", (root["agents"] as? [Any]).map { Self.declaredAgentsMatch($0, request: request) } == true)
            ]
            guard unloaded.allSatisfy(\.1) else {
                let failed = unloaded.filter { !$0.1 }.map(\.0).joined(separator: ",")
                Self.logger.error("Init frame announces loaded extensions or stopped naming them; keys [\(failed, privacy: .public)]")
                throw reject(.unsafeInitialization, .initializationExtensionsInvalid)
            }
            guard request.acceptedAnnouncedPermissionModes.contains(root["permissionMode"] as? String ?? "") else {
                throw reject(.unsafeInitialization, .initializationPermissionMismatch)
            }
            guard root["apiKeySource"] as? String == "none" else { throw reject(.unsafeInitialization, .initializationKeySourceInvalid) }
            guard let actual = root["model"] as? String,
                  ClaudeTextOnlyRequest.normalizedReportedModel(actual) == request.expectedResolvedModel else { throw reject(.unsafeInitialization, .initializationModelInvalid) }
            if let initialized = model {
                // A renewal's: nothing new to tell the host, which holds one
                // initialization a turn and would refuse a second.
                guard actual == initialized else { throw reject(.unsafeInitialization, .initializationModelInvalid) }
                renewalInitPending = false
                return []
            }
            model = actual
            // 2.1.272 and later name themselves. A plain dotted version passes
            // on so the app can say which Claude Code answered, or refused;
            // anything else is not a version and adds nothing.
            if let version = root["claude_code_version"] as? String, Self.isPlainVersion(version) {
                return [.initialized(sessionID: request.sessionID, actualModel: actual), .runtimeVersion(version)]
            }
            return [.initialized(sessionID: request.sessionID, actualModel: actual)]
        case "user":
            // An approved renewal's replay: its own id, once, after its init,
            // at the root, in this session, with the words the transport wrote. Not a second acknowledgement of the user's message, so no
            // event: the host holds one a turn.
            if renewalReplayPending, uuid(root["uuid"]) == windowMessageID {
                guard !renewalInitPending, parentID == nil else { throw reject(.invalidStream, .replayMessageMismatch) }
                guard uuid(root["session_id"]) == request.sessionID else { throw reject(.invalidStream, .replaySessionMismatch) }
                if let marker = root["isReplay"] {
                    guard let replay = marker as? NSNumber,
                          CFGetTypeID(replay) == CFBooleanGetTypeID(), replay.boolValue else {
                        throw reject(.invalidStream, .replayNotConfirmed)
                    }
                }
                guard let message = root["message"] as? [String: Any], message["role"] as? String == "user",
                      let replayedText = Self.replayText(message["content"]) else { throw reject(.invalidStream, .replayContentInvalid) }
                guard replayedText.utf8.elementsEqual(renewalText.utf8) else {
                    throw reject(.invalidStream, .replayTextMismatch)
                }
                renewalReplayPending = false
                return []
            }
            if acknowledged {
                // Claude also replays a helper's initial assignment. It is
                // private input to one approved, active helper, never a second
                // acknowledgement of the user's turn or a tool result.
                if let parentID, toolNamesByID[parentID] == ClaudeTextHelperPolicy.toolName,
                   let message = root["message"] as? [String: Any],
                   let replayedText = Self.replayText(message["content"]) {
                    guard uuid(root["session_id"]) == request.sessionID,
                          uuid(root["uuid"]) != nil, message["role"] as? String == "user",
                          root["subagent_type"] as? String == ClaudeTextHelperPolicy.agentType,
                          let inputJSON = helperRequests[parentID],
                          let input = try? JSONSerialization.jsonObject(with: inputJSON) as? [String: Any],
                          let prompt = input["prompt"] as? String,
                          let description = input["description"] as? String,
                          let replayedDescription = root["task_description"] as? String,
                          replayedDescription.utf8.elementsEqual(description.utf8),
                          replayedText.utf8.elementsEqual(prompt.utf8),
                          replayedHelperIDs.insert(parentID).inserted else {
                        throw reject(.invalidStream, .replayDuplicate)
                    }
                    return []
                }
                // Other user frames must contain results answering this run's
                // announced calls, in the same parent scope.
                guard grantsTools, uuid(root["session_id"]) == request.sessionID,
                      let message = root["message"] as? [String: Any], message["role"] as? String == "user",
                      let results = Self.toolResults(message["content"]),
                      results.allSatisfy({ grantedToolUseIDs.contains($0.toolUseID)
                          && toolParentsByID[$0.toolUseID] == (parentID ?? "") }),
                      grantedToolResultCount + results.count <= maximumToolUses else {
                    throw reject(.invalidStream, .replayDuplicate)
                }
                grantedToolResultCount += results.count
                finishedToolUseIDs.formUnion(results.map(\.toolUseID))
                let pictures = Self.screenPictures(message["content"]).filter { isMacControlTool(toolNamesByID[$0.toolUseID]) }
                // A web fetch whose page answered with an error status comes back
                // without is_error; the frame's tool_use_result carries the status
                // (Claude Code 2.1.280, a 500 from Amazon read "Read <url>").
                let fetchFailed = results.count == 1 && toolNamesByID[results[0].toolUseID] == "WebFetch"
                    && Self.isErrorStatus(root["tool_use_result"])
                let fetchReason = fetchFailed ? Self.errorStatus(root["tool_use_result"]).map { "The page answered with status \($0)." } : nil
                return pictures.map { .screenPicture($0) }
                    + results.flatMap { result -> [ClaudeTextOnlyEvent] in
                        let reason = result.failed ? result.reason : (fetchFailed ? fetchReason : nil)
                        return (reason.map { [.toolFailureReason(toolUseID: result.toolUseID, reason: $0)] } ?? [])
                            + [.toolFinished(toolUseID: result.toolUseID, failed: result.failed || fetchFailed)]
                    }
            }
            guard uuid(root["uuid"]) == request.messageID else { throw reject(.invalidStream, .replayMessageMismatch) }
            guard uuid(root["session_id"]) == request.sessionID else { throw reject(.invalidStream, .replaySessionMismatch) }
            // The SDK describes isReplay:true, but our evidence does not prove
            // that every raw CLI replay carries this SDK-described marker. The
            // fixed --replay-user-messages command plus exact frozen correlation
            // remains the wire proof. Reject an explicitly contradictory marker.
            if let marker = root["isReplay"] {
                guard let replay = marker as? NSNumber,
                      CFGetTypeID(replay) == CFBooleanGetTypeID(), replay.boolValue else {
                    throw reject(.invalidStream, .replayNotConfirmed)
                }
            }
            guard let message = root["message"] as? [String: Any], message["role"] as? String == "user",
                  let replayedText = Self.replayText(message["content"]) else { throw reject(.invalidStream, .replayContentInvalid) }
            guard replayedText.utf8.elementsEqual(request.text.utf8) else { throw reject(.invalidStream, .replayTextMismatch) }
            acknowledged = true
            return [.inputAcknowledged(messageID: request.messageID)]
        case "stream_event":
            guard model != nil, uuid(root["session_id"]) == request.sessionID, isInCurrentWindow(root, parentID: parentID),
                  let event = root["event"] as? [String: Any], let kind = event["type"] as? String else {
                throw reject(.invalidStream, .responseMismatch)
            }
            switch kind {
            case "content_block_start":
                guard let block = event["content_block"] as? [String: Any],
                      let kind = block["type"] as? String else { throw reject(.invalidStream, .responseMismatch) }
                if kind == "tool_use" {
                    _ = try recordToolUse(block, complete: false, parentID: parentID)
                } else {
                    guard ["text", "thinking", "redacted_thinking"].contains(kind) else {
                        throw reject(.invalidStream, .responseMismatch)
                    }
                }
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any], let kind = delta["type"] as? String else {
                    throw reject(.invalidStream, .responseMismatch)
                }
                if kind == "text_delta" {
                    let separator = pendingParagraphBreak ? Self.paragraphBreak(after: text) : ""
                    guard let addition = delta["text"] as? String,
                          addition.utf8.count + separator.utf8.count <= Self.maximumReplyBytes - text.utf8.count else {
                        throw reject(.outputLimitExceeded, .outputLimitExceeded)
                    }
                    // Text produced underneath a tool call is the tool's own
                    // working, not the bot speaking. It is admitted, because
                    // this run granted that call, and then dropped: only what
                    // the assistant says in its own frames becomes the reply.
                    guard !isUnderneathAToolCall else { return [] }
                    text += separator + addition
                    pendingParagraphBreak = false
                    return [.textSnapshot(text)]
                }
                if kind == "input_json_delta" {
                    // A granted call's arguments stream as text but are never
                    // part of the reply, so they are bounded and dropped.
                    guard grantsTools, !grantedToolUseIDs.isEmpty,
                          (delta["partial_json"] as? String)?.utf8.count ?? Int.max <= Self.maximumReplyBytes else {
                        throw reject(.invalidStream, .responseMismatch)
                    }
                    return []
                }
                guard ["thinking_delta", "signature_delta"].contains(kind) else { throw reject(.invalidStream, .responseMismatch) }
            case "message_start":
                guard let message = event["message"] as? [String: Any], message["role"] as? String == "assistant",
                      let actual = message["model"] as? String,
                      let resolved = ClaudeTextOnlyRequest.normalizedReportedModel(actual),
                      responseModelMatches(resolved, parentID: parentID),
                      let content = message["content"] as? [Any], content.isEmpty else { throw reject(.invalidStream, .responseMismatch) }
                if let parentID { nestedModels[parentID] = resolved }
                else { responseModel = resolved }
                // A granted run speaks again after a tool round trip. What it
                // says next begins a new paragraph, so narration and answer do
                // not run together in the saved reply. Only a message that
                // actually carries text opens it; a silent tool round does not.
                if grantsTools, !isUnderneathAToolCall, !text.isEmpty { pendingParagraphBreak = true }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                    let stopped = ["end_turn", "max_tokens", "stop_sequence", "refusal"]
                        + (grantsTools ? ["tool_use"] : [])
                    guard stopped.contains(reason) else { throw reject(.invalidStream, .responseMismatch) }
                    // The model decided not to answer this one. An ungranted
                    // turn can be declined exactly as a granted one can, so
                    // this sits with the ordinary stop reasons rather than
                    // behind the tool grant. A refusal underneath a granted
                    // call is that call's own business: the parent turn is
                    // still free to answer, so it does not decline here.
                    if reason == "refusal", !isUnderneathAToolCall { declined = true }
                }
            case "content_block_stop", "message_stop": break
            default: throw reject(.invalidStream, .responseMismatch)
            }
            return []
        case "rate_limit_event":
            guard model != nil, uuid(root["session_id"]) == request.sessionID,
                  let info = root["rate_limit_info"] as? [String: Any],
                  let status = info["status"] as? String else { throw reject(.invalidStream, .responseMismatch) }
            guard ["allowed", "allowed_warning"].contains(status) else { throw reject(.providerFailed, .providerFailure) }
            return []
        case "assistant":
            guard model != nil, uuid(root["session_id"]) == request.sessionID, isInCurrentWindow(root, parentID: parentID),
                  let message = root["message"] as? [String: Any], message["role"] as? String == "assistant",
                  let actual = message["model"] as? String,
                  let resolved = ClaudeTextOnlyRequest.normalizedReportedModel(actual),
                  responseModelMatches(resolved, parentID: parentID),
                  let blocks = message["content"] as? [[String: Any]], blocks.count <= 256 else {
                throw reject(.invalidStream, .responseMismatch)
            }
            var announced: [ClaudeTextOnlyEvent] = []
            for block in blocks {
                guard let kind = block["type"] as? String else { throw reject(.invalidStream, .responseMismatch) }
                if kind == "tool_use" {
                    if let use = try recordToolUse(block, complete: true, parentID: parentID) { announced.append(.toolUse(use)) }
                    continue
                }
                guard ["text", "thinking", "redacted_thinking"].contains(kind) else { throw reject(.invalidStream, .responseMismatch) }
            }
            if let parentID { nestedModels[parentID] = resolved }
            else { responseModel = resolved }
            // Stream deltas own partials. The terminal result owns the completed
            // reply, so the full assistant event must not double-append its text.
            // What it does carry is each tool call complete, for the activity line.
            return announced
        case "result":
            // A resumed turn the CLI cannot find ends with one error result and
            // no init (captured on 2.1.272): its own failure, so the stored
            // session is dropped and the next turn starts fresh, rather than a
            // broken stream the person is told could not be verified.
            if request.resumesSession, model == nil, Self.isLostSessionResult(root, request: request) {
                throw reject(.sessionNotFound, .sessionNotFound)
            }
            guard model != nil, uuid(root["session_id"]) == request.sessionID,
                  isInCurrentWindow(root, parentID: parentID) else { throw reject(.invalidStream, .responseMismatch) }
            if isUnderneathAToolCall {
                // Nested completion belongs to a tool's internal work. It can
                // neither finish the root nor confirm the root's model/text.
                guard let subtype = root["subtype"] as? String,
                      ["success", "error_max_turns", "error_during_execution"].contains(subtype),
                      let error = root["is_error"] as? NSNumber, CFGetTypeID(error) == CFBooleanGetTypeID(),
                      root["result"] == nil || (root["result"] as? String)?.utf8.count ?? Int.max <= Self.maximumReplyBytes else {
                    throw reject(.invalidStream, .responseMismatch)
                }
                return []
            }
            // A declined turn's terminal frame has no answer to carry, and
            // needs none: the decision was already on the wire. It closes the
            // turn here rather than being refused as an empty or failed
            // result, which would log a refusal and blame the app for one.
            if declined { completed = true; return [] }
            // The CLI ends a run that would need one more assistant message
            // than `--max-turns` allows with this subtype and no reply text. It
            // is the turn cap, not a provider or connection fault, and the
            // service reports it as its own failure.
            if root["subtype"] as? String == "error_max_turns" {
                // A turn that renews by card waits for the user instead: the child is
                // still alive, its stdin still open, and on 2.1.281 one more
                // message there runs a fresh allowance of rounds with the
                // earlier ones in context. Only its own capped
                // result: an error, naming this window's message when it names one.
                if request.renewsRoundsByCard, control != nil,
                   let error = root["is_error"] as? NSNumber, CFGetTypeID(error) == CFBooleanGetTypeID(), error.boolValue,
                   root["user_message_uuid"] == nil || uuid(root["user_message_uuid"]) == windowMessageID {
                    awaitingRenewal = true
                    return [.roundsRanOut]
                }
                throw reject(.turnLimitReached, .turnLimitReached)
            }
            // A turn with a card may end with denials on record — work or a
            // connector: a card the user refused is a normal end, not a broken
            // stream. So may a turn that reads without a card, when every
            // denial names one of its read tools: the CLI refused those reads
            // itself, a protected-root Read with no frame at all.
            guard root["subtype"] as? String == "success",
                  request.requiresPermissionControl || Self.absentOrEmpty(root["permission_denials"])
                    || (request.grantsReading && Self.deniesOnlyReads(root["permission_denials"])),
                  let error = root["is_error"] as? NSNumber,
                  CFGetTypeID(error) == CFBooleanGetTypeID(), !error.boolValue,
                  let result = root["result"] as? String, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw reject(.providerFailed, .providerFailure)
            }
            guard result.utf8.count <= Self.maximumReplyBytes else { throw reject(.outputLimitExceeded, .outputLimitExceeded) }
            if let rawUsage = root["modelUsage"] {
                guard let usage = rawUsage as? [String: Any] else {
                    throw reject(.unsafeInitialization, .finalModelMismatch)
                }
                if grantsTools {
                    // A granted tool runs its own internal model query (the CLI
                    // applies the fetch prompt and runs the search through
                    // separate calls), so a granted turn's usage names more than
                    // one model. The turn's own model must still be there exactly
                    // once and must still agree with every assistant frame; the
                    // helpers are bounded and claim nothing about who answered.
                    guard (1...Self.maximumGrantedUsageModels).contains(usage.count),
                          usage.values.allSatisfy({ $0 is [String: Any] }) else {
                        throw reject(.unsafeInitialization, .finalModelMismatch)
                    }
                    let answering = usage.keys.filter {
                        ClaudeTextOnlyRequest.normalizedReportedModel($0) == request.expectedResolvedModel
                    }
                    guard answering.count == 1, let actual = answering.first,
                          responseModel == nil || responseModel == request.expectedResolvedModel else {
                        throw reject(.unsafeInitialization, .finalModelMismatch)
                    }
                    confirmedModel = actual
                } else {
                    // Official stream-json may announce a retired/remapped name at
                    // init. Its successful result.modelUsage is the actual-model
                    // authority; it must still agree with any assistant response.
                    guard usage.count == 1, let actual = usage.keys.first,
                          let resolved = ClaudeTextOnlyRequest.normalizedReportedModel(actual),
                          usage[actual] is [String: Any], responseModel == nil || responseModel == resolved else {
                        throw reject(.unsafeInitialization, .finalModelMismatch)
                    }
                    confirmedModel = actual
                }
            }
            // On a granted run the CLI's result text is the last assistant
            // message alone, not everything the model said around its tool
            // calls. The reply is what streamed; the result must end it, and
            // marks it complete. Without a grant, or when nothing streamed, the
            // result is the reply, as it always was.
            let reply: String
            if grantsTools, !text.isEmpty {
                guard Self.trimmed(text).hasSuffix(Self.trimmed(result)) else {
                    throw reject(.invalidStream, .responseMismatch)
                }
                reply = text
            } else {
                reply = result
            }
            finalText = reply
            completed = true
            return [.textSnapshot(reply)]
        case "tool_progress":
            // The CLI's tool executor heartbeats every thirty seconds while a
            // call runs, naming the call by its own identifier plus a heartbeat
            // suffix. Only a heartbeat of a call this run announced, for a tool
            // this run was granted, is admitted; it carries no reply text and is
            // dropped, within a bound a real turn stays far below.
            guard grantsTools, model != nil, uuid(root["session_id"]) == request.sessionID,
                  Self.isToolProgressFrame(root),
                  let identifier = root["tool_use_id"] as? String,
                  grantedToolUseIDs.contains(where: { identifier.hasPrefix($0) }),
                  let name = canonicalToolName(root["tool_name"]), admitsToolName(name),
                  toolProgressFrameCount < Self.maximumToolProgressFrames else {
                throw reject(.invalidStream, .unexpectedEvent)
            }
            toolProgressFrameCount += 1
            return []
        default:
            guard Self.isInformationOnlyUnknown(root, type: type, request: request) else {
                throw reject(.invalidStream, .unexpectedEvent)
            }
            try ignoreInformationalEvent(or: reject(.invalidStream, .unexpectedEvent))
            return []
        }
    }

    /// One message for the app's hire server. Only a turn that
    /// carries the server gets them, only for that one server name, each
    /// request id once, within a bound. They come before the init frame (the
    /// CLI connects its servers first) and a cancellation can follow the
    /// result, so neither initialization nor completion is required. The turn's
    /// control answers the handshake, a notification, the tool list and any
    /// other method at once; a call to the hire tool is handed to the host.
    private mutating func hireServerMessage(_ root: [String: Any]) throws -> [ClaudeTextOnlyEvent] {
        guard request.carriesAppServer, let control,
              root["session_id"] == nil || uuid(root["session_id"]) == request.sessionID,
              let id = root["request_id"] as? String, Self.identifier(id), id != controlInitializationID,
              !permissionRequestIDs.contains(id),
              let body = root["request"] as? [String: Any],
              body["server_name"] as? String == ClaudeTextHirePolicy.serverName,
              let message = body["message"] as? [String: Any], message["jsonrpc"] as? String == "2.0",
              let method = message["method"] as? String, Self.isPlainMethod(method),
              hireServerMessageCount < Self.maximumHireServerMessages,
              hireServerMessageIDs.insert(id).inserted else {
            throw reject(.invalidStream, .unexpectedEvent)
        }
        var jsonrpcID: ClaudeTextJSONRPCID?
        if let raw = message["id"], !(raw is NSNull) {
            guard let parsed = Self.jsonrpcID(raw) else { throw reject(.invalidStream, .unexpectedEvent) }
            jsonrpcID = parsed
        }
        let params = message["params"] as? [String: Any]
        guard message["params"] == nil || message["params"] is NSNull || params != nil else {
            throw reject(.invalidStream, .unexpectedEvent)
        }
        let kind: ClaudeTextHireServerMessage.Kind
        switch (method, jsonrpcID) {
        case ("initialize", .some):
            let version = (params?["protocolVersion"] as? String).flatMap { Self.isPlainProtocolVersion($0) ? $0 : nil }
            kind = .initialize(protocolVersion: version)
        case ("tools/list", .some):
            kind = .toolsList
        case ("tools/call", .some):
            guard let params, let name = params["name"] as? String, Self.isPlainToolName(name),
                  let meta = params["_meta"] as? [String: Any],
                  let toolUseID = meta["claudecode/toolUseId"] as? String, Self.identifier(toolUseID) else {
                throw reject(.invalidStream, .unexpectedEvent)
            }
            let arguments = params["arguments"] ?? [String: Any]()
            guard let object = arguments as? [String: Any],
                  let argumentsJSON = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                throw reject(.invalidStream, .unexpectedEvent)
            }
            // The bot's own call, announced by its own reply rather than by a
            // helper underneath a tool call or by nothing at all.
            let isOwnCall = toolNamesByID[toolUseID] == "mcp__\(ClaudeTextHirePolicy.serverName)__\(name)"
                && toolParentsByID[toolUseID] == ""
            kind = .call(name: name, toolUseID: toolUseID, argumentsJSON: argumentsJSON, isOwnCall: isOwnCall)
        case ("initialize", nil), ("tools/list", nil), ("tools/call", nil):
            throw reject(.invalidStream, .unexpectedEvent)
        case (_, nil):
            let cancelled = method == "notifications/cancelled" ? params?["requestId"].flatMap(Self.jsonrpcID) : nil
            kind = .notification(cancelled: cancelled)
        default:
            kind = .otherMethod
        }
        hireServerMessageCount += 1
        let call = control.receiveHireServerMessage(ClaudeTextHireServerMessage(requestID: id, id: jsonrpcID, kind: kind),
                                                    offering: request.appServerToolNames)
        switch call {
        case .hire(let hire): return [.hireRequested(hire)]
        case .worker(let worker): return [.workerRequested(worker)]
        case .selfSetup(let setup): return [.selfSetupRequested(setup)]
        case nil: return []
        }
    }

    private static func jsonrpcID(_ value: Any) -> ClaudeTextJSONRPCID? {
        if let text = value as? String { return identifier(text) ? .string(text) : nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              let exact = Int64(exactly: number.doubleValue) else { return nil }
        return .number(exact)
    }

    /// A JSON-RPC method name: letters, digits, `/`, `_`, `-` and `.`, at most 64 bytes.
    private static func isPlainMethod(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || [47, 95, 45, 46].contains($0)
        }
    }

    /// A protocol version as MCP spells one, `2025-11-25`: digits and hyphens.
    private static func isPlainProtocolVersion(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || $0 == 45 }
    }

    /// A tool call is admitted only when this turn was granted that exact tool.
    /// Its identifier is remembered so the matching result, and any frame
    /// produced underneath it, can be correlated back to this granted call.
    private mutating func recordToolUse(_ block: [String: Any], complete: Bool, parentID: String?) throws -> ClaudeTextToolUse? {
        guard grantsTools, let name = canonicalToolName(block["name"]), admitsToolName(name),
              let identifier = block["id"] as? String, !identifier.isEmpty, identifier.utf8.count <= 256,
              identifier.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else {
            throw reject(.invalidStream, .responseMismatch)
        }
        guard toolNamesByID[identifier] == nil || (toolNamesByID[identifier] == name
                && toolParentsByID[identifier] == (parentID ?? "")) else {
            throw reject(.invalidStream, .nestedToolEvent)
        }
        if name == ClaudeTextHelperPolicy.toolName {
            guard parentID == nil else { throw reject(.invalidStream, .nestedToolEvent) }
            if complete {
                guard let input = block["input"] as? [String: Any], ClaudeTextHelperPolicy.accepts(input),
                      let encoded = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
                      helperAnnouncementInputs[identifier] == nil || helperAnnouncementInputs[identifier] == encoded,
                      helperRequests[identifier] == nil || helperRequests[identifier] == encoded else {
                    throw reject(.invalidStream, .nestedToolEvent)
                }
                helperAnnouncementInputs[identifier] = encoded
            }
        }
        toolNamesByID[identifier] = name
        toolParentsByID[identifier] = parentID ?? ""
        // The same call is announced twice, once starting its block and once in
        // the completed assistant message. Only a new identifier counts.
        // A call past the budget is the app's own limit, not a malformed stream:
        // it ends the run the way the CLI's turn cap does, with the text so far
        // kept and a status a reader can act on, rather than as a provider fault.
        guard grantedToolUseIDs.contains(identifier) || grantedToolUseCount < maximumToolUses else {
            throw reject(.turnLimitReached, .turnLimitReached)
        }
        if grantedToolUseIDs.insert(identifier).inserted { grantedToolUseCount += 1 }
        // The completed assistant message carries the whole input; the block
        // start does not. Each call is announced once, with its input.
        guard complete, let input = block["input"] as? [String: Any], announcedToolUseIDs.insert(identifier).inserted,
              let inputJSON = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
              inputJSON.count <= Self.maximumReplyBytes else { return nil }
        return ClaudeTextToolUse(id: identifier, toolName: name, inputJSON: inputJSON)
    }

    /// After a renewal, model output belongs to its message: it comes only
    /// once the renewal's init and replay have, and a root frame that names
    /// its message (`user_message_uuid`, as 2.1.281 does) names that one. A
    /// turn never renewed is read exactly as before.
    private func isInCurrentWindow(_ root: [String: Any], parentID: String?) -> Bool {
        guard renewalCount > 0 else { return true }
        guard !renewalInitPending, !renewalReplayPending else { return false }
        guard parentID == nil, let named = root["user_message_uuid"] else { return true }
        return uuid(named) == windowMessageID
    }

    private func responseModelMatches(_ resolved: String, parentID: String?) -> Bool {
        guard let parentID else { return responseModel == nil || responseModel == resolved }
        if toolNamesByID[parentID] == ClaudeTextHelperPolicy.toolName,
           resolved != request.expectedResolvedModel { return false }
        return nestedModels[parentID] == nil || nestedModels[parentID] == resolved
    }

    /// The CLI reports foreground helper lifecycle with the same task records
    /// used for background jobs. Only a host-approved Agent call can introduce
    /// a task identity; notifications are activity, never another user turn.
    private mutating func helperLifecycle(_ root: [String: Any]) throws -> [ClaudeTextOnlyEvent] {
        guard request.grantsWork, model != nil, uuid(root["session_id"]) == request.sessionID,
              let taskID = root["task_id"] as? String, Self.identifier(taskID),
              helperLifecycleFrameCount < Self.maximumToolProgressFrames else {
            throw reject(.invalidStream, .nestedToolEvent)
        }
        if root["subtype"] as? String == "task_started" {
            guard let toolID = root["tool_use_id"] as? String,
                  toolNamesByID[toolID] == ClaudeTextHelperPolicy.toolName,
                  control?.isHelperApproved(toolUseID: toolID) == true,
                  helperTaskIDs[taskID] == nil,
                  !helperTaskIDs.values.contains(toolID),
                  root["task_type"] == nil || root["task_type"] as? String == "local_agent" else {
                throw reject(.invalidStream, .nestedToolEvent)
            }
            helperTaskIDs[taskID] = toolID
        } else {
            guard let toolID = helperTaskIDs[taskID],
                  root["tool_use_id"] == nil || root["tool_use_id"] as? String == toolID else {
                throw reject(.invalidStream, .nestedToolEvent)
            }
            if root["subtype"] as? String == "task_updated" {
                // The signed CLI's wire-safe task patch contains status only.
                // It cannot authorize work, expose helper text, or finish the
                // root reply. A background transition contradicts our grant.
                guard uuid(root["uuid"]) != nil,
                      let patch = root["patch"] as? [String: Any], !patch.isEmpty,
                      Set(patch.keys).isSubset(of: ["status", "description", "end_time", "total_paused_ms", "error", "is_backgrounded"]),
                      control?.isHelperApproved(toolUseID: toolID) == true else {
                    throw reject(.invalidStream, .nestedToolEvent)
                }
                for (key, value) in patch {
                    switch key {
                    case "status":
                        guard ["pending", "running", "completed", "failed", "killed", "paused"].contains(value as? String ?? "") else {
                            throw reject(.invalidStream, .nestedToolEvent)
                        }
                    case "description", "error":
                        guard let value = value as? String, value.utf8.count <= Self.maximumReplyBytes else {
                            throw reject(.invalidStream, .nestedToolEvent)
                        }
                    case "is_backgrounded":
                        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID(), !value.boolValue else {
                            throw reject(.invalidStream, .nestedToolEvent)
                        }
                    default:
                        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                              value.doubleValue.isFinite, value.doubleValue >= 0,
                              value.doubleValue.rounded() == value.doubleValue else {
                            throw reject(.invalidStream, .nestedToolEvent)
                        }
                    }
                }
            }
            if root["subtype"] as? String == "task_notification" {
                guard ["completed", "failed", "stopped"].contains(root["status"] as? String ?? "") else {
                    throw reject(.invalidStream, .nestedToolEvent)
                }
            }
        }
        helperLifecycleFrameCount += 1
        return []
    }

    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { $0 >= 33 && $0 <= 126 }
    }

    /// The CLI's answer to `--resume` with an id it does not hold: an error
    /// result before any init, zero turns, and one error line naming it.
    static func isLostSessionResult(_ root: [String: Any], request: ClaudeTextOnlyRequest) -> Bool {
        guard root["subtype"] as? String == "error_during_execution",
              let error = root["is_error"] as? NSNumber, CFGetTypeID(error) == CFBooleanGetTypeID(), error.boolValue,
              (root["num_turns"] as? NSNumber)?.intValue == 0,
              let rawSession = root["session_id"], uuidString(rawSession) == request.sessionID,
              let errors = root["errors"] as? [String], errors.count == 1,
              errors[0].hasPrefix("No conversation found with session ID") else { return false }
        return true
    }

    /// A version as the CLI prints one: digits and dots only, `2.1.272`.
    static func isPlainVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 32 && parts.count == 3 && parts.allSatisfy { part in
            !part.isEmpty && part.utf8.count <= 8 && part.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
        }
    }

    /// A tool name the CLI could have: letters, digits, underscores and the
    /// hyphen a plugin-named server carries (`mcp__chrome-devtools__click`),
    /// at most 128 bytes. Anything else in a question is not a question.
    static func isPlainToolName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95 || $0 == 45
        }
    }

    /// Every call a user frame's tool-result blocks answer, with whether the
    /// result is an error, or nil when the frame is not a bounded,
    /// tool-result-only frame.
    private static func toolResults(_ content: Any?) -> [(toolUseID: String, failed: Bool, reason: String?)]? {
        guard let blocks = content as? [[String: Any]], !blocks.isEmpty,
              blocks.count <= maximumToolResultBlocks else { return nil }
        var results: [(toolUseID: String, failed: Bool, reason: String?)] = []
        for block in blocks {
            guard block["type"] as? String == "tool_result",
                  let identifier = block["tool_use_id"] as? String else { return nil }
            // Absent means it ran; present it must be a boolean, as on the result
            // frame: a flag this stream cannot read is not proof the call ran.
            var failed = false
            if let raw = block["is_error"] {
                guard let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
                failed = flag.boolValue
            }
            results.append((identifier, failed, failed ? failureReason(block["content"]) : nil))
        }
        return results
    }

    /// The most a failure's words are read to: they are cut to one short line
    /// where they are kept, so a long traceback is never carried whole.
    static let maximumFailureReasonBytes = 4_096

    /// The words a failed result carries: its text, or its text blocks joined,
    /// without the CLI's own `<tool_use_error>` wrapper. Nil when there are none.
    static func failureReason(_ content: Any?) -> String? {
        var text: String
        if let plain = content as? String {
            text = plain
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
        } else {
            return nil
        }
        if text.utf8.count > maximumFailureReasonBytes {
            text = String(decoding: text.utf8.prefix(maximumFailureReasonBytes), as: UTF8.self)
        }
        for tag in ["<tool_use_error>", "</tool_use_error>"] { text = text.replacingOccurrences(of: tag, with: " ") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The status a web page answered with, when it is an error (see below).
    static func errorStatus(_ toolUseResult: Any?) -> Int? {
        guard isErrorStatus(toolUseResult), let result = toolUseResult as? [String: Any],
              let code = result["code"] as? NSNumber else { return nil }
        return Int(exactly: code.doubleValue)
    }

    /// A tool_use_result whose `code` is an HTTP status of 400 or more. Only a
    /// number counts: a flag or text in its place says nothing.
    static func isErrorStatus(_ toolUseResult: Any?) -> Bool {
        guard let result = toolUseResult as? [String: Any], let code = result["code"] as? NSNumber,
              CFGetTypeID(code) != CFBooleanGetTypeID(), let status = Int(exactly: code.doubleValue) else { return false }
        return status >= 400
    }

    /// A call to a tool of this turn's Control this Mac server. Only that
    /// server's pictures are of the user's screen; a browser's are of its own page.
    private func isMacControlTool(_ name: String?) -> Bool {
        guard let name else { return false }
        return request.connectorAccess?.servers.contains {
            $0.role == .macControl && name.hasPrefix("mcp__\($0.name)__")
        } ?? false
    }

    /// The first PNG or JPEG in each tool result's own content, decoded. The
    /// CLI writes the picture again in `tool_use_result`; that copy is not read.
    /// Anything else, or base64 that does not decode, is left out.
    static func screenPictures(_ content: Any?) -> [ClaudeTextScreenPicture] {
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String,
                  let parts = block["content"] as? [[String: Any]] else { return nil }
            for part in parts where part["type"] as? String == "image" {
                guard let source = part["source"] as? [String: Any], source["type"] as? String == "base64",
                      let mediaType = source["media_type"] as? String, ["image/png", "image/jpeg"].contains(mediaType),
                      let encoded = source["data"] as? String, let data = Data(base64Encoded: encoded),
                      !data.isEmpty else { continue }
                return ClaudeTextScreenPicture(toolUseID: id, mediaType: mediaType, data: data)
            }
            return nil
        }
    }

    /// The break a further assistant message opens with: enough newlines to end
    /// the paragraph before it and never more, nothing when the text already
    /// ends one. Only ever appended, so every snapshot extends the one before.
    private static func paragraphBreak(after text: String) -> String {
        if text.isEmpty || text.hasSuffix("\n\n") { return "" }
        return text.hasSuffix("\n") ? "\n" : "\n\n"
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The retry frame's reviewed shape: attempt counters and a delay as
    /// numbers, an HTTP status as a number or null, the error snapshot and the
    /// no-response detail as values that are never read, an event UUID. Any
    /// other key means this is not the frame that was reviewed.
    private static func isAPIRetryFrame(_ root: [String: Any]) -> Bool {
        let reviewedKeys: Set<String> = ["type", "subtype", "session_id", "uuid", "attempt", "max_retries",
                                         "retry_delay_ms", "error_status", "error", "no_response"]
        guard root.count <= reviewedKeys.count, root.keys.allSatisfy(reviewedKeys.contains),
              ["attempt", "max_retries", "retry_delay_ms"].allSatisfy({ root[$0] is NSNumber }) else { return false }
        if let status = root["error_status"] { guard status is NSNumber || status is NSNull else { return false } }
        if let eventID = root["uuid"] { guard uuidString(eventID) != nil else { return false } }
        return true
    }

    /// A heartbeat's reviewed shape: the call's identifier with the CLI's
    /// suffix, the tool's name, a null parent, elapsed seconds as a number, the
    /// heartbeat flag set, an event UUID. Anything else is some other frame.
    private static func isToolProgressFrame(_ root: [String: Any]) -> Bool {
        let reviewedKeys: Set<String> = ["type", "tool_use_id", "tool_name", "parent_tool_use_id",
                                         "elapsed_time_seconds", "heartbeat", "session_id", "uuid"]
        guard root.count <= reviewedKeys.count, root.keys.allSatisfy(reviewedKeys.contains),
              let identifier = root["tool_use_id"] as? String, !identifier.isEmpty, identifier.utf8.count <= 320,
              identifier.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else { return false }
        if let elapsed = root["elapsed_time_seconds"] { guard elapsed is NSNumber else { return false } }
        if let heartbeat = root["heartbeat"] {
            guard let flag = heartbeat as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue else {
                return false
            }
        }
        if let eventID = root["uuid"] { guard uuidString(eventID) != nil else { return false } }
        return true
    }

    private static func isThinkingTokenFrame(_ root: [String: Any]) -> Bool {
        for (key, value) in root where !["type", "subtype", "session_id"].contains(key) {
            guard key.utf8.count <= 64,
                  key.utf8.allSatisfy({ $0 == 0x5f || ($0 >= 0x61 && $0 <= 0x7a) }),
                  !key.contains("tool"), !key.contains("parent"),
                  value is NSNull || value is NSNumber || (value as? String).flatMap(UUID.init(uuidString:)) != nil else {
                return false
            }
        }
        return true
    }

    private mutating func ignoreInformationalEvent(or rejection: ClaudeTextOnlyRejection) throws {
        guard ignoredInformationalEventCount < Self.maximumIgnoredInformationalEvents else { throw rejection }
        ignoredInformationalEventCount += 1
        let count = ignoredInformationalEventCount
        Self.logger.notice(
            "Ignored one bounded information-only Claude stream frame; run count: \(count, privacy: .public)"
        )
    }

    private func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }

    /// The keys Claude Code 2.1.280 to 2.1.282 write on a
    /// `model_refusal_no_fallback` frame (the stream-json serializer's
    /// `Fe({type:"system",subtype:"model_refusal_no_fallback",…})`, which adds
    /// the session id).
    static let refusalNoFallbackKeys: Set<String> = ["type", "subtype", "uuid", "session_id", "original_model",
        "request_id", "api_refusal_category", "api_refusal_explanation", "refused_user_message_uuid", "content"]

    private func reject(_ failure: ClaudeTextOnlyFailure, _ code: ClaudeTextOnlyDiagnosticCode) -> ClaudeTextOnlyRejection {
        ClaudeTextOnlyRejection(failure: failure, code: code)
    }

    private static func replayText(_ content: Any?) -> String? {
        // Official MessageParam accepts string or content-block array. Only a
        // single text block is admitted here; tools and attachments stay denied.
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]], blocks.count == 1,
              blocks[0]["type"] as? String == "text" else { return nil }
        return blocks[0]["text"] as? String
    }

    private static func absentOrEmpty(_ value: Any?) -> Bool {
        guard let value else { return true }
        return (value as? [Any])?.isEmpty == true
    }

    /// A result's denials, each naming Glob, Grep or Read, no more than one
    /// turn's calls. Judged by the tool's name alone: the wire is not proved
    /// to announce every denied call first.
    private static func deniesOnlyReads(_ value: Any?) -> Bool {
        guard let denials = value as? [Any], denials.count <= maximumGrantedToolUses else { return false }
        return denials.allSatisfy { entry in
            guard let denial = entry as? [String: Any], let name = denial["tool_name"] as? String else { return false }
            return ClaudeTextOnlyRequest.readToolNames.contains(name)
        }
    }

    /// An unknown event is ignorable only when every label identifies
    /// informational metadata and every field belongs to this reviewed, flat
    /// schema. Exact session correlation is mandatory because an unscoped frame
    /// cannot be distinguished from another concurrent CLI operation.
    private static func isInformationOnlyUnknown(_ root: [String: Any], type: String,
                                                 request: ClaudeTextOnlyRequest) -> Bool {
        let knownTypes: Set<String> = ["keep_alive", "command_lifecycle", "user", "stream_event",
                                       "rate_limit_event", "assistant", "result", "tool_progress"]
        let label: String
        if type == "system" {
            guard let subtype = root["subtype"] as? String,
                  !["init", "status", "api_retry"].contains(subtype) else { return false }
            label = subtype
        } else {
            guard !knownTypes.contains(type) else { return false }
            label = type
        }
        guard isInformationalLabel(label), root.count <= 24,
              let rawSession = root["session_id"], uuidString(rawSession) == request.sessionID else { return false }
        if let rawSubtype = root["subtype"] {
            guard let subtype = rawSubtype as? String, isInformationalLabel(subtype) else { return false }
        }
        for key in ["phase", "level", "category", "source"] {
            if let rawValue = root[key] {
                guard let value = rawValue as? String, isNonReservedInformationValue(value) else { return false }
            }
        }
        if let rawEventID = root["uuid"] {
            guard uuidString(rawEventID) != nil else { return false }
        }
        for (key, value) in root {
            guard isInformationOnlyKey(key), isFlatBoundedScalar(value) else { return false }
        }
        return true
    }

    private static func isInformationalLabel(_ value: String) -> Bool {
        guard let normalized = normalizedASCIIIdentifier(value), normalized.count <= 64 else { return false }
        let informationMarkers = ["info", "notice", "metadata", "telemetry", "progress", "status", "update",
                                  "version", "diagnostic", "heartbeat", "metric"]
        return informationMarkers.contains(where: normalized.contains)
            && !reservedInformationFamilies.contains(where: normalized.contains)
    }

    private static func isNonReservedInformationValue(_ value: String) -> Bool {
        guard let normalized = normalizedASCIIIdentifier(value), normalized.count <= 64 else { return false }
        return !reservedInformationFamilies.contains(where: normalized.contains)
    }

    private static let reservedInformationFamilies = [
        "assistant", "user", "result", "control", "tool", "hook", "permission",
        "auth", "credential", "secret", "token", "apikey", "password", "account",
        "subscription", "mcp", "plugin", "command", "exec", "action", "request",
        "response", "input", "output", "stream", "ratelimit", "billing", "usage",
        "cost", "model", "init", "session", "error", "failure", "failed", "retry",
        "cancel", "denial", "denied", "approval", "complete", "completion", "terminal",
        "stop", "message", "content"
    ]

    private static func isInformationOnlyKey(_ value: String) -> Bool {
        let reviewedKeys: Set<String> = [
            "type", "subtype", "session_id", "uuid", "sequence", "phase", "level", "version",
            "available", "active", "timestamp", "category", "source", "progress", "percent",
            "current", "total"
        ]
        return reviewedKeys.contains(value)
    }

    private static func isFlatBoundedScalar(_ value: Any) -> Bool {
        if value is NSNull || value is NSNumber { return true }
        if let string = value as? String { return string.utf8.count <= 1_024 }
        return false
    }

    private static func normalizedASCIIIdentifier(_ value: String) -> String? {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 48...57, 97...122: result.append(Character(UnicodeScalar(byte)))
            case 65...90: result.append(Character(UnicodeScalar(byte + 32)))
            case 45, 46, 95: continue
            default: return nil
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func uuidString(_ value: Any) -> UUID? {
        (value as? String).flatMap(UUID.init(uuidString:))
    }

    /// Bound nesting before Foundation allocates an object graph. Quoted braces
    /// and escaped quotes are content; they never increase structural depth.
    private static func boundedJSON(_ data: Data) -> Bool {
        var quoted = false, escaped = false
        var depth = 0
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; if depth > 24 { return false } }
            else if byte == 125 || byte == 93 { depth -= 1; if depth < 0 { return false } }
        }
        return !quoted && depth == 0
    }

    /// Whether any string in the line opens with U+FEFF, written raw or
    /// escaped. Foundation drops one such mark from the start of every string,
    /// keys included, where the CLI and a node server keep it, so a line that
    /// has one is not read here as it was sent. Quoted and escaped bytes are
    /// tracked as in `boundedJSON`, so a mark after an escaped quote, which
    /// both sides keep, is not counted.
    static func opensAStringWithByteOrderMark(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var quoted = false, escaped = false
        for (index, byte) in bytes.enumerated() {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            guard byte == 34 else { continue }
            quoted = true
            let next = bytes[(index + 1)...].prefix(6)
            if next.starts(with: [0xEF, 0xBB, 0xBF]) { return true }
            // `\uFEFF`, in either case.
            if next.count == 6, next.starts(with: [92, 117]),
               String(decoding: next.dropFirst(2), as: UTF8.self).lowercased() == "feff" { return true }
        }
        return false
    }

    /// The announced built-ins must be exactly the granted ones; every other
    /// announced name must sit in one of this turn's own selected namespaces.
    static func declaredToolsMatch(_ declared: [String], granted: Set<String>,
                                   request: ClaudeTextOnlyRequest) -> Bool {
        guard Set(declared).count == declared.count else { return false }
        // The app server's tools are announced exactly as the turn is offered them.
        let appTools = [ClaudeTextHirePolicy.qualifiedToolName, ClaudeTextWorkerPolicy.qualifiedToolName,
                        ClaudeTextScreenHandoffPolicy.qualifiedToolName, ClaudeTextSelfSetupPolicy.qualifiedToolName]
        for tool in appTools {
            guard declared.contains(tool) == request.appServerToolNames.contains(tool) else { return false }
        }
        let connectorNames = declared.filter { $0.hasPrefix("mcp__") && !appTools.contains($0) }
        guard Set(declared).subtracting(connectorNames).subtracting(appTools) == granted else { return false }
        guard let access = request.connectorAccess else { return connectorNames.isEmpty }
        guard !connectorNames.isEmpty, connectorNames.count <= maximumDeclaredConnectorTools else { return false }
        return connectorNames.allSatisfy(access.admitsToolName)
    }

    /// One announced entry per selected server, by name, each connected.
    static func declaredServersMatch(_ servers: [Any], request: ClaudeTextOnlyRequest) -> Bool {
        // The selected connectors, and the app's hire server on a turn that
        // carries it; a connector could never share its name and still pass,
        // because the count below would come out one short.
        let connectorNames = request.connectorAccess?.servers.map(\.name) ?? []
        let expected = Set(connectorNames + (request.carriesAppServer ? [ClaudeTextHirePolicy.serverName] : []))
        guard servers.count == connectorNames.count + (request.carriesAppServer ? 1 : 0),
              expected.count == servers.count else { return false }
        var seen = Set<String>()
        for entry in servers {
            guard let object = entry as? [String: Any],
                  let name = object["name"] as? String, expected.contains(name),
                  object["status"] as? String == "connected",
                  seen.insert(name).inserted else { return false }
        }
        return true
    }

    /// The agents the CLI may announce: none, or on a work turn exactly the
    /// one helper the command defined by name. Any other name is an agent
    /// loaded from a folder.
    static func declaredAgentsMatch(_ agents: [Any], request: ClaudeTextOnlyRequest) -> Bool {
        let expected = request.grantsWork ? [ClaudeTextHelperPolicy.agentType] : []
        return agents.count == expected.count && agents.compactMap { $0 as? String } == expected
    }

    /// A bound on the connector tools one turn may announce, across all of its
    /// servers together, so a replaced or hostile server cannot flood the turn's
    /// vocabulary. Over it, the turn fails at start. The browser alone announces
    /// twenty-nine tools, and every connector role at once announces
    /// ninety-nine; a tool counts as announced even when its card would refuse
    /// it. A new connector means sizing this bound again.
    static let maximumDeclaredConnectorTools = 100
}

extension ClaudeTextOnlyFailure: Error {}

struct ClaudeTextOnlyRejection: Error, Equatable {
    let failure: ClaudeTextOnlyFailure
    let code: ClaudeTextOnlyDiagnosticCode

}
