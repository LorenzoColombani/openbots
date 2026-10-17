import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

@Suite("Durable Google public configuration and update readiness")
struct GoogleWorkspaceConfigurationServiceTests {
    private let legacy = "123456-legacy.apps.googleusercontent.com"
    private let other = "987654-other.apps.googleusercontent.com"

    @Test("Missing state seeds the legacy ID once, reads it back, and survives a generic or identical bundle")
    func seedAndRestart() async throws {
        let repository = ConfigurationRepository()
        let first = service(repository, bundle: legacy)
        let resolved = await first.bootstrap()
        #expect(resolved.clientID == legacy)
        #expect(!resolved.clientIDReplaced)
        let ready = try #require(resolved.updateConfiguration)
        #expect(ready.durableClientID == legacy)
        #expect(try await first.freshlyVerifiedUpdateConfiguration(matching: ready) == ready)
        #expect(await repository.seedCount == 1)
        for bundle in [nil, "", legacy, " \(legacy)\n"] {
            let restarted = await service(repository, bundle: bundle).bootstrap()
            #expect(restarted == resolved)
        }
        #expect(await repository.seedCount == 1)
        #expect(await repository.replaceCount == 0)
    }

    @Test("A build carrying a different ID replaces the saved one once and asks for a new sign-in")
    func bundleReplacesSaved() async throws {
        let repository = ConfigurationRepository()
        let old = try #require(await service(repository, bundle: legacy).bootstrap().updateConfiguration)
        let rebuilt = service(repository, bundle: other)
        let replaced = await rebuilt.bootstrap()
        #expect(replaced.clientIDReplaced)
        #expect(replaced.issue == nil)
        #expect(replaced.clientID == other)
        #expect(try await repository.loadGoogleWorkspacePublicConfiguration()?.clientID == other)
        #expect(await repository.replaceCount == 1)
        // Update admission binds the new effective and durable ID, and an
        // expectation captured under the old ID no longer verifies.
        let ready = try #require(replaced.updateConfiguration)
        #expect(ready == .init(clientID: other, durableClientID: other))
        #expect(try await rebuilt.freshlyVerifiedUpdateConfiguration(matching: ready) == ready)
        await #expect(throws: GoogleWorkspacePublicConfigurationError.configurationChanged) {
            try await rebuilt.freshlyVerifiedUpdateConfiguration(matching: old)
        }
        // The notice is one-time; a later ID-free build inherits the new ID.
        for bundle in [other, nil] {
            let restarted = await service(repository, bundle: bundle).bootstrap()
            #expect(!restarted.clientIDReplaced)
            #expect(restarted.clientID == other)
            #expect(restarted.updateConfiguration == ready)
        }
        #expect(await repository.replaceCount == 1)
        #expect(await repository.seedCount == 1)
    }

    @Test("An invalid bundle ID never replaces a saved one")
    func invalidBundleKeepsSaved() async throws {
        let repository = ConfigurationRepository()
        let resolved = await service(repository, bundle: legacy).bootstrap()
        for bundle in [" ", "invalid", "x.apps.googleusercontent.com/"] {
            #expect(await service(repository, bundle: bundle).bootstrap() == resolved)
        }
        #expect(await repository.replaceCount == 0)
        #expect(try await repository.loadGoogleWorkspacePublicConfiguration()?.clientID == legacy)
    }

    @Test("A failed replacement keeps the saved ID effective and disables updates", arguments: [
        ConfigurationRepository.Fault.replace, .concurrentReplace, .replaceReadbackMissing,
        .replaceReadbackDifferent, .replaceReadbackFailure
    ])
    private func replaceFailures(fault: ConfigurationRepository.Fault) async throws {
        for environment in [nil, other] {
            let repository = ConfigurationRepository()
            _ = await service(repository, bundle: legacy).bootstrap()
            await repository.setFault(fault)
            let result = await service(repository, bundle: other, environment: environment).bootstrap()
            // Explicit environment configuration still wins for connectors.
            #expect(result.clientID == (environment ?? legacy))
            #expect(result.updateConfiguration == nil)
            #expect(result.issue == .storageUnavailable)
            #expect(!result.clientIDReplaced)
            #expect(await repository.replaceCount == 1)
        }
    }

    @Test("Explicit environment overrides are effective but never replace or seed the durable ID")
    func environmentOverride() async throws {
        let repository = ConfigurationRepository()
        let configured = await service(repository, bundle: legacy, environment: other).bootstrap()
        #expect(configured.clientID == other)
        // A source update would bake the override into the rebuilt app, which
        // would then replace the durable ID, so a differing override blocks it.
        #expect(configured.updateConfiguration == nil)
        #expect(configured.issue == nil)
        #expect(try await repository.loadGoogleWorkspacePublicConfiguration()?.clientID == legacy)
        let matching = await service(repository, bundle: legacy, environment: legacy).bootstrap()
        #expect(matching.updateConfiguration == .init(clientID: legacy, durableClientID: legacy))
        let empty = ConfigurationRepository()
        let transient = await service(empty, bundle: nil, environment: other).bootstrap()
        #expect(transient.clientID == other)
        #expect(transient.updateConfiguration == nil)
        #expect(try await empty.loadGoogleWorkspacePublicConfiguration() == nil)
        #expect(await empty.seedCount == 0)
    }

    @Test("An explicit invalid override blocks all effective fallback", arguments: ["", " ", "not-an-id"])
    func invalidEnvironment(value: String) async throws {
        let repository = ConfigurationRepository()
        let result = await service(repository, bundle: legacy, environment: value).bootstrap()
        #expect(result.clientID == nil)
        #expect(result.updateConfiguration == nil)
        #expect(result.issue == .invalidConfiguration)
        // The legacy identity is preserved independently of the transient input.
        #expect(try await repository.loadGoogleWorkspacePublicConfiguration()?.clientID == legacy)
    }

    @Test("Malformed durable state is not treated as absent or overwritten")
    func malformed() async {
        let repository = ConfigurationRepository(fault: .malformed)
        let result = await service(repository, bundle: legacy).bootstrap()
        #expect(result.issue == .invalidConfiguration)
        #expect(result.clientID == nil)
        #expect(result.updateConfiguration == nil)
        #expect(await repository.seedCount == 0)
        let explicit = await service(repository, bundle: legacy, environment: other).bootstrap()
        #expect(explicit.clientID == other)
        #expect(explicit.updateConfiguration == nil)
        #expect(explicit.issue == .invalidConfiguration)
        #expect(await repository.seedCount == 0)
    }

    @Test("Unconfigured installations remain usable and invalid legacy IDs never seed")
    func absentAndInvalid() async {
        let absent = ConfigurationRepository()
        let result = await service(absent, bundle: nil).bootstrap()
        #expect(result.issue == nil)
        #expect(result.updateConfiguration == .init())
        #expect(await absent.seedCount == 0)
        #expect(await service(absent, bundle: "").bootstrap() == result)
        let invalid = await service(absent, bundle: "invalid").bootstrap()
        #expect(invalid.issue == .invalidConfiguration)
        #expect(invalid.updateConfiguration == nil)
        #expect(await absent.seedCount == 0)
    }

    @Test("Save, read and readback failures disable updates", arguments: [
        ConfigurationRepository.Fault.save, .load, .readbackMissing, .readbackDifferent, .readbackFailure
    ])
    private func persistenceFailures(fault: ConfigurationRepository.Fault) async {
        let repository = ConfigurationRepository(fault: fault)
        let result = await service(repository, bundle: legacy).bootstrap()
        #expect(result.updateConfiguration == nil)
        #expect(result.issue == .storageUnavailable)
        #expect(result.clientID == legacy)
    }

    @Test("A concurrent seed is read back and remains the durable authority")
    func concurrentSeed() async throws {
        let repository = ConfigurationRepository(fault: .concurrentSeed)
        let result = await service(repository, bundle: legacy).bootstrap()
        #expect(result.clientID == other)
        #expect(result.updateConfiguration?.durableClientID == other)
        #expect(result.issue == nil)
    }

    @Test("Deletion, changes, malformed state and read failure after download refuse final readiness", arguments: [
        "deleted", "changed", "malformed", "unreadable"
    ])
    func finalReadback(mode: String) async throws {
        let repository = ConfigurationRepository()
        let resolver = service(repository, bundle: legacy)
        let resolved = await resolver.bootstrap()
        let captured = try #require(resolved.updateConfiguration)
        switch mode {
        case "deleted": await repository.replace(nil)
        case "changed": await repository.replace(try .init(clientID: other))
        case "malformed": await repository.setFault(.malformed)
        default: await repository.setFault(.load)
        }
        await #expect(throws: (any Error).self) {
            try await resolver.freshlyVerifiedUpdateConfiguration(matching: captured)
        }
        #expect(await repository.seedCount == 1)
    }

    @Test("An environment change after download invalidates the captured configuration")
    func changedEnvironment() async throws {
        let environment = MutableEnvironment()
        let repository = ConfigurationRepository()
        let resolver = GoogleWorkspaceConfigurationService(repository: repository, legacyClientID: legacy,
            environmentClientID: { environment.read() })
        let resolved = await resolver.bootstrap()
        let captured = try #require(resolved.updateConfiguration)
        environment.set(other)
        await #expect(throws: GoogleWorkspacePublicConfigurationError.configurationChanged) {
            try await resolver.freshlyVerifiedUpdateConfiguration(matching: captured)
        }
    }

    private func service(_ repository: ConfigurationRepository, bundle: String?, environment: String? = nil)
        -> GoogleWorkspaceConfigurationService {
        GoogleWorkspaceConfigurationService(repository: repository, legacyClientID: bundle, environmentClientID: { environment })
    }
}

