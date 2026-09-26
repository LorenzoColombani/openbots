import Foundation
import OpenBotsContent
import OpenBotsSecurity

public enum FirstToolJobAdmissionError: Error, Equatable, Sendable {
    case cancelled, invalidObservationTime, malformedInstallation, profileRootUnavailable
    case installationNotVerified(ClaudeInstallationState)
    case profileNotVerified(ClaudeProfileInspectionResult)
}

/// Static observations from the existing installation inspector. The filename
/// is descriptive, never a runtime version or compatibility assertion.
public struct FirstToolJobInstallationIdentity: Equatable, Sendable {
    public let requestedPath: String
    public let resolvedPath: String
    public let versionFilename: String
    public let sha256: String
    public let signature: ClaudeStaticSignatureIdentity
    public let fileIdentity: ClaudeInstallationFileIdentity
}

/// Exact existing Preview ownership metadata checked by ClaudeProfileInspector.
/// Provider state and credentials remain opaque; no profile inventory is read.
public struct FirstToolJobProfileMetadata: Equatable, Sendable {
    public let applicationSupportPath: String
    public let profilePath: String
    public let markerPath: String
    public let installationID: UUID
    public let rootID: UUID
    public let bundleIdentifier: String
    public let markerSchemaVersion: Int
    public let role: String
}

/// Non-launching evidence for a later frozen manifest. Every later authorized
/// operation must revalidate current installation and profile state separately.
public struct FirstToolJobAdmissionReceipt: Equatable, Sendable {
    public let installation: FirstToolJobInstallationIdentity
    public let profile: FirstToolJobProfileMetadata
    public let checkedAt: Date
    public var runtimeCompatibilityVerified: Bool { false }
    public var subscriptionVerified: Bool { false }
    public var containmentVerified: Bool { false }
    public var liveApprovalGranted: Bool { false }
    public var launchReady: Bool { false }
}

/// Joins the current native static-code inspection and exact nonsecret Preview
/// profile metadata inspection. Construction is inert. This bridge cannot run
/// Claude, bootstrap a profile, inspect auth, or mint a live-probe approval.
public struct FirstToolJobAdmission: Sendable {
    private let layout: PreviewStorageLayout
    private let applicationSupportRoot: VerifiedOwnedRoot?
    private let installationInspector: any ClaudeInstallationInspecting

    public init(layout: PreviewStorageLayout, applicationSupportRoot: VerifiedOwnedRoot?) {
        self.init(layout: layout, applicationSupportRoot: applicationSupportRoot,
            installationInspector: ClaudeInstallationInspector(homeDirectory: layout.homeDirectory))
    }

    /// The injected inspector is a trusted host testing/inspection seam, never
    /// a provider-supplied or decoded installation assertion.
    public init(layout: PreviewStorageLayout, applicationSupportRoot: VerifiedOwnedRoot?,
                installationInspector: any ClaudeInstallationInspecting) {
        self.layout = layout; self.applicationSupportRoot = applicationSupportRoot
        self.installationInspector = installationInspector
    }

    public func inspect(at now: Date = Date()) async throws -> FirstToolJobAdmissionReceipt {
        guard now.timeIntervalSince1970.isFinite else { throw FirstToolJobAdmissionError.invalidObservationTime }
        guard !Task.isCancelled else { throw FirstToolJobAdmissionError.cancelled }
        let inspection = await installationInspector.inspectInstallation()
        guard !Task.isCancelled else { throw FirstToolJobAdmissionError.cancelled }
        guard inspection.state == .verified else {
            throw FirstToolJobAdmissionError.installationNotVerified(inspection.state)
        }
        let identity = try installationIdentity(inspection.details)
        guard let root = applicationSupportRoot else { throw FirstToolJobAdmissionError.profileRootUnavailable }
        let profile = ClaudeProfileInspector().inspect(applicationSupportRoot: root, layout: layout)
        guard profile == .metadataVerified else { throw FirstToolJobAdmissionError.profileNotVerified(profile) }
        guard !Task.isCancelled else { throw FirstToolJobAdmissionError.cancelled }
        return FirstToolJobAdmissionReceipt(installation: identity,
            profile: FirstToolJobProfileMetadata(applicationSupportPath: root.url.path,
                profilePath: layout.claudeCLIProfileRoot.path,
                markerPath: layout.claudeCLIProfileRoot.appending(path: ClaudeProfileInspector.markerFilename).path,
                installationID: root.installationID, rootID: root.rootID,
                bundleIdentifier: OpenBotsPreviewIdentity.bundleIdentifier, markerSchemaVersion: 1, role: "preview"),
            checkedAt: now)
    }

    private func installationIdentity(_ details: ClaudeInstallationDetails) throws -> FirstToolJobInstallationIdentity {
        let requested = layout.homeDirectory.appending(path: ".local/bin/claude").path
        let versions = layout.homeDirectory.appending(path: ".local/share/claude/versions")
        guard details.requestedPath.utf8.elementsEqual(requested.utf8),
              let filename = details.versionFilename, !filename.isEmpty, filename.utf8.count <= 255,
              filename != ".", filename != "..", !filename.contains("/"),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let resolved = details.resolvedPath,
              resolved.utf8.elementsEqual(versions.appending(path: filename).path.utf8),
              let digest = details.sha256, Self.hex(digest, bytes: 32),
              let signature = details.signature,
              signature.identifier == ClaudeInstallationInspector.expectedIdentifier,
              signature.teamIdentifier == ClaudeInstallationInspector.expectedTeamIdentifier,
              let codeHash = signature.codeDirectoryHash, Self.hex(codeHash, bytes: 20),
              let file = details.fileIdentity, file.inode > 0, file.byteCount >= 4,
              file.byteCount <= ClaudeInstallationInspector.maximumExecutableBytes else {
            throw FirstToolJobAdmissionError.malformedInstallation
        }
        return FirstToolJobInstallationIdentity(requestedPath: details.requestedPath, resolvedPath: resolved,
            versionFilename: filename, sha256: digest, signature: signature, fileIdentity: file)
    }

    private static func hex(_ value: String, bytes: Int) -> Bool {
        value.utf8.count == bytes * 2 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
