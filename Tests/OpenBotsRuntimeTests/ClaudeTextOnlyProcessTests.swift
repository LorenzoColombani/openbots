import Darwin
import Foundation
import Testing
@testable import OpenBotsRuntime

@Test("Synthetic text child receives one JSON input, EOF and the exact per-run context environment; callbacks drain before success",
      arguments: ["default", "standard"])
func claudeTextProcessRoundTrip(contextWindow: String) async throws {
    let template = try textOnlyTestRequest(text: "Text \" newline\n😀 $(touch injected)", contextWindow: contextWindow)
    let fixture = try ClaudeConnectionFixture(body: """
    [ "$1" = --print ] || exit 31
    [ "$NETRC" = /dev/null ] || exit 32
    [ -z "${ANTHROPIC_API_KEY+x}" ] || exit 33
    [ -z "${CLAUDE_CODE_OAUTH_TOKEN+x}" ] || exit 34
    [ "$CLAUDE_CODE_DISABLE_TERMINAL_TITLE" = 1 ] || exit 35
    [ "$CLAUDE_CODE_DISABLE_ATTACHMENTS" = 1 ] || exit 37
    [ "$CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK" = 1 ] || exit 41
    [ "${CLAUDE_CODE_DISABLE_1M_CONTEXT-unset}" = "\(contextWindow == "standard" ? "1" : "unset")" ] || exit 40
    printf '%s\\n' "$@" > argv-observed
    prompt_file=''
    while [ "$#" -gt 0 ]; do
      [ "$1" != --system-prompt ] || exit 38
      if [ "$1" = --system-prompt-file ]; then shift; prompt_file="$1"; fi
      shift
    done
    [ -n "$prompt_file" ] && [ -f "$prompt_file" ] || exit 39
    /bin/cat "$prompt_file" > system-prompt-observed
    printf 'ignored diagnostic with account-like information\\n' >&2
    \(try textProcessEmit(textOnlyTestInit(template)))
    IFS= read -r line
    printf '{"isReplay":true,"parent_tool_use_id":null,%s\\n' "${line#?}"
    if IFS= read -r extra; then exit 36; fi
    \(try textProcessEmit(textOnlyTestDelta(template, text: "Hello ")))
    \(try textProcessEmit(textOnlyTestDelta(template, text: "back")))
    \(try textProcessEmit(textOnlyTestResult(template)))
    """, name: "fake '$(touch injected)' claude")
    defer { fixture.remove() }
    let request = try textOnlyTestRequest(target: fixture.target, text: template.text,
                                        systemPrompt: "Literal ' ; $(touch injected)", contextWindow: contextWindow)
    let events = TextProcessEvents()
    let result = await NativeClaudeTextOnlyRunner().run(request: request) { event in
        try? await Task.sleep(for: .milliseconds(10))
        await events.append(event)
    }
    #expect(result == .success(.init(sessionID: request.sessionID, actualModel: "claude-sonnet-5", text: "Hello back", confirmedActualModel: "claude-sonnet-5")))
    let observed = await events.snapshot()
    #expect(observed.contains(.inputSubmitted(messageID: request.messageID)))
    #expect(observed.contains(.inputAcknowledged(messageID: request.messageID)))
    #expect(observed.last == .textSnapshot("Hello back"))
    #expect(observed.allSatisfy { if case .diagnostic = $0 { return false }; return true })
    #expect(!FileManager.default.fileExists(atPath: fixture.target.workingDirectoryURL.appendingPathComponent("injected").path))
    let arguments = try fixture.readWorkingFile("argv-observed")
    #expect(!arguments.contains(request.systemPrompt))
    #expect(!arguments.contains(request.text))
    #expect(try fixture.readWorkingFile("system-prompt-observed") == request.systemPrompt)
    #expect(!FileManager.default.fileExists(atPath: ClaudeTextOnlyCommandBuilder.systemPromptFileURL(for: request).path))
}

