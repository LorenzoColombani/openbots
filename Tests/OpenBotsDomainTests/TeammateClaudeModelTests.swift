import Foundation
import Testing
@testable import OpenBotsDomain

struct TeammateClaudeModelTests {
    @Test("Old teammate JSON without a model keeps the original Sonnet launch")
    func missingModelDecodesWithoutUpgrade() throws {
        let original = try teammate()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "claudeModel")
        json.removeValue(forKey: "claudeEffort")
        json.removeValue(forKey: "claudeContextWindow")
        let decoded = try JSONDecoder().decode(Teammate.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == original)
        #expect(decoded.claudeModel == nil)
        #expect(decoded.requestedClaudeModel == "sonnet")
        #expect(decoded.claudeEffort == nil)
        #expect(decoded.requestedClaudeEffort == "default")
        #expect(decoded.claudeContextWindow == nil)
        #expect(decoded.requestedClaudeContextWindow == "default")
    }

    @Test("Unknown saved model strings survive Codable without normalization", arguments: ["future-model-v9[1m]", " Retired Model 🦉 ", ""])
    func savedModelRemainsExact(model: String) throws {
        var original = try teammate()
        original.claudeModel = model
        original.claudeEffort = model
        original.claudeContextWindow = model
        let decoded = try JSONDecoder().decode(Teammate.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.requestedClaudeModel == model)
        #expect(decoded.requestedClaudeEffort == model)
        #expect(decoded.requestedClaudeContextWindow == model)
    }

    @Test("Effort policy distinguishes compatible models and CLI defaults")
    func effortCompatibilityAndDefaultPolicy() {
        #expect(ClaudeEffortPolicy.supportedValues(for: "claude-haiku-4-5-20251001").isEmpty)
        #expect(ClaudeEffortPolicy.defaultValue(for: "claude-haiku-4-5-20251001") == nil)
        #expect(ClaudeEffortPolicy.supportedValues(for: "claude-sonnet-4-6") == ["low", "medium", "high", "max"])
        #expect(!ClaudeEffortPolicy.supportedValues(for: "claude-opus-4-6").contains("xhigh"))
        #expect(ClaudeEffortPolicy.defaultValue(for: "claude-opus-4-7") == "xhigh")
        #expect(ClaudeEffortPolicy.defaultValue(for: "sonnet") == "high")
        #expect(ClaudeEffortPolicy.supportedValues(for: "claude-fable-5").contains("xhigh"))
        #expect(!ClaudeEffortPolicy.supportedValues(for: "claude-fable-5").contains("ultracode"))
        #expect(ClaudeEffortPolicy.supportedValues(for: "unknown").isEmpty)
    }

    @Test("Context policy distinguishes ordinary windows, explicit long support, and unknown models")
    func contextWindowCompatibilityAndDefaultPolicy() {
        #expect(ClaudeContextWindowPolicy.supportedValues(for: "claude-sonnet-4-6") == ["default", "standard", "long"])
        #expect(ClaudeContextWindowPolicy.defaultTokenLimit(for: "claude-sonnet-4-6") == 200_000)
        #expect(ClaudeContextWindowPolicy.defaultTokenLimit(for: "claude-opus-4-6") == 1_000_000)
        #expect(ClaudeContextWindowPolicy.defaultTokenLimit(for: "sonnet") == 1_000_000)
        #expect(ClaudeContextWindowPolicy.supportedValues(for: "claude-haiku-4-5-20251001") == ["default", "standard"])
        #expect(ClaudeContextWindowPolicy.defaultTokenLimit(for: "claude-haiku-4-5-20251001") == 200_000)
        #expect(!ClaudeContextWindowPolicy.supportedValues(for: "claude-opus-4-5-20251101").contains("long"))
        #expect(ClaudeContextWindowPolicy.supportedValues(for: "unknown") == ["default"])
        #expect(ClaudeContextWindowPolicy.defaultTokenLimit(for: "unknown") == nil)
    }

    private func teammate() throws -> Teammate {
        let now = Date(timeIntervalSince1970: 1_000)
        return try Teammate(id: TeammateID(UUID()), profile: TeammateProfile(displayName: "Model QA", role: "Research"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 1,
                silhouette: "round", paletteToken: "sky", eyeDialect: "calm", nonColorIdentityCue: "crown",
                accessibleIdentityDescription: "Round creature"), createdAt: now, updatedAt: now)
    }
}
