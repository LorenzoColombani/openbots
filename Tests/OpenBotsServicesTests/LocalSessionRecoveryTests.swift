import Foundation
import Testing
import OpenBotsDomain
@testable import OpenBotsPersistence
@testable import OpenBotsServices

@Suite("Bounded local session recovery marker")
struct LocalSessionRecoveryTests {
    @Test("Version-one session records round-trip with bounded data and coherent dates")
    func recordContract() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        for status in [LocalSessionSaveOutcome.open, .saved, .incomplete] {
            let record = try LocalSessionRecoveryRecord(id: UUID(), startedAt: start,
                endedAt: status == .open ? nil : start.addingTimeInterval(10), status: status)
            let data = try record.encodedData()
            #expect(data.count <= LocalSessionRecoveryRecord.maximumEncodedByteCount)
            #expect(try LocalSessionRecoveryRecord.decode(data) == record)
        }
        #expect(throws: LocalSessionRecoveryError.invalidRecord) {
            try LocalSessionRecoveryRecord(version: 2, id: UUID(), startedAt: start, status: .open)
        }
        #expect(throws: LocalSessionRecoveryError.invalidRecord) {
            try LocalSessionRecoveryRecord(id: UUID(), startedAt: start, endedAt: start, status: .open)
        }
        #expect(throws: LocalSessionRecoveryError.invalidRecord) {
            try LocalSessionRecoveryRecord(id: UUID(), startedAt: start, status: .saved)
        }
        #expect(throws: LocalSessionRecoveryError.invalidRecord) {
            try LocalSessionRecoveryRecord(id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(-1), status: .incomplete)
        }
        #expect(throws: LocalSessionRecoveryError.invalidRecord) {
            try LocalSessionRecoveryRecord(id: UUID(), startedAt: Date(timeIntervalSince1970: .infinity), status: .open)
        }
    }

    @Test("Initializer and finish-before-begin do not read, write or consult the clock")
    func inertConstruction() async {
        let repository = SessionRepositoryDouble()
        let clock = SessionTestClock()
        let service = LocalSessionRecoveryService(repository: repository, clock: clock)
        #expect(await repository.begins == 0)
        #expect(await repository.finishes == 0)
        #expect(clock.calls == 0)
        #expect(await service.finish(saved: true) == false)
        #expect(await repository.finishes == 0)
        #expect(clock.calls == 0)
    }

    @Test("A confirmed save survives an actual SQLite close and reopen without a warning")
    func savedReopen() async throws {
        let fixture = try SessionSQLiteFixture()
        defer { fixture.remove() }
        let weak = try await persistSession(fixture, saved: true)
        #expect(weak.value == nil)
        let store = try fixture.open()
        let service = LocalSessionRecoveryService(repository: store, clock: SessionTestClock())
        #expect(await service.begin() == nil)
        #expect(try await sessionRecord(store)?.status == .open)
        #expect(try await store.runtimeFacts().migrationCount == fixture.migrationCount)
        try assertSessionFilesAreProtected(fixture)
    }

    @Test("An unclosed session survives SQLite reopen and reports uncertainty, not certain data loss")
    func openReopen() async throws {
        let fixture = try SessionSQLiteFixture()
        defer { fixture.remove() }
        let weak = try await persistSession(fixture, saved: nil)
        #expect(weak.value == nil)
        let store = try fixture.open()
        let service = LocalSessionRecoveryService(repository: store, clock: SessionTestClock())
        let notice = await service.begin()
        #expect(notice == LocalSessionRecoveryService.unconfirmedCloseNotice)
        #expect(notice?.contains("does not confirm that anything was lost") == true)
        #expect(notice?.contains(fixture.directory.path) == false)
        #expect(try await sessionRecord(store)?.status == .open)
    }

    @Test("Explicit incomplete saving remains an unconfirmed-close notice on reopen")
    func incompleteReopen() async throws {
        let fixture = try SessionSQLiteFixture()
        defer { fixture.remove() }
        let weak = try await persistSession(fixture, saved: false)
        #expect(weak.value == nil)
        let store = try fixture.open()
        #expect(try await sessionRecord(store)?.status == .incomplete)
        let service = LocalSessionRecoveryService(repository: store, clock: SessionTestClock())
        #expect(await service.begin() == LocalSessionRecoveryService.unconfirmedCloseNotice)
    }

    @Test("A late previous-session finish cannot close a new session on another connection")
    func staleFinishAcrossConnections() async throws {
        let fixture = try SessionSQLiteFixture()
        defer { fixture.remove() }
        let oldStore = try fixture.open()
        let newStore = try fixture.open()
        let oldID = UUID(), newID = UUID()
        let date = Date(timeIntervalSince1970: 1_000)
        #expect(try await oldStore.beginLocalSession(id: oldID, at: date) == nil)
        let previous = try await newStore.beginLocalSession(id: newID, at: date.addingTimeInterval(1))
        #expect(previous?.id == oldID && previous?.status == .open)
        await #expect(throws: LocalSessionRecoveryError.staleSession) {
            try await oldStore.finishLocalSession(id: oldID, outcome: .saved, at: date.addingTimeInterval(2))
        }
        #expect(try await sessionRecord(newStore)?.id == newID)
        #expect(try await sessionRecord(newStore)?.status == .open)
        try await newStore.finishLocalSession(id: newID, outcome: .incomplete, at: date.addingTimeInterval(3))
        #expect(try await sessionRecord(oldStore)?.status == .incomplete)
    }

    @Test("Malformed or oversized prior metadata is never overwritten by begin or finish")
    func malformedMetadata() async throws {
        let fixture = try SessionSQLiteFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        let id = UUID()
        let valid = try LocalSessionRecoveryRecord(id: id, startedAt: Date(timeIntervalSince1970: 1_000), status: .open)
        let validJSON = String(decoding: try valid.encodedData(), as: UTF8.self)
        let cases = ["", "not json", "[]", String(repeating: "x", count: 1_025),
                     validJSON.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
                     validJSON.replacingOccurrences(of: "\"status\":\"open\"", with: "\"status\":\"saved\""),
                     validJSON.dropLast() + ",\"privatePath\":\"forbidden\"}"]
        for json in cases {
            _ = try await store.execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
                bindings: [.text("preview_local_session_v1"), .text(json)])
            await #expect(throws: LocalSessionRecoveryError.invalidRecord) {
                try await store.beginLocalSession(id: UUID(), at: Date(timeIntervalSince1970: 1_001))
            }
            await #expect(throws: LocalSessionRecoveryError.invalidRecord) {
                try await store.finishLocalSession(id: id, outcome: .saved, at: Date(timeIntervalSince1970: 1_002))
            }
            #expect(try await sessionJSON(store) == json)
        }
        let service = LocalSessionRecoveryService(repository: store)
        #expect(await service.begin() == LocalSessionRecoveryService.unavailableNotice)
        #expect(await service.finish(saved: true) == false)
        #expect(try await sessionJSON(store) == cases.last)
    }

    @Test("Only an exact open marker can finish, with no same-ID reset or time reversal")
    func finishContract() async throws {
        let fixture = try SessionSQLiteFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        let id = UUID(), date = Date(timeIntervalSince1970: 1_000)
        _ = try await store.beginLocalSession(id: id, at: date)
        await #expect(throws: LocalSessionRecoveryError.staleSession) { try await store.beginLocalSession(id: id, at: date) }
        await #expect(throws: LocalSessionRecoveryError.invalidTransition) { try await store.finishLocalSession(id: id, outcome: .open, at: date) }
        await #expect(throws: LocalSessionRecoveryError.invalidRecord) { try await store.finishLocalSession(id: id, outcome: .saved, at: date.addingTimeInterval(-1)) }
        #expect(try await sessionRecord(store)?.status == .open)
        try await store.finishLocalSession(id: id, outcome: .saved, at: date)
        await #expect(throws: LocalSessionRecoveryError.staleSession) { try await store.finishLocalSession(id: id, outcome: .incomplete, at: date) }
        #expect(try await sessionRecord(store)?.status == .saved)
    }

    @Test("Concurrent finish attempts have exactly one persisted winner")
    func concurrentFinish() async throws {
        let fixture = try SessionSQLiteFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        let id = UUID(), date = Date(timeIntervalSince1970: 1_000)
        _ = try await store.beginLocalSession(id: id, at: date)
        let successes = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<8 {
                group.addTask {
                    do { try await store.finishLocalSession(id: id, outcome: index.isMultiple(of: 2) ? .saved : .incomplete, at: date); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        #expect(successes == 1)
        #expect(try await sessionRecord(store)?.status != .open)
    }

    @Test("Cancellation before SQLite begin or finish preserves the existing marker")
    func cancelledRepositoryWrite() async throws {
        let fixture = try SessionSQLiteFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        let id = UUID(), date = Date(timeIntervalSince1970: 1_000)
        _ = try await store.beginLocalSession(id: id, at: date)
        let before = try await sessionJSON(store)
        let begin = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.beginLocalSession(id: UUID(), at: date)
        }
        await #expect(throws: CancellationError.self) { try await begin.value }
        let finish = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.finishLocalSession(id: id, outcome: .saved, at: date)
        }
        await #expect(throws: CancellationError.self) { try await finish.value }
        #expect(try await sessionJSON(store) == before)
    }

    @Test("Cancelled service finish leaves an open marker and never reports saving succeeded")
    func cancelledServiceFinish() async throws {
        let fixture = try SessionSQLiteFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        let service = LocalSessionRecoveryService(repository: store, clock: SessionTestClock())
        #expect(await service.begin() == nil)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.finish(saved: true)
        }
        #expect(await task.value == false)
        #expect(try await sessionRecord(store)?.status == .open)
        let next = LocalSessionRecoveryService(repository: store, clock: SessionTestClock())
        #expect(await next.begin() == LocalSessionRecoveryService.unconfirmedCloseNotice)
    }

    @Test("Failed save-status writes preserve open recovery and unrelated metadata")
    func failedFinish() async throws {
        let fixture = try SessionSQLiteFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        _ = try await store.execute(sql: "INSERT INTO app_metadata(key,value) VALUES ('unrelated_local_test','preserved');")
        let service = LocalSessionRecoveryService(repository: store, clock: SessionTestClock())
        #expect(await service.begin() == nil)
        _ = try await store.execute(sql: "PRAGMA query_only=ON;")
        #expect(await service.finish(saved: true) == false)
        _ = try await store.execute(sql: "PRAGMA query_only=OFF;")
        #expect(try await sessionRecord(store)?.status == .open)
        let next = LocalSessionRecoveryService(repository: store, clock: SessionTestClock())
        #expect(await next.begin() == LocalSessionRecoveryService.unconfirmedCloseNotice)
        #expect(try await store.query(sql: "SELECT value FROM app_metadata WHERE key='unrelated_local_test';").first?.text("value") == "preserved")
        try assertSessionFilesAreProtected(fixture)
    }

    @Test("Service duplicate begin and matching finish do not rewrite or extend one session")
    func duplicateServiceCalls() async {
        let repository = SessionRepositoryDouble()
        let service = LocalSessionRecoveryService(repository: repository, clock: SessionTestClock())
        #expect(await service.begin() == nil)
        #expect(await service.begin() == nil)
        #expect(await repository.begins == 1)
        #expect(await service.finish(saved: true))
        #expect(await service.finish(saved: true))
        #expect(await service.finish(saved: false) == false)
        #expect(await repository.finishes == 1)
    }

    private func persistSession(_ fixture: SessionSQLiteFixture, saved: Bool?) async throws -> WeakSessionStore {
        let store = try fixture.open()
        let service = LocalSessionRecoveryService(repository: store, clock: SessionTestClock())
        #expect(await service.begin() == nil)
        if let saved { #expect(await service.finish(saved: saved)) }
        return WeakSessionStore(store)
    }
}