@Test("Synthetic child preserves acknowledged partial text when a coalesced output ends in provider failure")
func claudeTextProcessPreservesPartialOnError() async throws {
    let template = try textOnlyTestRequest()
    let prefixAndError = try textOnlyTestInit(template) + textOnlyTestReplay(template)
        + textOnlyTestDelta(template, text: "Verified partial")
        + textOnlyTestResult(template, override: ["is_error": true, "result": "Unvalidated diagnostic"])
    #expect(prefixAndError.count < 4_096)
    let fixture = try ClaudeConnectionFixture(body: """
    IFS= read -r line
    if IFS= read -r extra; then exit 31; fi
    \(try textProcessEmit(prefixAndError))
    """)
    defer { fixture.remove() }
    let request = try textOnlyTestRequest(target: fixture.target)
    let events = TextProcessEvents()
    let result = await NativeClaudeTextOnlyRunner().run(request: request) { await events.append($0) }
    #expect(result == .failed(.providerFailed))
    let observed = await events.snapshot()
    #expect(observed.filter { $0 == .initialized(sessionID: request.sessionID, actualModel: "claude-sonnet-5") }.count == 1)
    #expect(observed.filter { $0 == .inputAcknowledged(messageID: request.messageID) }.count == 1)
    #expect(observed.filter { $0 == .textSnapshot("Verified partial") }.count == 1)
    #expect(!observed.contains(.textSnapshot("Unvalidated diagnostic")))
    #expect(observed.last == .diagnostic(.providerFailure))
    #expect(observed.filter { if case .diagnostic = $0 { return true }; return false }.count == 1)
}

// A window of
// sixty-four rounds can use most of the ceiling from launch; the renewal card
// waits ten minutes, and the turn must not end as "did not finish in time"
// under it. Here the ceiling is six seconds, the rounds run out after three,
// and the user answers four seconds later, past the ceiling from launch.
@Test("When the rounds run out the ceiling moves to a whole ceiling from then, so an answer after the launch ceiling still renews")
func renewalCardOutlivesTheLaunchCeiling() async throws {
    let template = try roundsRenewalRequest(try textOnlyTestRequest().target)
    let fixture = try ClaudeConnectionFixture(body: try roundsRenewalChild(template, pausesBeforeTheCap: 3))
    defer { fixture.remove() }
    let request = try roundsRenewalRequest(fixture.target)
    let control = ClaudeTextTurnControl()
    let result = await NativeClaudeTextOnlyRunner(testTimeout: 30, testOverallTimeout: 6)
        .run(request: request, control: control) { event in
            guard case .roundsRanOut = event else { return }
            try? await Task.sleep(for: .seconds(4))
            control.decideRoundsRenewal(renew: true)
        }
    #expect(result == .success(.init(sessionID: request.sessionID, actualModel: "claude-sonnet-5",
        text: "Working. Done.", confirmedActualModel: "claude-sonnet-5")))
}

// The fallback frame ends the turn at that frame; the child
// is stopped, and neither its exit nor the stop reads as a fault.
@Test("A child that hands a refused reply to another model is stopped, and the turn ends declined with no diagnostic")
func claudeTextProcessEndsARefusalFallbackAsDeclined() async throws {
    let template = try textOnlyTestRequest()
    let refused = try textOnlyTestInit(template) + textOnlyTestReplay(template)
        + textOnlyTestDelta(template, text: "I started")
        + textOnlyTestLine(["type": "system", "subtype": "model_refusal_fallback", "uuid": UUID().uuidString.lowercased(),
            "session_id": template.sessionID.uuidString.lowercased(), "trigger": "refusal", "direction": "retry",
            "original_model": template.expectedResolvedModel, "fallback_model": "claude-opus-5", "request_id": "req_1",
            "api_refusal_category": NSNull(), "api_refusal_explanation": NSNull(), "refused_user_message_uuid": NSNull(),
            "content": ""])
    let fixture = try ClaudeConnectionFixture(body: """
    IFS= read -r line
    \(try textProcessEmit(refused))
    sleep 30
    """)
    defer { fixture.remove() }
    let events = TextProcessEvents()
    let request = try textOnlyTestRequest(target: fixture.target)
    let started = Date()
    let result = await NativeClaudeTextOnlyRunner().run(request: request) { await events.append($0) }
    #expect(result == .failed(.declined))
    #expect(Date().timeIntervalSince(started) < 20, "the child was left to run")
    let observed = await events.snapshot()
    #expect(observed.contains(.textSnapshot("I started")))
    #expect(!observed.contains { if case .diagnostic = $0 { return true }; return false }, "\(observed)")
}

