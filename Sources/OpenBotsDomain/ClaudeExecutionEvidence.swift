import Foundation

public enum ClaudeExecutionEvidenceError: Error, Equatable, Sendable {
    case invalidSelection, invalidLaunchModel, invalidInitialization, invalidResult
}

/// Frozen execution metadata, not a replacement for the user's saved preferences.
/// Unknown saved profile values stay in Teammate; they cannot become launch proof.
public struct ClaudeExecutionSelection: Codable, Equatable, Sendable {
    public static let maximumModelBytes = 200
    private static let suffixedModels: Set<String> = ["claude-opus-4-6", "claude-sonnet-4-6"]

    public let model: String
    public let effort: String
    public let contextWindow: String
    /// Frozen alias resolution at launch. Nil on older records, whose bundled
    /// alias mapping remains stable even after the live catalog changes.
    public let resolvedModel: String?

    public init(model: String, effort: String, contextWindow: String, resolvedModel: String? = nil) {
        self.model = model; self.effort = effort; self.contextWindow = contextWindow
        self.resolvedModel = resolvedModel
    }

    public var expectedResolvedModel: String { resolvedModel ?? ClaudeModelPolicy.bundled.model(model)?.id ?? model }
    public var launchModel: String {
        contextWindow == "long" && Self.suffixedModels.contains(model) ? model + "[1m]" : model
    }

    @discardableResult
    public func validated() throws -> Self {
        guard model.utf8.count <= Self.maximumModelBytes, effort.utf8.count <= 16, contextWindow.utf8.count <= 16,
              ClaudeModelPolicy.isModelIdentity(model) || ClaudeModelPolicy.aliases.contains(model),
              resolvedModel == nil || ClaudeModelPolicy.isModelIdentity(resolvedModel!),
              resolvedModel == nil || resolvedModel == model || ClaudeModelPolicy.aliases.contains(model),
              effort == "default" || ClaudeModelPolicy.efforts.contains(effort),
              ["default", "standard", "long"].contains(contextWindow) else {
            throw ClaudeExecutionEvidenceError.invalidSelection
        }
        return self
    }

    /// Suffix normalization proves only an identity match, never context capacity.
    public static func normalizedReportedModel(_ value: String) -> String? {
        ClaudeModelPolicy.normalizedIdentity(value)
    }

    private enum CodingKeys: String, CodingKey { case model, effort, contextWindow, resolvedModel }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(model: try values.decode(String.self, forKey: .model),
                  effort: try values.decode(String.self, forKey: .effort),
                  contextWindow: try values.decode(String.self, forKey: .contextWindow),
                  resolvedModel: try values.decodeIfPresent(String.self, forKey: .resolvedModel))
        try validated()
    }
    public func encode(to encoder: any Encoder) throws {
        try validated()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(model, forKey: .model)
        try values.encode(effort, forKey: .effort)
        try values.encode(contextWindow, forKey: .contextWindow)
        try values.encodeIfPresent(resolvedModel, forKey: .resolvedModel)
    }
}

/// What the app prepared for one fresh CLI session. Its presence alone does not
/// prove that a process started, input was accepted, or settings were effective.
public struct ClaudeExecutionRequest: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let selection: ClaudeExecutionSelection
    public let launchModel: String

    public init(sessionID: UUID, selection: ClaudeExecutionSelection, launchModel: String) {
        self.sessionID = sessionID; self.selection = selection; self.launchModel = launchModel
    }

    @discardableResult
    public func validated() throws -> Self {
        try selection.validated()
        guard launchModel.utf8.count <= ClaudeExecutionSelection.maximumModelBytes + 4,
              launchModel.utf8.elementsEqual(selection.launchModel.utf8) else {
            throw ClaudeExecutionEvidenceError.invalidLaunchModel
        }
        return self
    }

    private enum CodingKeys: String, CodingKey { case sessionID, selection, launchModel }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sessionID: try values.decode(UUID.self, forKey: .sessionID),
                  selection: try values.decode(ClaudeExecutionSelection.self, forKey: .selection),
                  launchModel: try values.decode(String.self, forKey: .launchModel))
        try validated()
    }
    public func encode(to encoder: any Encoder) throws {
        try validated()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encode(selection, forKey: .selection)
        try values.encode(launchModel, forKey: .launchModel)
    }
}

public enum ClaudeExecutionModelStatus: String, Codable, Equatable, Sendable {
    case notObserved, startupObserved, resultMatches, resultDiffers
}

/// Only admitted protocol fields. A result model is not proof of effective
/// effort, context capacity, remaining allowance, billing, or the model's claims.
/// The repository must bind this value to its exact acknowledged successful run
/// before treating resultModel as successful-result evidence.
public struct ClaudeExecutionEvidence: Codable, Equatable, Sendable {
    public let request: ClaudeExecutionRequest
    public let initializedModel: String?
    public let resultModel: String?
    /// The Claude Code version that ran the turn, as its init frame named it
    /// (2.1.272 and later say so); absent from records written before it.
    public let claudeCodeVersion: String?

    public init(request: ClaudeExecutionRequest, initializedModel: String?, resultModel: String?,
                claudeCodeVersion: String? = nil) {
        self.request = request; self.initializedModel = initializedModel; self.resultModel = resultModel
        self.claudeCodeVersion = claudeCodeVersion
    }

    public var modelStatus: ClaudeExecutionModelStatus {
        guard (try? validated()) != nil, initializedModel != nil else { return .notObserved }
        guard let resultModel else { return .startupObserved }
        return ClaudeExecutionSelection.normalizedReportedModel(resultModel)
            == request.selection.expectedResolvedModel ? .resultMatches : .resultDiffers
    }

    @discardableResult
    public func validated() throws -> Self {
        try request.validated()
        if let initializedModel {
            guard ClaudeExecutionSelection.normalizedReportedModel(initializedModel) != nil else {
                throw ClaudeExecutionEvidenceError.invalidInitialization
            }
        }
        if let resultModel {
            guard initializedModel != nil,
                  ClaudeExecutionSelection.normalizedReportedModel(resultModel) != nil else {
                throw ClaudeExecutionEvidenceError.invalidResult
            }
        }
        return self
    }

    private enum CodingKeys: String, CodingKey { case request, initializedModel, resultModel, claudeCodeVersion }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(request: try values.decode(ClaudeExecutionRequest.self, forKey: .request),
                  initializedModel: try values.decodeIfPresent(String.self, forKey: .initializedModel),
                  resultModel: try values.decodeIfPresent(String.self, forKey: .resultModel),
                  claudeCodeVersion: try values.decodeIfPresent(String.self, forKey: .claudeCodeVersion))
        try validated()
    }
    public func encode(to encoder: any Encoder) throws {
        try validated()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(request, forKey: .request)
        try values.encodeIfPresent(initializedModel, forKey: .initializedModel)
        try values.encodeIfPresent(resultModel, forKey: .resultModel)
        try values.encodeIfPresent(claudeCodeVersion, forKey: .claudeCodeVersion)
    }
}
