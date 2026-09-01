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
    static let maximumReplyBytes = 262_144
    /// A short metadata burst can straddle several transport stages. Thirty-two
    /// leaves room for that drift while preventing an unbounded stream of
    /// unreviewed frames from hiding the absence of terminal proof.
    static let maximumIgnoredInformationalEvents = 32
    private let request: ClaudeTextOnlyRequest
    private var pending = Data()
    private var totalBytes = 0
    private var model: String?
    private var responseModel: String?
    private var confirmedModel: String?
    private var acknowledged = false
    private var text = ""
    private var finalText: String?
    private var completed = false
    private(set) var ignoredInformationalEventCount = 0

    init(request: ClaudeTextOnlyRequest) { self.request = request }

    /// Deliver each fully validated line immediately. A later line in the same
    /// read may fail, but cannot retract its already verified prefix. The caller
    /// must stop consuming after any error; offending data is never delivered.
    mutating func consume(_ bytes: Data, onEvent: (ClaudeTextOnlyEvent) -> Void) throws {
        let admittedCount = min(bytes.count, Self.maximumOutputBytes - totalBytes)
        totalBytes += admittedCount
        pending.append(bytes.prefix(admittedCount))
        while let newline = pending.firstIndex(of: 0x0a) {
            if newline == pending.startIndex {
                // Empty framing lines carry no event. Consume a run together
                // rather than shifting the same bounded buffer once per byte.
                let next = pending.firstIndex(where: { $0 != 0x0a }) ?? pending.endIndex
                pending.removeSubrange(..<next)
                continue
            }
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            guard line.count <= Self.maximumLineBytes else { throw reject(.outputLimitExceeded, .outputLimitExceeded) }
            for event in try parse(line) { onEvent(event) }
        }
        guard pending.count <= Self.maximumLineBytes else { throw reject(.outputLimitExceeded, .outputLimitExceeded) }
        guard admittedCount == bytes.count else { throw reject(.outputLimitExceeded, .outputLimitExceeded) }
    }

    func finish(exitCode: Int32, onDiagnostic: (ClaudeTextOnlyDiagnosticCode) -> Void = { _ in }) -> ClaudeTextOnlyResult {
        guard exitCode == 0 else { onDiagnostic(.processFailed); return .failed(.processFailed) }
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
        if let parent = root["parent_tool_use_id"], !(parent is NSNull) { throw reject(.invalidStream, .nestedToolEvent) }
        // The official CLI's raw transport includes frames the SDK hides.
        // Neither heartbeat nor queue lifecycle proves initialization, input
        // acceptance or a completed reply, including when it follows a result.
        if type == "keep_alive" {
            guard root.count == 1 else { throw reject(.invalidStream, .invalidKeepAlive) }
            return []
        }
        if type == "command_lifecycle" {
            guard uuid(root["command_uuid"]) == request.messageID,
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
        if completed {
            guard Self.isInformationOnlyUnknown(root, type: type, request: request) else {
                throw reject(.invalidStream, .eventAfterResult)
            }
            try ignoreInformationalEvent(or: reject(.invalidStream, .eventAfterResult))
            return []
        }
        switch type {
        case "system":
            if root["subtype"] as? String == "api_retry" { throw reject(.providerFailed, .providerFailure) }
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
                if let mode = root["permissionMode"], mode as? String != "dontAsk" {
                    throw reject(.unsafeInitialization, .statusPermissionMismatch)
                }
                return []
            }
            if root["subtype"] as? String != "init" {
                guard Self.isInformationOnlyUnknown(root, type: type, request: request) else {
                    throw reject(.unsafeInitialization, .unexpectedSystemEvent)
                }
                try ignoreInformationalEvent(or: reject(.unsafeInitialization, .unexpectedSystemEvent))
                return []
            }
            guard model == nil else { throw reject(.unsafeInitialization, .duplicateInitialization) }
            guard uuid(root["session_id"]) == request.sessionID else { throw reject(.unsafeInitialization, .initializationSessionMismatch) }
            guard let tools = root["tools"] as? [Any], tools.isEmpty else { throw reject(.unsafeInitialization, .initializationToolsInvalid) }
            guard let servers = root["mcp_servers"] as? [Any], servers.isEmpty,
                  Self.absentOrEmpty(root["mcp_server_errors"]) else { throw reject(.unsafeInitialization, .initializationMCPInvalid) }
            guard let plugins = root["plugins"] as? [Any], plugins.isEmpty,
                  Self.absentOrEmpty(root["plugin_errors"]) else { throw reject(.unsafeInitialization, .initializationPluginsInvalid) }
            guard root["permissionMode"] as? String == "dontAsk" else { throw reject(.unsafeInitialization, .initializationPermissionMismatch) }
            guard root["apiKeySource"] as? String == "none" else { throw reject(.unsafeInitialization, .initializationKeySourceInvalid) }
            guard let actual = root["model"] as? String,
                  ClaudeTextOnlyRequest.normalizedReportedModel(actual) == request.expectedResolvedModel else { throw reject(.unsafeInitialization, .initializationModelInvalid) }
            model = actual
            return [.initialized(sessionID: request.sessionID, actualModel: actual)]
        case "user":
            guard !acknowledged else { throw reject(.invalidStream, .replayDuplicate) }
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
            guard model != nil, uuid(root["session_id"]) == request.sessionID,
                  let event = root["event"] as? [String: Any], let kind = event["type"] as? String else {
                throw reject(.invalidStream, .responseMismatch)
            }
            switch kind {
            case "content_block_start":
                guard let block = event["content_block"] as? [String: Any],
                      let kind = block["type"] as? String, ["text", "thinking", "redacted_thinking"].contains(kind) else {
                    throw reject(.invalidStream, .responseMismatch)
                }
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any], let kind = delta["type"] as? String else {
                    throw reject(.invalidStream, .responseMismatch)
                }
                if kind == "text_delta" {
                    guard let addition = delta["text"] as? String,
                          addition.utf8.count <= Self.maximumReplyBytes - text.utf8.count else {
                        throw reject(.outputLimitExceeded, .outputLimitExceeded)
                    }
                    text += addition
                    return [.textSnapshot(text)]
                }
                guard ["thinking_delta", "signature_delta"].contains(kind) else { throw reject(.invalidStream, .responseMismatch) }
            case "message_start":
                guard let message = event["message"] as? [String: Any], message["role"] as? String == "assistant",
                      let actual = message["model"] as? String,
                      let resolved = ClaudeTextOnlyRequest.normalizedReportedModel(actual),
                      responseModel == nil || responseModel == resolved,
                      let content = message["content"] as? [Any], content.isEmpty else { throw reject(.invalidStream, .responseMismatch) }
                responseModel = resolved
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String,
                   !["end_turn", "max_tokens", "stop_sequence"].contains(reason) { throw reject(.invalidStream, .responseMismatch) }
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
            guard model != nil, uuid(root["session_id"]) == request.sessionID,
                  let message = root["message"] as? [String: Any], message["role"] as? String == "assistant",
                  let actual = message["model"] as? String,
                  let resolved = ClaudeTextOnlyRequest.normalizedReportedModel(actual),
                  responseModel == nil || responseModel == resolved,
                  let blocks = message["content"] as? [[String: Any]], blocks.count <= 256 else {
                throw reject(.invalidStream, .responseMismatch)
            }
            for block in blocks {
                guard let kind = block["type"] as? String,
                      ["text", "thinking", "redacted_thinking"].contains(kind) else { throw reject(.invalidStream, .responseMismatch) }
            }
            responseModel = resolved
            // Stream deltas own partials. The terminal result owns the completed
            // reply, so the full assistant event must not double-append its text.
            return []
        case "result":
            guard model != nil, uuid(root["session_id"]) == request.sessionID else { throw reject(.invalidStream, .responseMismatch) }
            guard root["subtype"] as? String == "success", Self.absentOrEmpty(root["permission_denials"]),
                  let error = root["is_error"] as? NSNumber,
                  CFGetTypeID(error) == CFBooleanGetTypeID(), !error.boolValue,
                  let result = root["result"] as? String, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw reject(.providerFailed, .providerFailure)
            }
            guard result.utf8.count <= Self.maximumReplyBytes else { throw reject(.outputLimitExceeded, .outputLimitExceeded) }
            if let rawUsage = root["modelUsage"] {
                // Official stream-json may announce a retired/remapped name at
                // init. Its successful result.modelUsage is the actual-model
                // authority; it must still agree with any assistant response.
                guard let usage = rawUsage as? [String: Any], usage.count == 1,
                      let actual = usage.keys.first,
                      let resolved = ClaudeTextOnlyRequest.normalizedReportedModel(actual),
                      usage[actual] is [String: Any], responseModel == nil || responseModel == resolved else {
                    throw reject(.unsafeInitialization, .finalModelMismatch)
                }
                confirmedModel = actual
            }
            finalText = result
            completed = true
            return [.textSnapshot(result)]
        default:
            guard Self.isInformationOnlyUnknown(root, type: type, request: request) else {
                throw reject(.invalidStream, .unexpectedEvent)
            }
            try ignoreInformationalEvent(or: reject(.invalidStream, .unexpectedEvent))
            return []
        }
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

    /// An unknown event is ignorable only when every label identifies
    /// informational metadata and every field belongs to this reviewed, flat
    /// schema. Exact session correlation is mandatory because an unscoped frame
    /// cannot be distinguished from another concurrent CLI operation.
    private static func isInformationOnlyUnknown(_ root: [String: Any], type: String,
                                                 request: ClaudeTextOnlyRequest) -> Bool {
        let knownTypes: Set<String> = ["keep_alive", "command_lifecycle", "user", "stream_event",
                                       "rate_limit_event", "assistant", "result"]
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
}

extension ClaudeTextOnlyFailure: Error {}

struct ClaudeTextOnlyRejection: Error, Equatable {
    let failure: ClaudeTextOnlyFailure
    let code: ClaudeTextOnlyDiagnosticCode
}
