import Darwin
import Foundation
import Testing
@testable import OpenBotsRuntime

@Test("Private prompt files preserve bounded UTF8 content with exact restrictive permissions and cleanup")
func claudeTextPrivatePromptFile() throws {
    let fixture = try ClaudeConnectionFixture(body: ":")
    defer { fixture.remove() }
    let request = try textOnlyTestRequest(target: fixture.target,
        systemPrompt: String(repeating: "😀", count: 24_576))
    let url = ClaudeTextOnlyCommandBuilder.systemPromptFileURL(for: request)
    let file = try ClaudeTextOnlyPromptFile.create(for: request)
    var metadata = stat()
    #expect(lstat(url.path, &metadata) == 0)
    #expect(metadata.st_mode & S_IFMT == S_IFREG)
    #expect(metadata.st_mode & 0o7777 == 0o600)
    #expect(metadata.st_uid == geteuid())
    #expect(metadata.st_nlink == 1)
    #expect(try Data(contentsOf: url) == Data(request.systemPrompt.utf8))
    #expect(file.isUnchanged())
    #expect(file.removeIfUnchanged())
    #expect(file.removeIfUnchanged())
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test("Empty and oversized private prompts fail without creating runtime files")
func claudeTextPrivatePromptBounds() throws {
    let fixture = try ClaudeConnectionFixture(body: ":")
    defer { fixture.remove() }
    for prompt in ["", String(repeating: "x", count: 98_305)] {
        #expect(throws: ClaudeTextOnlyRequestError.invalidSystemPrompt) {
            let request = try textOnlyTestRequest(target: fixture.target, systemPrompt: prompt)
            _ = try ClaudeTextOnlyPromptFile.create(for: request)
        }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.target.temporaryDirectoryURL.path).isEmpty)
}

@Test("Private prompt creation refuses existing regular files, symlinks, directories and FIFOs without replacing them")
func claudeTextPrivatePromptCollisions() throws {
    let fixture = try ClaudeConnectionFixture(body: ":")
    defer { fixture.remove() }
    let request = try textOnlyTestRequest(target: fixture.target)
    let url = ClaudeTextOnlyCommandBuilder.systemPromptFileURL(for: request)
    let sentinel = fixture.root.appendingPathComponent("sentinel")
    try Data("preserve sentinel".utf8).write(to: sentinel, options: .withoutOverwriting)
    let manager = FileManager.default
    for kind in ["file", "symlink", "directory", "fifo"] {
        switch kind {
        case "file": try Data("preserve existing".utf8).write(to: url, options: .withoutOverwriting)
        case "symlink": try manager.createSymbolicLink(at: url, withDestinationURL: sentinel)
        case "directory": try manager.createDirectory(at: url, withIntermediateDirectories: false)
        default: #expect(mkfifo(url.path, 0o600) == 0)
        }
        #expect(throws: ClaudeTextOnlyPromptFileError.self) { _ = try ClaudeTextOnlyPromptFile.create(for: request) }
        var metadata = stat()
        #expect(lstat(url.path, &metadata) == 0)
        if kind == "file" { #expect(try String(contentsOf: url, encoding: .utf8) == "preserve existing") }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve sentinel")
        try manager.removeItem(at: url)
    }
}

@Test("Private prompt creation refuses unsafe temp permissions and symlinked ancestors without repair")
func claudeTextPrivatePromptUnsafeDirectory() throws {
    let fixture = try ClaudeConnectionFixture(body: ":")
    defer { fixture.remove() }
    let manager = FileManager.default
    let request = try textOnlyTestRequest(target: fixture.target)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.target.temporaryDirectoryURL.path)
    #expect(throws: ClaudeTextOnlyPromptFileError.self) { _ = try ClaudeTextOnlyPromptFile.create(for: request) }
    var metadata = stat()
    #expect(lstat(fixture.target.temporaryDirectoryURL.path, &metadata) == 0)
    #expect(metadata.st_mode & 0o7777 == 0o755)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.target.temporaryDirectoryURL.path)
    let original = fixture.root.appendingPathComponent("original-temp")
    try manager.moveItem(at: fixture.target.temporaryDirectoryURL, to: original)
    try manager.createSymbolicLink(at: fixture.target.temporaryDirectoryURL, withDestinationURL: original)
    #expect(throws: ClaudeTextOnlyPromptFileError.self) { _ = try ClaudeTextOnlyPromptFile.create(for: request) }
    #expect(try manager.contentsOfDirectory(atPath: original.path).isEmpty)
}

