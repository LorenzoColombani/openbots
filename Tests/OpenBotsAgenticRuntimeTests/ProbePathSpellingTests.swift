import Foundation
import OpenBotsExecutionRules
import Testing

@Suite("Exact temporary path spelling")
struct ProbePathSpellingTests {
    @Test("An existing physical temporary folder retains its exact approval identity")
    func existingTemporaryFolder() throws {
        let root = URL(fileURLWithPath: "/private/tmp/OpenBotsPath-\(UUID().uuidString).noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AgenticProbePaths(root: root,
            configurationDirectory: URL(fileURLWithPath: "/Users/example/profile.noindex"),
            homeDirectory: URL(fileURLWithPath: "/Users/example"),
            claudeExecutable: URL(fileURLWithPath: "/usr/bin/false"))
        #expect(paths.root.path == root.path)
        let physical = try target(root.path)
        #expect(physical.canonicalIdentifier == root.path)
        // Alternate spellings do not gain the same frozen target identity.
        let alias = try target(String(root.path.dropFirst("/private".count)))
        #expect(physical != alias)
    }

    @Test("Traversal, repeated separators, controls, and relative names remain invalid",
          arguments: ["/private/tmp/../outside", "/private/tmp/./work", "/private/tmp//work",
                      "/private/tmp/work/", "/private/tmp/work\u{0}", "tmp/work",
                      "/Users/example/../outside", "/private/tmpish/../tmp/work"])
    func invalidTarget(_ path: String) {
        #expect(throws: (any Error).self) { try target(path) }
    }

    @Test("A similar prefix cannot become the allowed temporary root",
          arguments: ["/private/tmpish/test.noindex", "/Users/example/test.noindex", "/private/tmp/plain"])
    func invalidProbeRoot(_ path: String) {
        #expect(throws: (any Error).self) {
            try AgenticProbePaths(root: URL(fileURLWithPath: path),
                configurationDirectory: URL(fileURLWithPath: "/Users/example/profile.noindex"),
                homeDirectory: URL(fileURLWithPath: "/Users/example"),
                claudeExecutable: URL(fileURLWithPath: "/usr/bin/false"))
        }
    }

    private func target(_ path: String) throws -> CanonicalTarget {
        try CanonicalTarget(kind: .filesystem, canonicalIdentifier: path,
                            location: .appOwned, scope: .narrowFolder)
    }
}
