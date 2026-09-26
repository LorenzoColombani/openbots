import Darwin
import Foundation
import Testing
@testable import OpenBotsServices

@Suite("Physical native job workspace identity and nofollow boundaries", .serialized)
struct NativeAgenticJobWorkspaceTests {
    @Test("An existing physical private-tmp workspace creates and reads one report with restrictive modes")
    func normalReport() throws {
        let fixture = JobWorkspaceFixture()
        defer { fixture.remove() }
        var workspace = try NativeAgenticJobWorkspace(root: fixture.root)
        try workspace.createDirectory(fixture.worker)
        try workspace.createDirectory(fixture.work)
        let bytes = Data("Completed synthetic report.\n".utf8)
        try workspace.writeNew(bytes, to: fixture.report)
        try workspace.verify()
        #expect(try workspace.readRegular(fixture.report, maximum: 65_536) == bytes)
        for directory in [fixture.root, fixture.worker, fixture.work] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.report.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(throws: (any Error).self) { try workspace.readRegular(fixture.report, maximum: bytes.count - 1) }
    }

    @Test("Replacing a worker ancestor with a symlink cannot redirect reads or creates outside the retained workspace")
    func replacedAncestorSymlink() throws {
        let fixture = JobWorkspaceFixture(), outside = JobWorkspaceFixture()
        defer { fixture.remove(); outside.remove() }
        var workspace = try NativeAgenticJobWorkspace(root: fixture.root)
        try workspace.createDirectory(fixture.worker)
        try workspace.createDirectory(fixture.work)
        var other = try NativeAgenticJobWorkspace(root: outside.root)
        try other.createDirectory(outside.worker)
        try other.createDirectory(outside.work)
        let sentinel = Data("Outside fixture bytes must stay outside.\n".utf8)
        try other.writeNew(sentinel, to: outside.report)
        let parked = fixture.root.appending(path: "original-worker")
        try FileManager.default.moveItem(at: fixture.worker, to: parked)
        try FileManager.default.createSymbolicLink(at: fixture.worker, withDestinationURL: outside.worker)

        #expect(throws: (any Error).self) { try workspace.verify() }
        #expect(throws: (any Error).self) { try workspace.readRegular(fixture.report, maximum: 65_536) }
        #expect(throws: (any Error).self) { try workspace.writeNew(Data("must not escape".utf8), to: fixture.work.appending(path: "escaped.txt")) }
        #expect(throws: (any Error).self) { try workspace.createDirectory(fixture.work.appending(path: "escaped-directory")) }
        #expect(try other.readRegular(outside.report, maximum: 65_536) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: outside.work.appending(path: "escaped.txt").path))
        #expect(!FileManager.default.fileExists(atPath: outside.work.appending(path: "escaped-directory").path))
    }

