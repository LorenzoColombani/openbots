import Foundation

/// The two web capabilities a granted bot may use inside a job. Each has an
/// independent app-wide master switch AND a per-bot grant; enabling one never
/// implies the other. The raw value is the official Claude Code tool name.
public enum AgenticWebCapability: String, CaseIterable, Codable, Hashable, Sendable {
    case search = "WebSearch"
    case fetch = "WebFetch"

    public var toolName: String { rawValue }

    /// Callback identity the host registers for this tool's PreToolUse hook,
    /// so a callback names its tool before any input is read.
    public var hookCallbackID: String {
        switch self {
        case .search: "openbots-first-job-websearch"
        case .fetch: "openbots-first-job-webfetch"
        }
    }

    public var displayName: String {
        switch self {
        case .search: "Web search"
        case .fetch: "Web fetch"
        }
    }

    /// Stable key for accessibility identifiers and logs.
    public var settingKey: String {
        switch self {
        case .search: "webSearch"
        case .fetch: "webFetch"
        }
    }

    public init?(toolName: String) { self.init(rawValue: toolName) }

    public init?(hookCallbackID: String) {
        guard let match = Self.allCases.first(where: { $0.hookCallbackID == hookCallbackID }) else { return nil }
        self = match
    }

    /// Tool names in one fixed order, so generated launch inputs stay stable.
    public static func toolNames(_ capabilities: Set<AgenticWebCapability>) -> [String] {
        allCases.filter(capabilities.contains).map(\.toolName)
    }
}

public enum AgenticWebInputError: Error, Equatable, Sendable {
    case invalidQuery
    case invalidDomainList
    case invalidURL
}

/// Lexical checks on the inputs Claude's web tools carry. Nothing here resolves
/// a name, opens a connection or reads a page; it only refuses shapes that the
/// granted read-only public-web capability does not cover. A public hostname
/// can still resolve anywhere; that limit belongs to the later web stage.
public enum AgenticWebInputPolicy {
    public static let maximumQueryBytes = 2_048
    public static let maximumURLBytes = 2_048
    public static let maximumDomainEntries = 32
    /// Special-use or non-public top-level names a granted fetch never targets.
    static let specialUseTopLevels: Set<String> = [
        "localhost", "local", "internal", "lan", "home", "corp", "intranet", "arpa", "test", "invalid", "onion"
    ]

    /// A search query: visible text only, bounded, with no control characters.
    public static func validateQuery(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, text.utf8.count <= maximumQueryBytes,
              !text.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7f || $0.properties.generalCategory == .control
                      || $0.properties.generalCategory == .format
              }) else {
            throw AgenticWebInputError.invalidQuery
        }
    }

    /// Optional allow/deny lists on a search: a bounded list of plain hostnames.
    public static func validateDomainList(_ entries: [String]) throws {
        guard entries.count <= maximumDomainEntries, entries.allSatisfy(isHostname) else {
            throw AgenticWebInputError.invalidDomainList
        }
    }

    /// The one page a granted bot may read: an absolute http(s) URL naming a
    /// public host, with no credentials, no port and no special-use name. The
    /// authority is read from the text as written (Foundation would decode a
    /// punycode host), and the input is returned unchanged; the check is
    /// lexical only.
    @discardableResult
    public static func validatedPublicURL(_ text: String) throws -> String {
        guard !text.isEmpty, text.utf8.count <= maximumURLBytes,
              text.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else { throw AgenticWebInputError.invalidURL }
        let lowered = text.lowercased()
        guard let scheme = ["https://", "http://"].first(where: lowered.hasPrefix) else {
            throw AgenticWebInputError.invalidURL
        }
        let authority = String(lowered.dropFirst(scheme.count).prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard !authority.isEmpty, !authority.contains("@"), !authority.contains("["), !authority.contains(":"),
              isHostname(authority), !isSpecialUse(authority) else {
            throw AgenticWebInputError.invalidURL
        }
        return text
    }

    /// At least two lowercase DNS labels whose top level starts with a letter
    /// (punycode top levels included), so an IP literal, a bare name or a
    /// bracketed address never passes.
    static func isHostname(_ value: String) -> Bool {
        let host = value.lowercased()
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let top = labels.last else { return false }
        for label in labels {
            guard !label.isEmpty, label.utf8.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2d }) else {
                return false
            }
        }
        return top.utf8.count >= 2 && top.utf8.first.map { $0 >= 0x61 && $0 <= 0x7a } == true
    }

    static func isSpecialUse(_ host: String) -> Bool {
        guard let top = host.split(separator: ".").last else { return true }
        return specialUseTopLevels.contains(String(top))
    }
}