@Test("A child stopped by the turn cap reports the cap as its diagnostic, not a provider fault")
func claudeTextProcessReportsTheTurnCapAsItsOwnDiagnostic() async throws {
    let template = try textOnlyTestRequest()
    let capped = try textOnlyTestInit(template) + textOnlyTestReplay(template)
        + textOnlyTestDelta(template, text: "Still reading.")
        + textOnlyTestResult(template, override: ["subtype": "error_max_turns", "is_error": true])
    let fixture = try ClaudeConnectionFixture(body: """
    IFS= read -r line
    \(try textProcessEmit(capped))
    """)
    defer { fixture.remove() }
    let events = TextProcessEvents()
    let request = try textOnlyTestRequest(target: fixture.target)
    let result = await NativeClaudeTextOnlyRunner().run(request: request) { await events.append($0) }
    #expect(result == .failed(.turnLimitReached))
    let observed = await events.snapshot()
    #expect(observed.contains(.textSnapshot("Still reading.")))
    #expect(observed.last == .diagnostic(.turnLimitReached))
}

@Test("Synthetic failed initialization returns only one static gate diagnostic, never its provider values")
func claudeTextProcessStaticInitializationDiagnostic() async throws {
    let template = try textOnlyTestRequest()
    let fixture = try ClaudeConnectionFixture(body: """
    IFS= read -r line
    \(try textProcessEmit(textOnlyTestInit(template, override: ["apiKeySource": "synthetic-secret-never-returned"])))
    """)
    defer { fixture.remove() }
    let events = TextProcessEvents()
    let result = await NativeClaudeTextOnlyRunner().run(request: try textOnlyTestRequest(target: fixture.target)) { await events.append($0) }
    #expect(result == .failed(.unsafeInitialization))
    let observed = await events.snapshot()
    #expect(observed == [.inputSubmitted(messageID: template.messageID), .diagnostic(.initializationKeySourceInvalid)])
}

@Test("A mismatched model initialization fails with truthful already-submitted input evidence")
func claudeTextProcessRejectsUnexpectedModelAfterInput() async throws {
    let template = try textOnlyTestRequest(model: "claude-sonnet-5")
    let fixture = try ClaudeConnectionFixture(body: """
    IFS= read -r line
    \(try textProcessEmit(textOnlyTestInit(template, override: ["model": "claude-opus-5"])))
    """)
    defer { fixture.remove() }
    let events = TextProcessEvents()
    let result = await NativeClaudeTextOnlyRunner().run(request: try textOnlyTestRequest(target: fixture.target,
        model: "claude-sonnet-5")) { await events.append($0) }
    #expect(result == .failed(.unsafeInitialization))
    #expect(await events.snapshot() == [.inputSubmitted(messageID: template.messageID), .diagnostic(.initializationModelInvalid)])
}

@Test("Synthetic startup and requesting status before string replay complete without widening the tool boundary")
func claudeTextProcessDocumentedStartupForms() async throws {
    let template = try textOnlyTestRequest()
    let status = try textOnlyTestLine(["type": "system", "subtype": "status", "status": NSNull(),
        "uuid": UUID().uuidString, "session_id": template.sessionID.uuidString, "permissionMode": "dontAsk"])
    let requesting = try textOnlyTestLine(["type": "system", "subtype": "status", "status": "requesting",
        "uuid": UUID().uuidString, "session_id": template.sessionID.uuidString])
    let fixture = try ClaudeConnectionFixture(body: """
    IFS= read -r line
    \(try textProcessEmit(status + textOnlyTestInit(template) + requesting + textOnlyTestReplay(template, stringContent: true) + textOnlyTestResult(template)))
    """)
    defer { fixture.remove() }
    let events = TextProcessEvents()
    let result = await NativeClaudeTextOnlyRunner().run(request: try textOnlyTestRequest(target: fixture.target)) { await events.append($0) }
    #expect(result == .success(.init(sessionID: template.sessionID, actualModel: "claude-sonnet-5", text: "Hello back", confirmedActualModel: "claude-sonnet-5")))
    let observed = await events.snapshot()
    #expect(observed.filter { $0 == .inputAcknowledged(messageID: template.messageID) }.count == 1)
    #expect(observed.allSatisfy { if case .diagnostic = $0 { return false }; return true })
}

@Test("Text transport never starts a changed pinned executable")
func claudeTextProcessChangedExecutable() async throws {
    let fixture = try ClaudeConnectionFixture(body: "/usr/bin/touch invoked")
    defer { fixture.remove() }
    try Data("#!/bin/sh\n/usr/bin/touch invoked\n# changed\n".utf8).write(to: fixture.target.executableURL)
    let result = await NativeClaudeTextOnlyRunner().run(request: try textOnlyTestRequest(target: fixture.target)) { _ in }
    #expect(result == .failed(.launchRejected))
    #expect(!FileManager.default.fileExists(atPath: fixture.target.workingDirectoryURL.appendingPathComponent("invoked").path))
}