@Test("Private prompt transport never uses the account profile or home as its scratch directory")
func claudeTextPrivatePromptRejectsAccountDirectories() throws {
    let fixture = try ClaudeConnectionFixture(body: ":")
    defer { fixture.remove() }
    for directory in [fixture.target.profileURL, fixture.target.homeDirectoryURL] {
        let original = fixture.target
        let target = try ClaudeConnectionTarget(executableURL: original.executableURL,
            expectedExecutableSHA256: original.expectedExecutableSHA256, profileURL: original.profileURL,
            workingDirectoryURL: original.workingDirectoryURL, temporaryDirectoryURL: directory,
            homeDirectoryURL: original.homeDirectoryURL)
        let request = try textOnlyTestRequest(target: target)
        #expect(throws: ClaudeTextOnlyPromptFileError.self) { _ = try ClaudeTextOnlyPromptFile.create(for: request) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}

@Test("Cleanup preserves a replacement file and the moved original instead of deleting by pathname")
func claudeTextPrivatePromptPreservesReplacement() throws {
    let fixture = try ClaudeConnectionFixture(body: ":")
    defer { fixture.remove() }
    let request = try textOnlyTestRequest(target: fixture.target)
    let url = ClaudeTextOnlyCommandBuilder.systemPromptFileURL(for: request)
    let file = try ClaudeTextOnlyPromptFile.create(for: request)
    let moved = fixture.target.temporaryDirectoryURL.appendingPathComponent("moved-original")
    try FileManager.default.moveItem(at: url, to: moved)
    try Data("replacement must survive".utf8).write(to: url, options: .withoutOverwriting)
    #expect(!file.isUnchanged())
    #expect(!file.removeIfUnchanged())
    #expect(try String(contentsOf: url, encoding: .utf8) == "replacement must survive")
    #expect(try String(contentsOf: moved, encoding: .utf8) == request.systemPrompt)
}

@Test("Cleanup refuses an altered prompt or a moved temp directory without broad deletion")
func claudeTextPrivatePromptPreservesChangedIdentity() throws {
    let fixture = try ClaudeConnectionFixture(body: ":")
    defer { fixture.remove() }
    let request = try textOnlyTestRequest(target: fixture.target)
    let url = ClaudeTextOnlyCommandBuilder.systemPromptFileURL(for: request)
    let file = try ClaudeTextOnlyPromptFile.create(for: request)
    try Data("changed private prompt".utf8).write(to: url)
    #expect(!file.isUnchanged())
    #expect(!file.removeIfUnchanged())
    let moved = fixture.root.appendingPathComponent("moved-temp")
    try FileManager.default.moveItem(at: fixture.target.temporaryDirectoryURL, to: moved)
    try FileManager.default.createDirectory(at: fixture.target.temporaryDirectoryURL, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    try Data("replacement directory file".utf8).write(to: url, options: .withoutOverwriting)
    #expect(!file.removeIfUnchanged())
    #expect(try String(contentsOf: url, encoding: .utf8) == "replacement directory file")
    #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent(url.lastPathComponent).path))
}

@Test("Cancellation during a private prompt write removes only its partial owned file")
func claudeTextPrivatePromptPartialWriteCleanup() throws {
    let fixture = try ClaudeConnectionFixture(body: ":")
    defer { fixture.remove() }
    let request = try textOnlyTestRequest(target: fixture.target, systemPrompt: String(repeating: "x", count: 98_304))
    var checks = 0
    #expect(throws: ClaudeTextOnlyPromptFileError.self) {
        _ = try ClaudeTextOnlyPromptFile.create(for: request) {
            checks += 1
            return checks < 4
        }
    }
    #expect(checks == 4)
    #expect(!FileManager.default.fileExists(atPath: ClaudeTextOnlyCommandBuilder.systemPromptFileURL(for: request).path))
}
