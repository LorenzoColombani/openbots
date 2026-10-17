import Foundation
import CoreFoundation

/// Nonsecret capabilities from the CLI's initialize response, or the bundled reference.
/// A listed model is not proof of remaining allowance or permission to incur charges.
public struct ClaudeModelDescriptor: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let aliases: Set<String>
    public let efforts: [String]
    public let contextWindows: [String]
    public let contextTokens: Int?
    public let defaultEffort: String?
}

public struct ClaudeModelCatalogSnapshot: Equatable, Sendable {
    public let models: [ClaudeModelDescriptor]
    public let checkedAt: Date?
    public var isLive: Bool { checkedAt != nil }

    public func model(_ value: String) -> ClaudeModelDescriptor? {
        models.first { $0.id == value || $0.aliases.contains(value) }
    }
    public var admittedModels: Set<String> {
        Set(models.flatMap { [$0.id] + $0.aliases.sorted() })
    }

    /// The input is only response.models, never the surrounding account/path fields.
    /// Any malformed entry rejects the update, leaving a clearly labelled fallback.
    public static func parse(modelsJSON: Data, checkedAt: Date) throws -> Self {
        guard modelsJSON.count <= 256 * 1_024,
              let entries = try JSONSerialization.jsonObject(with: modelsJSON) as? [[String: Any]],
              (1...64).contains(entries.count) else { throw ClaudeModelCatalogError.invalidCatalog }
        var models: [ClaudeModelDescriptor] = []
        var values: Set<String> = []
        for entry in entries {
            guard let value = entry["value"] as? String,
                  let resolved = entry["resolvedModel"] as? String,
                  let display = entry["displayName"] as? String,
                  !display.isEmpty, display.utf8.count <= 160,
                  display.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }),
                  ClaudeModelPolicy.isModelIdentity(resolved),
                  value == resolved || value == resolved + "[1m]" || ClaudeModelPolicy.aliases.contains(value),
                  values.insert(value).inserted else { throw ClaudeModelCatalogError.invalidCatalog }
            // These never become choices, including if a newer CLI advertises them.
            if resolved.contains("mythos") || display.lowercased().contains("mythos")
                || resolved == "claude-fable-5" { continue }
            let supported = entry["supportedEffortLevels"] as? [String] ?? []
            guard supported.count <= ClaudeModelPolicy.efforts.count,
                  Set(supported).count == supported.count,
                  supported.allSatisfy(ClaudeModelPolicy.efforts.contains),
                  entry["supportedEffortLevels"] == nil || entry["supportedEffortLevels"] is [String] else {
                throw ClaudeModelCatalogError.invalidCatalog
            }
            if let flag = entry["supportsEffort"] {
                guard let number = flag as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw ClaudeModelCatalogError.invalidCatalog
                }
            }
            let supportsEffort = entry["supportsEffort"] as? Bool ?? false
            guard supportsEffort || supported.isEmpty else { throw ClaudeModelCatalogError.invalidCatalog }
            let efforts = ClaudeModelPolicy.efforts.filter { supported.contains($0) }
            let reference = ClaudeModelPolicy.bundled.model(resolved)
            let descriptor = ClaudeModelDescriptor(
                id: resolved, name: reference?.name ?? ClaudeModelPolicy.displayName(resolved),
                aliases: ClaudeModelPolicy.aliases.contains(value) ? [value] : [], efforts: efforts,
                // The CLI currently supplies no context capability. Reuse a pinned
                // reference only for that exact model; new identities stay unknown.
                contextWindows: reference?.contextWindows ?? ["default"],
                contextTokens: reference?.contextTokens,
                defaultEffort: reference?.defaultEffort.flatMap { efforts.contains($0) ? $0 : nil }
            )
            if let index = models.firstIndex(where: { $0.id == resolved }) {
                let old = models[index]
                guard old.efforts == descriptor.efforts else { throw ClaudeModelCatalogError.invalidCatalog }
                models[index] = ClaudeModelDescriptor(id: old.id, name: old.name,
                    aliases: old.aliases.union(descriptor.aliases), efforts: old.efforts,
                    contextWindows: old.contextWindows, contextTokens: old.contextTokens,
                    defaultEffort: old.defaultEffort)
            } else { models.append(descriptor) }
        }
        guard !models.isEmpty else { throw ClaudeModelCatalogError.invalidCatalog }
        return Self(models: models, checkedAt: checkedAt)
    }
}