@Test("Synthetic raw CLI lifecycle before init and after result preserves one real acknowledged reply")
func claudeTextProcessRawQueueLifecycle() async throws {
    let template = try textOnlyTestRequest()
    let heartbeat = try textOnlyTestLine(["type": "keep_alive"])
    var frames = try textOnlyTestCommandLifecycle(template, state: "queued") + heartbeat
    frames += try textOnlyTestInit(template) + textOnlyTestCommandLifecycle(template, state: "started")
    frames += try textOnlyTestReplay(template) + textOnlyTestDelta(template, text: "Hello ")
    frames += try textOnlyTestResult(template) + textOnlyTestCommandLifecycle(template, state: "completed") + heartbeat
    #expect(frames.count < 4_096)
    let fixture = try ClaudeConnectionFixture(body: """
    IFS= read -r line
    if IFS= read -r extra; then exit 31; fi
    \(try textProcessEmit(frames))
    """)
    defer { fixture.remove() }
    let events = TextProcessEvents()
    let result = await NativeClaudeTextOnlyRunner().run(request: try textOnlyTestRequest(target: fixture.target)) {
        await events.append($0)
    }
    #expect(result == .success(.init(sessionID: template.sessionID, actualModel: "claude-sonnet-5", text: "Hello back", confirmedActualModel: "claude-sonnet-5")))
    let observed = await events.snapshot()
    #expect(observed.filter { $0 == .initialized(sessionID: template.sessionID, actualModel: "claude-sonnet-5") }.count == 1)
    #expect(observed.filter { $0 == .inputAcknowledged(messageID: template.messageID) }.count == 1)
    #expect(observed.last == .textSnapshot("Hello back"))
    #expect(observed.allSatisfy { if case .diagnostic = $0 { return false }; return true })
}

@Test("A preexisting prompt file prevents launch and is never overwritten or removed")
func claudeTextProcessPromptCollision() async throws {
    let fixture = try ClaudeConnectionFixture(body: "/usr/bin/touch unexpected-launch")
    defer { fixture.remove() }
    let request = try textOnlyTestRequest(target: fixture.target)
    let url = ClaudeTextOnlyCommandBuilder.systemPromptFileURL(for: request)
    try Data("preexisting private file".utf8).write(to: url, options: .withoutOverwriting)
    let result = await NativeClaudeTextOnlyRunner().run(request: request) { _ in }
    #expect(result == .failed(.launchFailed))
    #expect(try String(contentsOf: url, encoding: .utf8) == "preexisting private file")
    #expect(!FileManager.default.fileExists(atPath: fixture.target.workingDirectoryURL.appendingPathComponent("unexpected-launch").path))
}

@Test("A valid child reply cannot succeed if the private prompt changed before cleanup")
func claudeTextProcessRejectsPromptCleanupFailure() async throws {
    let template = try textOnlyTestRequest()
    let fixture = try ClaudeConnectionFixture(body: """
    prompt_file=''
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --system-prompt-file ]; then shift; prompt_file="$1"; fi
      shift
    done
    [ -n "$prompt_file" ] || exit 41
    printf 'modified prompt must be preserved' > "$prompt_file"
    \(try textProcessEmit(textOnlyTestInit(template)))
    IFS= read -r line
    printf '{"isReplay":true,"parent_tool_use_id":null,%s\\n' "${line#?}"
    \(try textProcessEmit(textOnlyTestResult(template)))
    """)
    defer { fixture.remove() }
    let request = try textOnlyTestRequest(target: fixture.target)
    let events = TextProcessEvents()
    let result = await NativeClaudeTextOnlyRunner().run(request: request) { await events.append($0) }
    #expect(result == .failed(.processFailed))
    let observed = await events.snapshot()
    #expect(observed.contains(.inputAcknowledged(messageID: request.messageID)))
    #expect(observed.last == .diagnostic(.processFailed))
    let contents = try String(contentsOf: ClaudeTextOnlyCommandBuilder.systemPromptFileURL(for: request), encoding: .utf8)
    #expect(contents == "modified prompt must be preserved")
}

