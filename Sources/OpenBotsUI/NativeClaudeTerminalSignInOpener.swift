import AppKit
import Foundation
import OpenBotsServices

/// Opens an already admitted, app-generated command file in Apple's Terminal.
/// The service owns command validation and operation admission. This adapter
/// never reads the file, parses a login transcript or observes credentials.
@MainActor
public final class NativeClaudeTerminalSignInOpener: ClaudeOfficialSignInOpening {
    private let terminalURL: @MainActor @Sendable () -> URL?
    private let openCommand: @MainActor @Sendable (URL, URL) async -> Bool

    public init() {
        terminalURL = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        }
        openCommand = { commandFile, terminal in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            return await withCheckedContinuation { continuation in
                NSWorkspace.shared.open(
                    [commandFile], withApplicationAt: terminal, configuration: configuration
                ) { application, error in
                    // Launch acceptance is not evidence of completed sign-in.
                    continuation.resume(returning: application != nil && error == nil)
                }
            }
        }
    }

    /// Test seam: no NSWorkspace lookup or application opening is necessary.
    init(
        terminalURL: @escaping @MainActor @Sendable () -> URL?,
        openCommand: @escaping @MainActor @Sendable (URL, URL) async -> Bool
    ) {
        self.terminalURL = terminalURL
        self.openCommand = openCommand
    }

    public func openOfficialSignIn(commandFile: URL) async -> Bool {
        guard !Task.isCancelled, commandFile.isFileURL,
              commandFile.pathExtension == "command",
              let terminal = terminalURL(), terminal.isFileURL else { return false }
        guard !Task.isCancelled else { return false }
        // Cancellation after dispatch cannot undo the user's Terminal flow.
        return await openCommand(commandFile, terminal)
    }
}
