import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsUI

/// Composed presentation tests only. Services are in-memory, gates ignore
/// cancellation deliberately. Only the source-contract test reads repository
/// source; no window, process, runtime or user content is opened.
@MainActor
@Suite("Workspace shutdown integration")
struct WorkspaceShutdownIntegrationTests {
    @Test("The synchronous workspace boundary refuses send, hiring, profile and selection work")
    func admissionClosesSynchronously() async throws {
        let first = try shutdownWorkspaceChat("Ada")
        let second = try shutdownWorkspaceChat("Mira")
        let service = WorkspaceShutdownChatService(chats: [first, second])
        let profile = WorkspaceShutdownProfileService(first.teammate)
        let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: UnusedShutdownHiringService(), profileService: profile)
        try await model.loadInitialWorkspace()
        model.conversation.composerText = "Unsent before close"
        let rows = model.conversation.messages

        model.beginShutdown()
        model.beginShutdown()
        #expect(model.isShuttingDown && model.conversation.isShuttingDown)
        #expect(!model.conversation.canSend && !model.canEditSelectedProfile)
        model.conversation.sendCurrentText()
        model.beginTeammateCreation()
        model.editSelectedProfile()
        model.sidebar.selection = second.teammate.id.rawValue
        #expect(await model.flushForShutdown())
        await yieldQueuedPresentationTasks()