@Test("Text cancellation reaps its process group even while stdin is under backpressure")
func claudeTextProcessCancellation() async throws {
    let fixture = try ClaudeConnectionFixture(body: """
    printf '%s' "$$" > parent.pid
    /bin/sleep 30 &
    printf '%s' "$!" > descendant.pid
    wait
    """)
    defer { fixture.remove() }
    let request = try textOnlyTestRequest(target: fixture.target, text: String(repeating: "x", count: 65_536))
    let operation = Task { await NativeClaudeTextOnlyRunner().run(request: request) { _ in } }
    guard let descendant = await textProcessPID(fixture, name: "descendant.pid") else {
        operation.cancel(); _ = await operation.value
        Issue.record("Synthetic child never became ready"); return
    }
    operation.cancel()
    #expect(await operation.value == .cancelled)
    let parent = try #require(Int32(fixture.readWorkingFile("parent.pid")))
    #expect(await textProcessGone(parent))
    #expect(await textProcessGone(descendant))
    #expect(!FileManager.default.fileExists(atPath: ClaudeTextOnlyCommandBuilder.systemPromptFileURL(for: request).path))
}

/// Seen on Claude Code 2.1.280 (fixture `run-code-probe`): the CLI
/// runs every Bash command in a shell that leads a process group of its own,
/// so killing the CLI's group left a running script alive. The synthetic CLI
/// here makes the same shape with job control: a shell in a new group, a
/// script under it.
@Test("Stop reaps a script whose shell leads a process group of its own, as the CLI's Bash tool does")
func claudeTextProcessCancellationReapsOwnGroupShell() async throws {
    let fixture = try ClaudeConnectionFixture(body: """
    printf '%s' "$$" > parent.pid
    set -m
    /bin/sh -c '/bin/sleep 30 & printf "%s" "$!" > script.pid; wait' &
    set +m
    wait
    """)
    defer { fixture.remove() }
    let request = try textOnlyTestRequest(target: fixture.target)
    let operation = Task { await NativeClaudeTextOnlyRunner().run(request: request) { _ in } }
    guard let script = await textProcessPID(fixture, name: "script.pid") else {
        operation.cancel(); _ = await operation.value
        Issue.record("Synthetic script never became ready"); return
    }
    let parent = try #require(Int32(fixture.readWorkingFile("parent.pid")))
    // The shape under test, or the test proves nothing: the script is in a
    // group that is not the CLI's.
    #expect(getpgid(script) != getpgid(parent))
    #expect(getpgid(script) > 1)
    operation.cancel()
    #expect(await operation.value == .cancelled)
    #expect(await textProcessGone(parent))
    #expect(await textProcessGone(script))
}

/// The mark is read from the process's environment, which macOS shows for a
/// script's interpreter (Homebrew's Python, as in the probe) but hides for a
/// platform binary such as /bin/sleep; hence this interpreter, and hence the
/// approval policy refusing a background run before it starts.
private let homebrewPython = "/opt/homebrew/bin/python3"

@Test("A script the CLI sent to the background does not outlive a turn that ends normally",
      .enabled(if: FileManager.default.isExecutableFile(atPath: homebrewPython)))
func claudeTextProcessSuccessReapsBackgroundRun() async throws {
    let template = try textOnlyTestRequest()
    let fixture = try ClaudeConnectionFixture(body: """
    set -m
    /bin/sh -c '\(homebrewPython) -c "import time; time.sleep(30)" & printf "%s" "$!" > script.pid' &
    set +m
    while [ ! -s script.pid ]; do /bin/sleep 0.05; done
    \(try textProcessEmit(textOnlyTestInit(template)))
    IFS= read -r line
    printf '{"isReplay":true,"parent_tool_use_id":null,%s\\n' "${line#?}"
    \(try textProcessEmit(textOnlyTestDelta(template, text: "Started")))
    \(try textProcessEmit(textOnlyTestResult(template)))
    """)
    defer { fixture.remove() }
    let request = try textOnlyTestRequest(target: fixture.target, text: template.text)
    let result = await NativeClaudeTextOnlyRunner().run(request: request) { _ in }
    guard case .success = result else { Issue.record("expected success, got \(result)"); return }
    let script = try #require(Int32(fixture.readWorkingFile("script.pid")))
    #expect(await textProcessGone(script))
}

