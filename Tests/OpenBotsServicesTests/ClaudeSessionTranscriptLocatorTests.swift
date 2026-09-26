import Foundation
import OpenBotsDomain
@testable import OpenBotsServices
import Testing

/// What the CLI keeps of a kept session under the app profile, and
/// how the app removes it when the session is dropped. The shapes follow the
/// real files: a transcript line carries `type`, `sessionId` and `cwd`; a
/// history line carries `display`, `pastedContents`, `project`, `sessionId`
/// and `timestamp`. Every content here is invented.
@Suite("Claude session transcripts under the app profile")
struct ClaudeSessionTranscriptLocatorTests {
    @Test("Dropping a session removes its transcript in every project folder, its own folder, and its history lines, and nothing else")
    func removalTakesOnlyTheSessionsFiles() throws {
        let f = try ProfileFixture(); defer { f.remove() }
        let session = UUID(), other = UUID()
        // The CLI names the folder after the turn's cwd, so one session can sit under two.
        let work = try f.project("-Users-someone-Bots-Pillow-Work-noindex")
        let desk = try f.project("-Users-someone-Bots-Pillow")
        let inWork = try f.transcript(session, in: work)
        let inDesk = try f.transcript(session, in: desk)
        let otherTranscript = try f.transcript(other, in: desk)
        // The session's own folder holds its helpers' transcripts.
        let own = work.appendingPathComponent(session.uuidString.lowercased(), isDirectory: true)
        let subagents = own.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try Data("{\"type\":\"user\",\"sessionId\":\"\(session.uuidString.lowercased())\",\"isSidechain\":true}\n".utf8)
            .write(to: subagents.appendingPathComponent("agent-a1b2c3.jsonl"))
        let kept = [f.historyLine(other, display: "hello"), "not json at all", f.historyLine(other, display: "bye")]
        let history = [kept[0], f.historyLine(session, display: "Remember the word: lantern."),
                       kept[1], f.historyLine(session, display: "What was the word?"), kept[2]]
        try f.writeHistory(history.joined(separator: "\n") + "\n")
        let otherBytes = try Data(contentsOf: otherTranscript)
        let rootBefore = try f.rootNames()

        let removal = try ClaudeSessionTranscriptLocator.remove(profileURL: f.root, sessionID: session)

        #expect(removal.droppedHistoryLines == 2)
        #expect(Set(removal.removedPaths) == [inWork.path, inDesk.path, own.path])
        #expect(removal.removedAnything)
        #expect(!ClaudeSessionTranscriptLocator.exists(profileURL: f.root, sessionID: session))
        #expect(!FileManager.default.fileExists(atPath: own.path))
        #expect(ClaudeSessionTranscriptLocator.exists(profileURL: f.root, sessionID: other))
        #expect(try Data(contentsOf: otherTranscript) == otherBytes)
        // The other lines survive byte for byte, the malformed one included, with the trailing newline.
        #expect(try String(contentsOf: f.historyURL, encoding: .utf8) == kept.joined(separator: "\n") + "\n")
        #expect(try f.mode(f.historyURL) == 0o600)
        // Rewritten in place through a temporary file and a rename: nothing left beside it.
        #expect(try f.rootNames() == rootBefore)
    }

    @Test("A project folder the removal left empty goes too; one still holding another session's file, or one it took nothing from, stays")
    func aFolderLeftEmptyGoesWithTheSession() throws {
        let f = try ProfileFixture(); defer { f.remove() }
        let session = UUID(), other = UUID()
        // One folder per turn's working folder (empty TextTurns-…-Work-noindex
        // folders were once left after the bots went).
        let alone = try f.project("-Users-someone-TextTurns-A-Work-noindex")
        let shared = try f.project("-Users-someone-TextTurns-B-Work-noindex")
        let untouched = try f.project("-Users-someone-TextTurns-C-Work-noindex")
        try f.transcript(session, in: alone)
        try f.transcript(session, in: shared)
        try f.transcript(other, in: shared)

        _ = try ClaudeSessionTranscriptLocator.remove(profileURL: f.root, sessionID: session)

        #expect(!FileManager.default.fileExists(atPath: alone.path))
        #expect(FileManager.default.fileExists(atPath: shared.path))
        #expect(FileManager.default.fileExists(atPath: untouched.path))
        #expect(ClaudeSessionTranscriptLocator.exists(profileURL: f.root, sessionID: other))
    }

