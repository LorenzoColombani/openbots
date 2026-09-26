import Foundation
import Testing
@testable import OpenBotsRuntime

// Peekaboo's `see` writes each screenshot of the user's screen to the account's
// own temporary folder as peekaboo-observation-<UUID>.png, whatever TMPDIR says
// (recorded on 2.1.280), and nothing took it away.

private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func file(_ name: String, in folder: URL, modified: Date) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    return url
}

@Test("A turn's own screenshots go when it ends; older ones, other files and links are left alone")
func aTurnsScreenshotsAreSweptAndNothingElse() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let started = Date()
    let mine = try file("peekaboo-observation-\(UUID().uuidString).png", in: root, modified: started.addingTimeInterval(2))
    let older = try file("peekaboo-observation-\(UUID().uuidString).png", in: root, modified: started.addingTimeInterval(-60))
    let other = try file("notes-\(UUID().uuidString).png", in: root, modified: started.addingTimeInterval(2))
    let lock = try file("boo.peekaboo.sckit-capture.lock", in: root, modified: started.addingTimeInterval(2))
    let target = try file("kept.png", in: root, modified: started.addingTimeInterval(2))
    let link = root.appendingPathComponent("peekaboo-observation-\(UUID().uuidString).png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let removed = MacControlScreenshotSweep.remove(in: root, modifiedSince: started)

    #expect(removed == 1)
    let manager = FileManager.default
    #expect(!manager.fileExists(atPath: mine.path))
    #expect(manager.fileExists(atPath: older.path) && manager.fileExists(atPath: other.path))
    #expect(manager.fileExists(atPath: lock.path) && manager.fileExists(atPath: target.path))
    #expect((try? manager.destinationOfSymbolicLink(atPath: link.path)) != nil)
}

@Test("At launch no turn runs, so every stray screenshot goes")
func atLaunchEveryStrayScreenshotGoes() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = try file("peekaboo-observation-\(UUID().uuidString).png", in: root, modified: Date(timeIntervalSinceNow: -86_400))
    #expect(MacControlScreenshotSweep.remove(in: root, modifiedSince: .distantPast) == 1)
    #expect(!FileManager.default.fileExists(atPath: old.path))
}

@Test("The folder swept is the account's own temporary folder, the one Peekaboo writes to")
func theSweptFolderIsTheAccountsTemporaryFolder() throws {
    let folder = try #require(MacControlScreenshotSweep.accountTemporaryFolder())
    #expect(folder.path.hasPrefix("/private/var/folders/") || folder.path.hasPrefix("/var/folders/"))
}
