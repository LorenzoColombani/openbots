import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

/// The switch store used to forget everything at launch. The web switches
/// now survive a relaunch, so the store
/// restores them from a repository and writes every later change to it. These
/// pin that seam: what comes back, what is written, in what order, and what
/// happens when the database says no.
@Suite("The switch store restoring and persisting the web switches")
struct AgenticJobAccessStoreTests {
    @Test("A restored switch is on the way a switch just turned on is on, and observers hear about it")
    func restoreBringsBackWhatWasOn() async throws {
        let bot = TeammateID(UUID()), other = TeammateID(UUID())
        let repository = WebSwitchRepositoryDouble(stored: .init(app: [.webSearch], bots: [bot: [.webFetch]]))
        let store = AgenticJobAccessStore(reportWriteFailure: { _ in })
        let changes = await store.changes()
        await store.restore(from: repository)
        let access = await store.current(teammateID: bot)
        #expect(access.webSearch == AgenticCapabilitySwitch(appEnabled: true, botEnabled: false, appRevision: 1, botRevision: 0))
        #expect(access.webFetch == AgenticCapabilitySwitch(appEnabled: false, botEnabled: true, appRevision: 0, botRevision: 1))
        #expect(access.jobs == .off, "the jobs switch is session-local and is never restored")
        #expect(access.grantedWebCapabilities.isEmpty, "one restored switch on either side grants nothing, like a live one")
        #expect((await store.current(teammateID: other)).webFetch.botEnabled == false)
        // The observer that subscribed before the restore is woken by it.
        #expect(await changes.first(timeout: .seconds(2)))
        // A live flip of the other half now grants, and revisions continue from the restored one.
        await store.setAppEnabled(true, capability: .web(.fetch))
        let granted = await store.current(teammateID: bot)
        #expect(granted.grantedWebCapabilities == [.fetch])
        #expect(granted.webFetch.appRevision == 1 && granted.webFetch.botRevision == 1)
        await store.waitForPendingWrites()
        #expect(await repository.loads == 1)
        #expect(await repository.writes == [.app(.webFetch, true)], "a restore is a read; only the live flip is written")
    }

