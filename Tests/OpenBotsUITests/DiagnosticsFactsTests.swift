import Testing
@testable import OpenBotsUI

/// Diagnostics once read the same build number for every build, so it could
/// not say which build was installed. The build
/// script now stamps the source commit (and the commit's date as the build number);
/// Diagnostics shows the commit when the bundle carries one.
@Suite("Diagnostics facts")
struct DiagnosticsFactsTests {
    @Test("A stamped bundle names its source commit")
    func stampedBundleNamesItsCommit() {
        let rows = DiagnosticsFacts.rows(info: [
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "2026.9.22",
            "OpenBotsSourceCommit": "3c9c864a1b2c"
        ])
        #expect(rows == [
            .init(label: "Version", value: "0.1.0"), .init(label: "Build", value: "2026.9.22"),
            .init(label: "Source", value: "3c9c864a1b2c")
        ])
    }

    @Test("A bundle built without the script shows no Source row rather than an empty one")
    func unstampedBundleHasNoSourceRow() {
        let rows = DiagnosticsFacts.rows(info: [
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "2026.8.30", "OpenBotsSourceCommit": " "
        ])
        #expect(rows.map(\.label) == ["Version", "Build"])
    }
}
