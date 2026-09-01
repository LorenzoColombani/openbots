import AppKit
import OpenBotsDomain
import OpenBotsServices
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class RunRecoveryWorkspaceTests: XCTestCase {
    func testConstructionAndContextActivationDoNotReadOrMutate() async {
        let service = RecoveryTestService()
        let model = RunRecoveryWorkspaceModel(service: service)
        model.activateConversation(recoveryUUID(1))
        model.activateConversation(recoveryUUID(1))
        model.activateConversation(nil)
        await model.load()
        await model.startDemo()
        await model.recoverExpiredDemos()
        let calls = await service.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(model.canMutate)
        XCTAssertEqual(model.loadState, .idle)
    }

    func testReadOnlyLoadIsBoundedAndDoesNotAcknowledgeOrRecover() async throws {
        let conversation = recoveryUUID(1)
        let records = try (1...8).map { try recoveryReview(conversation: conversation, run: UInt64($0), state: .interrupted) }
        let service = RecoveryTestService(records: [conversation: records])
        let model = RunRecoveryWorkspaceModel(service: service)
        model.activateConversation(conversation)
        await model.load()
        XCTAssertEqual(model.loadState, .ready)
        XCTAssertEqual(model.reviews.count, 8)
        XCTAssertEqual(model.visibleReviews.count, 5)
        XCTAssertTrue(model.canStartDemo)
        let calls = await service.calls
        XCTAssertEqual(calls, [.load(conversation)])
    }

    func testStartAcknowledgeAndFinishUseExactDisplayedRunRevisions() async throws {
        let conversation = recoveryUUID(2)
        let service = RecoveryTestService()
        let model = RunRecoveryWorkspaceModel(service: service)
        model.activateConversation(conversation)
        await model.load()
        await model.startDemo()
        let started = try XCTUnwrap(model.reviews.first)
        XCTAssertEqual(started.record.state, .running)
        XCTAssertTrue(model.canAcknowledge(started))
        XCTAssertFalse(model.canFinish(started))
        await model.finishDemo(runID: started.id.rawValue)
        await model.acknowledgeDemo(runID: started.id.rawValue)
        let acknowledged = try XCTUnwrap(model.reviews.first)
        XCTAssertTrue(model.canFinish(acknowledged))
        XCTAssertFalse(model.canAcknowledge(acknowledged))
        XCTAssertFalse(model.canFinish(started), "A previously displayed revision cannot authorize a later action")
        await model.finishDemo(runID: acknowledged.id.rawValue)
        XCTAssertEqual(model.reviews.first?.record.state, .succeeded)
        let calls = await service.calls
        XCTAssertEqual(calls, [.load(conversation), .start(conversation),
                               .acknowledge(started.id.rawValue, started.record.revision),
                               .finish(acknowledged.id.rawValue, acknowledged.record.revision)])
    }

    func testAnotherInputsAcknowledgementDoesNotEnableFinishForUnacknowledgedInitialInput() async throws {
        let conversation = recoveryUUID(3)
        let initial = try recoveryReview(conversation: conversation, run: 20)
        let another = RunInputReceipt(runID: initial.id, messageID: MessageID(recoveryUUID(99)), sequence: 2,
                                     state: .acknowledged, updatedAt: initial.record.updatedAt)
        let review = RunRecoveryReview(record: initial.record, inputs: initial.inputs + [another], entries: initial.entries)
        let service = RecoveryTestService(records: [conversation: [review]])
        let model = RunRecoveryWorkspaceModel(service: service)
        model.activateConversation(conversation)
        await model.load()
        XCTAssertFalse(model.canFinish(review))
        await model.finishDemo(runID: review.id.rawValue)
        let calls = await service.calls
        XCTAssertEqual(calls, [.load(conversation)])
    }

    func testExplicitStopUsesStoppingThenInterruptedWithUnknownReceipt() async throws {
        let conversation = recoveryUUID(19)
        let initial = try recoveryReview(conversation: conversation, run: 90)
        let service = RecoveryTestService(records: [conversation: [initial]])
        let model = RunRecoveryWorkspaceModel(service: service)
        model.activateConversation(conversation)
        await model.load()
        await model.requestStopDemo(runID: initial.id.rawValue, expectedRevision: 3)
        let stopping = try XCTUnwrap(model.reviews.first)
        XCTAssertEqual(stopping.record.state, .stopping)
        XCTAssertFalse(model.canRequestStop(stopping))
        XCTAssertFalse(model.canFinish(stopping))
        await model.interruptDemo(runID: stopping.id.rawValue, expectedRevision: stopping.record.revision)
        XCTAssertEqual(model.reviews.first?.record.state, .interrupted)
        XCTAssertEqual(model.reviews.first?.inputs.first?.state, .outcomeUnknown)
        let calls = await service.calls
        XCTAssertEqual(calls, [.load(conversation), .requestStop(initial.id.rawValue, 3), .interrupt(initial.id.rawValue, 4)])
    }

    func testExplicitFailureCanResolveUnclaimedQueuedPartialStart() async throws {
        let conversation = recoveryUUID(20)
        let initial = try recoveryReview(conversation: conversation, run: 91, revision: 1, state: .queued, input: .queued)
        let queued = RunRecoveryReview(record: .init(request: initial.record.request, origin: .localFixture, state: .queued,
                                                    revision: 1, lease: nil, updatedAt: initial.record.updatedAt),
                                      inputs: initial.inputs, entries: initial.entries)
        let service = RecoveryTestService(records: [conversation: [queued]])
        let model = RunRecoveryWorkspaceModel(service: service)
        model.activateConversation(conversation)
        await model.load()
        XCTAssertTrue(model.canFail(queued))
        XCTAssertFalse(model.canInterrupt(queued))
        await model.failDemo(runID: queued.id.rawValue, expectedRevision: 1)
        XCTAssertEqual(model.reviews.first?.record.state, .failed)
        let calls = await service.calls
        XCTAssertEqual(calls, [.load(conversation), .fail(queued.id.rawValue, 1)])
    }

    func testDisplayedRevisionCannotBeReplacedByNewerRowBeforeActionBegins() async throws {
        let conversation = recoveryUUID(16)
        let old = try recoveryReview(conversation: conversation, run: 80, revision: 3)
        let current = recoveryUpdated(old, state: .running, input: .acknowledged, revision: 8)
        let service = RecoveryTestService(records: [conversation: [old]])
        let model = RunRecoveryWorkspaceModel(service: service)
        model.activateConversation(conversation)
        await model.load()
        await service.replace(conversation: conversation, reviews: [current])
        await model.load()
        await model.acknowledgeDemo(runID: old.id.rawValue, expectedRevision: old.record.revision)
        await model.finishDemo(runID: old.id.rawValue, expectedRevision: old.record.revision)
        await model.interruptDemo(runID: old.id.rawValue, expectedRevision: old.record.revision)
        let calls = await service.calls
        XCTAssertEqual(calls, [.load(conversation), .load(conversation)])
        XCTAssertEqual(model.reviews.first, current)
    }

    func testLateLoadDoesNotReplaceNewConversation() async throws {
        let first = recoveryUUID(4), second = recoveryUUID(5)
        let firstReview = try recoveryReview(conversation: first, run: 30)
        let secondReview = try recoveryReview(conversation: second, run: 31)
        let gate = RecoveryTestGate()
        let service = RecoveryTestService(records: [first: [firstReview], second: [secondReview]], gates: [.load(first): gate])
        let model = RunRecoveryWorkspaceModel(service: service)
        model.activateConversation(first)
        let slow = Task { await model.load() }
        try await waitRecoveryGate(gate)
        model.activateConversation(second)
        await model.load()
        await gate.release()
        await slow.value
        XCTAssertEqual(model.conversationID, second)
        XCTAssertEqual(model.reviews, [secondReview])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.needsRefresh)
    }

    func testLateMutationFailureDoesNotShowErrorInOtherConversation() async throws {
        let first = recoveryUUID(6), second = recoveryUUID(7)
        let gate = RecoveryTestGate()
        let service = RecoveryTestService(gates: [.start(first): gate], failures: [.start(first): .privateMessage])
        let model = RunRecoveryWorkspaceModel(service: service)
        model.activateConversation(first)
        await model.load()
        let slow = Task { await model.startDemo() }
        try await waitRecoveryGate(gate)
        model.activateConversation(second)
        await model.load()
        await gate.release()
        await slow.value
        XCTAssertEqual(model.conversationID, second)
        XCTAssertEqual(model.loadState, .ready)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.reviews.isEmpty)
    }

    func testDoubleClickAndLeaveReturnKeepOnePendingMutationThenRequireExplicitRefresh() async throws {
        let conversation = recoveryUUID(8)
        let gate = RecoveryTestGate()
        let service = RecoveryTestService(gates: [.start(conversation): gate])
        let model = RunRecoveryWorkspaceModel(service: service)
        model.activateConversation(conversation)
        await model.load()
        let slow = Task { await model.startDemo() }
        try await waitRecoveryGate(gate)
        await model.startDemo()
        model.activateConversation(recoveryUUID(9))
        model.activateConversation(conversation)
        XCTAssertTrue(model.isBusy)
        await model.load()
        await model.startDemo()
        await gate.release()
        await slow.value
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.needsRefresh)
        XCTAssertTrue(model.reviews.isEmpty, "An old generation must not install its mutation receipt")
        XCTAssertNotNil(model.statusMessage)
        await model.load()
        XCTAssertEqual(model.reviews.count, 1, "The committed demo remains discoverable after explicit reload")
        XCTAssertFalse(model.needsRefresh)
        let calls = await service.calls
        XCTAssertEqual(calls.filter { $0 == .start(conversation) }.count, 1)
    }

    func testStaleRevisionStopsAutomaticRetryAndRefreshAdoptsNewVersion() async throws {
        let conversation = recoveryUUID(10)
        let old = try recoveryReview(conversation: conversation, run: 40, revision: 3)
        let newer = recoveryUpdated(old, state: .running, input: .submitted, revision: 9)
        let service = RecoveryTestService(records: [conversation: [old]],
                                          failures: [.acknowledge(old.id.rawValue, 3): .stale])
        let model = RunRecoveryWorkspaceModel(service: service)
        model.activateConversation(conversation)
        await model.load()
        await model.acknowledgeDemo(runID: old.id.rawValue)
        XCTAssertTrue(model.needsRefresh)
        XCTAssertNotNil(model.errorMessage)
        await model.acknowledgeDemo(runID: old.id.rawValue)
        var calls = await service.calls
        XCTAssertEqual(calls.filter { $0 == .acknowledge(old.id.rawValue, 3) }.count, 1)
        await service.replace(conversation: conversation, reviews: [newer])
        await model.load()
        await model.acknowledgeDemo(runID: old.id.rawValue)
        calls = await service.calls
        XCTAssertTrue(calls.contains(.acknowledge(old.id.rawValue, 9)))
        XCTAssertFalse(model.needsRefresh)
    }

    func testRecoveryMergesOnlyChangedRunsAndKeepsUnknownInputHonest() async throws {
        let conversation = recoveryUUID(11)
        let active = try recoveryReview(conversation: conversation, run: 50)
        let completed = try recoveryReview(conversation: conversation, run: 51, state: .succeeded, input: .acknowledged)
        let recovered = recoveryUpdated(active, state: .interrupted, input: .outcomeUnknown, revision: 8)
        let service = RecoveryTestService(records: [conversation: [active, completed]], recoveries: [conversation: [recovered]])
        let model = RunRecoveryWorkspaceModel(service: service)
        model.activateConversation(conversation)
        await model.load()
        XCTAssertEqual(model.reviews.first(where: { $0.id == active.id })?.record.state, .running)
        await model.recoverExpiredDemos()
        XCTAssertEqual(model.reviews.count, 2)
        XCTAssertTrue(model.reviews.contains(completed))
        XCTAssertEqual(model.reviews.first(where: { $0.id == active.id })?.inputs.first?.state, .outcomeUnknown)
        XCTAssertFalse(model.canAcknowledge(recovered))
        XCTAssertFalse(model.canFinish(recovered))
        XCTAssertTrue(model.statusMessage?.contains("no input was resent") ?? false)
        let calls = await service.calls
        XCTAssertEqual(calls, [.load(conversation), .recover(conversation)])
    }

    func testMissingUserMessageAndPrivateErrorsStayLocalWithoutPayloads() async throws {
        let conversation = recoveryUUID(12)
        let service = RecoveryTestService(failures: [.start(conversation): .needMessage])
        let model = RunRecoveryWorkspaceModel(service: service)
        model.activateConversation(conversation)
        await model.load()
        await model.startDemo()
        XCTAssertTrue(model.errorMessage?.contains("Send a user message") ?? false)
        XCTAssertTrue(model.needsRefresh)
        XCTAssertTrue(model.reviews.isEmpty)
        await service.setFailure(.privateMessage, call: .recover(conversation))
        await model.load()
        await model.recoverExpiredDemos()
        XCTAssertFalse(model.errorMessage?.contains("/Users/") ?? true)
        XCTAssertFalse(model.errorMessage?.contains("private-token") ?? true)
    }

    func testWrongConversationReceiptFailsClosedAndCannotGrantActions() async throws {
        let conversation = recoveryUUID(13)
        let wrong = try recoveryReview(conversation: recoveryUUID(14), run: 60)
        let service = RecoveryTestService(records: [conversation: [wrong]])
        let model = RunRecoveryWorkspaceModel(service: service)
        model.activateConversation(conversation)
        await model.load()
        XCTAssertEqual(model.loadState, .failed)
        XCTAssertTrue(model.reviews.isEmpty)
        XCTAssertFalse(model.canStartDemo)
        XCTAssertFalse(model.canAcknowledge(wrong))
    }

    func testExecutorOriginCannotBePresentedAsLocalDemo() async throws {
        let conversation = recoveryUUID(17)
        let local = try recoveryReview(conversation: conversation, run: 81)
        let executor = RunRecoveryReview(record: .init(request: local.record.request, origin: .executor, state: .running,
                                                      revision: 3, lease: local.record.lease, updatedAt: local.record.updatedAt),
                                         inputs: local.inputs, entries: local.entries)
        let service = RecoveryTestService(records: [conversation: [executor]])
        let model = RunRecoveryWorkspaceModel(service: service)
        model.activateConversation(conversation)
        await model.load()
        XCTAssertEqual(model.loadState, .failed)
        XCTAssertTrue(model.reviews.isEmpty)
        XCTAssertFalse(model.canAcknowledge(executor))
    }

    func testExpiredLeaseAndPartialStartExplainExplicitRecoveryWithoutRetry() async throws {
        let conversation = recoveryUUID(18)
        let review = try recoveryReview(conversation: conversation, run: 82)
        let service = RecoveryTestService(records: [conversation: [review]],
                                          failures: [.acknowledge(review.id.rawValue, 3): .expiredLease])
        let model = RunRecoveryWorkspaceModel(service: service)
        model.activateConversation(conversation)
        await model.load()
        await model.acknowledgeDemo(runID: review.id.rawValue)
        XCTAssertTrue(model.errorMessage?.contains("Refresh") ?? false)
        XCTAssertTrue(model.errorMessage?.contains("Recover Expired Demos") ?? false)
        XCTAssertTrue(model.needsRefresh)
        XCTAssertFalse(model.canMutate)
        await model.recoverExpiredDemos()
        let calls = await service.calls
        XCTAssertEqual(calls, [.load(conversation), .acknowledge(review.id.rawValue, 3)])

        let partialService = RecoveryTestService(failures: [.start(conversation): .partialStart])
        let partial = RunRecoveryWorkspaceModel(service: partialService)
        partial.activateConversation(conversation)
        await partial.load()
        await partial.startDemo()
        let explanation = try XCTUnwrap(partial.errorMessage)
        XCTAssertTrue(explanation.contains("Part of the demo was saved before setup stopped"))
        XCTAssertTrue(explanation.contains("Refresh to see what is available and the next step"))
        XCTAssertTrue(explanation.contains("Nothing will be resent automatically"))
        XCTAssertFalse(explanation.contains("lease"), "Ordinary recovery explains the outcome, not internal ownership metadata.")
        XCTAssertTrue(partial.needsRefresh)
        XCTAssertFalse(partial.canMutate)
        await partial.startDemo()
        let partialCalls = await partialService.calls
        XCTAssertEqual(partialCalls, [.load(conversation), .start(conversation)])
    }

    func testNativeSectionRendersAtInspectorInnerAndWiderWidthsWithoutTriggeringDemoActions() async throws {
        let conversation = recoveryUUID(15)
        let review = try recoveryReview(conversation: conversation, run: 70)
        let service = RecoveryTestService(records: [conversation: [review]])
        for scheme in [ColorScheme.light, .dark] {
            let model = RunRecoveryWorkspaceModel(service: service)
            model.activateConversation(conversation)
            await model.load()
            let controller = NSHostingController(rootView: RunRecoveryWorkspaceView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.background)
                .environment(\.colorScheme, scheme))
            controller.view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            for width: CGFloat in [238, 270, 360, 760] {
                controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 1_000)
                for _ in 0..<4 {
                    controller.view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(5))
                }
                let size = controller.sizeThatFits(in: CGSize(width: width, height: 1_000))
                XCTAssertTrue(size.width.isFinite && size.height.isFinite)
                XCTAssertGreaterThan(size.width, 0)
                XCTAssertGreaterThan(size.height, 0)
                XCTAssertLessThanOrEqual(size.width, width + 0.5)
                XCTAssertLessThanOrEqual(size.height, 1_000)
                try captureRecovery(controller.view, name: "run-history-\(scheme)-\(Int(width))")
            }
        }
        let calls = await service.calls
        XCTAssertTrue(calls.allSatisfy { if case .load = $0 { return true }; return false })
    }

    func testViewSourceUsesExplicitDemoActionsWithoutTokensPayloadOrAutomaticMutation() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/OpenBotsUI/RunRecoveryWorkspaceView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for label in ["Run history", "Start Demo", "Refresh", "Recover Expired Demos", "Record Demo Acknowledgement", "Finish Demo", "Interrupt Demo", "Request Demo Stop", "Finish Demo Stop", "Fail Demo", "Technical details"] {
            XCTAssertTrue(source.contains("\"\(label)\""))
        }
        XCTAssertTrue(source.contains("RunRecoveryWorkspaceModel.disclosure"))
        XCTAssertTrue(source.contains(".task(id: model.conversationID) { await model.load() }"))
        XCTAssertTrue(source.contains("Outcome unknown — not retried"))
        XCTAssertEqual(source.components(separatedBy: "expectedRevision: review.record.revision").count - 1, 6)
        for forbidden in [".token", ".ownerID", ".initialInput.text", "Timer", "Task.detached", "keyboardShortcut(.defaultAction)", "TeammateExecutor"] {
            XCTAssertFalse(source.contains(forbidden))
        }
    }

    private func captureRecovery(_ host: NSView, name: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".build.noindex/shutdown-ui-tests/rendered/run-history", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
}