        #expect(model.hiringModel == nil && model.profileEditor == nil)
        #expect(model.conversation.conversationID == first.id.rawValue)
        #expect(model.conversation.messages == rows)
        #expect(model.conversation.composerText == "Unsent before close")
        let receipt = await service.receipt()
        #expect(receipt.sendCount == 0 && receipt.selectCount == 0 && receipt.clearCount == 0)
        #expect(await profile.saveCount == 0)
        model.finishShutdown()
    }

    @Test("Every already-accepted fixture send settles during grace without streaming its saved reply")
    func acceptedSendsSettleWithoutStartingReplyPresentation() async throws {
        let chat = try shutdownWorkspaceChat("Ada")
        let gate = WorkspaceShutdownGate()
        let service = WorkspaceShutdownChatService(chats: [chat], sendGate: gate)
        let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: UnusedShutdownHiringService())
        try await model.loadInitialWorkspace()
        let ids = [UUID(), UUID()]
        for (index, id) in ids.enumerated() {
            model.conversation.composerText = "Accepted message \(index)"
            model.conversation.sendCurrentText(messageID: id)
        }
        do { try await gate.waitForArrivals(2) }
        catch {
            model.beginShutdown()
            model.finishShutdown()
            await gate.release()
            throw error
        }
        model.beginShutdown()
        let closing = Task { await model.flushForShutdown() }
        await gate.release()
        #expect(await closing.value)

        let receipt = await service.receipt()
        #expect(receipt.sendCount == 2 && receipt.messages.count == 4)
        let savedUserIDs = receipt.messages.filter { $0.author == .user }.map { $0.id.rawValue }
        #expect(Set(savedUserIDs) == Set(ids))
        #expect(model.conversation.messages.count == 2)
        #expect(model.conversation.messages.allSatisfy { ids.contains($0.id) && $0.delivery == .sent })
        #expect(!model.conversation.messageRows.contains { $0.snapshot.streamState == .streaming })
        #expect(!model.conversation.canSend)
        model.finishShutdown()
    }

    @Test("Terminal shutdown fences success, error and partial-reply callbacks from a noncooperative send",
          arguments: WorkspaceShutdownSendOutcome.allCases)
    func lateSendOutcomeCannotPublish(outcome: WorkspaceShutdownSendOutcome) async throws {
        let chat = try shutdownWorkspaceChat("Ada")
        let gate = WorkspaceShutdownGate()
        let service = WorkspaceShutdownChatService(chats: [chat], sendGate: gate, outcome: outcome)
        let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: UnusedShutdownHiringService())
        try await model.loadInitialWorkspace()
        model.conversation.composerText = "Already accepted"
        model.conversation.sendCurrentText()
        do { try await gate.waitForArrivals(1) }
        catch {
            model.beginShutdown()
            model.finishShutdown()
            await gate.release()
            throw error
        }
        model.beginShutdown()
        // Enter the existing-task join before finishing. Awaiting this handle
        // after releasing the fake proves the real workspace continuation ran.
        let probe = WorkspaceShutdownGate()
        let settling = Task {
            // Same-actor signaling adds no suspension before the real join.
            probe.recordArrival()
            return await model.conversation.settleForShutdown()
        }
        do { try await probe.waitForArrivals(1) }
        catch {
            settling.cancel()
            model.finishShutdown()
            await gate.release()
            await probe.release()
            _ = await settling.value
            throw error
        }
        model.finishShutdown()
        let rows = model.conversation.messages
        let sidebar = model.sidebar.rows
        let input = model.conversation.inputAvailability
        await gate.release()
        #expect(!(await settling.value))

        #expect(model.conversation.messages == rows)
        #expect(model.sidebar.rows == sidebar, "A late defer must not publish teammate activity after finish.")
        #expect(model.conversation.inputAvailability == input)
        let receipt = await service.receipt()
        #expect(receipt.sendCount == 1)
        #expect(receipt.messages.count == outcome.savedMessageCount,
                "Cancellation does not undo an already-issued atomic service operation.")
    }

    @Test("Finishing before an accepted task starts prevents its service launch")
    func acceptedButUnstartedTaskIsCancelled() async throws {
        let chat = try shutdownWorkspaceChat("Ada")
        let service = WorkspaceShutdownChatService(chats: [chat])
        let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: UnusedShutdownHiringService())
        try await model.loadInitialWorkspace()
        model.conversation.composerText = "Accepted synchronously, not started"
        model.conversation.sendCurrentText()
        let pending = model.conversation.messages
        model.beginShutdown()
        model.finishShutdown()
        await yieldQueuedPresentationTasks()
        #expect(await service.receipt().sendCount == 0)
        #expect(model.conversation.messages == pending)
        #expect(!(await model.flushForShutdown()))
    }

    @Test("Held profile and hiring editors cannot start new writes after workspace shutdown begins")
    func existingEditorsAlsoLoseAdmission() async throws {
        let chat = try shutdownWorkspaceChat("Existing")
        let profile = WorkspaceShutdownProfileService(chat.teammate)
        let profileWorkspace = DurableWorkspaceModel(mode: .reviewFixture, service: WorkspaceShutdownChatService(chats: [chat]),
            hiringService: UnusedShutdownHiringService(), profileService: profile)
        try await profileWorkspace.loadInitialWorkspace()
        profileWorkspace.editSelectedProfile()
        let editor = try #require(profileWorkspace.profileEditor)
        await editor.load()
        editor.displayName = "Unsubmitted edit"
        profileWorkspace.beginShutdown()
        #expect(await editor.save() == nil)
        #expect(await profile.saveCount == 0)
        profileWorkspace.finishShutdown()

        let candidate = try shutdownWorkspaceChat("Candidate")
        let hiring = try WorkspaceShutdownHiringService(chat: candidate)
        let hiringWorkspace = DurableWorkspaceModel(mode: .reviewFixture, service: WorkspaceShutdownChatService(chats: [chat]), hiringService: hiring)
        try await hiringWorkspace.loadInitialWorkspace()
        hiringWorkspace.beginTeammateCreation()
        let conversation = try #require(hiringWorkspace.hiringModel)
        await conversation.load()
        #expect(conversation.canHire)
        hiringWorkspace.beginShutdown()
        #expect(!conversation.canHire)
        #expect(!(await conversation.confirmHire()))
        #expect(await hiring.confirmCount == 0)
        hiringWorkspace.finishShutdown()
    }

    @Test("An initial roster load cannot populate or start another load after terminal shutdown")
    func lateInitialLoadCannotPopulateWorkspace() async throws {
        let chat = try shutdownWorkspaceChat("Late roster")
        let gate = WorkspaceShutdownGate()
        let service = WorkspaceShutdownChatService(chats: [chat], rosterGate: gate)
        let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: UnusedShutdownHiringService())
        let loading = Task { try await model.loadInitialWorkspace() }
        do { try await gate.waitForArrivals(1) }
        catch {
            loading.cancel()
            model.beginShutdown()
            model.finishShutdown()
            await gate.release()
            _ = await loading.result
            throw error
        }
        model.beginShutdown()
        model.finishShutdown()
        let rows = model.sidebar.rows
        let transcript = model.conversation.messages
        await gate.release()
        do { try await loading.value } catch is CancellationError { }
        #expect(model.sidebar.rows == rows && rows.isEmpty)
        #expect(model.conversation.messages == transcript)
        #expect(model.conversation.conversationID == nil)
        let receipt = await service.receipt()
        #expect(receipt.selectedReads == 0 && receipt.pageReads == 0)
    }

    @Test("Counted arrival timeout releases a suspended child and leaves no test waiter behind")
    func countedArrivalTimeoutCleanup() async throws {
        let gate = WorkspaceShutdownGate()
        let child = Task {
            await gate.suspend()
            try Task.checkCancellation()
        }
        do {
            try await gate.waitForArrivals(1)
            // One child exists; the second arrival can never happen. This
            // tests timeout cleanup without a scheduler-speed assumption.
            await #expect(throws: WorkspaceShutdownTestError.expectedContinuation) {
                try await gate.waitForArrivals(2, timeout: .zero)
            }
        } catch {
            child.cancel()
            await gate.release()
            _ = await child.result
            throw error
        }
        child.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await child.value }
        #expect(gate.waitingChildCount == 0 && gate.arrivalWaiterCount == 0)
    }

    @Test("A finished workspace ignores a previously prepared profile or hiring completion")
    func lateProfileAndHiringCallbacksDoNotReopenWorkspace() async throws {
        let chat = try shutdownWorkspaceChat("Original")
        let candidate = try shutdownWorkspaceChat("New hire")
        let hiring = try WorkspaceShutdownHiringService(chat: candidate)
        let service = WorkspaceShutdownChatService(chats: [chat])
        let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: hiring)
        try await model.loadInitialWorkspace()
        model.beginTeammateCreation()
        let hiringModel = try #require(model.hiringModel)
        await hiringModel.load()
        #expect(await hiringModel.confirmHire())
        var revised = chat.teammate
        revised.profile = try revised.profile.revised(displayName: "Late profile", role: "Research")
        model.beginShutdown()
        model.finishShutdown()
        let rows = model.sidebar.rows
        let selection = model.sidebar.selection
        let title = model.conversation.title
        let transcript = model.conversation.messages
        model.profileDidSave(revised)
        model.completeHiring(from: hiringModel)
        #expect(model.sidebar.rows == rows && model.sidebar.selection == selection)
        #expect(model.conversation.title == title && model.conversation.messages == transcript)
        #expect(model.conversation.isShuttingDown && !model.conversation.canSend)
    }

    @Test("Native close wiring has a finite unconditional termination reply and observes only workspace windows — source only")
    func nativeCloseWiringSourceContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Apps/OpenBotsPreviewApp/OpenBotsPreviewApp.swift"), encoding: .utf8)
        let guardSource = try String(contentsOf: root.appendingPathComponent("Sources/OpenBotsUI/DraftQuitGuard.swift"), encoding: .utf8)
        let delegate = try sourceSection(app, from: "private final class PreviewApplicationDelegate", to: "private struct WorkspaceWindowReporter")
        let scene = try sourceSection(app, from: "var body: some Scene", to: "/// AppKit owns termination")
        let settings = try #require(scene.range(of: "Settings {"))
        let workspaceReporter = try #require(scene.range(of: ".background(WorkspaceWindowReporter"))
        #expect(workspaceReporter.lowerBound < settings.lowerBound)
        #expect(!scene[settings.lowerBound...].contains("WorkspaceWindowReporter"))
        #expect(delegate.contains("forName: NSWindow.willCloseNotification, object: window"))
        let observer = try sourceSection(delegate, from: "func observeWorkspaceWindow", to: "func applicationShouldTerminateAfterLastWindowClosed")
        #expect(observer.contains("object: window, queue: .main"))
        #expect(observer.contains("MainActor.assumeIsolated {"))
        #expect(!observer.contains("Task {"), "The last workspace must freeze admission before another actor turn, even with Settings open.")
        try expectInOrder(observer, ["if self.workspaceWindows.isEmpty {", "self.beginShutdown?()", "NSApplication.shared.terminate(nil)"])
        #expect(delegate.contains("private let draftQuitGuard = DraftQuitGuard()"))
        #expect(delegate.contains("request(begin:") && delegate.contains("flush: saveAvailableState"))
        #expect(delegate.contains("finish: { self.finishShutdown?() }"))
        #expect(delegate.contains("sender.reply(toApplicationShouldTerminate: true)"))
        #expect(!delegate.contains("reply(toApplicationShouldTerminate: false)"))
        #expect(!delegate.contains("NSAlert") && !delegate.contains("runModal"))
        #expect(guardSource.contains("maximumGrace: Duration = .seconds(3)"))
        #expect(guardSource.contains("min(Self.maximumGrace, max(.zero, timeout))"))
        #expect(app.contains("await composition?.saveAvailableStateForShutdown()"))
        #expect(app.contains("composition?.workspace?.finishShutdown()"))
        // These checks inspect composition source only. They do not establish
        // a physical macOS window-close, process-exit or accessibility pass.
    }

    @Test("Startup source fences late recovery, attachment and photo results before another load or UI publication — source only")
    func startupCloseFencesSourceContract() throws {
        let app = try readAppSource()
        let openCheck = try sourceSection(app, from: "private func requireOpen()", to: "func saveAvailableStateForShutdown()")
        #expect(openCheck.contains("guard !isClosing, !Task.isCancelled else { throw CancellationError() }"))
        let startup = try sourceSection(app, from: "func start() async", to: "private func makeAttachmentService")
        try expectInOrder(startup, [
            "let previousCloseNotice = await recovery.begin()", "try requireOpen()", "sessionRecoveryNotice = previousCloseNotice"
        ])
        try expectInOrder(startup, [
            "let attachmentService = await makeAttachmentService(context: context)", "try requireOpen()", "let service = DurableTeammateChatService("
        ])
        try expectInOrder(startup, [
            "let verifiedPhotoRoot = try? await Task.detached", "}.value", "try requireOpen()", "if let photoRoot = verifiedPhotoRoot"
        ])
        #expect(startup.contains("try requireOpen()\n            try await workspace.loadInitialWorkspace("))
        try expectInOrder(startup, [
            "try await workspace.loadInitialWorkspace(",
            "guard !isClosing, !Task.isCancelled else { workspace.beginShutdown(); workspace.finishShutdown(); return }",
            "self.workspace = workspace"
        ])
        #expect(startup.contains("} catch {\n            guard !isClosing, !Task.isCancelled else { return }\n            workspace = nil"),
                "Cancellation/close must not publish the late startup recovery screen.")
        let attachmentFactory = try sourceSection(app, from: "private func makeAttachmentService", to: "func beginTeammateCreation()")
        try expectInOrder(attachmentFactory, ["}.value", "try requireOpen()", "let ingestor = AttachmentIngestor()"])
        // This protects the concrete source ordering, not physical scheduling
        // or a claim that arbitrary synchronous startup work is preemptible.
    }

    @Test("Attachment Reveal rechecks close and withdrawn Work Context callbacks remain disconnected — source only")
    func externalUICallbackFencesSourceContract() throws {
        let app = try readAppSource()
        let attachmentReveal = try sourceSection(app, from: "reveal: { [weak self]", to: "preview: {")
        try expectInOrder(attachmentReveal, [
            "let url = try await attachmentService.revealLocation(", "try self.requireOpen()",
            "NSWorkspace.shared.activateFileViewerSelecting([url])"
        ])
        // These live callback routes were removed with the approved chat-only
        // composition before baseline 5324322. Their old ordering assertion
        // referred to code that no longer existed; the underlying services and
        // their safety tests remain. Do not restore hidden external callbacks.
        #expect(!app.contains("revealer: { [weak self]"))
        #expect(!app.contains("chooseSnapshotDestination: { [weak self]"))
        #expect(!app.contains("createSnapshot: { [weak self]"))
        // No Finder, panel, picker result, bookmark or external write is used
        // by this test. Native race/interaction verification stays separate.
    }

    @Test("Attachment adapter source skips new cleanup after cancellation — source only")
    func cancelledAttachmentCleanupSourceContract() throws {
        let app = try readAppSource()
        let factory = try sourceSection(app, from: "private func makeAttachmentService", to: "func beginTeammateCreation()")
        let importer = try sourceSection(factory, from: "importer: { url, id in", to: "verifier: {")
        try expectInOrder(importer, [
            "let receipt = try await ingestor.ingest(", "try Task.checkCancellation()",
            "let published = try await store.publish(", "try Task.checkCancellation()",
            "try await ingestor.discard(receipt, inside: ingestRoot)"
        ])
        #expect(importer.contains("if !Task.isCancelled { try? await ingestor.discard(receipt, inside: ingestRoot) }"))
        // Already-accepted exact app-owned scratch cleanup may settle within
        // grace; this assertion does not imply rollback of an in-flight commit.
    }

    private func readAppSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Apps/OpenBotsPreviewApp/OpenBotsPreviewApp.swift"), encoding: .utf8)
    }

    private func expectInOrder(_ source: String, _ fragments: [String]) throws {
        var position = source.startIndex
        for fragment in fragments {
            let match = try #require(source.range(of: fragment, range: position..<source.endIndex),
                                     "Missing or out-of-order shutdown fence: \(fragment)")
            position = match.upperBound
        }
    }

    private func sourceSection(_ source: String, from start: String, to end: String) throws -> String {
        let begin = try #require(source.range(of: start))
        let finish = try #require(source.range(of: end, range: begin.upperBound..<source.endIndex))
        return String(source[begin.lowerBound..<finish.lowerBound])
    }

    private func yieldQueuedPresentationTasks() async {
        for _ in 0..<30 { await Task.yield() }
    }

}