    @Test("A session with nothing on disk leaves the profile alone: no history file appears, and one without its lines is not rewritten")
    func nothingToRemoveLeavesTheProfileAlone() throws {
        let f = try ProfileFixture(); defer { f.remove() }
        let session = UUID(), other = UUID()
        // No projects folder and no history yet: nothing to do, nothing created.
        let bare = try ClaudeSessionTranscriptLocator.remove(profileURL: f.root, sessionID: session)
        #expect(bare == ClaudeSessionTranscriptRemoval(removedPaths: [], droppedHistoryLines: 0))
        #expect(!bare.removedAnything)
        #expect(!FileManager.default.fileExists(atPath: f.historyURL.path))
        // Another session's history and transcript: the file keeps its inode, so it was never rewritten.
        try f.writeHistory(f.historyLine(other, display: "hello") + "\n")
        try f.transcript(other, in: f.project("-Users-someone-Bots-Zed"))
        let inode = try f.inode(f.historyURL)
        let untouched = try ClaudeSessionTranscriptLocator.remove(profileURL: f.root, sessionID: session)
        #expect(!untouched.removedAnything)
        #expect(try f.inode(f.historyURL) == inode)
        #expect(ClaudeSessionTranscriptLocator.exists(profileURL: f.root, sessionID: other))
    }

    @Test("A symbolic link under the profile is never followed: files named for the session outside projects/ stay, and are not taken for the session's")
    func removalNeverFollowsALinkOutOfTheProfile() throws {
        let f = try ProfileFixture(); defer { f.remove() }
        let outside = try ProfileFixture(); defer { outside.remove() }
        let session = UUID()
        // Files named for the session in a folder outside the profile, and a
        // project entry that is a link to that folder, beside a real project.
        let strayTranscript = try outside.transcript(session, in: outside.root)
        let strayFolder = outside.root.appendingPathComponent(session.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: strayFolder, withIntermediateDirectories: false)
        let real = try f.project("-Users-someone-Bots-Pillow")
        let inReal = try f.transcript(session, in: real)
        let link = real.deletingLastPathComponent().appendingPathComponent("-Users-someone-Elsewhere", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.root)

        let removal = try ClaudeSessionTranscriptLocator.remove(profileURL: f.root, sessionID: session)

        #expect(removal.removedPaths == [inReal.path])
        #expect(FileManager.default.fileExists(atPath: strayTranscript.path))
        #expect(FileManager.default.fileExists(atPath: strayFolder.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == outside.root.path)
        #expect(!ClaudeSessionTranscriptLocator.exists(profileURL: f.root, sessionID: session))

        // `projects` itself a link out of the profile: nothing under it is the session's.
        let linked = try ProfileFixture(); defer { linked.remove() }
        let farProject = try outside.project("-Users-someone-Bots-Zed")
        let farTranscript = try outside.transcript(session, in: farProject)
        try FileManager.default.createSymbolicLink(at: linked.root.appendingPathComponent("projects", isDirectory: true),
                                                   withDestinationURL: farProject.deletingLastPathComponent())
        #expect(!ClaudeSessionTranscriptLocator.exists(profileURL: linked.root, sessionID: session))
        let none = try ClaudeSessionTranscriptLocator.remove(profileURL: linked.root, sessionID: session)
        #expect(none.removedPaths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: farTranscript.path))
    }
}