private enum RecoveryTestCall: Hashable, Sendable {
    case load(UUID), start(UUID), acknowledge(UUID, Int64), finish(UUID, Int64), interrupt(UUID, Int64), recover(UUID)
    case requestStop(UUID, Int64), fail(UUID, Int64)
}

private enum RecoveryTestFailure: Sendable { case stale, needMessage, privateMessage, expiredLease, partialStart }

private actor RecoveryTestService: RunRecoveryFixtureServing {
    private var records: [UUID: [RunRecoveryReview]]
    private let gates: [RecoveryTestCall: RecoveryTestGate]
    private var failures: [RecoveryTestCall: RecoveryTestFailure]
    private let recoveries: [UUID: [RunRecoveryReview]]
    private(set) var calls: [RecoveryTestCall] = []

    init(records: [UUID: [RunRecoveryReview]] = [:], gates: [RecoveryTestCall: RecoveryTestGate] = [:],
         failures: [RecoveryTestCall: RecoveryTestFailure] = [:], recoveries: [UUID: [RunRecoveryReview]] = [:]) {
        self.records = records; self.gates = gates; self.failures = failures; self.recoveries = recoveries
    }
    func reviews(conversationID: ConversationID) async throws -> [RunRecoveryReview] {
        let captured = records[conversationID.rawValue] ?? []
        try await before(.load(conversationID.rawValue))
        return captured
    }
    func startDemo(conversationID: ConversationID) async throws -> RunRecoveryReview {
        try await before(.start(conversationID.rawValue))
        let review = try recoveryReview(conversation: conversationID.rawValue, run: UInt64(100 + calls.count))
        records[conversationID.rawValue, default: []].append(review)
        return review
    }
    func acknowledgeDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview {
        try await before(.acknowledge(runID.rawValue, expectedRevision))
        return try mutate(runID, revision: expectedRevision, state: .running, input: .acknowledged)
    }
    func finishDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview {
        try await before(.finish(runID.rawValue, expectedRevision))
        return try mutate(runID, revision: expectedRevision, state: .succeeded, input: .acknowledged)
    }
    func interruptDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview {
        try await before(.interrupt(runID.rawValue, expectedRevision))
        return try mutate(runID, revision: expectedRevision, state: .interrupted, input: .outcomeUnknown)
    }
    func requestStopDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview {
        try await before(.requestStop(runID.rawValue, expectedRevision))
        return try mutate(runID, revision: expectedRevision, state: .stopping, input: .submitted)
    }
    func failDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview {
        try await before(.fail(runID.rawValue, expectedRevision))
        return try mutate(runID, revision: expectedRevision, state: .failed, input: .outcomeUnknown)
    }
    func recoverExpiredDemos(conversationID: ConversationID) async throws -> [RunRecoveryReview] {
        try await before(.recover(conversationID.rawValue))
        let changed = recoveries[conversationID.rawValue] ?? []
        let ids = Set(changed.map(\.id))
        records[conversationID.rawValue] = changed + (records[conversationID.rawValue] ?? []).filter { !ids.contains($0.id) }
        return changed
    }
    func replace(conversation: UUID, reviews: [RunRecoveryReview]) { records[conversation] = reviews }
    func setFailure(_ failure: RecoveryTestFailure, call: RecoveryTestCall) { failures[call] = failure }
    private func before(_ call: RecoveryTestCall) async throws {
        calls.append(call)
        if let gate = gates[call] { await gate.wait() }
        if let failure = failures[call] {
            switch failure {
            case .stale: throw RunJournalError.staleRevision
            case .needMessage: throw RunRecoveryFixtureError.needUserMessage
            case .privateMessage: throw RecoveryPrivateError()
            case .expiredLease: throw RunJournalError.leaseExpired
            case .partialStart: throw RunRecoveryFixtureError.partialStart(runID: RunID(recoveryUUID(999)))
            }
        }
    }
    private func mutate(_ id: RunID, revision: Int64, state: WorkRunState, input: RunInputState) throws -> RunRecoveryReview {
        guard let old = records.values.flatMap({ $0 }).first(where: { $0.id == id }) else { throw RunJournalError.unavailable }
        guard old.record.revision == revision else { throw RunJournalError.staleRevision }
        let changed = recoveryUpdated(old, state: state, input: input, revision: revision + 1)
        let conversation = old.record.request.conversationID.rawValue
        records[conversation] = (records[conversation] ?? []).map { $0.id == id ? changed : $0 }
        return changed
    }
}

