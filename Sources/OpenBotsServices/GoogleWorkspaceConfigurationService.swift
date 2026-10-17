import Foundation
import OpenBotsDomain

public struct GoogleWorkspaceConfigurationResolution: Equatable, Sendable {
    public enum Issue: Equatable, Sendable { case invalidConfiguration, storageUnavailable }
    public let clientID: String?
    public let updateConfiguration: GoogleWorkspaceUpdateConfiguration?
    public let issue: Issue?
    /// This launch replaced the saved ID with the build's own. Saved Google
    /// sign-ins belong to the old client, so the account must be connected
    /// again. Raised once: the next launch finds the two IDs equal.
    public var clientIDReplaced = false
}

/// Bootstrapped only after control storage has opened. One result is shared by
/// Google connectors and update admission; a transient environment override is
/// never copied into the durable record. A build that carries its own ID is the
/// authority and replaces a different saved one; an ID-free build inherits it.
/// This service has no credential boundary.
public struct GoogleWorkspaceConfigurationService: Sendable {
    private let repository: any GoogleWorkspacePublicConfigurationRepository
    private let legacyClientID: String?
    private let environmentClientID: @Sendable () -> String?

    public init(repository: any GoogleWorkspacePublicConfigurationRepository, legacyClientID: String?,
                environmentClientID: @escaping @Sendable () -> String? = {
                    ProcessInfo.processInfo.environment["OPENBOTS_GOOGLE_OAUTH_CLIENT_ID"]
                }) {
        self.repository = repository
        // Unconfigured source builds expand the optional build setting to an
        // exact empty plist string. Only that legacy representation is absent;
        // explicit empty environment overrides remain invalid.
        self.legacyClientID = legacyClientID == "" ? nil : legacyClientID
        self.environmentClientID = environmentClientID
    }

    public func bootstrap() async -> GoogleWorkspaceConfigurationResolution {
        do {
            var durable = try await repository.loadGoogleWorkspacePublicConfiguration()
            if durable == nil, let legacy = normalized(legacyClientID) {
                let seed = try GoogleWorkspacePublicConfiguration(clientID: legacy)
                var savedByThisBootstrap = true
                do { try await repository.seedGoogleWorkspacePublicConfiguration(seed) }
                catch GoogleWorkspacePublicConfigurationError.alreadyConfigured {
                    // Another bootstrap won. Read its authority, never overwrite.
                    savedByThisBootstrap = false
                }
                durable = try await repository.loadGoogleWorkspacePublicConfiguration()
                guard durable != nil, !savedByThisBootstrap || durable == seed else {
                    throw GoogleWorkspacePublicConfigurationError.readbackMismatch
                }
            } else if let saved = durable, let legacy = normalized(legacyClientID), legacy != saved.clientID {
                return try await replace(saved, withBundleClientID: legacy)
            }
            return try resolve(durable: durable)
        } catch {
            let issue: GoogleWorkspaceConfigurationResolution.Issue =
                error as? GoogleWorkspacePublicConfigurationError == .invalidRecord ? .invalidConfiguration : .storageUnavailable
            // Explicit environment configuration still wins for connectors.
            // Invalid durable state has no legacy fallback; every storage
            // failure disables updates, even with a valid explicit override.
            let override = environmentClientID()
            let fallback = override != nil ? normalized(override)
                : (issue == .storageUnavailable ? normalized(legacyClientID) : nil)
            return .init(clientID: fallback, updateConfiguration: nil, issue: issue)
        }
    }

    /// A corrected or rotated ID in a rebuilt app. A failed write or readback
    /// keeps the old saved ID effective and disables updates, so this launch
    /// never treats the new ID as durable. Logs that it changed, never the ID.
    private func replace(_ saved: GoogleWorkspacePublicConfiguration, withBundleClientID bundle: String) async throws
        -> GoogleWorkspaceConfigurationResolution {
        let replacement = try GoogleWorkspacePublicConfiguration(clientID: bundle)
        do {
            try await repository.replaceGoogleWorkspacePublicConfiguration(saved, with: replacement)
            guard try await repository.loadGoogleWorkspacePublicConfiguration() == replacement else {
                throw GoogleWorkspacePublicConfigurationError.readbackMismatch
            }
        } catch {
            AgenticDiagnosticsLog.error("google",
                "the build's Google client ID differs from the saved one and could not replace it; updates are disabled")
            let override = environmentClientID()
            return .init(clientID: override != nil ? normalized(override) : saved.clientID,
                         updateConfiguration: nil, issue: .storageUnavailable)
        }
        AgenticDiagnosticsLog.note("google",
            "the build's Google client ID replaced the saved one; the Google account must be connected again")
        var resolution = try resolve(durable: replacement)
        resolution.clientIDReplaced = true
        return resolution
    }

    /// Called before download and again inside the frozen final-save boundary.
    /// It does not seed or repair state: deletion, corruption, override changes,
    /// and repository errors all invalidate a previously captured expectation.
    public func freshlyVerifiedUpdateConfiguration(matching expected: GoogleWorkspaceUpdateConfiguration) async throws
        -> GoogleWorkspaceUpdateConfiguration {
        let durable = try await repository.loadGoogleWorkspacePublicConfiguration()
        let current = try resolve(durable: durable)
        guard current.updateConfiguration == expected else {
            throw GoogleWorkspacePublicConfigurationError.configurationChanged
        }
        return expected
    }

    private func resolve(durable: GoogleWorkspacePublicConfiguration?) throws -> GoogleWorkspaceConfigurationResolution {
        try durable?.validate()
        let override = environmentClientID()
        let candidate = override ?? durable?.clientID ?? legacyClientID
        if candidate != nil, normalized(candidate) == nil {
            return .init(clientID: nil, updateConfiguration: nil, issue: .invalidConfiguration)
        }
        let effective = normalized(candidate)
        // A source update bakes the effective ID into the rebuilt app, which
        // would then replace the saved one: an override that differs from the
        // durable record must not reach an update.
        let overridden = override != nil && effective != durable?.clientID
        return .init(clientID: effective,
                     updateConfiguration: overridden ? nil : .init(clientID: effective, durableClientID: durable?.clientID),
                     issue: nil)
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              GoogleWorkspacePublicConfiguration.validClientID(value) else { return nil }
        return value
    }
}
