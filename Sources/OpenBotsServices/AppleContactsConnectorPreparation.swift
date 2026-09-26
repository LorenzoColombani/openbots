import Darwin
import Foundation
import OpenBotsDomain
import OpenBotsRuntime

/// Freezes the launch for the app's own Contacts reader.
///
/// The same shape as the mail sender's — the program is shipped in the bundle,
/// so the only questions are whether it is there and whether there is a node to
/// run it with — with one difference that matters: this one IS fenced. The
/// sender only ever talks about what it did with what the user approved, and its
/// answers are the app's own sentences. A contact card is not: a vCard arrives
/// from whoever sent it, and the reader hands back what is written on it. So
/// its results reach the model wrapped, like the mail reader's and the
/// browser's, and the fence being unavailable means the row does not launch at
/// all rather than launching unfenced.
///
/// Nothing is written for a lookup, so a contacts turn owns no directory.
public struct AppleContactsConnectorPreparation: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The row is not the contacts reader's.
        case notTheContactsReader
        /// Only a stdio server can be resolved to a local program.
        case unsupportedTransport
        /// The build does not carry the reader. Nothing can be looked up.
        case scriptMissing
        /// Contacts.app is not on this Mac, so there is nothing to read.
        case applicationMissing
        /// No absolute node to run it with.
        case interpreterMissing
        /// No node to run the fence with, or no fence in the bundle.
        case fenceUnavailable(FenceProxyResource.Failure)
    }

    /// The command an app-owned row names for this server.
    public static let command = "apple-contacts"

    private let scriptURL: URL?
    private let applicationCandidateURLs: [URL]
    private let interpreterCandidateURLs: [URL]
    private let tools: InstalledToolResolution
    private let applicationName: String
    /// The shim the row's badge is judged against, so a test can hand it one.
    private let fence: FenceProxyResource

    public init(scriptURL: URL? = AppOwnedConnectorCatalog.appleContactsScriptURL,
                applicationCandidateURLs: [URL] = AppOwnedConnectorCatalog.contactsApplicationURLs,
                interpreterCandidateURLs: [URL] = BrowserConnectorPreparation.defaultInterpreterURLs,
                applicationName: String = "OpenBots Next",
                ownerUID: uid_t = getuid(),
                fence: FenceProxyResource = FenceProxyResource()) {
        self.scriptURL = scriptURL
        self.applicationCandidateURLs = applicationCandidateURLs
        self.interpreterCandidateURLs = interpreterCandidateURLs
        self.tools = InstalledToolResolution(ownerUID: ownerUID)
        self.applicationName = applicationName
        self.fence = fence
    }

    /// The shipped script, the node that will run it, and the Contacts it will
    /// drive.
    public func resolve(_ launch: ConnectorLaunchConfiguration) throws
        -> (script: URL, interpreter: URL, application: URL) {
        guard launch.command == Self.command else { throw Failure.notTheContactsReader }
        guard launch.transport == .stdio else { throw Failure.unsupportedTransport }
        guard let scriptURL, FileManager().isReadableFile(atPath: scriptURL.path) else {
            throw Failure.scriptMissing
        }
        guard let application = applicationCandidateURLs
            .first(where: { FileManager().fileExists(atPath: $0.path) })
        else { throw Failure.applicationMissing }
        guard let interpreter = tools.firstResolved(of: interpreterCandidateURLs) else {
            throw Failure.interpreterMissing
        }
        return (scriptURL.standardizedFileURL, interpreter, application.standardizedFileURL)
    }
}

extension AppleContactsConnectorPreparation: ConnectorLaunchPreparing {
    public func prepares(_ launch: ConnectorLaunchConfiguration) -> Bool {
        launch.command == Self.command
    }

    /// A lookup writes nothing of its own.
    public var needsOwnedProfile: Bool { false }

    public func server(for launch: ConnectorLaunchConfiguration, profileURL: URL?,
                       temporaryDirectoryURL: URL,
                       fence: FenceProxyResource) throws -> ClaudeTextConnectorServer {
        let resolved = try resolve(launch)
        let role = ClaudeTextConnectorRole.appleContactsRead
        // Whoever wrote the card wrote the words this hands back, so the reader
        // is never launched outside the fence.
        precondition(role.handsBackUntrustedMaterial)
        let program: ClaudeTextConnectorProgram
        do {
            program = try fence.fenced(
                .node(interpreterURL: resolved.interpreter, entryPointURL: resolved.script),
                label: role.fenceLabel)
        } catch let failure as FenceProxyResource.Failure { throw Failure.fenceUnavailable(failure) }
        return try ClaudeTextConnectorServer(
            name: launch.serverKey, role: role, program: program, options: [],
            // The permission hint the reader prints when Contacts refuses has
            // to name the app the user will actually find in System Settings — and
            // the Contacts it starts is the one THIS side resolved, so the
            // badge and the launch cannot end up pointing at two different
            // copies the way two independent lookups would.
            environment: ["OPENBOTS_APP_NAME": applicationName,
                          "OPENBOTS_CONTACTS_APP": resolved.application.path])
    }

    public func availability(for launch: ConnectorLaunchConfiguration) -> ConnectorAvailability? {
        guard prepares(launch) else { return nil }
        do {
            _ = try resolve(launch)
            // The fence is part of being launchable, so its absence is the
            // row's problem too, not a surprise inside a turn.
            try fence.verify()
            return .ready
        } catch Failure.scriptMissing {
            return .unavailable("This build is missing the contacts reader. Reinstall the app.")
        } catch Failure.applicationMissing {
            return .unavailable("Contacts is not installed on this Mac.")
        } catch Failure.interpreterMissing {
            return .needsSetup("Node is not installed where the app can use it, and the contacts "
                + "reader needs it to run.")
        } catch let failure as FenceProxyResource.Failure {
            return FenceProxyResource.availability(for: failure)
        } catch {
            return .needsSetup("The contacts reader cannot be used as this build carries it.")
        }
    }
}
