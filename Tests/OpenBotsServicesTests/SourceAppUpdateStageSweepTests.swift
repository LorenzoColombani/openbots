import Darwin
import Foundation
import Testing
@testable import OpenBotsServices

@Suite("Source update stage sweep")
struct SourceAppUpdateStageSweepTests {
    private var manager: FileManager { .default }

    private func write(_ text: String, to url: URL) throws {
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        guard manager.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// A stage as the worker leaves it: heavy source and build products, the
    /// job, a build log, and whichever launch and stop receipts the case needs.
    private func stage(in root: URL, controller: Int32? = nil, stopped: Bool? = nil) throws -> URL {
        let url = root.appending(path: UUID().uuidString)
        try manager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try write("built app bytes", to: url.appending(path: "source/.build.noindex/source-update/Build/Products/Release/OpenBots Next.app/Contents/MacOS/OpenBots Next"))
        try write("{\"files\":[]}", to: url.appending(path: "job.json"))
        try write("build output", to: url.appending(path: "build.log"))
        try write("temporary", to: url.appending(path: "tmp.build-droppings"))
        if let controller {
            try write("{\"controllerIdentity\":{\"pid\":\(controller)},\"nonce\":\"a\"}", to: url.appending(path: "launch.json"))
        }
        if let stopped {
            try write("{\"nonce\":\"a\",\"stopped\":\(stopped)}", to: url.appending(path: "stopped.json"))
        }
        return url
    }

    @Test("Finished stages keep only their receipts, live ones are untouched, and only the newest ten stay")
    func sweep() throws {
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().appending(path: "source-update-sweep-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appending(path: "source-update-sweep-outside-\(UUID().uuidString)")
        try write("not ours", to: outside.appending(path: "keep.txt"))
        defer { try? manager.removeItem(at: outside) }

        let oldest = try stage(in: root, controller: 999_999, stopped: true)
        let finished = try stage(in: root, controller: 999_999, stopped: true)
        try manager.createSymbolicLink(at: finished.appending(path: "escape"), withDestinationURL: outside)
        let neverLaunched = try stage(in: root)
        var others: [URL] = []
        for _ in 0..<8 { others.append(try stage(in: root, controller: 999_999, stopped: true)) }
        // Running controller (this test's own process) without a stop receipt.
        let running = try stage(in: root, controller: getpid())
        let kept = try stage(in: root)
        try write("{\"status\":\"installed\"}", to: root.appending(path: "last-installation.json"))
        try write("previous app", to: root.appending(path: "Rollback/\(UUID().uuidString)/OpenBots Next.app/Contents/Info.plist"))

        sweepSourceUpdateStages(in: root, keeping: kept)

        let heavy = "source/.build.noindex/source-update/Build/Products/Release/OpenBots Next.app/Contents/MacOS/OpenBots Next"
        for stage in [finished, neverLaunched] + others {
            #expect(!manager.fileExists(atPath: stage.appending(path: "source").path))
            #expect(!manager.fileExists(atPath: stage.appending(path: "job.json").path))
            #expect(!manager.fileExists(atPath: stage.appending(path: "tmp.build-droppings").path))
            #expect(manager.fileExists(atPath: stage.appending(path: "build.log").path))
        }
        #expect(manager.fileExists(atPath: finished.appending(path: "stopped.json").path))
        #expect(manager.fileExists(atPath: finished.appending(path: "launch.json").path))
        // The link was removed, never followed.
        #expect((try? manager.destinationOfSymbolicLink(atPath: finished.appending(path: "escape").path)) == nil)
        #expect(manager.fileExists(atPath: outside.appending(path: "keep.txt").path))
        // Eleven stages were sweepable; the oldest goes whole.
        #expect(!manager.fileExists(atPath: oldest.path))
        for stage in [running, kept] {
            #expect(manager.fileExists(atPath: stage.appending(path: heavy).path))
            #expect(manager.fileExists(atPath: stage.appending(path: "job.json").path))
        }
        #expect(manager.fileExists(atPath: root.appending(path: "last-installation.json").path))
        let rollbacks = try manager.contentsOfDirectory(atPath: root.appending(path: "Rollback").path)
        #expect(rollbacks.count == 1)
    }

    @Test("A missing root is never created by a sweep")
    func missingRoot() {
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().appending(path: "source-update-absent-\(UUID().uuidString)")
        sweepSourceUpdateStages(in: root, keeping: nil)
        #expect(!manager.fileExists(atPath: root.path))
    }
}