enum WorkspaceShutdownSendOutcome: CaseIterable, Equatable, Sendable {
    case success, failure, savedUserOnly
    var savedMessageCount: Int {
        switch self { case .success: 2; case .failure: 0; case .savedUserOnly: 1 }
    }
}

private enum WorkspaceShutdownTestError: Error, Equatable { case unused, expectedContinuation }

/// Main-actor signaling lets the join test mark entry without inserting a
/// scheduling hop between its signal and the actual presentation join.
@MainActor
private final class WorkspaceShutdownGate {
    private var arrivals = 0
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [UUID: (count: Int, continuation: CheckedContinuation<Void, Error>)] = [:]
    var waitingChildCount: Int { waiting.count }
    var arrivalWaiterCount: Int { arrivalWaiters.count }

    func recordArrival() {
        guard !released else { return }
        arrivals += 1
        let completed = arrivalWaiters.filter { $0.value.count <= arrivals }.map(\.key)
        for id in completed { arrivalWaiters.removeValue(forKey: id)?.continuation.resume() }
    }

    func suspend() async {
        recordArrival()
        guard !released else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func waitForArrivals(_ count: Int, timeout: Duration = .seconds(5)) async throws {
        try Task.checkCancellation()
        if arrivals >= count { return }
        guard !released else { throw CancellationError() }
        let id = UUID()
        let timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) }
            catch { return }
            self?.failArrival(id, error: WorkspaceShutdownTestError.expectedContinuation)
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                arrivalWaiters[id] = (count, continuation)
            }
        } onCancel: {
            Task { @MainActor in self.failArrival(id, error: CancellationError()) }
        }
        try Task.checkCancellation()
    }

    func release() async {
        released = true
        let current = waiting
        waiting.removeAll()
        current.forEach { $0.resume() }
        let arrivals = arrivalWaiters.values
        arrivalWaiters.removeAll()
        for waiter in arrivals { waiter.continuation.resume(throwing: CancellationError()) }
    }

    private func failArrival(_ id: UUID, error: any Error) {
        arrivalWaiters.removeValue(forKey: id)?.continuation.resume(throwing: error)
    }
}

