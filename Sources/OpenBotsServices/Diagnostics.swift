import Foundation

public enum DiagnosticSeverity: String, Codable, Sendable {
    case information
    case warning
    case error
}

public enum DiagnosticCategory: String, Codable, Sendable {
    case startup
    case storage
    case persistence
    case runtime
    case authorization
}

/// Deliberately excludes prompts, message bodies, file contents, paths, tokens,
/// connector payloads, and arbitrary metadata. Rich support exports are a later
/// separately redacted boundary.
public struct DiagnosticEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let occurredAt: Date
    public let severity: DiagnosticSeverity
    public let category: DiagnosticCategory
    public let code: String
    public let correlationID: UUID?

    public init(
        id: UUID,
        occurredAt: Date,
        severity: DiagnosticSeverity,
        category: DiagnosticCategory,
        code: String,
        correlationID: UUID? = nil
    ) throws {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCode.isEmpty, normalizedCode.count <= 120 else {
            throw DiagnosticValidationError.invalidCode
        }
        guard normalizedCode.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0)
        }) else {
            throw DiagnosticValidationError.invalidCode
        }
        self.id = id
        self.occurredAt = occurredAt
        self.severity = severity
        self.category = category
        self.code = normalizedCode
        self.correlationID = correlationID
    }
}

public enum DiagnosticValidationError: Error, Equatable, Sendable {
    case invalidCode
}

public protocol DiagnosticSink: Sendable {
    func record(_ event: DiagnosticEvent) async
}

public actor InMemoryDiagnosticSink: DiagnosticSink {
    private var events: [DiagnosticEvent] = []

    public init() {}

    public func record(_ event: DiagnosticEvent) async {
        events.append(event)
    }

    public func recordedEvents() -> [DiagnosticEvent] {
        events
    }
}
