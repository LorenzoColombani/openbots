import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

private func modelCatalogFrame() throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: ["type": "control_response", "response": [
        "request_id": ClaudeModelDiscoveryCommand.requestID, "subtype": "success",
        "response": ["account": ["email": "must-never-be-published@example.invalid"],
                     "models": [["value": "sonnet", "resolvedModel": "claude-sonnet-5-5", "displayName": "Sonnet",
                                 "supportsEffort": true, "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]]]]
    ]])
    data.append(10)
    return data
}

@Suite("Initialize-only model discovery")
struct ClaudeModelCatalogDiscoveryTests {
    @Test("The sanitized real CLI 2.1.286 catalog yields four canonical subscription choices")
    func recordedCatalog() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/model-catalog/claude-2.1.286.initialize.json")
        let catalog = try ClaudeModelCatalogSnapshot.parse(modelsJSON: Data(contentsOf: file), checkedAt: Date())
        #expect(Set(catalog.models.map(\.id)) == ["claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5-5", "claude-haiku-4-5-20251001"])
        #expect(catalog.model("sonnet")?.efforts == ClaudeModelPolicy.efforts)
        #expect(catalog.model("haiku")?.efforts == [])
        #expect(catalog.model("sonnet")?.contextTokens == nil)
        #expect(catalog.model("default")?.id == catalog.model("opus")?.id)
    }

    @Test("The observed 2.1.300 Fable alias no longer rejects the entire live catalog")
    func currentRecordedCatalog() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/model-catalog/claude-2.1.300.initialize.json")
        // Only validated model identifiers/aliases and known effort fields were
        // retained from the initialize-only probe; display labels are normalized.
        let models = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        var frame = try JSONSerialization.data(withJSONObject: ["type": "control_response", "response": [
            "request_id": ClaudeModelDiscoveryCommand.requestID, "subtype": "success", "response": ["models": models]
        ]])
        frame.append(10)
        var parser = ClaudeModelCatalogWireParser()
        let parsed = try parser.append(frame)
        let catalog = try #require(parsed)
        #expect(catalog.isLive)
        #expect(catalog.models.count == 4)
        #expect(catalog.model("fable")?.id == "claude-fable-5-1")
        #expect(catalog.model("haiku")?.id == "claude-haiku-5-5")
        #expect(catalog.model("sonnet")?.id == "claude-sonnet-5-5")
        #expect(catalog.model("haiku")?.efforts == ClaudeModelPolicy.efforts)
        #expect(catalog.model("haiku")?.contextTokens == nil)
        #expect(catalog.model("claude-haiku-4-5-20251001") == nil)
        let template = try textOnlyTestRequest()
        let request = try ClaudeTextOnlyRequest(target: template.target, runID: template.runID,
            sessionID: template.sessionID, messageID: template.messageID, text: template.text,
            systemPrompt: template.systemPrompt, model: "haiku", modelCatalog: catalog)
        #expect(request.expectedResolvedModel == "claude-haiku-5-5")
        #expect(request.executionRequest.selection.model == "haiku")
    }

    @Test("Discovery sends precisely one initialize request with empty hooks and no user input")
    func commandHasNoTurn() throws {
        let input = ClaudeModelDiscoveryCommand.input
        let frame = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
        #expect(frame["type"] as? String == "control_request")
        let request = try #require(frame["request"] as? [String: Any])
        #expect(request["subtype"] as? String == "initialize")
        #expect((request["hooks"] as? [String: Any])?.isEmpty == true)
        #expect(frame["message"] == nil)
        let arguments = ClaudeModelDiscoveryCommand.arguments
        for flag in ["--safe-mode", "--restricted", "--no-session-persistence", "--no-chrome", "--disable-slash-commands", "--strict-mcp-config"] {
            #expect(arguments.contains(flag))
        }
        #expect(arguments[try #require(arguments.firstIndex(of: "--tools")) + 1] == "")
        #expect(arguments[try #require(arguments.firstIndex(of: "--disallowedTools")) + 1] == "*")
        #expect(!arguments.contains("--system-prompt"))
    }

    @Test("Only the bounded matching initialize response yields a sanitized model snapshot")
    func wireExtraction() throws {
        let data = try modelCatalogFrame()
        var parser = ClaudeModelCatalogWireParser()
        #expect(try parser.append(data.prefix(19)) == nil)
        let parsed = try parser.append(data.dropFirst(19))
        let catalog = try #require(parsed)
        #expect(catalog.model("sonnet")?.id == "claude-sonnet-5-5")
        #expect(catalog.models.count == 1)
        #expect(!String(describing: catalog).contains("must-never-be-published"))
        for bad in ["{\"type\":\"user\"}\n", "{\"type\":\"control_request\"}\n",
                    "{\"type\":\"control_response\",\"response\":{\"request_id\":\"other\",\"subtype\":\"success\"}}\n"] {
            var rejected = ClaudeModelCatalogWireParser()
            #expect(throws: (any Error).self) { try rejected.append(Data(bad.utf8)) }
        }
        var oversized = ClaudeModelCatalogWireParser()
        #expect(throws: (any Error).self) { try oversized.append(Data(repeating: 32, count: 1_048_577)) }
    }

    @Test("Failure categories distinguish protocol framing from catalog content without retaining either")
    func failureCategories() throws {
        let cases: [(String, ClaudeModelCatalogDiscoveryFailure)] = [
            ("private invalid bytes\n", .invalidFrame),
            ("{\"type\":\"system\",\"private\":\"never report this\"}\n", .unexpectedFrame),
            ("{\"type\":\"control_response\",\"response\":{\"request_id\":\"private-other\"}}\n", .responseMismatch)
        ]
        for (frame, expected) in cases {
            var parser = ClaudeModelCatalogWireParser()
            #expect(throws: expected) { try parser.append(Data(frame.utf8)) }
        }
    }

    @Test("The native discovery failure observer receives a fixed code rather than provider content")
    func nativeFailureDiagnostic() async throws {
        let fixture = try ClaudeConnectionFixture(body: """
        IFS= read -r line
        printf '%s\\n' '{"type":"system","private":"never report this"}'
        /bin/sleep 30
        """)
        defer { fixture.remove() }
        let codes = CatalogFailureRecorder()
        let catalog = await NativeClaudeModelCatalogDiscoverer(testTimeout: 3, diagnostic: { codes.append($0) })
            .discover(target: fixture.target)
        #expect(catalog == nil)
        #expect(codes.values == [.unexpectedFrame])
    }

    @Test("A synthetic child receives only the handshake and is stopped after returning models")
    func nativeTransportHasNoUserMessage() async throws {
        let encoded = try modelCatalogFrame().base64EncodedString()
        let fixture = try ClaudeConnectionFixture(body: """
        IFS= read -r line
        printf '%s' "$line" > received-handshake
        printf '%s' '\(encoded)' | /usr/bin/base64 -D
        /bin/sleep 30
        """)
        defer { fixture.remove() }
        let catalog = await NativeClaudeModelCatalogDiscoverer().discover(target: fixture.target)
        #expect(catalog?.model("sonnet")?.id == "claude-sonnet-5-5")
        let received = try Data(contentsOf: fixture.target.workingDirectoryURL.appending(path: "received-handshake"))
        #expect(received == ClaudeModelDiscoveryCommand.input.dropLast())
    }

    @Test("An unresponsive synthetic discovery child is bounded and cancellation never yields a catalog")
    func boundedTransport() async throws {
        let fixture = try ClaudeConnectionFixture(body: "/bin/sleep 30")
        defer { fixture.remove() }
        let result = await NativeClaudeModelCatalogDiscoverer(testTimeout: 0.1).discover(target: fixture.target)
        #expect(result == nil)
        let task = Task { await NativeClaudeModelCatalogDiscoverer().discover(target: fixture.target) }
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test("A newly discovered alias is frozen and accepts the CLI's new Sonnet result")
    func liveAliasDoesNotUseTheOldStaticResolution() throws {
        var parser = ClaudeModelCatalogWireParser()
        let parsed = try parser.append(modelCatalogFrame())
        let catalog = try #require(parsed)
        let template = try textOnlyTestRequest()
        let request = try ClaudeTextOnlyRequest(target: template.target, runID: template.runID,
            sessionID: template.sessionID, messageID: template.messageID, text: template.text,
            systemPrompt: template.systemPrompt, model: "sonnet", effort: "xhigh", modelCatalog: catalog)
        #expect(request.expectedResolvedModel == "claude-sonnet-5-5")
        #expect(request.executionRequest.selection.resolvedModel == "claude-sonnet-5-5")
        var stream = ClaudeTextOnlyStream(request: request)
        _ = try stream.consume(textOnlyTestInit(request, override: ["model": "claude-sonnet-5-5[1m]"])
            + textOnlyTestReplay(request)
            + textOnlyTestResult(request, override: ["modelUsage": ["claude-sonnet-5-5[1m]": [:]]]), onEvent: { _ in })
        #expect(stream.finish(exitCode: 0) == .success(.init(sessionID: request.sessionID,
            actualModel: "claude-sonnet-5-5[1m]", text: "Hello back", confirmedActualModel: "claude-sonnet-5-5[1m]")))
    }
}

private final class CatalogFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ClaudeModelCatalogDiscoveryFailure] = []
    func append(_ value: ClaudeModelCatalogDiscoveryFailure) { lock.withLock { recorded.append(value) } }
    var values: [ClaudeModelCatalogDiscoveryFailure] { lock.withLock { recorded } }
}