@Test("Text deadline reaps a child that closes stdout without exiting")
func claudeTextProcessDeadline() async throws {
    let fixture = try ClaudeConnectionFixture(body: """
    printf '%s' "$$" > parent.pid
    exec 1>&-
    /bin/sleep 30 &
    printf '%s' "$!" > descendant.pid
    wait
    """)
    defer { fixture.remove() }
    let request = try textOnlyTestRequest(target: fixture.target)
    let lifecycle = ClaudeProcessLifecycleObservation()
    let operation = Task {
        await NativeClaudeTextOnlyRunner(testTimeout: 3) { lifecycle.record($0) }
            .run(request: request) { _ in }
    }
    guard let descendant = await textProcessPID(fixture, name: "descendant.pid") else {
        operation.cancel(); _ = await operation.value
        Issue.record("Deadline fixture did not become ready before its limit"); return
    }
    let parent = try #require(Int32(fixture.readWorkingFile("parent.pid")))
    #expect(Darwin.kill(parent, 0) == 0)
    #expect(Darwin.kill(descendant, 0) == 0)
    #expect(await operation.value == .failed(.timedOut))
    let elapsed = try #require(lifecycle.duration)
    #expect(elapsed >= .milliseconds(2_800))
    #expect(elapsed < .seconds(6))
    #expect(await textProcessGone(parent))
    #expect(await textProcessGone(descendant))
    #expect(!FileManager.default.fileExists(atPath: ClaudeTextOnlyCommandBuilder.systemPromptFileURL(for: request).path))
}

@Test("A text child that keeps writing outlives the silence budget and still succeeds")
func claudeTextProcessSilenceBudgetFollowsOutput() async throws {
    let template = try textOnlyTestRequest()
    let fixture = try ClaudeConnectionFixture(body: """
    \(try textProcessEmit(textOnlyTestInit(template)))
    IFS= read -r line
    printf '{"isReplay":true,"parent_tool_use_id":null,%s\\n' "${line#?}"
    for tick in 1 2 3 4 5 6 7 8 9 10 11 12; do
    /bin/sleep 0.4
    \(try textProcessEmit(textOnlyTestDelta(template, text: "tick ")))
    done
    \(try textProcessEmit(textOnlyTestResult(template)))
    """)
    defer { fixture.remove() }
    let lifecycle = ClaudeProcessLifecycleObservation()
    let request = try textOnlyTestRequest(target: fixture.target)
    let result = await NativeClaudeTextOnlyRunner(testTimeout: 3, testOverallTimeout: 60) { lifecycle.record($0) }
        .run(request: request) { _ in }
    #expect(result == .success(.init(sessionID: request.sessionID, actualModel: "claude-sonnet-5",
                                     text: "Hello back", confirmedActualModel: "claude-sonnet-5")))
    // The child wrote for longer than a whole silence budget and still
    // finished. One flat deadline of the same size ended exactly this answer.
    let elapsed = try #require(lifecycle.duration)
    #expect(elapsed > .seconds(4))
    #expect(elapsed < .seconds(60))
}

@Test("A silent text child fails on the silence budget long before the overall cap")
func claudeTextProcessSilenceBudgetTimeout() async throws {
    let fixture = try ClaudeConnectionFixture(body: """
    exec 1>&-
    /bin/sleep 30
    """)
    defer { fixture.remove() }
    let lifecycle = ClaudeProcessLifecycleObservation()
    let request = try textOnlyTestRequest(target: fixture.target)
    let result = await NativeClaudeTextOnlyRunner(testTimeout: 3, testOverallTimeout: 300) { lifecycle.record($0) }
        .run(request: request) { _ in }
    // A child that never writes still ends on its silence budget, five minutes
    // before the overall cap this runner was given.
    #expect(result == .failed(.timedOut))
    let elapsed = try #require(lifecycle.duration)
    #expect(elapsed >= .milliseconds(2_500))
    #expect(elapsed < .seconds(60))
}

