import Foundation
import OpenBotsExecutionRules
import Testing
@testable import OpenBotsAgenticRuntime

// Claude Code 2.1.281 announces a built-in plugin,
// agents-md, in every init frame unless the settings switch it off, and the job
// session refuses any announced plugin. The job's settings carry the switch for
// the conversation process and the worker alike.
@Test("A job's settings switch off the built-in plugin that loads AGENTS.md")
func jobSettingsDisableAgentsMd() throws {
    let root = URL(fileURLWithPath: "/private/tmp/OpenBotsJobSettings-\(UUID().uuidString).noindex")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AgenticProbePaths(root: root,
        configurationDirectory: URL(fileURLWithPath: "/Users/example/profile.noindex"),
        homeDirectory: URL(fileURLWithPath: "/Users/example"),
        claudeExecutable: URL(fileURLWithPath: "/usr/bin/false"))
    for webTools in [[], ["WebSearch", "WebFetch"]] {
        let data = try FirstToolJobLaunchPreparation.settingsJSON(paths: paths, webTools: webTools)
        let settings = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(settings["enabledPlugins"] as? [String: Bool] == ["agents-md@builtin": false], "\(webTools)")
    }
}

// A refused reply is never handed to another model, on the
// job runner's launch as on a chat turn's.
@Test("A job's launch keeps a refused reply from being handed to another model")
func jobEnvironmentDisablesRefusalFallback() throws {
    let root = URL(fileURLWithPath: "/private/tmp/OpenBotsJobSettings-\(UUID().uuidString).noindex")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AgenticProbePaths(root: root,
        configurationDirectory: URL(fileURLWithPath: "/Users/example/profile.noindex"),
        homeDirectory: URL(fileURLWithPath: "/Users/example"),
        claudeExecutable: URL(fileURLWithPath: "/usr/bin/false"))
    #expect(FirstToolJobLaunchPreparation.environment(paths: paths)["CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK"] == "1")
}
