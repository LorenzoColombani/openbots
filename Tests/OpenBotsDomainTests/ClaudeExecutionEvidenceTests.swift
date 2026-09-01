import Foundation
import Testing
@testable import OpenBotsDomain

@Suite("Durable Claude execution selectors and evidence")
struct ClaudeExecutionEvidenceTests {
    @Test("Frozen selectors round-trip with exact session and documented long-context launch mapping")
    func requestRoundTrip() throws {
        let selection = ClaudeExecutionSelection(model: "claude-opus-4-6", effort: "max", contextWindow: "long")
        let request = ClaudeExecutionRequest(sessionID: UUID(), selection: selection,
                                             launchModel: "claude-opus-4-6[1m]")
        #expect(try request.validated() == request)
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(ClaudeExecutionRequest.self, from: data) == request)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(root.keys) == ["sessionID", "selection", "launchModel"])
        let selectors = try #require(root["selection"] as? [String: String])
        #expect(selectors == ["model": "claude-opus-4-6", "effort": "max", "contextWindow": "long"])
    }

    @Test("A prepared request, startup observation and successful result remain different evidence")
    func evidenceStages() throws {
        let request = self.request()
        let values: [(String?, String?, ClaudeExecutionModelStatus)] = [
            (nil, nil, .notObserved),
            ("claude-sonnet-5", nil, .startupObserved),
            ("claude-sonnet-5", "claude-sonnet-5", .resultMatches),
            ("claude-sonnet-5", "claude-haiku-4-5-20251001", .resultDiffers)
        ]
        for (initialized, result, status) in values {
            let evidence = ClaudeExecutionEvidence(request: request, initializedModel: initialized, resultModel: result)
            #expect(try evidence.validated() == evidence)
            #expect(evidence.modelStatus == status)
            let decoded = try JSONDecoder().decode(ClaudeExecutionEvidence.self, from: JSONEncoder().encode(evidence))
            #expect(decoded == evidence)
            #expect(decoded.request.selection.model == "sonnet")
            #expect(decoded.request.selection.effort == "default")
            #expect(decoded.request.selection.contextWindow == "default")
        }
    }

    @Test("Long-context suffixes preserve raw reported IDs but do not add effort or capacity proof")
    func suffixIsOnlyIdentityEvidence() throws {
        let selection = ClaudeExecutionSelection(model: "claude-opus-4-6", effort: "low", contextWindow: "standard")
        let request = ClaudeExecutionRequest(sessionID: UUID(), selection: selection, launchModel: selection.launchModel)
        let evidence = ClaudeExecutionEvidence(request: request, initializedModel: "claude-opus-4-6",
                                              resultModel: "claude-opus-4-6[1m]")
        #expect(try evidence.validated().modelStatus == .resultMatches)
        #expect(evidence.resultModel == "claude-opus-4-6[1m]")
        let root = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any])
        #expect(Set(root.keys) == ["request", "initializedModel", "resultModel"])
    }

    @Test("Unsupported execution selectors fail without rewriting their raw values")
    func unavailableSelections() throws {
        let values = [
            ClaudeExecutionSelection(model: "retired-model", effort: "default", contextWindow: "default"),
            ClaudeExecutionSelection(model: "sonnet --tools Bash", effort: "default", contextWindow: "default"),
            ClaudeExecutionSelection(model: String(repeating: "x", count: 201), effort: "default", contextWindow: "default"),
            ClaudeExecutionSelection(model: "claude-sonnet-4-6", effort: "xhigh", contextWindow: "default"),
            ClaudeExecutionSelection(model: "claude-opus-5", effort: "ultracode", contextWindow: "default"),
            ClaudeExecutionSelection(model: "claude-haiku-4-5-20251001", effort: "default", contextWindow: "long"),
            ClaudeExecutionSelection(model: "sonnet", effort: "default", contextWindow: "1m")
        ]
        for selection in values {
            let original = selection
            #expect(throws: ClaudeExecutionEvidenceError.invalidSelection) { try selection.validated() }
            #expect(throws: ClaudeExecutionEvidenceError.invalidSelection) { try JSONEncoder().encode(selection) }
            #expect(selection == original)
        }
    }

    @Test("An independent launch argument cannot substitute the requested model or suffix")
    func launchModelMustMatchSelection() throws {
        for launch in ["claude-opus-5", "sonnet[1m]", "sonnet --effort max", "sonnet\0"] {
            let value = ClaudeExecutionRequest(sessionID: UUID(), selection: request().selection, launchModel: launch)
            #expect(throws: ClaudeExecutionEvidenceError.invalidLaunchModel) { try value.validated() }
        }
    }

    @Test("Malformed, uncorrelated or result-only metadata cannot acquire evidence status")
    func invalidEvidenceFailsClosed() throws {
        let values = [
            ClaudeExecutionEvidence(request: request(), initializedModel: "claude-opus-5", resultModel: nil),
            ClaudeExecutionEvidence(request: request(), initializedModel: nil, resultModel: "claude-sonnet-5"),
            ClaudeExecutionEvidence(request: request(), initializedModel: "claude-sonnet-5", resultModel: "claude-unreviewed"),
            ClaudeExecutionEvidence(request: request(), initializedModel: "claude-sonnet-5", resultModel: "sonnet"),
            ClaudeExecutionEvidence(request: request(), initializedModel: "claude-sonnet-5", resultModel: "claude-sonnet-5[1m]")
        ]
        for evidence in values {
            #expect(throws: ClaudeExecutionEvidenceError.self) { try evidence.validated() }
            #expect(throws: ClaudeExecutionEvidenceError.self) { try JSONEncoder().encode(evidence) }
            #expect(evidence.modelStatus == .notObserved)
        }
    }

    @Test("Decoding rechecks selectors, launch mapping and observed evidence rather than trusting stored JSON")
    func forgedJSONRejected() throws {
        let good = ClaudeExecutionEvidence(request: request(), initializedModel: "claude-sonnet-5", resultModel: nil)
        let root = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [String: Any])
        var wrongLaunch = root
        var requestJSON = try #require(root["request"] as? [String: Any])
        requestJSON["launchModel"] = "claude-opus-5"
        wrongLaunch["request"] = requestJSON
        var wrongInit = root; wrongInit["initializedModel"] = "claude-opus-5"
        var resultOnly = root; resultOnly.removeValue(forKey: "initializedModel"); resultOnly["resultModel"] = "claude-sonnet-5"
        for invalid in [wrongLaunch, wrongInit, resultOnly] {
            let data = try JSONSerialization.data(withJSONObject: invalid)
            #expect(throws: ClaudeExecutionEvidenceError.self) { try JSONDecoder().decode(ClaudeExecutionEvidence.self, from: data) }
        }
    }

    @Test("Legacy absence stays absent instead of manufacturing a default execution")
    func absentLegacyEvidenceIsUnknown() throws {
        struct LegacyContainer: Codable { let executionRequest: ClaudeExecutionRequest?; let executionEvidence: ClaudeExecutionEvidence? }
        let decoded = try JSONDecoder().decode(LegacyContainer.self, from: Data("{}".utf8))
        #expect(decoded.executionRequest == nil && decoded.executionEvidence == nil)
    }

    private func request() -> ClaudeExecutionRequest {
        ClaudeExecutionRequest(sessionID: UUID(),
            selection: ClaudeExecutionSelection(model: "sonnet", effort: "default", contextWindow: "default"), launchModel: "sonnet")
    }
}
