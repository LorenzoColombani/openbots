import Foundation
@testable import OpenBotsUI

/// The layout diagnostics are off in the shipped app, so a test that asserts on
/// `LayoutStormCounters.lifetime` has to turn them on for itself. It cannot do
/// that through `OPENBOTS_LAYOUT_DIAGNOSTICS`: the SwiftPM wrapper launches with
/// an empty environment, and the layout suites re-launch themselves in a child
/// process that inherits only five named variables.
@MainActor
func withLayoutDiagnostics<T>(
    counters: Bool = true,
    storms: Bool = false,
    _ body: () throws -> T
) rethrows -> T {
    let previousCounters = LayoutStormCounters.isEnabled
    let previousStorms = LayoutStormDiagnostics.isEnabled
    LayoutStormCounters.isEnabled = counters
    LayoutStormDiagnostics.isEnabled = storms
    defer {
        LayoutStormCounters.isEnabled = previousCounters
        LayoutStormDiagnostics.isEnabled = previousStorms
    }
    return try body()
}
