import Foundation
import Testing
@testable import OpenBotsServices

// Failed replies retain bounded diagnostic records in a private local folder,
// so a stream error can be investigated after the turn ends.
@Suite("What a failed reply keeps")
struct FailedTurnRecordsTests {
    @Test("A kept failure holds its latest frames and its CLI transcript, private to the user")
    func keepsFramesAndTranscript() throws {
        let place = try Place(); defer { place.remove() }
        let records = FailedTurnRecords(root: place.root)
        let runID = UUID(), sessionID = UUID()
        try place.transcript(sessionID, "{\"type\":\"user\"}\n")
        records.hold(runID: runID, frames: [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])
        records.finished(runID: runID, profileURL: place.profile, sessionID: sessionID, keep: true)
        let folders = try place.kept()
        #expect(folders.count == 1)
        let folder = try #require(folders.first)
        #expect(folder.lastPathComponent.hasSuffix(runID.uuidString.lowercased()))
        #expect(try String(contentsOf: folder.appendingPathComponent("frames.jsonl"), encoding: .utf8) == "{\"a\":1}\n{\"b\":2}\n")
        #expect(try String(contentsOf: folder.appendingPathComponent("transcript.jsonl"), encoding: .utf8) == "{\"type\":\"user\"}\n")
        #expect(try place.mode(folder) == 0o700)
        #expect(try place.mode(folder.appendingPathComponent("frames.jsonl")) == 0o600)
        #expect(try place.mode(place.root) == 0o700)
    }

    @Test("A turn that is not kept leaves nothing, and its held frames are let go")
    func notKeptLeavesNothing() throws {
        let place = try Place(); defer { place.remove() }
        let records = FailedTurnRecords(root: place.root)
        let runID = UUID(), sessionID = UUID()
        try place.transcript(sessionID, "private\n")
        records.hold(runID: runID, frames: [Data("x".utf8)])
        records.finished(runID: runID, profileURL: place.profile, sessionID: sessionID, keep: false)
        #expect(try place.kept().isEmpty)
        #expect(records.heldRunCount == 0)
    }

    @Test("Only the last five failures stay")
    func keepsOnlyTheLastFive() throws {
        let place = try Place(); defer { place.remove() }
        let records = FailedTurnRecords(root: place.root)
        var runs: [UUID] = []
        for index in 0..<7 {
            let runID = UUID(); runs.append(runID)
            records.hold(runID: runID, frames: [Data("\(index)".utf8)])
            records.finished(runID: runID, profileURL: place.profile, sessionID: UUID(), keep: true,
                             now: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
        }
        let names = try place.kept().map(\.lastPathComponent)
        #expect(names.count == FailedTurnRecords.keptFailures)
        #expect(Set(runs.suffix(5).map { $0.uuidString.lowercased() }) == Set(names.map { String($0.suffix(36)) }))
    }

    @Test("A transcript that is a link is never followed, and frames alone are still kept")
    func linkedTranscriptIsNotRead() throws {
        let place = try Place(); defer { place.remove() }
        let secret = place.base.appendingPathComponent("elsewhere.txt")
        try Data("NOT-HIS-TO-KEEP".utf8).write(to: secret)
        let sessionID = UUID()
        let project = place.profile.appendingPathComponent("projects/-p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent(sessionID.uuidString.lowercased() + ".jsonl"),
                                                   withDestinationURL: secret)
        let records = FailedTurnRecords(root: place.root)
        let runID = UUID()
        records.hold(runID: runID, frames: [Data("f".utf8)])
        records.finished(runID: runID, profileURL: place.profile, sessionID: sessionID, keep: true)
        let folder = try #require(try place.kept().first)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("frames.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.jsonl").path))
    }

    @Test("Frames held for runs that never finish are bounded")
    func heldFramesAreBounded() throws {
        let place = try Place(); defer { place.remove() }
        let records = FailedTurnRecords(root: place.root)
        for _ in 0..<(FailedTurnRecords.keptFailures * 3) { records.hold(runID: UUID(), frames: [Data("f".utf8)]) }
        #expect(records.heldRunCount == FailedTurnRecords.keptFailures)
    }
}

private struct Place {
    let base: URL
    var root: URL { base.appendingPathComponent("Logs/failed-turns", isDirectory: true) }
    var profile: URL { base.appendingPathComponent("CLIProfile", isDirectory: true) }
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("failed-turns-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Logs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    }
    func transcript(_ sessionID: UUID, _ text: String) throws {
        let project = profile.appendingPathComponent("projects/-work", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: project.appendingPathComponent(sessionID.uuidString.lowercased() + ".jsonl"))
    }
    func kept() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
