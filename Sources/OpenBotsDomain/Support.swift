import Foundation

public enum DomainValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty(field: String)
    case tooLong(field: String, maximum: Int)
    case invalid(field: String, reason: String)

    public var description: String {
        switch self {
        case let .empty(field):
            "\(field) cannot be empty."
        case let .tooLong(field, maximum):
            "\(field) cannot exceed \(maximum) characters."
        case let .invalid(field, reason):
            "\(field) is invalid: \(reason)"
        }
    }
}

public protocol OpenBotsClock: Sendable {
    func now() -> Date
}

public struct SystemClock: OpenBotsClock {
    public init() {}
    public func now() -> Date { Date() }
}

public protocol UUIDGenerator: Sendable {
    func next() -> UUID
}

public struct SystemUUIDGenerator: UUIDGenerator {
    public init() {}
    public func next() -> UUID { UUID() }
}

enum DomainText {
    static func required(_ value: String, field: String, maximum: Int) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DomainValidationError.empty(field: field) }
        guard trimmed.count <= maximum else {
            throw DomainValidationError.tooLong(field: field, maximum: maximum)
        }
        return trimmed
    }

    static func optional(_ value: String?, field: String, maximum: Int) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maximum else {
            throw DomainValidationError.tooLong(field: field, maximum: maximum)
        }
        return trimmed
    }
}

public struct PageRequest: Equatable, Sendable {
    public let limit: Int
    public let beforeSequence: Int64?

    public init(limit: Int, beforeSequence: Int64? = nil) throws {
        guard (1...500).contains(limit) else {
            throw DomainValidationError.invalid(
                field: "page limit",
                reason: "must be between 1 and 500"
            )
        }
        self.limit = limit
        self.beforeSequence = beforeSequence
    }
}

public struct Page<Element: Sendable>: Sendable {
    public let elements: [Element]
    public let hasMore: Bool

    public init(elements: [Element], hasMore: Bool) {
        self.elements = elements
        self.hasMore = hasMore
    }
}