@Test("A text child that never stops writing fails at the overall cap, not the silence budget")
func claudeTextProcessOverallCap() async throws {
    let template = try textOnlyTestRequest()
    let fixture = try ClaudeConnectionFixture(body: """
    printf '%s' "$$" > parent.pid
    \(try textProcessEmit(textOnlyTestInit(template)))
    while :; do
    /bin/sleep 0.4
    \(try textProcessEmit(textOnlyTestDelta(template, text: "tick ")))
    done
    """)
    defer { fixture.remove() }
    let lifecycle = ClaudeProcessLifecycleObservation()
    let request = try textOnlyTestRequest(target: fixture.target)
    let result = await NativeClaudeTextOnlyRunner(testTimeout: 3, testOverallTimeout: 6) { lifecycle.record($0) }
        .run(request: request) { _ in }
    #expect(result == .failed(.timedOut))
    // Output every 400 ms keeps restarting the three-second silence budget,
    // so only the absolute ceiling from launch can end this turn. A silence
    // failure would have landed a full budget earlier than this bound.
    let elapsed = try #require(lifecycle.duration)
    #expect(elapsed >= .seconds(5))
    #expect(elapsed < .seconds(60))
    let parent = try #require(Int32(fixture.readWorkingFile("parent.pid")))
    #expect(await textProcessGone(parent))
}

@Test("An unbounded text child's stdout is terminated without storing raw output")
func claudeTextProcessOutputLimit() async throws {
    let fixture = try ClaudeConnectionFixture(body: """
    printf '%s' "$$" > parent.pid
    while :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done
    """)
    defer { fixture.remove() }
    let result = await NativeClaudeTextOnlyRunner().run(request: try textOnlyTestRequest(target: fixture.target)) { _ in }
    #expect(result == .failed(.outputLimitExceeded))
    let parent = try #require(Int32(fixture.readWorkingFile("parent.pid")))
    #expect(await textProcessGone(parent))
}

@Test("Normal text completion cleans up a descendant that inherited stdout")
func claudeTextProcessNormalDescendantCleanup() async throws {
    let request = try textOnlyTestRequest()
    let fixture = try ClaudeConnectionFixture(body: """
    /bin/sleep 30 &
    printf '%s' "$!" > descendant.pid
    \(try textProcessEmit(textOnlyTestInit(request)))
    IFS= read -r line
    printf '{"isReplay":true,"parent_tool_use_id":null,%s\\n' "${line#?}"
    \(try textProcessEmit(textOnlyTestResult(request)))
    """)
    defer { fixture.remove() }
    let began = ContinuousClock.now
    let result = await NativeClaudeTextOnlyRunner().run(request: try textOnlyTestRequest(target: fixture.target)) { _ in }
    #expect(result == .success(.init(sessionID: request.sessionID, actualModel: "claude-sonnet-5", text: "Hello back", confirmedActualModel: "claude-sonnet-5")))
    #expect(ContinuousClock.now - began < .seconds(3))
    let descendant = try #require(Int32(fixture.readWorkingFile("descendant.pid")))
    #expect(await textProcessGone(descendant))
}

@Test("Closed stdin cannot SIGPIPE the app and cannot become a successful send")
func claudeTextProcessClosedInput() async throws {
    let fixture = try ClaudeConnectionFixture(body: """
    printf '%s' "$$" > parent.pid
    exec 0<&-
    /bin/sleep 30 &
    printf '%s' "$!" > descendant.pid
    wait
    """)
    defer { fixture.remove() }
    let result = await NativeClaudeTextOnlyRunner().run(
        request: try textOnlyTestRequest(target: fixture.target, text: String(repeating: "x", count: 65_536))) { _ in }
    #expect(result == .failed(.inputRejected))
    let parent = try #require(Int32(fixture.readWorkingFile("parent.pid")))
    #expect(await textProcessGone(parent))
    if let descendant = try? Int32(fixture.readWorkingFile("descendant.pid")) {
        #expect(await textProcessGone(descendant))
    }
}

@Test("Already cancelled text request does not launch the synthetic executable")
func claudeTextProcessCancelledBeforeStart() async throws {
    let fixture = try ClaudeConnectionFixture(body: "/usr/bin/touch invoked")
    defer { fixture.remove() }
    let request = try textOnlyTestRequest(target: fixture.target)
    let operation = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await NativeClaudeTextOnlyRunner().run(request: request) { _ in }
    }
    #expect(await operation.value == .cancelled)
    #expect(!FileManager.default.fileExists(atPath: fixture.target.workingDirectoryURL.appendingPathComponent("invoked").path))
}

