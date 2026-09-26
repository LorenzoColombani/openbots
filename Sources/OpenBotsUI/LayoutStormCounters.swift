import Foundation
import OpenBotsServices

/// Whether the layout diagnostics below run at all.
///
/// They have found real layout storms and are kept, but they must not be what
/// the app pays for by default: every counter builds a string and updates
/// dictionaries on the main thread, and `label.setFrameOrigin` alone
/// means one string per visible label per scrolled frame. Off unless the
/// environment asks for it; a test that asserts on the counters turns them on.
enum LayoutDiagnosticsDefault {
    static let isEnabled = ProcessInfo.processInfo.environment["OPENBOTS_LAYOUT_DIAGNOSTICS"] == "1"
}

/// Diagnostics only. Counts named events per second on the main thread and,
/// when the total crosses a storm threshold, writes one bounded line naming
/// the busiest counters (names and numbers only, never text), so a live
/// re-layout loop names which component keeps firing.
@MainActor
enum LayoutStormCounters {
    /// Set `OPENBOTS_LAYOUT_DIAGNOSTICS=1`, or assign this from the main actor
    /// in a test. While it is false `hit` returns before its detail is ever built.
    static var isEnabled = LayoutDiagnosticsDefault.isEnabled
    static let threshold = 150
    static let maximumLines = 60
    private static var windowStart: TimeInterval = 0
    private static var counts: [String: Int] = [:]
    private static var details: [String: String] = [:]
    private static var total = 0
    private static var loggedThisWindow = false
    private static var linesWritten = 0
    /// Lifetime totals per name, for tests that need to prove a layout settled.
    /// Only counted while `isEnabled`.
    private(set) static var lifetime: [String: Int] = [:]

    /// The detail is an autoclosure so a disabled counter never builds the
    /// string: these are called from `setFrameOrigin` and `sizeThatFits`, which
    /// run for every visible label on every frame the transcript moves.
    static func hit(_ name: String, detail: @autoclosure () -> String? = nil) {
        guard isEnabled else { return }
        lifetime[name, default: 0] += 1
        let now = ProcessInfo.processInfo.systemUptime
        if now - windowStart >= 1 {
            windowStart = now; counts = [:]; details = [:]; total = 0; loggedThisWindow = false
        }
        counts[name, default: 0] += 1
        total += 1
        if let detail = detail() {
            let clipped = String(detail.prefix(400))
            let existing = details[name] ?? ""
            if !existing.contains(clipped), existing.count < 1_200 {
                details[name] = existing.isEmpty ? clipped : existing + " | " + clipped
            }
        }
        guard total >= threshold, !loggedThisWindow, linesWritten < maximumLines else { return }
        loggedThisWindow = true
        linesWritten += 1
        let top = counts.sorted { $0.value > $1.value }.prefix(12).map { entry in
            "\(entry.key)=\(entry.value)" + (details[entry.key].map { "(\($0))" } ?? "")
        }.joined(separator: " ")
        AgenticDiagnosticsLog.note("layout", "event storm: \(total)+ events this second; \(top)")
    }
}