private actor WorkspaceShutdownChatService: DurableTeammateChatServing {
    let chats: [DurableDirectChatSnapshot]
    let sendGate: WorkspaceShutdownGate?
    let rosterGate: WorkspaceShutdownGate?
    let outcome: WorkspaceShutdownSendOutcome
    private var sendCount = 0, selectCount = 0, clearCount = 0, selectedReads = 0, pageReads = 0
    private var messages: [Message] = []
    init(chats: [DurableDirectChatSnapshot], sendGate: WorkspaceShutdownGate? = nil,
         rosterGate: WorkspaceShutdownGate? = nil, outcome: WorkspaceShutdownSendOutcome = .success) {
        self.chats = chats; self.sendGate = sendGate; self.rosterGate = rosterGate; self.outcome = outcome
    }
    func activeDirectChats() async throws -> [DurableDirectChatSnapshot] {
        if let rosterGate { await rosterGate.suspend() }
        return chats
    }
    func selectedDirectChat() async throws -> DurableChatSelectionSnapshot? {
        selectedReads += 1
        return chats.first.map { DurableChatSelectionSnapshot(teammate: $0.teammate, conversation: $0.conversation) }
    }
    func select(teammateID: TeammateID, conversationID: ConversationID) async throws { selectCount += 1 }
    func clearSelection() async throws { clearCount += 1 }
    func createTeammateAndDirectChat(_ draft: DurableTeammateDraft) async throws -> DurableTeammateChatCreationSnapshot {
        throw WorkspaceShutdownTestError.unused
    }
    func loadMessages(conversationID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> DurableMessagePageSnapshot {
        pageReads += 1
        return DurableMessagePageSnapshot(conversationID: conversationID, messages: [], hasMore: false, nextBeforeSequence: nil)
    }
    func sendMessageToLocalFixture(conversationID: ConversationID, teammateID: TeammateID,
                                   userMessageID: MessageID, text: String) async throws -> DurableLocalFixtureExchangeSnapshot {
        sendCount += 1
        if let sendGate { await sendGate.suspend() }
        if outcome == .failure { throw WorkspaceShutdownTestError.unused }
        let user = try shutdownWorkspaceMessage(id: userMessageID, conversationID: conversationID,
                                               author: .user, sequence: Int64(messages.count + 1), text: text)
        messages.append(user)
        if outcome == .savedUserOnly { throw DurableTeammateChatError.fixtureReplyUnavailable(userMessage: user) }
        let reply = try shutdownWorkspaceMessage(id: MessageID(UUID()), conversationID: conversationID,
            author: .teammate(teammateID), sequence: user.sequence + 1, text: "Saved local fixture reply; no runtime ran.")
        messages.append(reply)
        return DurableLocalFixtureExchangeSnapshot(userMessage: user, fixtureReply: reply)
    }
    func receipt() -> (sendCount: Int, selectCount: Int, clearCount: Int, selectedReads: Int, pageReads: Int, messages: [Message]) {
        (sendCount, selectCount, clearCount, selectedReads, pageReads, messages)
    }
}

private actor WorkspaceShutdownProfileService: TeammateProfileEditing {
    let teammate: Teammate
    private(set) var saveCount = 0
    init(_ teammate: Teammate) { self.teammate = teammate }
    func loadProfile(teammateID: TeammateID) async throws -> Teammate { teammate }
    func saveProfile(teammateID: TeammateID, expectedRevision: UInt64, draft: TeammateProfileEditDraft) async throws -> Teammate {
        saveCount += 1
        return teammate
    }
}

private actor UnusedShutdownHiringService: HiringConversationServing {
    func loadOrStart() async throws -> HiringConversationSnapshot { throw WorkspaceShutdownTestError.unused }
    func submit(text: String) async throws -> HiringConversationSnapshot { throw WorkspaceShutdownTestError.unused }
    func revise(field: HiringCandidateField, value: String) async throws -> HiringConversationSnapshot { throw WorkspaceShutdownTestError.unused }
    func cancel() async throws { throw WorkspaceShutdownTestError.unused }
    func confirm(appearance: AgentAppearance) async throws -> DurableTeammateChatCreationSnapshot { throw WorkspaceShutdownTestError.unused }
}

private actor WorkspaceShutdownHiringService: HiringConversationServing {
    let snapshot: HiringConversationSnapshot
    let creation: DurableTeammateChatCreationSnapshot
    private(set) var confirmCount = 0
    init(chat: DurableDirectChatSnapshot) throws {
        let date = Date(timeIntervalSince1970: 1000)
        let draft = try HiringDraft(id: HiringDraftID(chat.teammate.id.rawValue), phase: .readyForReview,
            displayName: chat.teammate.profile.displayName, role: "Research", responsibilities: "Research",
            workingStyle: "Clear", skills: "Synthesis", permissionIntent: "None", projectPlacement: "None",
            teamPlacement: "None", revision: 1, createdAt: date, updatedAt: date)
        let turn = try HiringTurn(id: HiringTurnID(UUID()), draftID: draft.id, sequence: 1,
                                 author: .guide, text: "Local fixture", createdAt: date)
        snapshot = HiringConversationSnapshot(persisted: try HiringDraftSnapshot(draft: draft, turns: [turn]), focusedField: nil)
        creation = DurableTeammateChatCreationSnapshot(teammate: chat.teammate, conversation: chat.conversation,
            fixtureGreeting: try shutdownWorkspaceMessage(id: MessageID(UUID()), conversationID: chat.id,
                author: .teammate(chat.teammate.id), sequence: 1, text: "Local hiring fixture"),
            selection: DurableChatSelectionSnapshot(teammate: chat.teammate, conversation: chat.conversation))
    }
    func loadOrStart() async throws -> HiringConversationSnapshot { snapshot }
    func submit(text: String) async throws -> HiringConversationSnapshot { snapshot }
    func revise(field: HiringCandidateField, value: String) async throws -> HiringConversationSnapshot { snapshot }
    func cancel() async throws {}
    func confirm(appearance: AgentAppearance) async throws -> DurableTeammateChatCreationSnapshot {
        confirmCount += 1
        return creation
    }
}

private func shutdownWorkspaceChat(_ name: String) throws -> DurableDirectChatSnapshot {
    let date = Date(timeIntervalSince1970: 1000)
    let teammate = try Teammate(id: TeammateID(UUID()), profile: TeammateProfile(displayName: name, role: "Research"),
        appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 1, silhouette: "sprout",
            paletteToken: "violet", eyeDialect: "bright", nonColorIdentityCue: "leaf ears",
            accessibleIdentityDescription: "Sprout with leaf ears", revision: 1), createdAt: date, updatedAt: date)
    let conversation = try Conversation(id: ConversationID(UUID()), kind: .direct(teammateID: teammate.id),
                                       title: name, createdAt: date, updatedAt: date)
    return DurableDirectChatSnapshot(teammate: teammate, conversation: conversation)
}

private func shutdownWorkspaceMessage(id: MessageID, conversationID: ConversationID, author: MessageAuthor,
                                      sequence: Int64, text: String) throws -> Message {
    let date = Date(timeIntervalSince1970: 1000)
    return try Message(id: id, conversationID: conversationID, sequence: sequence, author: author,
        deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))],
        createdAt: date, updatedAt: date)
}
