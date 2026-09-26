import Foundation
import OpenBotsServices

/// What the setup screen says at a person's first blocked moment, in the app's
/// own words: what did not happen, and what to do next. No build vocabulary
/// ("Preview", "one-shot", "tracing", "isolation", "prerequisites",
/// "metadata", "provider flow", "inconclusive") reaches the screen.
public enum ClaudeSetupWording {
    /// The official native install.
    public static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    public static let installPageURL = URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup")!

    public static func explanation(_ problem: ClaudeSetupProblem) -> String {
        switch problem {
        case .installationMissing:
            "Claude Code is not on this Mac. Bots are Claude Code sessions, so it has to be installed first. Nothing was started."
        case .installationRejected:
            "The Claude Code on this Mac is not the official one. Nothing was launched."
        case .installationUnavailable:
            "OpenBots could not check the Claude Code on this Mac. Nothing was started."
        case .profileMissing:
            "OpenBots has not set up its own Claude account folder yet. Nothing can sign in until it does."
        case .profileRejected:
            "OpenBots does not recognise its Claude account folder. No password or token was read or changed."
        case .profileUnavailable:
            "OpenBots could not check its Claude account folder. Nothing was signed in or out."
        case .connectionCheckInconclusive:
            "OpenBots could not confirm your Claude subscription. This does not mean you are signed out, and it will not retry on its own."
        case .signInIncomplete:
            "OpenBots could not confirm the sign-in finished. Check Terminal, then press Check Claude."
        }
    }

    public static let installOffer = "Paste it in Terminal, then press Check Claude."
    public static let copyInstallCommandTitle = "Copy the install command"
    public static let openInstallPageTitle = "Open the install page"

    /// The vocabulary the screen never uses. A test walks every sentence.
    /// "official CLI", "Claude CLI" and "teammate" are build words too.
    public static let bannedWords = ["Preview", "one-shot", "tracing", "isolation", "prerequisites", "metadata",
                                     "provider flow", "inconclusive", "official CLI", "Claude CLI", "teammate"]

    /// The line at the top of the screen, in a few words.
    public static func title(for state: ClaudeSetupState, localInstallationChecked: Bool) -> String {
        switch state {
        case .notChecked, .readyToConnect: "Claude connection not checked"
        case .checking: "Checking this Mac…"
        case .needsSignIn: "Sign in to Claude"
        case .signingIn: "Getting sign-in ready…"
        case .signedInNeedsVerification: "Signed in, plan not checked yet"
        case .handedOffNeedsVerification: "Finish sign-in in Terminal"
        case .checkingSubscription: "Checking Claude…"
        case .verified: "Connected to Claude"
        case .problem: "Could not check Claude"
        case .actionRequired(.correctedStatusCheckApproval):
            localInstallationChecked ? "Claude Code is installed" : "Checking your sign-in needs your OK"
        case .actionRequired(.tracedOfficialSignIn): "Sign-in is not ready yet"
        case .cancelled: "Stopped waiting"
        }
    }

    /// The sentences under the title: what is true now, and what to do next.
    public static func status(for state: ClaudeSetupState) -> String {
        switch state {
        case .notChecked:
            "Check Claude looks at Claude Code on this Mac and at your Claude plan. It does not sign you in or send saved messages."
        case .checking:
            "Checking Claude Code on this Mac. Your account is not checked yet, and nothing is sent to Claude."
        case .readyToConnect:
            "Claude Code on this Mac looks right. Press Check Claude to check your Claude plan."
        case .needsSignIn:
            "Claude Code says OpenBots is signed out. Press Sign in with Claude to sign in through Terminal. Your saved work stays here."
        case .signingIn:
            "Getting Claude Code’s own sign-in ready in Terminal. Your Claude plan is not checked yet."
        case .signedInNeedsVerification:
            "Sign-in finished, but your Claude plan is not checked yet. OpenBots checks it when you come back to this window, or press Check Claude."
        case .handedOffNeedsVerification:
            "Follow the sign-in steps in Terminal and your browser. When you come back to this window, OpenBots checks your sign-in by itself. You can also press Check Claude."
        case .checkingSubscription:
            "Asking Claude Code about your Claude plan. This does not sign you in or send any messages."
        case .verified:
            "Your Claude plan passed its last check. Each new reply is checked again first. What each bot may do is set separately."
        case .actionRequired(.correctedStatusCheckApproval):
            "One sign-in check needs your OK before OpenBots can go on. Your earlier OK is already saved."
        case .actionRequired(.tracedOfficialSignIn):
            "Sign-in cannot start until its safety check is ready. Your earlier OK is saved, and no sign-in window was opened."
        case .cancelled:
            "Stopped waiting. What was found earlier is still below. This does not close Terminal, stop a sign-in already running there, or sign you out."
        case .problem(let problem):
            explanation(problem)
        }
    }

    public static let signInHelp = "Opens Claude Code’s own sign-in in Terminal. Come back to this window when you are done."
    public static let signInNote = "Sign-in opens Claude Code in Terminal for your Claude Pro or Max account. Follow the steps in your browser. OpenBots never sees your password or copies your sign-in."
    public static let checkHelp = "Checks Claude Code on this Mac, then your Claude plan. It does not sign you in or send messages."
    public static let inspectHelp = "Checks Claude Code on this Mac and OpenBots’ own account folder only. Your account is not checked."
    public static let findingsNote = "These checks alone do not mean Claude is connected."
    public static let textRepliesNote = "New messages can get a Claude reply after a fresh check. What a bot may use follows the switches for the whole app and that bot’s own switches."
    public static let localWorkNote = "You can create and choose bots, read saved conversations, and save messages with files on this Mac. Saved messages are not sent later by themselves."

    public static func installationLabel(_ finding: ClaudeInstallationFinding) -> String {
        switch finding {
        case .notChecked: "Not checked"
        case .missing: "Not found"
        case .verified: "The real Claude Code"
        case .rejected: "Not the real Claude Code"
        case .unavailable: "Could not check"
        }
    }

    public static func profileLabel(_ finding: ClaudeProfileFinding) -> String {
        switch finding {
        case .notChecked: "Not checked"
        case .missing: "Not found"
        case .metadataVerified: "Set up and checked"
        case .rejected: "Not recognised"
        case .unavailable: "Could not check"
        }
    }

    public static func details(for state: ClaudeSetupState) -> String {
        switch state {
        case .actionRequired(.correctedStatusCheckApproval):
            "The local check only looks at the Claude Code on this Mac and OpenBots’ own account folder. A fresh status check needs your approval; nothing retries by itself. Sign-in, if it is needed later, is its own step."
        case .actionRequired(.tracedOfficialSignIn):
            "Sign-in cannot start until its safety check is ready. When it is, Terminal runs only Claude Code’s own sign-in command for OpenBots’ account folder. OpenBots never reads or copies tokens."
        case .readyToConnect, .needsSignIn, .signedInNeedsVerification, .handedOffNeedsVerification, .verified, .checkingSubscription, .signingIn:
            "Your subscription counts as confirmed only when Claude Code itself reports a claude.ai Pro or Max plan. Terminal opening, a browser opening or a sign-in returning is not that. Status and sign-in use OpenBots’ own account folder; neither gives a bot any tool."
        default:
            "Check Claude looks at the Claude Code on this Mac and OpenBots’ own account folder, then asks Claude Code for your subscription status. Inspect Installation does the local part only. Sign-in is offered when Claude Code says it is needed."
        }
    }
}
