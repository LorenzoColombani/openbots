import Darwin
import Foundation
import OpenBotsDomain
import OpenBotsRuntime

/// Freezes the launch for the app's own Messages server.
///
/// The Contacts reader's shape — the program is shipped in the bundle, so the
/// questions are whether it is there, whether Messages is on the Mac, and
/// whether there is a node to run it with — and, like that reader, it IS
/// fenced: what `read_messages` hands back was written by whoever texted the user.
/// The fence being unavailable means the row does not launch at all rather
/// than launching unfenced.
///
/// It needs two permissions, both granted to OpenBots Next itself because the
/// server runs as the app's child. Automation → Messages is asked for by macOS
/// at the first send, and the server says so in plain words when it is refused.
/// Full Disk Access is different in the way that matters here: macOS NEVER
/// asks for it. A read without it simply fails, so a row that read "ready"
/// would switch on and then fail every read with no prompt anywhere. That is
/// why this availability opens the database itself, read-only, and says
/// "needs setup" with the pane to open when it cannot. The launch does not
/// require it: a grant made before the user flips the switch still starts the
/// server, whose refusal then names the same pane.
///
/// Nothing is written for a read or a send, so a Messages turn owns no
/// directory.
public struct AppleMessagesConnectorPreparation: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The row is not the Messages server's.
        case notTheMessagesServer
        /// Only a stdio server can be resolved to a local program.
        case unsupportedTransport
        /// The build does not carry the server.
        case scriptMissing
        /// Messages.app is not on this Mac, so there is nothing to drive.
        case applicationMissing
        /// No absolute node to run it with.
        case interpreterMissing
        /// No node to run the fence with, or no fence in the bundle.
        case fenceUnavailable(FenceProxyResource.Failure)
    }

    /// The command an app-owned row names for this server.
    public static let command = "apple-messages"

    private let scriptURL: URL?
    private let applicationCandidateURLs: [URL]
    private let databaseURL: URL
    private let interpreterCandidateURLs: [URL]
    private let tools: InstalledToolResolution
    private let applicationName: String
    /// The shim the row's badge is judged against, so a test can hand it one.
    private let fence: FenceProxyResource

    /// `databaseURL` is always passed in by a test: the default is the user's
    /// real history, and a test that read it would pass on one Mac and fail on
    /// every other one.
    public init(scriptURL: URL? = AppOwnedConnectorCatalog.appleMessagesScriptURL,
                applicationCandidateURLs: [URL] = AppOwnedConnectorCatalog.messagesApplicationURLs,
                databaseURL: URL = AppOwnedConnectorCatalog.messagesDatabaseURL(
                    homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser),
                interpreterCandidateURLs: [URL] = BrowserConnectorPreparation.defaultInterpreterURLs,
                applicationName: String = "OpenBots Next",
                ownerUID: uid_t = getuid(),
                fence: FenceProxyResource = FenceProxyResource()) {
        self.scriptURL = scriptURL
        self.applicationCandidateURLs = applicationCandidateURLs
        self.databaseURL = databaseURL
        self.interpreterCandidateURLs = interpreterCandidateURLs
        self.tools = InstalledToolResolution(ownerUID: ownerUID)
        self.applicationName = applicationName
        self.fence = fence
    }

    /// The shipped script, the node that will run it, the Messages it will
    /// start, and the history it reads.
    public func resolve(_ launch: ConnectorLaunchConfiguration) throws
        -> (script: URL, interpreter: URL, application: URL, database: URL) {
        guard launch.command == Self.command else { throw Failure.notTheMessagesServer }
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
        return (scriptURL.standardizedFileURL, interpreter, application.standardizedFileURL,
                databaseURL.standardizedFileURL)
    }

    /// Whether this process can open the user's Messages history for reading, as the
    /// `errno` of the attempt: zero when it can.
    ///
    /// A real `open(2)`, closed at once, and deliberately not a stat or an
    /// `isReadableFile`: those answer from the file's mode bits, which say yes
    /// on a file privacy protection will still refuse to open. Full Disk
    /// Access never raises a prompt, so trying costs nothing and asks nobody.
    static func databaseOpenError(_ url: URL) -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return errno }
        close(descriptor)
        return 0
    }
}

