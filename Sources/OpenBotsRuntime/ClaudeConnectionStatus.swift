import Foundation

public enum ClaudeConnectionSubscriptionTier: String, Equatable, Sendable {
    case pro, max
}

/// The only information allowed to leave the status transport. No transcript,
/// email, account identifier, error text or unrecognized JSON field is retained.
public enum ClaudeConnectionStatusResult: Equatable, Sendable {
    case eligible(ClaudeConnectionSubscriptionTier)
    case signedOut
    case inconclusive
    case cancelled
}

public protocol ClaudeStatusChecking: Sendable {
    func checkStatus(target: ClaudeConnectionTarget) async -> ClaudeConnectionStatusResult
}

enum ClaudeConnectionStatusParser {
    static let maximumOutputBytes = 16 * 1_024

    static func classify(stdout: Data, exitCode: Int32) -> ClaudeConnectionStatusResult {
        guard exitCode == 0 || exitCode == 1,
              !stdout.isEmpty, stdout.count <= maximumOutputBytes,
              hasBoundedUnambiguousShape(stdout),
              let value = try? JSONDecoder().decode(Status.self, from: stdout)
        else { return .inconclusive }

        if !value.loggedIn,
           value.authMethod.lowercased() == "none",
           value.apiProvider == nil || value.apiProvider?.lowercased() == "firstparty",
           value.subscriptionType == nil {
            return .signedOut
        }
        guard exitCode == 0, value.loggedIn,
              value.authMethod.lowercased() == "claude.ai",
              value.apiProvider?.lowercased() == "firstparty",
              let tier = ClaudeConnectionSubscriptionTier(rawValue: value.subscriptionType?.lowercased() ?? "")
        else { return .inconclusive }
        return .eligible(tier)
    }

    private struct Status: Decodable {
        let loggedIn: Bool
        let authMethod: String
        let apiProvider: String?
        let subscriptionType: String?

        enum CodingKeys: String, CodingKey {
            case loggedIn, authMethod, apiProvider, subscriptionType
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            loggedIn = try values.decode(Bool.self, forKey: .loggedIn)
            authMethod = try values.decode(String.self, forKey: .authMethod)
            apiProvider = try values.decodeIfPresent(String.self, forKey: .apiProvider)
            subscriptionType = try values.decodeIfPresent(String.self, forKey: .subscriptionType)
            guard [authMethod, apiProvider, subscriptionType].compactMap({ $0 })
                .allSatisfy({ $0.utf8.count <= 64 }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Status field exceeds limit"))
            }
        }
    }

    /// JSONDecoder performs grammar/type validation. This preceding bounded
    /// scan caps depth/member count and rejects duplicate root keys, including
    /// differently escaped spellings, before the decoder can choose a value.
    private static func hasBoundedUnambiguousShape(_ data: Data) -> Bool {
        let bytes = Array(data)
        guard bytes.first(where: { ![9, 10, 13, 32].contains($0) }) == 123 else { return false }
        var depth = 0
        var separators = 0
        var stringStart: Int?
        var escaped = false
        var expectsRootKey = false
        var isRootKey = false
        var keys = Set<String>()
        for (index, byte) in bytes.enumerated() {
            if let start = stringStart {
                if escaped { escaped = false; continue }
                if byte == 92 { escaped = true; continue }
                if byte == 34 {
                    if isRootKey {
                        guard index - start <= 130,
                              let key = try? JSONDecoder().decode(String.self, from: Data(bytes[start...index])),
                              key.utf8.count <= 128, keys.insert(key).inserted, keys.count <= 32
                        else { return false }
                        expectsRootKey = false
                    }
                    stringStart = nil
                }
                continue
            }
            switch byte {
            case 34:
                stringStart = index
                isRootKey = depth == 1 && expectsRootKey
            case 123, 91:
                depth += 1
                guard depth <= 8 else { return false }
                if depth == 1 { expectsRootKey = true }
            case 125, 93:
                depth -= 1
                guard depth >= 0 else { return false }
            case 44:
                separators += 1
                guard separators <= 64 else { return false }
                if depth == 1 { expectsRootKey = true }
            default: break
            }
        }
        return depth == 0 && stringStart == nil
    }
}
