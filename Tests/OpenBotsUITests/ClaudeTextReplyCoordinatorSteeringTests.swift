import Foundation
import OpenBotsDomain
import OpenBotsServices
@testable import OpenBotsUI
import Testing

/// A live bug: with a
/// Messages card waiting the user corrected New Bot once and it landed; the second
/// correction, typed while the corrected turn was up with its own card, was
/// refused with "This bot already has an active or unresolved reply", and no
/// Stop was offered while that run was still alive.
@MainActor
@Suite("Corrections while a card waits")
struct ClaudeTextReplyCoordinatorSteeringTests {
    @Test("A second correction stops the corrected turn, starts only once it has settled, and Stop stays offered throughout")
    func aSecondCorrectionSupersedesTheCorrectedTurn() async throws {
        let service = CardHoldingReplyService()
        let coordinator = ClaudeTextReplyCoordinator(service: service, changed: {})
        let conversation = ConversationID(UUID())
        let bot = TeammateID(UUID())

        // What the workspace does for every typed message: reserve, send, finish.
        func type(_ text: String) -> (UUID, Task<ClaudeTextTurnResult, Never>) {
            let id = UUID()
            #expect(coordinator.reserve(conversationID: conversation.rawValue, messageID: id), "\(text) was refused")
            let submission = ClaudeTextTurnSubmission(conversationID: conversation, teammateID: bot,
                                                      userMessageID: MessageID(id), text: text)
            return (id, Task { @MainActor in
                let result = await coordinator.send(submission) { _ in }
                coordinator.finish(conversationID: conversation.rawValue, messageID: id, outcome: result.outcome)
                return result
            })
        }
        func waitUntil(_ step: String, _ condition: () async -> Bool) async {
            for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(5)) }
            if !(await condition()) { Issue.record("timed out: \(step)") }
        }
        var phase: ClaudeTextReplyPhase? { coordinator.phase(for: conversation.rawValue) }

        let (first, _) = type("Send him hello")
        await waitUntil("the first turn waits on its card") { await service.isWaiting(first) }

        let (correction, _) = type("I said good night, not hello")
        #expect(phase == .correcting(team: false))
        await waitUntil("the first turn is stopped") { await service.wasCancelled(first) }
        await service.release(first, .stopped)
        await waitUntil("the correction waits on its own card") { await service.isWaiting(correction) }
        #expect(phase?.isBusy == true)

        let (second, last) = type("And sign it from me")
        #expect(phase == .correcting(team: false))
        await waitUntil("the corrected turn is stopped too") { await service.wasCancelled(correction) }
        #expect(await service.refusedWhileBusy.isEmpty, "the second correction never reaches a bot that is still running")
        #expect(phase?.isBusy == true, "Stop stays offered while the corrected turn settles")

        await service.release(correction, .stopped)
        await waitUntil("the second correction waits on its card") { await service.isWaiting(second) }
        #expect(await service.started == [first, correction, second])
        #expect(await service.corrections == [false, true, true])
        #expect(phase?.isBusy == true)

        await service.release(second, .completed)
        #expect(await last.value.outcome == .completed)
        #expect(phase == .completed)
        #expect(await service.refusedWhileBusy.isEmpty)
    }

    /// A message typed during a turn stops it at once, and
    /// if that message is then refused (its attachment or draft could not be
    /// taken) it never sends. The chat stayed "correcting" for good: every later
    /// message was refused as busy, and nothing announced the chat free again.
    @Test("A correction refused after it stopped the running turn gives the chat back to that turn, whose end frees it")
    func aRefusedCorrectionGivesTheChatBack() async throws {
        let service = CardHoldingReplyService()
        let coordinator = ClaudeTextReplyCoordinator(service: service, changed: {})
        var freed: [UUID] = []
        coordinator.conversationFreed = { freed.append($0) }
        let conversation = ConversationID(UUID())
        let bot = TeammateID(UUID())
        func waitUntil(_ step: String, _ condition: () async -> Bool) async {
            for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(5)) }
            if !(await condition()) { Issue.record("timed out: \(step)") }
        }
        var phase: ClaudeTextReplyPhase? { coordinator.phase(for: conversation.rawValue) }

        let first = UUID()
        #expect(coordinator.reserve(conversationID: conversation.rawValue, messageID: first))
        let running = Task { @MainActor in
            let result = await coordinator.send(ClaudeTextTurnSubmission(conversationID: conversation, teammateID: bot,
                userMessageID: MessageID(first), text: "Send him hello")) { _ in }
            coordinator.finish(conversationID: conversation.rawValue, messageID: first, outcome: result.outcome)
        }
        await waitUntil("the turn waits on its card") { await service.isWaiting(first) }

        // Typed, then refused before it could send.
        let refused = UUID()
        #expect(coordinator.reserve(conversationID: conversation.rawValue, messageID: refused))
        coordinator.abandon(conversationID: conversation.rawValue, messageID: refused)
        await waitUntil("the running turn was stopped") { await service.wasCancelled(first) }
        #expect(phase?.isBusy == true, "the stopped turn is still settling")
        await service.release(first, .stopped)
        await running.value
        #expect(phase == .stopped)
        #expect(freed == [conversation.rawValue])
        // And the chat takes the next message as a fresh turn, not a correction.
        let next = UUID()
        #expect(coordinator.reserve(conversationID: conversation.rawValue, messageID: next))
        #expect(!coordinator.supersedesRunningTurn(conversationID: conversation.rawValue, messageID: next))
    }

    /// The replaced turn can end before its
    /// correction is refused. Handing the chat back to a turn that already
    /// ended left it "stopping" for good.
    @Test("A correction refused after the turn it replaced already ended frees the chat itself")
    func aRefusedCorrectionAfterTheReplacedTurnEnded() async throws {
        let service = CardHoldingReplyService()
        let coordinator = ClaudeTextReplyCoordinator(service: service, changed: {})
        var freed: [UUID] = []
        coordinator.conversationFreed = { freed.append($0) }
        let conversation = ConversationID(UUID())
        let bot = TeammateID(UUID())
        func waitUntil(_ step: String, _ condition: () async -> Bool) async {
            for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(5)) }
            if !(await condition()) { Issue.record("timed out: \(step)") }
        }
        let first = UUID()
        #expect(coordinator.reserve(conversationID: conversation.rawValue, messageID: first))
        let running = Task { @MainActor in
            let result = await coordinator.send(ClaudeTextTurnSubmission(conversationID: conversation, teammateID: bot,
                userMessageID: MessageID(first), text: "Send him hello")) { _ in }
            coordinator.finish(conversationID: conversation.rawValue, messageID: first, outcome: result.outcome)
        }
        await waitUntil("the turn waits on its card") { await service.isWaiting(first) }
        let refused = UUID()
        #expect(coordinator.reserve(conversationID: conversation.rawValue, messageID: refused))
        await waitUntil("the running turn was stopped") { await service.wasCancelled(first) }
        await service.release(first, .stopped)
        await running.value
        // Only now is the correction refused: the turn it replaced is gone.
        coordinator.abandon(conversationID: conversation.rawValue, messageID: refused)
        #expect(coordinator.phase(for: conversation.rawValue)?.isBusy != true)
        #expect(freed == [conversation.rawValue])
        let next = UUID()
        #expect(coordinator.reserve(conversationID: conversation.rawValue, messageID: next))
        #expect(!coordinator.supersedesRunningTurn(conversationID: conversation.rawValue, messageID: next))
    }

    /// Stop, then a message typed while the stopped
    /// turn still winds down and refused before it sends, freed the chat with
    /// that turn still running under it.
    @Test("A correction refused while a stopped turn still winds down leaves the chat busy until that turn has ended")
    func aRefusedCorrectionWaitsForAStoppedTurnStillRunning() async throws {
        let service = CardHoldingReplyService()
        let coordinator = ClaudeTextReplyCoordinator(service: service, changed: {})
        var freed: [UUID] = []
        coordinator.conversationFreed = { freed.append($0) }
        let conversation = ConversationID(UUID())
        let bot = TeammateID(UUID())
        func waitUntil(_ step: String, _ condition: () async -> Bool) async {
            for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(5)) }
            if !(await condition()) { Issue.record("timed out: \(step)") }
        }
        let first = UUID()
        #expect(coordinator.reserve(conversationID: conversation.rawValue, messageID: first))
        let running = Task { @MainActor in
            let result = await coordinator.send(ClaudeTextTurnSubmission(conversationID: conversation, teammateID: bot,
                userMessageID: MessageID(first), text: "Send him hello")) { _ in }
            coordinator.finish(conversationID: conversation.rawValue, messageID: first, outcome: result.outcome)
        }
        await waitUntil("the turn waits on its card") { await service.isWaiting(first) }
        #expect(coordinator.reserve(conversationID: conversation.rawValue, messageID: UUID()))
        coordinator.stop(conversationID: conversation.rawValue)
        let refused = UUID()
        #expect(coordinator.reserve(conversationID: conversation.rawValue, messageID: refused))
        coordinator.abandon(conversationID: conversation.rawValue, messageID: refused)
        #expect(coordinator.phase(for: conversation.rawValue)?.isBusy == true, "the stopped turn is still running")
        #expect(freed.isEmpty)
        await waitUntil("the running turn was stopped") { await service.wasCancelled(first) }
        await service.release(first, .stopped)
        await running.value
        #expect(coordinator.phase(for: conversation.rawValue)?.isBusy != true)
        #expect(freed == [conversation.rawValue])
    }

    /// A handoff leg, a report or a worker's wake
    /// reserved a busy chat the way a typed message does, so it stopped the
    /// turn running there and left its takeover marker behind for good. Only
    /// the person's own message steers; the app's turns wait for a free chat.
    @Test("A turn the app starts takes only a free chat: on a busy one it is refused and the running turn goes on")
    func anAppTurnNeverTakesABusyChat() async throws {
        let service = CardHoldingReplyService()
        let coordinator = ClaudeTextReplyCoordinator(service: service, changed: {})
        let conversation = ConversationID(UUID())
        let bot = TeammateID(UUID())
        func waitUntil(_ step: String, _ condition: () async -> Bool) async {
            for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(5)) }
            if !(await condition()) { Issue.record("timed out: \(step)") }
        }
        let first = UUID()
        #expect(coordinator.reserveIdle(conversationID: conversation.rawValue, messageID: first), "a free chat is taken")
        let running = Task { @MainActor in
            let result = await coordinator.send(ClaudeTextTurnSubmission(conversationID: conversation, teammateID: bot,
                userMessageID: MessageID(first), text: "Send him hello")) { _ in }
            coordinator.finish(conversationID: conversation.rawValue, messageID: first, outcome: result.outcome)
        }
        await waitUntil("the turn waits on its card") { await service.isWaiting(first) }
        #expect(!coordinator.reserveIdle(conversationID: conversation.rawValue, messageID: UUID()))
        #expect(coordinator.holds(conversationID: conversation.rawValue, messageID: first))
        #expect(coordinator.phase(for: conversation.rawValue)?.isBusy == true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!(await service.wasCancelled(first)), "the running turn goes on")
        // The person's own message still steers.
        let typed = UUID()
        #expect(coordinator.reserve(conversationID: conversation.rawValue, messageID: typed))
        #expect(coordinator.supersedesRunningTurn(conversationID: conversation.rawValue, messageID: typed))
        coordinator.abandon(conversationID: conversation.rawValue, messageID: typed)
        await waitUntil("stopped") { await service.wasCancelled(first) }
        await service.release(first, .stopped)
        await running.value
    }

    @Test("Stop reaches the corrected turn, not only the one it replaced")
    func stopReachesTheCorrectedTurn() async throws {
        let service = CardHoldingReplyService()
        let coordinator = ClaudeTextReplyCoordinator(service: service, changed: {})
        let conversation = ConversationID(UUID())
        let bot = TeammateID(UUID())
        func type(_ text: String) -> (UUID, Task<ClaudeTextTurnResult, Never>) {
            let id = UUID()
            #expect(coordinator.reserve(conversationID: conversation.rawValue, messageID: id))
            let submission = ClaudeTextTurnSubmission(conversationID: conversation, teammateID: bot,
                                                      userMessageID: MessageID(id), text: text)
            return (id, Task { @MainActor in
                let result = await coordinator.send(submission) { _ in }
                coordinator.finish(conversationID: conversation.rawValue, messageID: id, outcome: result.outcome)
                return result
            })
        }
        func waitUntil(_ step: String, _ condition: () async -> Bool) async {
            for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(5)) }
            if !(await condition()) { Issue.record("timed out: \(step)") }
        }

        let (first, _) = type("Send him hello")
        await waitUntil("the first turn waits") { await service.isWaiting(first) }
        let (correction, last) = type("I said good night")
        await waitUntil("the first turn is stopped") { await service.wasCancelled(first) }
        await service.release(first, .stopped)
        await waitUntil("the correction waits on its card") { await service.isWaiting(correction) }

        coordinator.stop(conversationID: conversation.rawValue)
        #expect(coordinator.phase(for: conversation.rawValue) == .stopping)
        await waitUntil("Stop reaches the corrected turn") { await service.wasCancelled(correction) }
        await service.release(correction, .stopped)
        #expect(await last.value.outcome == .stopped)
        #expect(coordinator.phase(for: conversation.rawValue) == .stopped)
    }

    @Test("Stop pressed while a correction waits for the stopped turn withdraws both, and the conversation comes free")
    func stopWhileACorrectionWaits() async throws {
        let service = CardHoldingReplyService()
        let coordinator = ClaudeTextReplyCoordinator(service: service, changed: {})
        let conversation = ConversationID(UUID())
        let bot = TeammateID(UUID())
        func type(_ text: String) -> (UUID, Task<ClaudeTextTurnResult, Never>) {
            let id = UUID()
            #expect(coordinator.reserve(conversationID: conversation.rawValue, messageID: id))
            let submission = ClaudeTextTurnSubmission(conversationID: conversation, teammateID: bot,
                                                      userMessageID: MessageID(id), text: text)
            return (id, Task { @MainActor in
                let result = await coordinator.send(submission) { _ in }
                coordinator.finish(conversationID: conversation.rawValue, messageID: id, outcome: result.outcome)
                return result
            })
        }
        func waitUntil(_ step: String, _ condition: () async -> Bool) async {
            for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(5)) }
            if !(await condition()) { Issue.record("timed out: \(step)") }
        }

        let (first, firstTask) = type("Send him hello")
        await waitUntil("the first turn waits") { await service.isWaiting(first) }
        let (correction, correctionTask) = type("I said good night")
        await waitUntil("the first turn is stopped") { await service.wasCancelled(first) }
        coordinator.stop(conversationID: conversation.rawValue)
        await service.release(first, .stopped)
        #expect(await correctionTask.value.outcome == .stopped)
        _ = await firstTask.value
        #expect(await service.started == [first], "the withdrawn correction never runs")
        #expect(!(await service.isWaiting(correction)))
        #expect(coordinator.phase(for: conversation.rawValue)?.isBusy != true,
                "Stop ends in a free conversation, not one stuck stopping")
        let (next, nextTask) = type("Start over: send nothing")
        await waitUntil("the next message runs") { await service.isWaiting(next) }
        await service.release(next, .completed)
        #expect(await nextTask.value.outcome == .completed)
    }
}