extension AppleMessagesConnectorPreparation: ConnectorLaunchPreparing {
    public func prepares(_ launch: ConnectorLaunchConfiguration) -> Bool {
        launch.command == Self.command
    }

    /// A read or a send writes nothing of its own.
    public var needsOwnedProfile: Bool { false }

    public func server(for launch: ConnectorLaunchConfiguration, profileURL: URL?,
                       temporaryDirectoryURL: URL,
                       fence: FenceProxyResource) throws -> ClaudeTextConnectorServer {
        let resolved = try resolve(launch)
        let role = ClaudeTextConnectorRole.appleMessages
        // Whoever texted the user wrote the words this hands back, so the server is
        // never launched outside the fence.
        precondition(role.handsBackUntrustedMaterial)
        let program: ClaudeTextConnectorProgram
        do {
            program = try fence.fenced(
                .node(interpreterURL: resolved.interpreter, entryPointURL: resolved.script),
                label: role.fenceLabel)
        } catch let failure as FenceProxyResource.Failure { throw Failure.fenceUnavailable(failure) }
        // The chats this bot may read. A launch
        // the store did not stamp names none, and says so as an empty list:
        // the server reads nothing either way, never everything.
        let chats = launch.chatScope ?? AppleMessagesChatScope(guids: [])
        return try ClaudeTextConnectorServer(
            name: launch.serverKey, role: role, program: program, options: [],
            // The database and the Messages it starts are the ones THIS side
            // resolved, so the badge and the launch cannot point at two
            // different copies; and the permission hints name the app the user will
            // actually find in System Settings.
            environment: ["OPENBOTS_APP_NAME": applicationName,
                          "OPENBOTS_MESSAGES_APP": resolved.application.path,
                          "OPENBOTS_MESSAGES_DB": resolved.database.path,
                          AppleMessagesChatScope.environmentKey: chats.environmentValue],
            chatScope: chats)
    }

    public func availability(for launch: ConnectorLaunchConfiguration) -> ConnectorAvailability? {
        guard prepares(launch) else { return nil }
        let resolved: (script: URL, interpreter: URL, application: URL, database: URL)
        do {
            resolved = try resolve(launch)
            // The fence is part of being launchable, so its absence is the
            // row's problem too, not a surprise inside a turn.
            try fence.verify()
        } catch Failure.scriptMissing {
            return .unavailable("This build is missing the Messages connector. Reinstall the app.")
        } catch Failure.applicationMissing {
            return .unavailable("Messages is not installed on this Mac.")
        } catch Failure.interpreterMissing {
            return .needsSetup("Node is not installed where the app can use it, and the Messages "
                + "connector needs it to run.")
        } catch let failure as FenceProxyResource.Failure {
            return FenceProxyResource.availability(for: failure)
        } catch {
            return .needsSetup("The Messages connector cannot be used as this build carries it.")
        }
        switch Self.databaseOpenError(resolved.database) {
        case 0:
            return .ready
        case ENOENT, ENOTDIR:
            // Messages has never kept a history here, or privacy protection
            // hides the folder entirely; from inside the app the two look the
            // same, so the sentence names both rather than guessing.
            return .needsSetup("There is no Messages history this app can see on this Mac. If Messages "
                + "is set up, turn on \(applicationName) in System Settings, Privacy & Security, "
                + "Full Disk Access.")
        default:
            return .needsSetup("\(applicationName) is not allowed to read your messages yet. Turn it on "
                + "in System Settings, Privacy & Security, Full Disk Access — macOS never asks for "
                + "this one.")
        }
    }
}
