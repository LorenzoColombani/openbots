import AppKit
import Foundation

/// The apps a connector starts in the background for a turn, and the one way
/// the app ends them (closing the app ends all work).
/// A Contacts lookup starts Contacts hidden (`open -g -j`, apple-contacts.js)
/// when it is not running; nothing quit it, and it ran on for half an hour
/// after the turn.
public protocol HiddenAppQuitting: Sendable {
    /// Whether an app with this bundle identifier runs for this user now.
    func isRunning(bundleIdentifier: String) -> Bool
    /// Asks the app to quit, the way a Quit from its menu does, but only
    /// while it is hidden and not in front: one the user brought up meanwhile
    /// is theirs. True when it was asked.
    func quitIfHidden(bundleIdentifier: String) -> Bool
}

public struct WorkspaceHiddenAppQuitter: HiddenAppQuitting {
    public init() {}

    public func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    public func quitIfHidden(bundleIdentifier: String) -> Bool {
        var asked = false
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        where app.isHidden && !app.isActive {
            asked = app.terminate() || asked
        }
        return asked
    }
}