public enum ClaudeModelCatalogError: Error { case invalidCatalog }

/// The one process-local catalog. Construction performs no I/O; only a verified
/// subscription's bounded discovery may replace it. Historical records never use it.
public final class ClaudeModelCatalogRegistry: @unchecked Sendable {
    public static let shared = ClaudeModelCatalogRegistry()
    public static let changed = Notification.Name("OpenBots.ClaudeModelCatalogChanged")
    private let lock = NSLock()
    private var value = ClaudeModelPolicy.bundled
    public init() {}
    public var snapshot: ClaudeModelCatalogSnapshot { lock.withLock { value } }
    public func replace(with snapshot: ClaudeModelCatalogSnapshot?) {
        lock.withLock { value = snapshot ?? ClaudeModelPolicy.bundled }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

public enum ClaudeModelPolicy {
    public static let aliases: Set<String> = ["default", "sonnet", "opus", "haiku", "fable"]
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]
    public static var current: ClaudeModelCatalogSnapshot { ClaudeModelCatalogRegistry.shared.snapshot }

    public static let bundled = ClaudeModelCatalogSnapshot(models: [
        reference("claude-haiku-4-5-20251001", "Haiku 4.5", aliases: ["haiku"], context: 200_000),
        reference("claude-sonnet-5", "Sonnet 5", aliases: ["sonnet"], efforts: efforts, context: 1_000_000),
        reference("claude-opus-5-5", "Opus 5.5", aliases: ["opus", "default"], efforts: efforts, context: 1_000_000, defaultEffort: "medium"),
        reference("claude-fable-5-1", "Fable 5.1", efforts: efforts, context: 1_000_000),
        reference("claude-opus-5", "Opus 5", efforts: efforts, context: 1_000_000),
        reference("claude-opus-4-8", "Opus 4.8", efforts: efforts, context: 1_000_000),
        reference("claude-opus-4-7", "Opus 4.7", efforts: efforts, context: 1_000_000, defaultEffort: "xhigh"),
        reference("claude-opus-4-6", "Opus 4.6", efforts: ["low", "medium", "high", "max"], context: 1_000_000),
        reference("claude-sonnet-4-6", "Sonnet 4.6", efforts: ["low", "medium", "high", "max"], context: 200_000, long: true),
        reference("claude-opus-4-5-20251101", "Opus 4.5", context: 200_000),
        reference("claude-sonnet-4-5-20250929", "Sonnet 4.5", context: 200_000)
    ], checkedAt: nil)

    private static func reference(_ id: String, _ name: String, aliases: Set<String> = [],
                                  efforts: [String] = [], context: Int, long: Bool = false,
                                  defaultEffort: String = "high") -> ClaudeModelDescriptor {
        ClaudeModelDescriptor(id: id, name: name, aliases: aliases, efforts: efforts,
            contextWindows: context == 1_000_000 || long ? ["default", "standard", "long"] : ["default", "standard"],
            contextTokens: context, defaultEffort: efforts.isEmpty ? nil : defaultEffort)
    }

    /// Bounded protocol identity, not availability. Historical evidence remains
    /// readable after removal from the current catalog, without admitting a launch.
    public static func isModelIdentity(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        return value.hasPrefix("claude-") && value.utf8.count <= 200 && parts.count >= 3
            && parts.allSatisfy { !$0.isEmpty } && parts.last?.first?.isNumber == true
            && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }
    }
    public static func normalizedIdentity(_ value: String) -> String? {
        // Reported identity only: this suffix never grants a launch option or
        // supplies missing context capabilities for a newly discovered model.
        let base = value.hasSuffix("[1m]") ? String(value.dropLast(4)) : value
        return isModelIdentity(base) ? base : nil
    }
    public static func resolvedModel(_ value: String) -> String? { current.model(value)?.id }
    public static func requiresMax(_ model: String) -> Bool {
        let resolved = resolvedModel(model) ?? model
        return (resolved.hasPrefix("claude-opus-") && resolved != "claude-opus-4-5-20251101")
            || resolved.hasPrefix("claude-fable-")
    }
    public static func displayName(_ id: String) -> String {
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().filter { $0.count != 8 }.joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }
}