    @Test("Replacing work with a different ordinary owner-0700 directory fails inode revalidation")
    func replacedOrdinaryDirectory() throws {
        let fixture = JobWorkspaceFixture()
        defer { fixture.remove() }
        var workspace = try NativeAgenticJobWorkspace(root: fixture.root)
        try workspace.createDirectory(fixture.worker)
        try workspace.createDirectory(fixture.work)
        let original = Data("Original completed report.\n".utf8)
        try workspace.writeNew(original, to: fixture.report)
        let parked = fixture.worker.appending(path: "original-work")
        try FileManager.default.moveItem(at: fixture.work, to: parked)
        try FileManager.default.createDirectory(at: fixture.work, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try Data("Replacement inode data".utf8).write(to: fixture.report)
        #expect(throws: (any Error).self) { try workspace.verify() }
        #expect(throws: (any Error).self) { try workspace.readRegular(fixture.report, maximum: 65_536) }
        #expect(throws: (any Error).self) { try workspace.writeNew(Data("new".utf8), to: fixture.work.appending(path: "new.txt")) }
        #expect(throws: (any Error).self) { try workspace.createDirectory(fixture.work.appending(path: "nested")) }
        #expect(try Data(contentsOf: parked.appending(path: "report.md")) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.work.appending(path: "new.txt").path))
    }

    @Test("A final report symlink or hardlink cannot be read or overwritten", arguments: ["symlink", "hardlink"])
    func finalFileLinks(_ kind: String) throws {
        let fixture = JobWorkspaceFixture(), outside = JobWorkspaceFixture()
        defer { fixture.remove(); outside.remove() }
        var workspace = try NativeAgenticJobWorkspace(root: fixture.root)
        try workspace.createDirectory(fixture.worker)
        try workspace.createDirectory(fixture.work)
        var other = try NativeAgenticJobWorkspace(root: outside.root)
        try other.createDirectory(outside.worker)
        try other.createDirectory(outside.work)
        let sentinel = Data("Only the other fixture owns these bytes.\n".utf8)
        try other.writeNew(sentinel, to: outside.report)
        if kind == "symlink" {
            try FileManager.default.createSymbolicLink(at: fixture.report, withDestinationURL: outside.report)
        } else {
            try #require(link(outside.report.path, fixture.report.path) == 0)
        }
        #expect(throws: (any Error).self) { try workspace.readRegular(fixture.report, maximum: 65_536) }
        #expect(throws: (any Error).self) { try workspace.writeNew(Data("overwrite".utf8), to: fixture.report) }
        #expect(try Data(contentsOf: outside.report) == sentinel)
    }

    @Test("Root, directory and file creation collisions never adopt or replace existing items")
    func exclusiveCreation() throws {
        let fixture = JobWorkspaceFixture()
        defer { fixture.remove() }
        var workspace = try NativeAgenticJobWorkspace(root: fixture.root)
        #expect(throws: (any Error).self) { try NativeAgenticJobWorkspace(root: fixture.root) }
        try workspace.createDirectory(fixture.worker)
        try workspace.createDirectory(fixture.work)
        #expect(throws: (any Error).self) { try workspace.createDirectory(fixture.worker) }
        let untracked = fixture.root.appending(path: "pre-existing")
        try FileManager.default.createDirectory(at: untracked, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        #expect(throws: (any Error).self) { try workspace.createDirectory(untracked) }
        let original = Data("Retain this exact existing report.".utf8)
        try workspace.writeNew(original, to: fixture.report)
        var before = stat(), after = stat()
        try #require(lstat(fixture.report.path, &before) == 0)
        #expect(throws: (any Error).self) { try workspace.writeNew(Data("replacement".utf8), to: fixture.report) }
        try #require(lstat(fixture.report.path, &after) == 0)
        #expect(before.st_dev == after.st_dev && before.st_ino == after.st_ino)
        #expect(try workspace.readRegular(fixture.report, maximum: 65_536) == original)
        try workspace.verify()
    }

    @Test("Sibling scope, traversal and an alternate tmp spelling cannot enter the owned directory chain")
    func scopeAndSpelling() throws {
        let fixture = JobWorkspaceFixture(), outside = JobWorkspaceFixture()
        defer { fixture.remove(); outside.remove() }
        var workspace = try NativeAgenticJobWorkspace(root: fixture.root)
        try workspace.createDirectory(fixture.worker)
        try workspace.createDirectory(fixture.work)
        var other = try NativeAgenticJobWorkspace(root: outside.root)
        try other.createDirectory(outside.worker)
        try other.createDirectory(outside.work)
        try other.writeNew(Data("outside".utf8), to: outside.report)
        #expect(throws: (any Error).self) { try workspace.readRegular(outside.report, maximum: 65_536) }
        #expect(throws: (any Error).self) { try workspace.writeNew(Data("escape".utf8), to: outside.work.appending(path: "escape.txt")) }
        #expect(throws: (any Error).self) { try workspace.createDirectory(outside.root.appending(path: "escape")) }
        let traversal = URL(fileURLWithPath: fixture.root.path + "/worker/../traversal")
        #expect(throws: (any Error).self) { try workspace.createDirectory(traversal) }
        try workspace.writeNew(Data("existing inside report".utf8), to: fixture.report)
        let alternate = URL(fileURLWithPath: String(fixture.report.path.dropFirst("/private".count)))
        #expect(throws: (any Error).self) { try workspace.readRegular(alternate, maximum: 65_536) }
        #expect(!FileManager.default.fileExists(atPath: outside.work.appending(path: "escape.txt").path))
    }
}

private struct JobWorkspaceFixture {
    let root = URL(fileURLWithPath: "/private/tmp/OpenBotsWorkspaceTest-\(UUID().uuidString).noindex")
    var worker: URL { root.appending(path: "worker") }
    var work: URL { worker.appending(path: "work") }
    var report: URL { work.appending(path: "report.md") }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
