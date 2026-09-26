import Foundation
import OpenBotsDomain
import OpenBotsRuntime

/// One connector's answer to "where is that server, and how is it started".
///
/// The launch service holds several of these and asks each row's owner. Nothing
/// here reaches the network or a package manager: a preparation reads the disk,
/// or it says the row needs setup.
public protocol ConnectorLaunchPreparing: ConnectorAvailabilityProbing {
    /// True when this preparation owns that row. A row nobody owns is not
    /// launched — mail, calendar and Drive each arrive with their own owner.
    func prepares(_ launch: ConnectorLaunchConfiguration) -> Bool

    /// Whether the launch needs a directory of its own for the turn.
    ///
    /// The browser does: its profile path is also the only honest way to tell
    /// the app's Chrome from the user's. A server that talks to an app already
    /// running on the Mac needs nothing, and must not be given a directory
    /// nothing will own.
    var needsOwnedProfile: Bool { get }

    /// The frozen launch for one turn, fenced when its answers come from
    /// outside the team.
    func server(for launch: ConnectorLaunchConfiguration, profileURL: URL?,
                temporaryDirectoryURL: URL, fence: FenceProxyResource) throws -> ClaudeTextConnectorServer
}

extension BrowserConnectorPreparation: ConnectorLaunchPreparing {
    public func prepares(_ launch: ConnectorLaunchConfiguration) -> Bool {
        (try? Self.packageSpecification(in: launch)) != nil
    }

    public var needsOwnedProfile: Bool { true }

    public func server(for launch: ConnectorLaunchConfiguration, profileURL: URL?,
                       temporaryDirectoryURL: URL,
                       fence: FenceProxyResource) throws -> ClaudeTextConnectorServer {
        guard let profileURL else { throw Failure.entryPointUnusable }
        return try server(for: launch, profileURL: profileURL,
                          temporaryDirectoryURL: temporaryDirectoryURL, fence: fence)
    }
}
