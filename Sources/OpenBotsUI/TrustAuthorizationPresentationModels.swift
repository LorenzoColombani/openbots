import Foundation

/// Copy shared by the scoped authorization fixture and its presentation tests.
/// These descriptions confer no capability and do not describe live readiness.
public enum TrustAuthorizationPresentation {
    public static let fixtureDisclosure =
        "Local simulation only. No real access is granted and no action runs. Demo state resets when OpenBots quits."
    public static let noContextMessage =
        "Choose a teammate conversation to review its demo access."
    public static let readChangeBoundary =
        "Read broadly, change narrowly. A read grant never allows creation, replacement, moving, renaming, or deletion."
    public static let shellStatus = "Shell is off — not available in this fixture."
    public static let shellWarning =
        "A future shell-enabled teammate could run broad local commands. Folder and domain toggles would not be a hard operating-system security boundary. This trust mode still needs a separate decision."
    public static let readinessDisclosure =
        "These demo controls do not install a connector, sign in, or request macOS permission."
    public static let reviewDisclosure =
        "Approval is for this exact demo target and payload, once. It does not execute the action."
    public static let loadFailure =
        "OpenBots couldn’t load this conversation’s demo access. No real authority changed."
    public static let actionFailure =
        "That demo action is no longer available. Review the current scope and prepare it again. No real action ran."

    public static func shortFingerprint(_ value: String) -> String {
        String(value.prefix(12))
    }
}