    @Test("Every web change is written at once, in order; a no-op and the jobs switch write nothing")
    func everyChangeIsWritten() async throws {
        let bot = TeammateID(UUID())
        let repository = WebSwitchRepositoryDouble()
        let store = AgenticJobAccessStore(reportWriteFailure: { _ in })
        await store.restore(from: repository)
        await store.setAppEnabled(true, capability: .web(.search))
        await store.setBotEnabled(true, capability: .web(.fetch), teammateID: bot)
        await store.setAppEnabled(true, capability: .web(.search))
        await store.setAppEnabled(true)
        await store.setBotEnabled(true, teammateID: bot)
        await store.setAppEnabled(false, capability: .web(.search))
        await store.setBotEnabled(false, capability: .web(.fetch), teammateID: bot)
        await store.waitForPendingWrites()
        #expect(await repository.writes == [
            .app(.webSearch, true), .bot(bot, .webFetch, true), .app(.webSearch, false), .bot(bot, .webFetch, false)
        ])
    }

    @Test("A write the database refuses still moves the live switch, is reported once, and does not block the next write")
    func aRefusedWriteIsReportedAndTheSwitchStillMoves() async throws {
        let bot = TeammateID(UUID())
        let repository = WebSwitchRepositoryDouble()
        let failures = FailureLog()
        let store = AgenticJobAccessStore(reportWriteFailure: { failures.append($0) })
        await store.restore(from: repository)
        await repository.refuseWrites(true)
        await store.setAppEnabled(true, capability: .web(.search))
        await store.waitForPendingWrites()
        #expect((await store.current(teammateID: bot)).webSearch.appEnabled, "the switch the user flipped is on now, saved or not")
        #expect(failures.messages.count == 1)
        #expect(failures.messages.first?.contains("app-wide webSearch on") == true)
        #expect(failures.messages.first?.contains("refused") == true)
        await repository.refuseWrites(false)
        await store.setBotEnabled(true, capability: .web(.fetch), teammateID: bot)
        await store.waitForPendingWrites()
        // The refused write was attempted and never retried; the one after it landed.
        #expect(await repository.attempts == 2)
        #expect(await repository.writes == [.bot(bot, .webFetch, true)])
        #expect(failures.messages.count == 1)
    }

    @Test("A switch moved before the restore keeps its live value and is written through; nothing is written before there is a repository")
    func aSwitchMovedBeforeRestoreWins() async throws {
        let bot = TeammateID(UUID())
        let repository = WebSwitchRepositoryDouble(stored: .init(app: [.webSearch, .webFetch], bots: [bot: [.webSearch]]))
        let store = AgenticJobAccessStore(reportWriteFailure: { _ in })
        await store.setAppEnabled(true, capability: .web(.search))
        await store.setAppEnabled(true, capability: .web(.fetch))
        await store.setAppEnabled(false, capability: .web(.fetch))
        await store.setBotEnabled(true, capability: .web(.search), teammateID: bot)
        await store.setBotEnabled(false, capability: .web(.search), teammateID: bot)
        await store.waitForPendingWrites()
        #expect(await repository.writes.isEmpty)
        await store.restore(from: repository)
        let access = await store.current(teammateID: bot)
        #expect(access.webSearch == AgenticCapabilitySwitch(appEnabled: true, botEnabled: false, appRevision: 1, botRevision: 2))
        #expect(access.webFetch == AgenticCapabilitySwitch(appEnabled: false, botEnabled: false, appRevision: 2, botRevision: 0))
        await store.waitForPendingWrites()
        #expect(Set(await repository.writes) == [.app(.webSearch, true), .app(.webFetch, false), .bot(bot, .webSearch, false)])
    }

    /// Bots that hire bots: a switch pair like the others, off by
    /// default, effective only with both halves on, kept between launches.
    @Test("The hire switches start off, need both halves, come back after a restore, and are written like the others")
    func theHireSwitchIsAPairLikeTheOthers() async throws {
        let bot = TeammateID(UUID()), other = TeammateID(UUID())
        let fresh = AgenticJobAccessStore(reportWriteFailure: { _ in })
        #expect((await fresh.current(teammateID: bot)).hire == .off)
        #expect(!(await fresh.hireGranted(teammateID: bot)))
        await fresh.setAppEnabled(true, capability: .hire)
        #expect(!(await fresh.hireGranted(teammateID: bot)), "the app-wide half alone grants nothing")
        await fresh.setBotEnabled(true, capability: .hire, teammateID: bot)
        #expect(await fresh.hireGranted(teammateID: bot))
        #expect(!(await fresh.hireGranted(teammateID: other)), "a bot's hire grant is its own")
        let before = await fresh.current(teammateID: bot)
        await fresh.setBotEnabled(false, capability: .hire, teammateID: bot)
        let after = await fresh.current(teammateID: bot)
        #expect(before.isOlder(than: after), "a hire switch moved makes the earlier reading older")
        #expect(!(await fresh.hireGranted(teammateID: bot)))
        #expect(after.work == .off && after.webSearch == .off && after.webFetch == .off, "hiring turns on nothing else")

        let repository = WebSwitchRepositoryDouble(stored: .init(app: [.hire], bots: [bot: [.hire]]))
        let restored = AgenticJobAccessStore(reportWriteFailure: { _ in })
        await restored.restore(from: repository)
        #expect((await restored.current(teammateID: bot)).hire
            == AgenticCapabilitySwitch(appEnabled: true, botEnabled: true, appRevision: 1, botRevision: 1))
        #expect(await restored.hireGranted(teammateID: bot))
        await restored.setAppEnabled(false, capability: .hire)
        await restored.setBotEnabled(true, capability: .hire, teammateID: other)
        await restored.waitForPendingWrites()
        #expect(await repository.writes == [.app(.hire, false), .bot(other, .hire, true)])
    }

    @Test("A restore the database refuses leaves every web switch off, says so, and later changes are still written")
    func aRefusedRestoreStartsOffAndKeepsWriting() async throws {
        let bot = TeammateID(UUID())
        let repository = WebSwitchRepositoryDouble(stored: .init(app: [.webSearch]), refusesLoad: true)
        let failures = FailureLog()
        let store = AgenticJobAccessStore(reportWriteFailure: { failures.append($0) })
        await store.restore(from: repository)
        let access = await store.current(teammateID: bot)
        #expect(access.webSearch == .off && access.webFetch == .off)
        #expect(failures.messages.count == 1)
        #expect(failures.messages.first?.contains("restore failed") == true)
        await store.setBotEnabled(true, capability: .web(.search), teammateID: bot)
        await store.waitForPendingWrites()
        #expect(await repository.writes == [.bot(bot, .webSearch, true)])
    }
}

private enum WebSwitchRefusal: Error { case refused }

private actor WebSwitchRepositoryDouble: AgenticWebSwitchRepository {
    enum Write: Hashable {
        case app(AgenticWebSwitchCapability, Bool)
        case bot(TeammateID, AgenticWebSwitchCapability, Bool)
    }
    private let stored: AgenticWebSwitchSnapshot
    private let refusesLoad: Bool
    private var refusesWrites = false
    private(set) var writes: [Write] = []
    private(set) var attempts = 0
    private(set) var loads = 0

    init(stored: AgenticWebSwitchSnapshot = .init(), refusesLoad: Bool = false) {
        self.stored = stored
        self.refusesLoad = refusesLoad
    }

    func refuseWrites(_ refuses: Bool) { refusesWrites = refuses }

    func loadWebSwitches() async throws -> AgenticWebSwitchSnapshot {
        loads += 1
        guard !refusesLoad else { throw WebSwitchRefusal.refused }
        return stored
    }

    func setAppWebSwitch(_ capability: AgenticWebSwitchCapability, enabled: Bool) async throws {
        attempts += 1
        guard !refusesWrites else { throw WebSwitchRefusal.refused }
        writes.append(.app(capability, enabled))
    }

    func setBotWebSwitch(_ capability: AgenticWebSwitchCapability, enabled: Bool, teammateID: TeammateID) async throws {
        attempts += 1
        guard !refusesWrites else { throw WebSwitchRefusal.refused }
        writes.append(.bot(teammateID, capability, enabled))
    }
}

private final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var messages: [String] { lock.withLock { lines } }
    func append(_ line: String) { lock.withLock { lines.append(line) } }
}

private extension AsyncStream where Element == Void {
    /// True when one element arrives within `timeout`; the wait is bounded so
    /// a store that never notifies fails the test instead of hanging it.
    func first(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in self { return true }; return false }
            group.addTask { try? await Task.sleep(for: timeout); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
