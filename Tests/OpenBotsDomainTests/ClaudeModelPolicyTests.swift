import Foundation
import Testing
@testable import OpenBotsDomain

@Suite("Subscription model catalog")
struct ClaudeModelPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func row(_ value: String = "sonnet", _ resolved: String = "claude-sonnet-5-5") -> [String: Any] {
        ["value": value, "resolvedModel": resolved, "displayName": "Sonnet",
         "description": "Provider price and private text are ignored", "supportsEffort": true,
         "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]]
    }
    private func parse(_ entries: [[String: Any]]) throws -> ClaudeModelCatalogSnapshot {
        try .parse(modelsJSON: JSONSerialization.data(withJSONObject: entries), checkedAt: now)
    }

    @Test("A new advertised Sonnet resolves its alias and has no invented context limit")
    func newModelCapabilities() throws {
        let catalog = try parse([row()])
        #expect(catalog.isLive)
        #expect(catalog.checkedAt == now)
        #expect(catalog.model("sonnet")?.id == "claude-sonnet-5-5")
        #expect(catalog.models.first?.name == "Sonnet 5.5")
        #expect(catalog.model("sonnet")?.efforts == ClaudeModelPolicy.efforts)
        #expect(catalog.model("sonnet")?.contextWindows == ["default"])
        #expect(catalog.model("sonnet")?.contextTokens == nil)
        #expect(!catalog.admittedModels.contains("claude-sonnet-5"))
    }

    @Test("Fable is admitted only when advertised and its resolved identity stays frozen in evidence")
    func advertisedFableAlias() throws {
        let catalog = try parse([row("fable", "claude-fable-5-1")])
        #expect(catalog.model("fable")?.id == "claude-fable-5-1")
        #expect(catalog.admittedModels == ["fable", "claude-fable-5-1"])
        #expect(ClaudeModelPolicy.bundled.model("fable") == nil)
        let evidence = ClaudeExecutionSelection(model: "fable", effort: "default", contextWindow: "default",
                                                 resolvedModel: "claude-fable-5-1")
        #expect(try evidence.validated() == evidence)
        #expect(evidence.expectedResolvedModel == "claude-fable-5-1")
        #expect(throws: ClaudeModelCatalogError.self) { try parse([row("unknown-alias", "claude-fable-5-1")]) }
    }

    @Test("Aliases sharing an identity deduplicate; Mythos and retired Fable never enter choices")
    func filteredAndDeduplicated() throws {
        let catalog = try parse([row("default", "claude-opus-5-5"), row("opus", "claude-opus-5-5"),
            row("claude-mythos-5-1", "claude-mythos-5-1"), row("claude-fable-5", "claude-fable-5")])
        #expect(catalog.models.count == 1)
        #expect(catalog.model("default")?.id == "claude-opus-5-5")
        #expect(catalog.model("opus")?.id == "claude-opus-5-5")
        #expect(!catalog.admittedModels.contains("claude-fable-5"))
        #expect(!catalog.admittedModels.contains { $0.contains("mythos") })
    }

    @Test("The recorded CLI 2.1.283 Fable 1m menu spelling keeps a canonical pinned choice")
    func contextSuffixInCatalogValue() throws {
        let catalog = try parse([row("claude-fable-5-1[1m]", "claude-fable-5-1")])
        #expect(catalog.models.map(\.id) == ["claude-fable-5-1"])
        #expect(!catalog.admittedModels.contains("claude-fable-5-1[1m]"))
    }

    @Test("Malformed, conflicting, unsafe and oversized lists cannot replace the fallback")
    func malformedCatalogs() throws {
        var badEffort = row(); badEffort["supportedEffortLevels"] = ["high", "shell"]
        var fakeBool = row(); fakeBool["supportsEffort"] = 1
        var badName = row(); badName["displayName"] = "Sonnet\nInjected"
        var badList = row(); badList["supportedEffortLevels"] = "high"
        let cases = [[], [row(), row()], [badEffort], [fakeBool], [badName], [badList],
            [row("sonnet", "--model")], [row("sonnet", "claude-sonnet-5;touch")],
            [row("unknown-alias", "claude-sonnet-5-5")], Array(repeating: row(), count: 65)]
        for values in cases { #expect(throws: ClaudeModelCatalogError.self) { try parse(values) } }
        #expect(throws: ClaudeModelCatalogError.self) {
            try ClaudeModelCatalogSnapshot.parse(modelsJSON: Data(repeating: 32, count: 262_145), checkedAt: now)
        }
    }

    @Test("An isolated registry falls back without altering stored preferences or another registry")
    func isolatedFallback() throws {
        let registry = ClaudeModelCatalogRegistry(), other = ClaudeModelCatalogRegistry()
        registry.replace(with: try parse([row()]))
        #expect(registry.snapshot.isLive)
        #expect(!other.snapshot.isLive)
        registry.replace(with: nil)
        #expect(registry.snapshot == ClaudeModelPolicy.bundled)
        #expect(registry.snapshot.model("sonnet")?.id == "claude-sonnet-5")
    }

    @Test("Evidence freezes the live alias and remains readable after model removal")
    func historicalEvidence() throws {
        let selection = ClaudeExecutionSelection(model: "sonnet", effort: "xhigh", contextWindow: "default",
                                                 resolvedModel: "claude-sonnet-5-5")
        let request = ClaudeExecutionRequest(sessionID: UUID(), selection: selection, launchModel: "sonnet")
        let evidence = ClaudeExecutionEvidence(request: request, initializedModel: "claude-sonnet-5-5",
                                                resultModel: "claude-sonnet-5-5")
        #expect(!ClaudeModelPolicy.bundled.admittedModels.contains("claude-sonnet-5-5"))
        let restored = try JSONDecoder().decode(ClaudeExecutionEvidence.self, from: JSONEncoder().encode(evidence))
        #expect(restored == evidence)
        #expect(restored.modelStatus == .resultMatches)
        let remapped = ClaudeExecutionEvidence(request: request, initializedModel: "claude-opus-5-5",
                                                resultModel: "claude-opus-5-5")
        #expect(try remapped.validated().modelStatus == .resultDiffers)
    }
}
