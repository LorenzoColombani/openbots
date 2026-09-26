import Darwin
import Foundation
import OpenBotsDomain
import OpenBotsRuntime

/// Finds the mail reader a tool install put on this Mac, and freezes the launch
/// for one turn.
///
/// It reads and never installs. The package is pinned, and the version is taken
/// from the install's own record rather than from the name of a directory —
/// a resolution that trusts a cache directory's name can run the wrong copy.
///
/// There is no profile and no temporary state: the reader drives Mail.app,
/// which is already running as the user, so nothing is written to the disk for a
/// mail turn at all.
public struct AppleMailConnectorPreparation: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The row is not the mail reader's.
        case notTheMailConnector
        /// Only a stdio server can be resolved to a local program.
        case unsupportedTransport
        /// Nothing usable at either place a tool install writes it. This is the
        /// needs-setup state: one command by the user fixes it, and the app
        /// never runs it for them.
        case toolNotInstalled
        /// It is installed, but not the version the app pins.
        case wrongVersion(installed: String?)
        /// No node to run the fence with, or no fence in the bundle.
        case fenceUnavailable(FenceProxyResource.Failure)
    }

    private let homeDirectoryURL: URL
    private let tools: InstalledToolResolution
    private let ownerUID: uid_t
    /// The shim the row's badge is judged against, so a test can hand it one.
    private let fence: FenceProxyResource

    public init(homeDirectoryURL: URL, ownerUID: uid_t = getuid(),
                fence: FenceProxyResource = FenceProxyResource()) {
        self.homeDirectoryURL = homeDirectoryURL
        self.tools = InstalledToolResolution(ownerUID: ownerUID)
        self.ownerUID = ownerUID
        self.fence = fence
    }

    private var fileManager: FileManager { FileManager() }

    /// The console script that will actually run, and the version its own
    /// install record claims.
    public func resolve(_ launch: ConnectorLaunchConfiguration) throws -> (script: URL, version: String) {
        guard launch.command == AppOwnedConnectorCatalog.appleMailPackage,
              launch.pinnedPackage == "\(AppOwnedConnectorCatalog.appleMailPackage)==\(AppOwnedConnectorCatalog.appleMailVersion)"
        else { throw Failure.notTheMailConnector }
        guard launch.transport == .stdio else { throw Failure.unsupportedTransport }
        guard let script = tools.firstResolved(
            of: AppOwnedConnectorCatalog.appleMailToolURLs(homeDirectoryURL: homeDirectoryURL))
        else { throw Failure.toolNotInstalled }
        let installed = installedVersion(besideScriptAt: script)
        guard installed == AppOwnedConnectorCatalog.appleMailVersion else {
            throw Failure.wrongVersion(installed: installed)
        }
        return (script, AppOwnedConnectorCatalog.appleMailVersion)
    }

    /// The version recorded by the install itself: the `dist-info` directory
    /// the packaging writes beside the script, never the path it sits in.
    private func installedVersion(besideScriptAt script: URL) -> String? {
        let toolRoot = script.deletingLastPathComponent().deletingLastPathComponent()
        let libraryRoot = toolRoot.appendingPathComponent("lib", isDirectory: true)
        let underscored = AppOwnedConnectorCatalog.appleMailPackage.replacingOccurrences(of: "-", with: "_")
        guard let pythons = try? fileManager.contentsOfDirectory(at: libraryRoot,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for python in pythons.sorted(by: { $0.path < $1.path }) {
            let packages = python.appendingPathComponent("site-packages", isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(at: packages,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for entry in entries where entry.pathExtension == "dist-info" {
                let name = entry.deletingPathExtension().lastPathComponent
                guard name.hasPrefix(underscored + "-") else { continue }
                return String(name.dropFirst(underscored.count + 1))
            }
        }
        return nil
    }
}

extension AppleMailConnectorPreparation: ConnectorLaunchPreparing {
    public func prepares(_ launch: ConnectorLaunchConfiguration) -> Bool {
        launch.command == AppOwnedConnectorCatalog.appleMailPackage
    }

    /// Nothing is written for a mail turn.
    public var needsOwnedProfile: Bool { false }

    public func server(for launch: ConnectorLaunchConfiguration, profileURL: URL?,
                       temporaryDirectoryURL: URL,
                       fence: FenceProxyResource) throws -> ClaudeTextConnectorServer {
        let resolved = try resolve(launch)
        let role = ClaudeTextConnectorRole.appleMailRead
        // A stranger wrote every message this will hand back, so the reader is
        // never launched outside the fence.
        let program: ClaudeTextConnectorProgram
        do { program = try fence.fenced(.installedTool(resolved.script), label: role.fenceLabel) }
        catch let failure as FenceProxyResource.Failure { throw Failure.fenceUnavailable(failure) }
        // Its file state goes where the turn's own temporary state goes, so
        // nothing it writes outlives the app's own scratch space. Nothing is
        // created here: the reader makes that directory only if it ever writes.
        return try ClaudeTextConnectorServer(
            name: launch.serverKey, role: role, program: program, options: [.readOnly],
            environment: ["APPLE_MAIL_MCP_HOME":
                temporaryDirectoryURL.appendingPathComponent("apple-mail", isDirectory: true).path])
    }

    /// What the row says before anything is launched.
    public func availability(for launch: ConnectorLaunchConfiguration) -> ConnectorAvailability? {
        guard prepares(launch) else { return nil }
        do {
            _ = try resolve(launch)
            // The fence is part of being launchable, so its absence is the
            // row's problem too, not a surprise inside a turn.
            try fence.verify()
            return .ready
        } catch Failure.toolNotInstalled {
            return .needsSetup("The mail reader is not installed yet. Install it once with "
                + "`uv tool install \(AppOwnedConnectorCatalog.appleMailPackage)"
                + "==\(AppOwnedConnectorCatalog.appleMailVersion)`.")
        } catch Failure.wrongVersion(let installed) {
            let has = installed.map { "Version \($0) is installed" } ?? "Another version is installed"
            return .needsSetup("\(has), and the app pins "
                + "\(AppOwnedConnectorCatalog.appleMailVersion). Install that one with "
                + "`uv tool install \(AppOwnedConnectorCatalog.appleMailPackage)"
                + "==\(AppOwnedConnectorCatalog.appleMailVersion)`.")
        } catch let failure as FenceProxyResource.Failure {
            return FenceProxyResource.availability(for: failure)
        } catch {
            return .needsSetup("The mail reader on this Mac cannot be used as it is installed.")
        }
    }
}
