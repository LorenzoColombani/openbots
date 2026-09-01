import Foundation
import Testing
@testable import OpenBotsUI

@MainActor
private final class TerminalSignInOpenSpy {
    var lookups = 0
    var commands: [URL] = []
    var applications: [URL] = []
}

@Test("Terminal handoff passes the exact file and application URLs, with acceptance only", arguments: [true, false])
@MainActor
func claudeTerminalHandoffUsesExplicitApplication(accepted: Bool) async {
    let command = URL(fileURLWithPath: "/private/tmp/Preview Runtime.noindex/Sign In.command")
    let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    let spy = TerminalSignInOpenSpy()
    let opener = NativeClaudeTerminalSignInOpener(
        terminalURL: { spy.lookups += 1; return terminal },
        openCommand: { file, application in
            spy.commands.append(file)
            spy.applications.append(application)
            return accepted
        }
    )
    #expect(spy.lookups == 0)
    #expect(spy.commands.isEmpty)
    #expect(await opener.openOfficialSignIn(commandFile: command) == accepted)
    #expect(spy.lookups == 1)
    #expect(spy.commands == [command])
    #expect(spy.applications == [terminal])
}

@Test("Terminal handoff rejects remote URLs and non-command files before any application lookup")
@MainActor
func claudeTerminalHandoffRejectsUnsupportedFiles() async throws {
    let spy = TerminalSignInOpenSpy()
    let opener = NativeClaudeTerminalSignInOpener(
        terminalURL: { spy.lookups += 1; return URL(fileURLWithPath: "/Terminal.app") },
        openCommand: { file, _ in spy.commands.append(file); return true }
    )
    for command in [
        try #require(URL(string: "https://example.invalid/sign-in.command")),
        URL(fileURLWithPath: "/private/tmp/sign-in.sh"),
        URL(fileURLWithPath: "/private/tmp/sign-in.txt")
    ] {
        #expect(await !opener.openOfficialSignIn(commandFile: command))
    }
    #expect(spy.lookups == 0)
    #expect(spy.commands.isEmpty)
}

@Test("A missing Terminal application fails without invoking any substitute")
@MainActor
func claudeTerminalHandoffDoesNotSubstituteMissingTerminal() async {
    let spy = TerminalSignInOpenSpy()
    let opener = NativeClaudeTerminalSignInOpener(
        terminalURL: { spy.lookups += 1; return nil },
        openCommand: { file, _ in spy.commands.append(file); return true }
    )
    #expect(await !opener.openOfficialSignIn(
        commandFile: URL(fileURLWithPath: "/private/tmp/sign-in.command")
    ))
    #expect(spy.lookups == 1)
    #expect(spy.commands.isEmpty)
}

@Test("A handoff cancelled before dispatch does not open Terminal")
@MainActor
func claudeTerminalHandoffCancellationBeforeDispatchIsInert() async {
    let spy = TerminalSignInOpenSpy()
    let opener = NativeClaudeTerminalSignInOpener(
        terminalURL: { spy.lookups += 1; return URL(fileURLWithPath: "/Terminal.app") },
        openCommand: { file, _ in spy.commands.append(file); return true }
    )
    let task = Task {
        await opener.openOfficialSignIn(commandFile: URL(fileURLWithPath: "/private/tmp/sign-in.command"))
    }
    task.cancel()
    #expect(await !task.value)
    #expect(spy.lookups == 0)
    #expect(spy.commands.isEmpty)
}