/// Holds every turn on its card until the test releases it, and does not end
/// a turn on cancellation alone: a Claude Code run parked on a card takes its
/// time to settle after Stop. Like `OfficialClaudeTextReplyService`, it
/// refuses a second turn for the bot while one is still in flight.
private actor CardHoldingReplyService: ClaudeTextReplyServing {
    private var inFlight: UUID?
    private var gates: [UUID: CheckedContinuation<ClaudeTextTurnOutcome, Never>] = [:]
    private var cancelled: Set<UUID> = []
    private(set) var started: [UUID] = []
    private(set) var corrections: [Bool] = []
    private(set) var refusedWhileBusy: [UUID] = []

    func sendText(_ submission: ClaudeTextTurnSubmission,
                  onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        let id = submission.userMessageID.rawValue
        guard inFlight == nil else {
            refusedWhileBusy.append(id)
            return .init(outcome: .failed(.busy))
        }
        inFlight = id
        started.append(id)
        corrections.append(submission.correctsRunningTurn)
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { gates[id] = $0 }
        } onCancel: {
            Task { await self.noteCancellation(id) }
        }
        inFlight = nil
        return .init(outcome: outcome)
    }

    func messageProvenance(conversationID: ConversationID,
                           messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] { [] }

    func isWaiting(_ id: UUID) -> Bool { gates[id] != nil }
    func wasCancelled(_ id: UUID) -> Bool { cancelled.contains(id) }
    func release(_ id: UUID, _ outcome: ClaudeTextTurnOutcome) { gates.removeValue(forKey: id)?.resume(returning: outcome) }
    private func noteCancellation(_ id: UUID) { cancelled.insert(id) }
}
