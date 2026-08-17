import XCTest
@testable import AgencyKit

/// Hermetic tests for the REAL process runner using /bin/sh — zero Claude usage.
/// Review #1 C1: `readToEnd()` in the termination handler blocks until every
/// holder of the pipe's write end closes it. `claude` exiting is not enough —
/// a background child it spawned (e.g. `sleep 30 &`) inherits stdout/stderr and
/// holds the pipe open, so the stream never finished and the teammate stayed
/// "busy" forever with no recovery path in the app.
final class ClaudeProcessRunnerTests: XCTestCase {
    private let tmp = FileManager.default.temporaryDirectory

    /// Collects the stream's lines with a hard deadline. Returns nil on timeout.
    private func collect(_ script: String, deadline: TimeInterval = 5.0) async -> (lines: [String], error: Error?)? {
        let runner = ClaudeProcessRunner()
        let task = Task { () -> (lines: [String], error: Error?) in
            var lines: [String] = []
            do {
                for try await line in runner.runLines(executable: "/bin/sh",
                                                      arguments: ["-c", script], cwd: tmp) {
                    lines.append(line)
                }
                return (lines, nil)
            } catch {
                return (lines, error)
            }
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            task.cancel()
        }
        let result = await task.value
        timeout.cancel()
        return Task.isCancelled ? nil : result
    }

    /// The C1 reproduction: sh exits instantly, but its background grandchild
    /// keeps the pipe's write end open for 30s. The stream must still finish.
    func testGrandchildHoldingPipeDoesNotHangStream() async throws {
        let start = Date()
        let result = await collect("sleep 30 & echo line1; echo line2")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5.0, "stream did not finish while a grandchild held the pipe (C1 hang)")
        XCTAssertEqual(result?.lines.filter { $0.contains("line") }, ["line1", "line2"])
        XCTAssertNil(result?.error ?? nil)
    }

    func testNonZeroExitSurfacesProcessFailureWithStderr() async throws {
        let result = await collect("echo out1; echo boom >&2; exit 3")
        XCTAssertEqual(result?.lines, ["out1"])
        let failure = result?.error as? ProcessFailure
        XCTAssertEqual(failure?.status, 3)
        XCTAssertEqual(failure?.stderr.contains("boom"), true)
    }

    func testOrderingAcrossChunksAndNoTrailingNewline() async throws {
        // 500 numbered lines plus a final unterminated tail.
        let result = await collect("i=0; while [ $i -lt 500 ]; do echo line-$i; i=$((i+1)); done; printf 'tail-no-newline'")
        let lines = result?.lines ?? []
        XCTAssertEqual(lines.count, 501)
        for (i, line) in lines.dropLast().enumerated() {
            XCTAssertEqual(line, "line-\(i)", "ordering broke at index \(i)")
        }
        XCTAssertEqual(lines.last, "tail-no-newline")
        XCTAssertNil(result?.error ?? nil)
    }
}
