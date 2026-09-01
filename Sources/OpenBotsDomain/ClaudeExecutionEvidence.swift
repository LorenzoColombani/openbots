import Foundation

public enum ClaudeExecutionEvidenceError: Error, Equatable, Sendable {
    case invalidSelection, invalidLaunchModel, invalidInitialization, invalidResult
}

/// Frozen execution metadata, not a replacement for the user's saved preferences.
/// Unknown saved profile values stay in Teammate; they cannot become launch proof.
public struct ClaudeExecutionSelection: Codable, Equatable, Sendable {
    public static let maximumModelBytes = 200
    /// Keep historical identities recordable if future launch availability changes.
    public static let recordableModels: Set<String> = [
        "sonnet", "claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-opus-5", "claude-fable-5",
        "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6",
        "claude-opus-4-5-20251101", "claude-sonnet-4-5-20250929"
    ]
    private static let suffixedModels: Set<String> = ["claude-opus-4-6", "claude-sonnet-4-6"]

    public let model: String
    public let effort: String
    public let contextWindow: String

    public init(model: String, effort: String, contextWindow: String) {
        self.model = model; self.effort = effort; self.contextWindow = contextWindow
    }

    public var expectedResolvedModel: String { model == "sonnet" ? "claude-sonnet-5" : model }
    public var launchModel: String {
        contextWindow == "long" && Self.suffixedModels.contains(model) ? model + "[1m]" : model
    }

    @discardableResult
    public func validated() throws -> Self {
        guard model.utf8.count <= Self.maximumModelBytes, effort.utf8.count <= 16, contextWindow.utf8.count <= 16,
              Self.recordableModels.contains(model),
              effort == "default" || ClaudeEffortPolicy.supportedValues(for: model).contains(effort),
              ClaudeContextWindowPolicy.supportedValues(for: model).contains(contextWindow) else {
            throw ClaudeExecutionEvidenceError.invalidSelection
        }
        return self
    }

    /// Suffix normalization proves only an identity match, never context capacity.
    public static func normalizedReportedModel(_ value: String) -> String? {
        guard value.utf8.count <= maximumModelBytes else { return nil }
        if value.hasSuffix("[1m]") {
            let base = String(value.dropLast(4))
            return suffixedModels.contains(base) ? base : nil
        }
        return value != "sonnet" && recordableModels.contains(value) ? value : nil
    }

    private enum CodingKeys: String, CodingKey { case model, effort, contextWindow }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(model: try values.decode(String.self, forKey: .model),
                  effort: try values.decode(String.self, forKey: .effort),
                  contextWindow: try values.decode(String.self, forKey: .contextWindow))
        try validated()
    }
    public func encode(to encoder: any Encoder) throws {
        try validated()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(model, forKey: .model)
        try values.encode(effort, forKey: .effort)
        try values.encode(contextWindow, forKey: .contextWindow)
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

    public init(request: ClaudeExecutionRequest, initializedModel: String?, resultModel: String?) {
        self.request = request; self.initializedModel = initializedModel; self.resultModel = resultModel
    }

    public var modelStatus: ClaudeExecutionModelStatus {
        guard (try? validated()) != nil, let initializedModel else { return .notObserved }
        guard let resultModel else { return .startupObserved }
        return ClaudeExecutionSelection.normalizedReportedModel(resultModel)
            == ClaudeExecutionSelection.normalizedReportedModel(initializedModel) ? .resultMatches : .resultDiffers
    }

    @discardableResult
    public func validated() throws -> Self {
        try request.validated()
        if let initializedModel {
            guard ClaudeExecutionSelection.normalizedReportedModel(initializedModel)
                    == request.selection.expectedResolvedModel else {
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

    private enum CodingKeys: String, CodingKey { case request, initializedModel, resultModel }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(request: try values.decode(ClaudeExecutionRequest.self, forKey: .request),
                  initializedModel: try values.decodeIfPresent(String.self, forKey: .initializedModel),
                  resultModel: try values.decodeIfPresent(String.self, forKey: .resultModel))
        try validated()
    }
    public func encode(to encoder: any Encoder) throws {
        try validated()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(request, forKey: .request)
        try values.encodeIfPresent(initializedModel, forKey: .initializedModel)
        try values.encodeIfPresent(resultModel, forKey: .resultModel)
    }
}
