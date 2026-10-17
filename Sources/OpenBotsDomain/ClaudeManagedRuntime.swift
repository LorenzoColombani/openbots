import Foundation

/// Descriptive version plus exact retained bytes and vendor signing identity.
public struct ClaudeRuntimeArtifact: Codable, Hashable, Sendable {
    public let version: String
    public let sha256: String
    public let signatureIdentifier: String
    public let teamIdentifier: String
    public let codeDirectoryHash: String

    public init(version: String, sha256: String, signatureIdentifier: String,
                teamIdentifier: String, codeDirectoryHash: String) {
        self.version = version; self.sha256 = sha256
        self.signatureIdentifier = signatureIdentifier; self.teamIdentifier = teamIdentifier
        self.codeDirectoryHash = codeDirectoryHash
    }

    public var isWellFormed: Bool {
        !version.isEmpty && version.utf8.count <= 128 && !version.contains("\0")
            && sha256.count == 64 && sha256.allSatisfy { "0123456789abcdef".contains($0) }
            && signatureIdentifier == "com.anthropic.claude-code" && teamIdentifier == "Q6L2SF6YDW"
            && codeDirectoryHash.count == 40 && codeDirectoryHash.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

public struct ClaudeRuntimeContract: Codable, Hashable, Sendable {
    /// Revision 2 validates alias families and binds the resolved model identity
    /// across initialization and terminal evidence, independent of a stale catalog.
    public static let currentSuiteRevision = 2
    public let appBuild: String
    public let protocolRevision: Int
    public let suiteRevision: Int
    public let profileSchemaVersion: Int
    public let compatibilityProfileID: UUID

    public init(appBuild: String, compatibilityProfileID: UUID, protocolRevision: Int = 1,
                suiteRevision: Int = ClaudeRuntimeContract.currentSuiteRevision, profileSchemaVersion: Int = 1) {
        self.appBuild = appBuild; self.compatibilityProfileID = compatibilityProfileID
        self.protocolRevision = protocolRevision; self.suiteRevision = suiteRevision
        self.profileSchemaVersion = profileSchemaVersion
    }
}

public enum ClaudeRuntimeCompatibilityCase: String, Codable, CaseIterable, Hashable, Sendable {
    case haikuReply, sonnetReply, inertToolAllowed, inertToolDenied, cancellationCleanup, sessionContinuation
}

/// Published by the compatibility runner only after all production-run checks finish.
public struct ClaudeRuntimeCompatibilityReceipt: Codable, Equatable, Sendable {
    public let artifact: ClaudeRuntimeArtifact
    public let contract: ClaudeRuntimeContract
    public let compatibilityProfilePath: String
    public let sourceRuntimeSHA256: String?
    public let passedCases: Set<ClaudeRuntimeCompatibilityCase>
    public let completedAt: Date

    public init(artifact: ClaudeRuntimeArtifact, contract: ClaudeRuntimeContract,
                compatibilityProfilePath: String, sourceRuntimeSHA256: String?,
                passedCases: Set<ClaudeRuntimeCompatibilityCase>, completedAt: Date) {
        self.artifact = artifact; self.contract = contract
        self.compatibilityProfilePath = compatibilityProfilePath
        self.sourceRuntimeSHA256 = sourceRuntimeSHA256; self.passedCases = passedCases
        self.completedAt = completedAt
    }
}

public enum ClaudeRuntimeCheckStatus: String, Codable, Sendable {
    case pending, running, failed, passed, needsAuthentication, cancelled
}

public struct ClaudeRuntimeCheckResult: Codable, Equatable, Sendable {
    public let artifactSHA256: String
    public let contract: ClaudeRuntimeContract
    public let status: ClaudeRuntimeCheckStatus
    public let message: String?
    public let receipt: ClaudeRuntimeCompatibilityReceipt?

    public init(artifactSHA256: String, contract: ClaudeRuntimeContract, status: ClaudeRuntimeCheckStatus,
                message: String? = nil, receipt: ClaudeRuntimeCompatibilityReceipt? = nil) {
        self.artifactSHA256 = artifactSHA256; self.contract = contract; self.status = status
        self.message = message.map { String($0.prefix(512)) }; self.receipt = receipt
    }
}

public struct ClaudeRuntimeState: Codable, Equatable, Sendable {
    public let active: ClaudeRuntimeArtifact?
    public let previous: ClaudeRuntimeArtifact?
    public let candidate: ClaudeRuntimeArtifact?
    public let generation: UInt64
    public let lastResult: ClaudeRuntimeCheckResult?
    /// The selection's full pass remains independent of later candidate attempts.
    public let activeReceipt: ClaudeRuntimeCompatibilityReceipt?

    public init(active: ClaudeRuntimeArtifact? = nil, previous: ClaudeRuntimeArtifact? = nil,
                candidate: ClaudeRuntimeArtifact? = nil, generation: UInt64 = 0,
                lastResult: ClaudeRuntimeCheckResult? = nil,
                activeReceipt: ClaudeRuntimeCompatibilityReceipt? = nil) {
        self.active = active; self.previous = previous; self.candidate = candidate
        self.generation = generation; self.lastResult = lastResult
        self.activeReceipt = activeReceipt
    }
}
