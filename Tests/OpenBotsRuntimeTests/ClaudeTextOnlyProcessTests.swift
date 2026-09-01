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
    let frames = try textOnlyTestCommandLifecycle(template, state: "queued") + heartbeat
        + textOnlyTestInit(template) + textOnlyTestCommandLifecycle(template, state: "started")
        + textOnlyTestReplay(template) + textOnlyTestDelta(template, text: "Hello ")
        + textOnlyTestResult(template) + textOnlyTestCommandLifecycle(template, state: "completed") + heartbeat
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
    for _ in 0..<200 {
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