private final class MutableEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func read() -> String? { lock.withLock { value } }
    func set(_ value: String?) { lock.withLock { self.value = value } }
}

private actor ConfigurationRepository: GoogleWorkspacePublicConfigurationRepository {
    enum Fault: Sendable {
        case save, load, readbackMissing, readbackDifferent, readbackFailure, malformed, concurrentSeed
        case replace, concurrentReplace, replaceReadbackMissing, replaceReadbackDifferent, replaceReadbackFailure
    }
    struct InjectedFailure: Error {}
    private static let third = "555555-third.apps.googleusercontent.com"
    private var fault: Fault?
    private var value: GoogleWorkspacePublicConfiguration?
    private(set) var seedCount = 0
    private(set) var replaceCount = 0
    init(fault: Fault? = nil) { self.fault = fault }
    func replace(_ value: GoogleWorkspacePublicConfiguration?) { self.value = value }
    func setFault(_ fault: Fault) { self.fault = fault }

    func loadGoogleWorkspacePublicConfiguration() async throws -> GoogleWorkspacePublicConfiguration? {
        if fault == .malformed { throw GoogleWorkspacePublicConfigurationError.invalidRecord }
        if fault == .load || (fault == .readbackFailure && seedCount > 0) { throw InjectedFailure() }
        if seedCount > 0, fault == .readbackMissing { return nil }
        if seedCount > 0, fault == .readbackDifferent { return try .init(clientID: "987654-other.apps.googleusercontent.com") }
        if replaceCount > 0, fault == .replaceReadbackFailure { throw InjectedFailure() }
        if replaceCount > 0, fault == .replaceReadbackMissing { return nil }
        if replaceCount > 0, fault == .replaceReadbackDifferent { return try .init(clientID: Self.third) }
        return value
    }

    func replaceGoogleWorkspacePublicConfiguration(_ expected: GoogleWorkspacePublicConfiguration,
                                                   with replacement: GoogleWorkspacePublicConfiguration) async throws {
        replaceCount += 1
        if fault == .replace { throw InjectedFailure() }
        if fault == .concurrentReplace { value = try .init(clientID: Self.third) }
        guard value == expected else { throw GoogleWorkspacePublicConfigurationError.configurationChanged }
        value = replacement
    }

    func seedGoogleWorkspacePublicConfiguration(_ configuration: GoogleWorkspacePublicConfiguration) async throws {
        seedCount += 1
        if fault == .save { throw InjectedFailure() }
        if fault == .concurrentSeed {
            value = try .init(clientID: "987654-other.apps.googleusercontent.com")
            throw GoogleWorkspacePublicConfigurationError.alreadyConfigured
        }
        guard value == nil else { throw GoogleWorkspacePublicConfigurationError.alreadyConfigured }
        value = configuration
    }
}
