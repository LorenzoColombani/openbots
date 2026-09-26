import Foundation
import Testing
@testable import OpenBotsRuntime

// Every bot reads the team's shared folder and its own skills, probed on 2.1.272
// with the tool-free turn's own flags: Glob, Grep and Read inside the added folders
// ran without a question; a Read outside them was refused.

private let sharedFolder = URL(fileURLWithPath: "/Users/x/OpenBots Next Preview Content/Shared")
private let skillsFolder = URL(fileURLWithPath: "/Users/x/OpenBots Next Preview Content/Skills/Pillow")

private func readAccessFixture(skills withSkills: Bool = true) throws -> ClaudeTextReadAccess {
    try ClaudeTextReadAccess(sharedDirectoryURL: sharedFolder, skillsDirectoryURL: withSkills ? skillsFolder : nil,
        skills: withSkills ? [ClaudeTextWorkSkill(name: "pickup", summary: "Resume a paused project")] : [],
        protectedPaths: ["/Users/x/.ssh"])
}

private func flag(_ arguments: [String], _ name: String) -> String? {
    arguments.firstIndex(of: name).map { arguments[$0 + 1] }
}

private func addedFolders(_ arguments: [String]) -> [String] {
    arguments.indices.filter { arguments[$0] == "--add-dir" }.map { arguments[$0 + 1] }
}

@Test("A bot without Work reads the shared folder and its skills: three read tools, one --add-dir each, the tool-free turn's own flags, no channel")
func readTurnCommandContract() throws {
    let request = try textOnlyTestRequest(readAccess: try readAccessFixture())
    #expect(request.grantsReading && request.grantsTools && !request.requiresPermissionControl && !request.grantsWork)
    #expect(request.grantedToolNames == ["Glob", "Grep", "Read"])
    #expect(request.expectedPermissionMode == "dontAsk")
    let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
    #expect(flag(arguments, "--tools") == "Glob,Grep,Read")
    #expect(arguments.contains("--safe-mode") && arguments.contains("--restricted"))
    #expect(!arguments.contains("--permission-prompt-tool") && !arguments.contains("--agents"))
    #expect(addedFolders(arguments) == [sharedFolder.path, skillsFolder.path])
    #expect(flag(arguments, "--max-turns") == String(ClaudeTextOnlyCommandBuilder.maximumGrantedTurns))
    let denied = try #require(flag(arguments, "--disallowedTools")).split(separator: ",").map(String.init)
    for name in ["Bash", "Write", "Edit", "MultiEdit", "NotebookEdit", "WebFetch", "Agent", "mcp__*"] { #expect(denied.contains(name)) }
    for name in ["Glob", "Grep", "Read"] { #expect(!denied.contains(name)) }
    let settings = try #require(flag(arguments, "--settings"))
    let object = try #require(try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])
    let permissions = try #require(object["permissions"] as? [String: Any])
    #expect(permissions["defaultMode"] as? String == "dontAsk")
    let deny = try #require(permissions["deny"] as? [String])
    #expect(!deny.contains("*"))
    for tool in ["Read", "Glob", "Grep"] { #expect(deny.contains("\(tool)(//Users/x/.ssh/**)")) }
    // A turn given nothing still launches the shipped tool-free command.
    let plain = ClaudeTextOnlyCommandBuilder.arguments(for: try textOnlyTestRequest())
    #expect(flag(plain, "--tools") == "" && flag(plain, "--disallowedTools") == "*")
    #expect(addedFolders(plain).isEmpty && flag(plain, "--max-turns") == "1")
}

@Test("Reading rides beside the web and the connectors, and a Work turn, which already reads, carries none of it")
func readJoinsTheOtherShapes() throws {
    let web = try textOnlyTestRequest(allowedTools: [.webSearch], readAccess: try readAccessFixture(skills: false))
    #expect(web.grantedToolNames == ["Glob", "Grep", "Read", "WebSearch"])
    let webArguments = ClaudeTextOnlyCommandBuilder.arguments(for: web)
    #expect(flag(webArguments, "--allowedTools") == "WebSearch")
    #expect(addedFolders(webArguments) == [sharedFolder.path])
    let webSettings = try #require(flag(webArguments, "--settings"))
    #expect(webSettings.contains("Read(//Users/x/.ssh/**)") && !webSettings.contains("\"*\""))

    let connector = try textOnlyTestRequest(connectorAccess: try connectorAccessFixture(), readAccess: try readAccessFixture())
    #expect(connector.grantedToolNames == ["AskUserQuestion", "Glob", "Grep", "Read"])
    let connectorArguments = ClaudeTextOnlyCommandBuilder.arguments(for: connector)
    #expect(connectorArguments.contains("--permission-prompt-tool"))
    #expect(addedFolders(connectorArguments) == [sharedFolder.path, skillsFolder.path])
    #expect(try #require(flag(connectorArguments, "--settings")).contains("Grep(//Users/x/.ssh/**)"))

    let work = try ClaudeTextWorkAccess(workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/desk.noindex/Pillow"), protectedPaths: [])
    let workTurn = try textOnlyTestRequest(workAccess: work, readAccess: try readAccessFixture())
    #expect(!workTurn.grantsReading && workTurn.readAccess == nil)
    #expect(ClaudeTextOnlyCommandBuilder.arguments(for: workTurn) == ClaudeTextOnlyCommandBuilder.arguments(for: try textOnlyTestRequest(workAccess: work)))
}

@Test("The init frame of a reading turn must announce exactly its three read tools")
func readTurnInitAnnouncesExactlyTheReadTools() throws {
    let request = try textOnlyTestRequest(readAccess: try readAccessFixture())
    var stream = ClaudeTextOnlyStream(request: request)
    _ = try stream.consume(try textOnlyTestInit(request, override: ["tools": ["Glob", "Grep", "Read"], "permissionMode": "default"])) { _ in }
    for tools in [["Glob", "Grep"], ["Glob", "Grep", "Read", "Bash"], ["Glob", "Grep", "Read", "Write"]] {
        var wrong = ClaudeTextOnlyStream(request: request)
        #expect(throws: ClaudeTextOnlyRejection.self, "\(tools)") {
            try wrong.consume(try textOnlyTestInit(request, override: ["tools": tools, "permissionMode": "default"])) { _ in }
        }
    }
}

@Test("Read access holds its folders to the same shape as Work's: absolute, plain, not under a protected root, skills only with their folder")
func readAccessShape() throws {
    _ = try readAccessFixture()
    #expect(throws: ClaudeTextWorkAccessError.self) {
        try ClaudeTextReadAccess(sharedDirectoryURL: URL(fileURLWithPath: "/Users/x/a/../Shared"), protectedPaths: [])
    }
    #expect(throws: ClaudeTextWorkAccessError.self) {
        try ClaudeTextReadAccess(sharedDirectoryURL: URL(fileURLWithPath: "/Users/x/.ssh/Shared"), protectedPaths: ["/Users/x/.ssh"])
    }
    #expect(throws: ClaudeTextWorkAccessError.self) {
        try ClaudeTextReadAccess(sharedDirectoryURL: sharedFolder, skills: [ClaudeTextWorkSkill(name: "pickup", summary: "")], protectedPaths: [])
    }
    #expect(throws: ClaudeTextWorkAccessError.self) { try ClaudeTextReadAccess(protectedPaths: []) }
}