private actor RecoveryTestGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private struct RecoveryPrivateError: LocalizedError {
    var errorDescription: String? { "private-token at /Users/example/private/run.json" }
}

private func waitRecoveryGate(_ gate: RecoveryTestGate) async throws {
    for _ in 0..<500 {
        if await gate.started { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw RecoveryGateTimeout()
}
private struct RecoveryGateTimeout: Error {}

private func recoveryUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "%08llx-AD01-0000-0000-000000000001", value))!
}

private func recoveryReview(conversation: UUID, run: UInt64, revision: Int64 = 3,
                            state: WorkRunState = .running, input: RunInputState = .submitted) throws -> RunRecoveryReview {
    let date = Date(timeIntervalSince1970: 1_788_000_000 + Double(run))
    let messageID = MessageID(recoveryUUID(run + 1_000))
    let request = try WorkRequest(runID: RunID(recoveryUUID(run)), teammateID: TeammateID(recoveryUUID(900)),
                                  conversationID: ConversationID(conversation), initiatingMessageID: messageID,
                                  profileRevision: 1, initialInput: WorkInput(messageID: messageID, sequence: 1, text: "private fixture payload"),
                                  submittedAt: date)
    let lease = RunLease(ownerID: recoveryUUID(901), token: recoveryUUID(902), generation: 1, expiresAt: date.addingTimeInterval(300))
    let record = RunJournalRecord(request: request, origin: .localFixture, state: state, revision: revision, lease: lease, updatedAt: date)
    return RunRecoveryReview(record: record,
                             inputs: [.init(runID: request.runID, messageID: messageID, sequence: 1, state: input, updatedAt: date)],
                             entries: [.init(runID: request.runID, sequence: 1, kind: .enqueued, state: .queued, inputMessageID: messageID, recordedAt: date),
                                       .init(runID: request.runID, sequence: 2, kind: .inputSubmitted, state: state, inputMessageID: messageID, recordedAt: date)])
}

private func recoveryUpdated(_ old: RunRecoveryReview, state: WorkRunState, input: RunInputState, revision: Int64) -> RunRecoveryReview {
    RunRecoveryReview(record: .init(request: old.record.request, origin: old.record.origin, state: state, revision: revision,
                                   lease: old.record.lease, updatedAt: old.record.updatedAt.addingTimeInterval(1)),
                      inputs: old.inputs.map { .init(runID: $0.runID, messageID: $0.messageID, sequence: $0.sequence, state: input, updatedAt: $0.updatedAt) },
                      entries: old.entries)
}
