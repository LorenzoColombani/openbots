import Darwin
import Foundation
import OpenBotsDomain
import OpenBotsRuntime

/// Freezes the launch for the app's own mail sender.
///
/// Simpler than the reader's, because nothing has to be found: the program is
/// shipped in the bundle, so the only question is whether there is a node to
/// run it with. It is not fenced — the answers are the app's own sentences
/// about what it did with what the user approved — and it writes nothing, so a send
/// turn owns no directory either.
public struct AppleMailSendPreparation: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The row is not the sender's.
        case notTheMailSender
        /// Only a stdio server can be resolved to a local program.
        case unsupportedTransport
        /// The build does not carry the sender. Nothing can be sent.
        case scriptMissing
        /// No absolute node to run it with.
        case interpreterMissing
    }

    /// The command an app-owned row names for this server.
    public static let command = "apple-mail-send"

    private let scriptURL: URL?
    private let interpreterCandidateURLs: [URL]
    private let tools: InstalledToolResolution
    private let applicationName: String

    public init(scriptURL: URL? = AppOwnedConnectorCatalog.appleMailSendScriptURL,
                interpreterCandidateURLs: [URL] = BrowserConnectorPreparation.defaultInterpreterURLs,
                applicationName: String = "OpenBots Next",
                ownerUID: uid_t = getuid()) {
        self.scriptURL = scriptURL
        self.interpreterCandidateURLs = interpreterCandidateURLs
        self.tools = InstalledToolResolution(ownerUID: ownerUID)
        self.applicationName = applicationName
    }

    /// The shipped script and the node that will run it.
    public func resolve(_ launch: ConnectorLaunchConfiguration) throws -> (script: URL, interpreter: URL) {
        guard launch.command == Self.command else { throw Failure.notTheMailSender }
        guard launch.transport == .stdio else { throw Failure.unsupportedTransport }
        guard let scriptURL, FileManager().isReadableFile(atPath: scriptURL.path) else {
            throw Failure.scriptMissing
        }
        guard let interpreter = tools.firstResolved(of: interpreterCandidateURLs) else {
            throw Failure.interpreterMissing
        }
        return (scriptURL.standardizedFileURL, interpreter)
    }
}

extension AppleMailSendPreparation: ConnectorLaunchPreparing {
    public func prepares(_ launch: ConnectorLaunchConfiguration) -> Bool {
        launch.command == Self.command
    }

    /// A send turn writes nothing of its own.
    public var needsOwnedProfile: Bool { false }

    public func server(for launch: ConnectorLaunchConfiguration, profileURL: URL?,
                       temporaryDirectoryURL: URL,
                       fence: FenceProxyResource) throws -> ClaudeTextConnectorServer {
        let resolved = try resolve(launch)
        // Not fenced, by declaration: this server's answers are the app's own.
        // The label the fence would use is defined for it all the same, so the
        // decision is visible rather than an omission.
        precondition(!ClaudeTextConnectorRole.appleMailSend.handsBackUntrustedMaterial)
        return try ClaudeTextConnectorServer(
            name: launch.serverKey, role: .appleMailSend,
            program: .node(interpreterURL: resolved.interpreter, entryPointURL: resolved.script),
            options: [],
            // The permission hint the sender prints when Mail refuses has to
            // name the app the user will actually find in System Settings.
            environment: ["OPENBOTS_APP_NAME": applicationName])
    }

    public func availability(for launch: ConnectorLaunchConfiguration) -> ConnectorAvailability? {
        guard prepares(launch) else { return nil }
        do {
            _ = try resolve(launch)
            return .ready
        } catch Failure.scriptMissing {
            return .unavailable("This build is missing the mail sender. Reinstall the app.")
        } catch Failure.interpreterMissing {
            return .needsSetup("Node is not installed where the app can use it, and the mail sender "
                + "needs it to run.")
        } catch {
            return .needsSetup("The mail sender cannot be used as this build carries it.")
        }
    }
}
