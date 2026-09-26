import Darwin
import Foundation
import OpenBotsDomain
import OpenBotsRuntime

/// Freezes the launch for the app's own Calendar reader.
///
/// The Contacts reader's shape, with one difference that runs through the whole
/// connector: this one drives no application. Contacts and Mail are read through
/// Apple Events, so their rows check that the app is installed and their
/// scripts start it hidden. Calendar is read through EventKit, in a binary the
/// bundle carries, so Calendar.app need not exist and is never launched.
///
/// Why a binary rather than the JXA every other app-owned reader uses is argued
/// in `apple-calendar.js`: an Apple Events reader
/// misses much of a year of a calendar because a recurring event has one start
/// date and `iCal.sdef` cannot expand a series. That is not a performance
/// preference, it is the difference between a reader that is right and one that
/// is quietly wrong, so the availability branches below are about the binary.
///
/// It IS fenced. An invitation's title, location and notes are written by
/// whoever sent it, and the reader hands them back verbatim, so the fence being
/// unavailable means the row does not launch at all rather than launching
/// unfenced.
///
/// Nothing is written for a read, so a calendar turn owns no directory.
public struct AppleCalendarConnectorPreparation: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The row is not the calendar reader's.
        case notTheCalendarReader
        /// Only a stdio server can be resolved to a local program.
        case unsupportedTransport
        /// The build does not carry the server. Nothing can be read.
        case scriptMissing
        /// The build does not carry the binary the server reads through.
        case helperMissing
        /// No absolute node to run the server with.
        case interpreterMissing
        /// No node to run the fence with, or no fence in the bundle.
        case fenceUnavailable(FenceProxyResource.Failure)
    }

    /// The command an app-owned row names for this server.
    public static let command = "apple-calendar"

    private let scriptURL: URL?
    private let helperCandidateURLs: [URL]
    private let interpreterCandidateURLs: [URL]
    private let tools: InstalledToolResolution
    private let applicationName: String
    /// The shim the row's badge is judged against, so a test can hand it one.
    private let fence: FenceProxyResource

    public init(scriptURL: URL? = AppOwnedConnectorCatalog.appleCalendarScriptURL,
                helperCandidateURLs: [URL] = AppOwnedConnectorCatalog.appleCalendarHelperURLs,
                interpreterCandidateURLs: [URL] = BrowserConnectorPreparation.defaultInterpreterURLs,
                applicationName: String = "OpenBots Next",
                ownerUID: uid_t = getuid(),
                fence: FenceProxyResource = FenceProxyResource()) {
        self.scriptURL = scriptURL
        self.helperCandidateURLs = helperCandidateURLs
        self.interpreterCandidateURLs = interpreterCandidateURLs
        self.tools = InstalledToolResolution(ownerUID: ownerUID)
        self.applicationName = applicationName
        self.fence = fence
    }

    /// The shipped server, the node that will run it, and the binary it reads
    /// the calendar through.
    public func resolve(_ launch: ConnectorLaunchConfiguration) throws
        -> (script: URL, interpreter: URL, helper: URL) {
        guard launch.command == Self.command else { throw Failure.notTheCalendarReader }
        guard launch.transport == .stdio else { throw Failure.unsupportedTransport }
        guard let scriptURL, FileManager().isReadableFile(atPath: scriptURL.path) else {
            throw Failure.scriptMissing
        }
        guard let helper = AppOwnedConnectorCatalog
            .resolvedAppleCalendarHelperURL(candidates: helperCandidateURLs)
        else { throw Failure.helperMissing }
        guard let interpreter = tools.firstResolved(of: interpreterCandidateURLs) else {
            throw Failure.interpreterMissing
        }
        return (scriptURL.standardizedFileURL, interpreter, helper)
    }
}

extension AppleCalendarConnectorPreparation: ConnectorLaunchPreparing {
    public func prepares(_ launch: ConnectorLaunchConfiguration) -> Bool {
        launch.command == Self.command
    }

    /// A read writes nothing of its own.
    public var needsOwnedProfile: Bool { false }

    public func server(for launch: ConnectorLaunchConfiguration, profileURL: URL?,
                       temporaryDirectoryURL: URL,
                       fence: FenceProxyResource) throws -> ClaudeTextConnectorServer {
        let resolved = try resolve(launch)
        let role = ClaudeTextConnectorRole.appleCalendarRead
        // Whoever sent the invitation wrote the words this hands back, so the
        // reader is never launched outside the fence.
        precondition(role.handsBackUntrustedMaterial)
        let program: ClaudeTextConnectorProgram
        do {
            program = try fence.fenced(
                .node(interpreterURL: resolved.interpreter, entryPointURL: resolved.script),
                label: role.fenceLabel)
        } catch let failure as FenceProxyResource.Failure { throw Failure.fenceUnavailable(failure) }
        return try ClaudeTextConnectorServer(
            name: launch.serverKey, role: role, program: program, options: [],
            // The binary the server reads through is the one THIS side
            // resolved, so the badge and the launch cannot end up pointing at
            // two different copies the way two independent lookups would — and
            // the permission hint names the app the user will actually find in
            // System Settings.
            environment: ["OPENBOTS_APP_NAME": applicationName,
                          "OPENBOTS_CALENDAR_HELPER": resolved.helper.path])
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
            return .unavailable("This build is missing the calendar reader. Reinstall the app.")
        } catch Failure.helperMissing {
            // Deliberately the same sentence as the one above. Which half of
            // the reader is missing is a fact about the build, not something the
            // user can act on differently, and both mean the same thing to them.
            return .unavailable("This build is missing the calendar reader. Reinstall the app.")
        } catch Failure.interpreterMissing {
            return .needsSetup("Node is not installed where the app can use it, and the calendar "
                + "reader needs it to run.")
        } catch let failure as FenceProxyResource.Failure {
            return FenceProxyResource.availability(for: failure)
        } catch {
            return .needsSetup("The calendar reader cannot be used as this build carries it.")
        }
    }
}