extension ClaudeSessionTranscriptLocatorTests {
    /// The rewrite once read through a linked
    /// `history.jsonl`, took the link's own mode (0755) and renamed a regular
    /// file over the link, so the profile's history became a world-readable copy
    /// and the linked file kept the session's lines.
    @Test("A history.jsonl that is a link is never read through or replaced: the removal says it could not, and the link and its file stay exactly as they were")
    func aLinkedHistoryIsNeverFollowedOrReplaced() throws {
        let f = try ProfileFixture(); defer { f.remove() }
        let outside = try ProfileFixture(); defer { outside.remove() }
        let session = UUID(), other = UUID()
        let target = outside.root.appendingPathComponent("history.jsonl")
        let lines = [f.historyLine(other, display: "hello"), f.historyLine(session, display: "Remember the word: lantern.")]
        guard FileManager.default.createFile(atPath: target.path, contents: Data((lines.joined(separator: "\n") + "\n").utf8),
                                             attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createSymbolicLink(at: f.historyURL, withDestinationURL: target)
        let targetBytes = try Data(contentsOf: target)
        let rootBefore = try f.rootNames()

        #expect(throws: (any Error).self) { try ClaudeSessionTranscriptLocator.remove(profileURL: f.root, sessionID: session) }

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.historyURL.path) == target.path)
        #expect(try Data(contentsOf: target) == targetBytes)
        #expect(try f.mode(target) == 0o600)
        #expect(try f.rootNames() == rootBefore, "no temporary file is left beside it")
    }

    /// A folder that could not be
    /// read was taken for an empty one, so the removal reported nothing on disk
    /// and the row was cleared with the session's files still there.
    @Test("A folder the removal cannot read makes it throw, never report nothing on disk, and the files stay findable")
    func anUnreadableFolderIsNotNothingOnDisk() throws {
        let f = try ProfileFixture(); defer { f.remove() }
        let session = UUID()
        let desk = try f.project("-Users-someone-Bots-Pillow")
        let transcript = try f.transcript(session, in: desk)
        let projects = desk.deletingLastPathComponent()

        // A project folder that cannot be read.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: desk.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: desk.path) }
        #expect(throws: (any Error).self) { try ClaudeSessionTranscriptLocator.remove(profileURL: f.root, sessionID: session) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: desk.path)
        #expect(FileManager.default.fileExists(atPath: transcript.path))

        // `projects` itself cannot be read.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: projects.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: projects.path) }
        #expect(throws: (any Error).self) { try ClaudeSessionTranscriptLocator.remove(profileURL: f.root, sessionID: session) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: projects.path)
        #expect(FileManager.default.fileExists(atPath: transcript.path))

        // Readable again, the same removal takes the transcript.
        let removal = try ClaudeSessionTranscriptLocator.remove(profileURL: f.root, sessionID: session)
        #expect(removal.removedPaths == [transcript.path])
    }

    /// The check for a transcript once
    /// followed a link standing in for the file itself, so a link to a
    /// transcript anywhere read as the session's own.
    @Test("A link standing in for a session's transcript is not taken for it, and removing the session removes the link, never its target")
    func aLinkedTranscriptIsNotTheTranscript() throws {
        let f = try ProfileFixture(); defer { f.remove() }
        let outside = try ProfileFixture(); defer { outside.remove() }
        let session = UUID()
        let target = try outside.transcript(session, in: outside.root)
        let targetBytes = try Data(contentsOf: target)
        let desk = try f.project("-Users-someone-Bots-Pillow")
        let link = desk.appendingPathComponent(session.uuidString.lowercased() + ".jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(!ClaudeSessionTranscriptLocator.exists(profileURL: f.root, sessionID: session))

        let removal = try ClaudeSessionTranscriptLocator.remove(profileURL: f.root, sessionID: session)
        #expect(removal.removedPaths == [link.path])
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil, "the link itself is gone")
        #expect(try Data(contentsOf: target) == targetBytes)
    }

    /// The removal of a session's own folder walks it through descriptors,
    /// each level opened without following a link, so a link inside it goes
    /// as a link and what it points at stays.
    @Test("A link inside a session's own folder is removed as a link, and the folder it points at keeps everything")
    func aLinkInsideTheSessionsFolderIsRemovedAsALink() throws {
        let f = try ProfileFixture(); defer { f.remove() }
        let outside = try ProfileFixture(); defer { outside.remove() }
        let session = UUID()
        let kept = outside.root.appendingPathComponent("keep", isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: false)
        try Data("not the session's".utf8).write(to: kept.appendingPathComponent("notes.txt"))
        let desk = try f.project("-Users-someone-Bots-Pillow")
        let own = desk.appendingPathComponent(session.uuidString.lowercased(), isDirectory: true)
        let subagents = own.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: subagents.appendingPathComponent("agent-a1.jsonl"))
        try FileManager.default.createSymbolicLink(at: subagents.appendingPathComponent("elsewhere"), withDestinationURL: kept)

        let removal = try ClaudeSessionTranscriptLocator.remove(profileURL: f.root, sessionID: session)

        #expect(removal.removedPaths == [own.path])
        #expect(!FileManager.default.fileExists(atPath: own.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: kept.path) == ["notes.txt"])
        #expect(try String(contentsOf: kept.appendingPathComponent("notes.txt"), encoding: .utf8) == "not the session's")
        // Left empty, the project folder goes with the session.
        #expect(!FileManager.default.fileExists(atPath: desk.path))
    }

    @Test("A history.jsonl rewritten keeps the mode of the file itself")
    func aRewrittenHistoryKeepsItsOwnMode() throws {
        let f = try ProfileFixture(); defer { f.remove() }
        let session = UUID(), other = UUID()
        try f.writeHistory([f.historyLine(other, display: "hello"), f.historyLine(session, display: "bye")].joined(separator: "\n") + "\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: f.historyURL.path)
        let removal = try ClaudeSessionTranscriptLocator.remove(profileURL: f.root, sessionID: session)
        #expect(removal.droppedHistoryLines == 1)
        #expect(try f.mode(f.historyURL) == 0o640)
        #expect(try String(contentsOf: f.historyURL, encoding: .utf8) == f.historyLine(other, display: "hello") + "\n")
    }
}