@Test("A suspended event consumer cannot postpone cancellation of the owned child group")
func claudeTextProcessCleanupIndependentOfConsumer() async throws {
    let template = try textOnlyTestRequest()
    let fixture = try ClaudeConnectionFixture(body: """
    printf '%s' "$$" > parent.pid
    /bin/sleep 30 &
    printf '%s' "$!" > descendant.pid
    \(try textProcessEmit(textOnlyTestInit(template)))
    wait
    """)
    defer { fixture.remove() }
    let gate = TextProcessDeliveryGate()
    let request = try textOnlyTestRequest(target: fixture.target)
    let operation = Task {
        await NativeClaudeTextOnlyRunner().run(request: request) { event in
            if case .initialized = event { await gate.hold() }
        }
    }
    guard let descendant = await textProcessPID(fixture, name: "descendant.pid") else {
        operation.cancel(); await gate.release(); _ = await operation.value
        Issue.record("Suspended-consumer fixture did not start"); return
    }
    var entered = false
    for _ in 0..<200 {
        if await gate.hasEntered { entered = true; break }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(entered)
    operation.cancel()
    let parent = try #require(Int32(fixture.readWorkingFile("parent.pid")))
    #expect(await textProcessGone(parent))
    #expect(await textProcessGone(descendant))
    await gate.release()
    #expect(await operation.value == .cancelled)
}

@Test("A working child that is not speaking has its text republished, so the turn's lease can be renewed")
func claudeTextProcessRepublishesTextWhileTheChildIsBusy() async throws {
    let template = try textOnlyTestRequest()
    // The child says one word, then only heartbeats for two seconds, the way
    // the CLI does while a web fetch or a long thinking phase is under way.
    let fixture = try ClaudeConnectionFixture(body: """
    \(try textProcessEmit(textOnlyTestInit(template)))
    IFS= read -r line
    printf '{"isReplay":true,"parent_tool_use_id":null,%s\\n' "${line#?}"
    \(try textProcessEmit(textOnlyTestDelta(template, text: "Hello")))
    for tick in 1 2 3 4 5 6 7 8; do
    /bin/sleep 0.25
    printf '{"type":"keep_alive"}\\n'
    done
    \(try textProcessEmit(textOnlyTestResult(template, override: ["result": "Hello"])))
    """)
    defer { fixture.remove() }
    let request = try textOnlyTestRequest(target: fixture.target)
    let events = TextProcessEvents()
    // At a half-second cadence the text so far is republished about four times
    // in those two seconds; in production the cadence is sixty seconds.
    let result = await NativeClaudeTextOnlyRunner(testTimeout: 3, testOverallTimeout: 30, testLeaseHeartbeat: 0.5)
        .run(request: request) { await events.append($0) }
    #expect(result == .success(.init(sessionID: request.sessionID, actualModel: "claude-sonnet-5",
                                     text: "Hello", confirmedActualModel: "claude-sonnet-5")))
    let republished = await events.snapshot().filter { $0 == .textSnapshot("Hello") }
    // One from the delta, one from the result, and the heartbeats between them.
    #expect(republished.count >= 4)
    #expect(republished.count <= 8)
    // At the production cadence the same child produces exactly the two.
    let quiet = TextProcessEvents()
    _ = await NativeClaudeTextOnlyRunner(testTimeout: 3, testOverallTimeout: 30)
        .run(request: request) { await quiet.append($0) }
    #expect(await quiet.snapshot().filter { $0 == .textSnapshot("Hello") }.count == 2)
}

private func textProcessEmit(_ data: Data) throws -> String {
    // Synthetic JSON fixtures only. Quoted heredoc prevents shell expansion.
    let text = try #require(String(data: data, encoding: .utf8))
    return "/bin/cat <<'OPENBOTS_SYNTHETIC_EVENT'\n" + text + "OPENBOTS_SYNTHETIC_EVENT"
}

private actor TextProcessEvents {
    private var values: [ClaudeTextOnlyEvent] = []
    func append(_ event: ClaudeTextOnlyEvent) { values.append(event) }
    func snapshot() -> [ClaudeTextOnlyEvent] { values }
}

private actor TextProcessDeliveryGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var hasEntered = false
    func hold() async {
        hasEntered = true
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private func textProcessPID(_ fixture: ClaudeConnectionFixture, name: String) async -> pid_t? {
    // A newly written fixture is a new executable to the system, and its very
    // first exec can cost a second or more while the whole file runs in
    // parallel. Wait well past that rather than call a slow start a failure.
    for _ in 0..<500 {
        if let text = try? fixture.readWorkingFile(name), let pid = Int32(text), pid > 1 { return pid }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

private func textProcessGone(_ pid: pid_t) async -> Bool {
    guard pid > 1 else { return false }
    for _ in 0..<100 {
        if Darwin.kill(pid, 0) != 0, errno == ESRCH { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}
