import Darwin
import Foundation
import Testing
@testable import OpenBotsRuntime

@Test("Status invokes only auth status with closed stdin and discards stderr")
func claudeConnectionNativeStatusUsesBoundedContract() async throws {
    let fixture = try ClaudeConnectionFixture(body: """
    [ "$#" -eq 2 ] && [ "$1" = auth ] && [ "$2" = status ] || exit 31
    if read -r unwanted; then exit 32; fi
    [ "$NETRC" = /dev/null ] || exit 33
    [ -z "${ANTHROPIC_API_KEY+x}" ] || exit 34
    [ -z "${CLAUDE_CODE_OAUTH_TOKEN+x}" ] || exit 35
    i=0
    while [ "$i" -lt 1000 ]; do
      printf 'synthetic stderr that must never become an app error\\n' >&2
      i=$((i+1))
    done
    /usr/bin/printf '%s' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"pro","email":"discard@example.invalid"}'
    """)
    defer { fixture.remove() }
    #expect(await NativeClaudeStatusChecker().checkStatus(target: fixture.target) == .eligible(.pro))
}

@Test("Status never launches an executable whose pinned bytes changed")
func claudeConnectionNativeStatusRejectsChangedFingerprint() async throws {
    let fixture = try ClaudeConnectionFixture(body: "/usr/bin/touch was-invoked")
    defer { fixture.remove() }
    try Data("#!/bin/sh\n/usr/bin/touch was-invoked\n# changed\n".utf8).write(to: fixture.target.executableURL)
    #expect(await NativeClaudeStatusChecker().checkStatus(target: fixture.target) == .inconclusive)
    #expect(!FileManager.default.fileExists(atPath: fixture.target.workingDirectoryURL.appendingPathComponent("was-invoked").path))
}

@Test("Oversized stdout terminates and reaps the owned status process")
func claudeConnectionNativeStatusBoundsOutput() async throws {
    let fixture = try ClaudeConnectionFixture(body: """
    /usr/bin/printf '%s' "$$" > parent.pid
    while :; do
      printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
    done
    """)
    defer { fixture.remove() }
    #expect(await NativeClaudeStatusChecker().checkStatus(target: fixture.target) == .inconclusive)
    let pid = try #require(Int32(fixture.readWorkingFile("parent.pid")))
    #expect(await connectionTestProcessGone(pid))
}

@Test("Cancellation kills the owned process group and returns no partial status")
func claudeConnectionNativeStatusCancelsOwnedGroup() async throws {
    let fixture = try ClaudeConnectionFixture(body: """
    /usr/bin/printf '%s' "$$" > parent.pid
    /bin/sleep 30 &
    /usr/bin/printf '%s' "$!" > descendant.pid
    wait
    """)
    defer { fixture.remove() }
    let operation = Task { await NativeClaudeStatusChecker().checkStatus(target: fixture.target) }
    guard let descendant = await connectionTestPID(fixture, filename: "descendant.pid") else {
        operation.cancel()
        _ = await operation.value
        Issue.record("Synthetic fixture did not start in time")
        return
    }
    operation.cancel()
    #expect(await operation.value == .cancelled)
    let parent = try #require(Int32(fixture.readWorkingFile("parent.pid")))
    #expect(await connectionTestProcessGone(parent))
    #expect(await connectionTestProcessGone(descendant))
}

@Test("Deadline cleanup handles a child that closes stdout but keeps running")
func claudeConnectionNativeStatusTimeoutClosesOwnedGroup() async throws {
    let fixture = try ClaudeConnectionFixture(body: """
    /usr/bin/printf '%s' "$$" > parent.pid
    exec 1>&-
    /bin/sleep 30 &
    /usr/bin/printf '%s' "$!" > descendant.pid
    wait
    """)
    defer { fixture.remove() }
    let lifecycle = ClaudeProcessLifecycleObservation()
    let operation = Task {
        await NativeClaudeStatusChecker(testTimeout: 3) { lifecycle.record($0) }
            .checkStatus(target: fixture.target)
    }
    guard let descendant = await connectionTestPID(fixture, filename: "descendant.pid") else {
        operation.cancel()
        _ = await operation.value
        Issue.record("Timeout fixture did not establish a running child before its deadline")
        return
    }
    let parent = try #require(Int32(fixture.readWorkingFile("parent.pid")))
    #expect(Darwin.kill(parent, 0) == 0)
    #expect(Darwin.kill(descendant, 0) == 0)
    #expect(await operation.value == .inconclusive)
    let elapsed = try #require(lifecycle.duration)
    #expect(elapsed >= .milliseconds(2_800))
    #expect(elapsed < .seconds(6))
    #expect(await connectionTestProcessGone(parent))
    #expect(await connectionTestProcessGone(descendant))
}

@Test("Successful status cleans up an inherited-output descendant without waiting for EOF")
func claudeConnectionNativeStatusCleansDescendantOnNormalExit() async throws {
    let fixture = try ClaudeConnectionFixture(body: """
    /bin/sleep 30 &
    /usr/bin/printf '%s' "$!" > descendant.pid
    /usr/bin/printf '%s' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}'
    """)
    defer { fixture.remove() }
    let began = ContinuousClock.now
    #expect(await NativeClaudeStatusChecker().checkStatus(target: fixture.target) == .eligible(.max))
    #expect(ContinuousClock.now - began < .seconds(3))
    let descendant = try #require(Int32(fixture.readWorkingFile("descendant.pid")))
    #expect(await connectionTestProcessGone(descendant))
}

@Test("Already cancelled status does not spawn even a valid synthetic executable")
func claudeConnectionNativeStatusHonorsCancellationBeforeLaunch() async throws {
    let fixture = try ClaudeConnectionFixture(body: "/usr/bin/touch was-invoked")
    defer { fixture.remove() }
    let operation = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await NativeClaudeStatusChecker().checkStatus(target: fixture.target)
    }
    #expect(await operation.value == .cancelled)
    #expect(!FileManager.default.fileExists(atPath: fixture.target.workingDirectoryURL.appendingPathComponent("was-invoked").path))
}

private func connectionTestPID(_ fixture: ClaudeConnectionFixture, filename: String) async -> pid_t? {
    for _ in 0..<200 {
        if let text = try? fixture.readWorkingFile(filename), let pid = Int32(text), pid > 1 { return pid }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

private func connectionTestProcessGone(_ pid: pid_t) async -> Bool {
    guard pid > 1 else { return false }
    for _ in 0..<100 {
        if Darwin.kill(pid, 0) != 0, errno == ESRCH { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}