private struct ProfileFixture {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextClaudeProfile-\(UUID()).noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    var historyURL: URL { root.appendingPathComponent("history.jsonl") }
    func remove() { try? FileManager.default.removeItem(at: root) }

    func project(_ slug: String) throws -> URL {
        let url = root.appendingPathComponent("projects", isDirectory: true).appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func transcript(_ id: UUID, in folder: URL) throws -> URL {
        let session = id.uuidString.lowercased()
        let url = folder.appendingPathComponent(session + ".jsonl")
        let lines = [
            "{\"type\":\"queue-operation\",\"operation\":\"enqueue\",\"sessionId\":\"\(session)\",\"timestamp\":\"2026-09-15T02:55:00.000Z\"}",
            "{\"type\":\"user\",\"sessionId\":\"\(session)\",\"cwd\":\"\(folder.path)\",\"uuid\":\"\(UUID().uuidString.lowercased())\",\"parentUuid\":null,\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":\"Remember the word: lantern.\"}}",
            "{\"type\":\"assistant\",\"sessionId\":\"\(session)\",\"cwd\":\"\(folder.path)\",\"uuid\":\"\(UUID().uuidString.lowercased())\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Lantern. Got it.\"}]}}",
        ]
        guard FileManager.default.createFile(atPath: url.path, contents: Data((lines.joined(separator: "\n") + "\n").utf8),
                                             attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    func historyLine(_ id: UUID, display: String) -> String {
        "{\"display\":\"\(display)\",\"pastedContents\":{},\"timestamp\":1789440900000,\"project\":\"/Users/someone/Bots/Pillow\",\"sessionId\":\"\(id.uuidString.lowercased())\"}"
    }

    func writeHistory(_ text: String) throws {
        guard FileManager.default.createFile(atPath: historyURL.path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
    }

    func mode(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? -1
    }

    func inode(_ url: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    func rootNames() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    }
}