private struct SessionSQLiteFixture: Sendable {
    let directory: URL
    let protection: ProtectionDecisionReceipt
    let migrationCount: Int
    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextLocalSession-\(UUID()).noindex", isDirectory: true)
        protection = try .init(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        // Assert the marker does not change the currently approved schema.
        migrationCount = StoragePersistenceCompositionService.expectedMigrationCount
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: .init(fileURL: directory.appending(path: "control.sqlite"), protection: .ordinarySQLite(decision: protection)))
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
private final class WeakSessionStore: @unchecked Sendable {
    weak var value: SQLiteStore?
    init(_ value: SQLiteStore) { self.value = value }
}
private final class SessionTestClock: OpenBotsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; count += 1; return Date(timeIntervalSince1970: 1_000) }
}
private actor SessionRepositoryDouble: LocalSessionRecoveryRepository {
    private(set) var begins = 0
    private(set) var finishes = 0
    private var current: LocalSessionRecoveryRecord?
    func beginLocalSession(id: UUID, at: Date) async throws -> LocalSessionRecoveryRecord? {
        begins += 1
        let prior = current
        current = try .init(id: id, startedAt: at, status: .open)
        return prior
    }
    func finishLocalSession(id: UUID, outcome: LocalSessionSaveOutcome, at: Date) async throws {
        guard let current, current.id == id, current.status == .open else { throw LocalSessionRecoveryError.staleSession }
        finishes += 1
        self.current = try .init(id: id, startedAt: current.startedAt, endedAt: at, status: outcome)
    }
}
private func sessionJSON(_ store: SQLiteStore) async throws -> String? {
    try await store.query(sql: "SELECT value FROM app_metadata WHERE key='preview_local_session_v1';").first?.text("value")
}
private func sessionRecord(_ store: SQLiteStore) async throws -> LocalSessionRecoveryRecord? {
    guard let json = try await sessionJSON(store) else { return nil }
    return try .decode(Data(json.utf8))
}
private func assertSessionFilesAreProtected(_ fixture: SessionSQLiteFixture) throws {
    for name in ["control.sqlite", "control.sqlite-wal", "control.sqlite-shm"] {
        let url = fixture.directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
