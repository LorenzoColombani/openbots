import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices
import SwiftUI

/// A view of the shared switches: the web and work switches the app keeps
/// between launches, and the session-local jobs switch, which it still reads
/// for the retired runner's admission but which nothing on screen sets any
/// more. Observing it never grants access.
@MainActor
public final class AgenticJobAccessModel: ObservableObject {
    @Published public private(set) var appEnabled = false
    @Published public private(set) var botEnabled = false
    @Published public private(set) var isReady = false
    @Published public private(set) var isUpdating = false
    @Published public private(set) var webSearchAppEnabled = false
    @Published public private(set) var webSearchBotEnabled = false
    @Published public private(set) var webFetchAppEnabled = false
    @Published public private(set) var webFetchBotEnabled = false
    @Published public private(set) var workAppEnabled = false
    @Published public private(set) var workBotEnabled = false
    @Published public private(set) var hireAppEnabled = false
    @Published public private(set) var hireBotEnabled = false
    @Published public private(set) var workersAppEnabled = false
    @Published public private(set) var workersBotEnabled = false
    @Published public private(set) var fetchersAppEnabled = false
    @Published public private(set) var fetchersBotEnabled = false
    public private(set) var teammateID: TeammateID?
    /// Effective for the selected bot: the hire master AND its own grant.
    public var hireIsEnabled: Bool { isReady && hireAppEnabled && hireBotEnabled }
    public var workersIsEnabled: Bool { isReady && workersAppEnabled && workersBotEnabled }
    public var fetchersIsEnabled: Bool { isReady && fetchersAppEnabled && fetchersBotEnabled }
    /// Effective for the selected bot: the master switch AND its own grant.
    public var workIsEnabled: Bool { isReady && workAppEnabled && workBotEnabled }
    public var isEnabled: Bool { isReady && appEnabled && botEnabled }
    public var isAvailable: Bool { store != nil }

    public func webAppEnabled(_ capability: AgenticWebCapability) -> Bool {
        capability == .search ? webSearchAppEnabled : webFetchAppEnabled
    }
    public func webBotEnabled(_ capability: AgenticWebCapability) -> Bool {
        capability == .search ? webSearchBotEnabled : webFetchBotEnabled
    }
    /// Effective for the selected bot's next job: its master switch AND its bot
    /// grant, judged per capability; neither web capability implies the other.
    public func webIsEnabled(_ capability: AgenticWebCapability) -> Bool {
        isReady && webAppEnabled(capability) && webBotEnabled(capability)
    }
    var changed: @MainActor () -> Void = {}
    private let store: AgenticJobAccessStore?
    private let globalViewID = TeammateID(UUID())
    private var refreshGeneration: UInt64 = 0
    private var snapshot: AgenticJobAccess?
    private var observation: Task<Void, Never>?

    public init(store: AgenticJobAccessStore?) {
        self.store = store
        guard let store else { return }
        observation = Task { [weak self] in
            let changes = await store.changes()
            await self?.refresh()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    deinit { observation?.cancel() }

    public func selectTeammate(_ id: TeammateID?) {
        LayoutStormCounters.hit("accessModel.selectTeammate")
        guard teammateID != id else { return }
        teammateID = id; botEnabled = false; isReady = false
        webSearchBotEnabled = false; webFetchBotEnabled = false; workBotEnabled = false; hireBotEnabled = false
        workersBotEnabled = false; fetchersBotEnabled = false
        snapshot = nil
        refreshGeneration &+= 1
        changed()
        Task { [weak self] in await self?.refresh() }
    }

    public func refresh() async {
        LayoutStormCounters.hit("accessModel.refresh")
        guard let store else { return }
        let generation = refreshGeneration, id = teammateID
        let access = await store.current(teammateID: id ?? globalViewID)
        guard !Task.isCancelled, generation == refreshGeneration, teammateID == id else { return }
        if let snapshot, access.isOlder(than: snapshot) { return }
        snapshot = access
        appEnabled = access.appEnabled; botEnabled = id == nil ? false : access.botEnabled
        webSearchAppEnabled = access.webSearch.appEnabled; webFetchAppEnabled = access.webFetch.appEnabled
        webSearchBotEnabled = id == nil ? false : access.webSearch.botEnabled
        webFetchBotEnabled = id == nil ? false : access.webFetch.botEnabled
        workAppEnabled = access.work.appEnabled
        workBotEnabled = id == nil ? false : access.work.botEnabled
        hireAppEnabled = access.hire.appEnabled
        hireBotEnabled = id == nil ? false : access.hire.botEnabled
        workersAppEnabled = access.workers.appEnabled
        workersBotEnabled = id == nil ? false : access.workers.botEnabled
        fetchersAppEnabled = access.fetchers.appEnabled
        fetchersBotEnabled = id == nil ? false : access.fetchers.botEnabled
        isReady = true; changed()
    }

    public func setHireAppEnabled(_ enabled: Bool) async {
        guard let store, !isUpdating else { return }
        isUpdating = true
        await store.setAppEnabled(enabled, capability: .hire)
        await refresh()
        isUpdating = false
    }

    public func setHireBotEnabled(_ enabled: Bool, teammateID expectedID: TeammateID? = nil) async {
        guard let store, let id = teammateID, !isUpdating,
              expectedID == nil || expectedID == id else { return }
        isUpdating = true
        await store.setBotEnabled(enabled, capability: .hire, teammateID: id)
        await refresh()
        isUpdating = false
    }

    public func setWorkersAppEnabled(_ enabled: Bool) async {
        guard let store, !isUpdating else { return }
        isUpdating = true
        await store.setAppEnabled(enabled, capability: .workers)
        await refresh()
        isUpdating = false
    }

    public func setWorkersBotEnabled(_ enabled: Bool, teammateID expectedID: TeammateID? = nil) async {
        guard let store, let id = teammateID, !isUpdating,
              expectedID == nil || expectedID == id else { return }
        isUpdating = true
        await store.setBotEnabled(enabled, capability: .workers, teammateID: id)
        await refresh()
        isUpdating = false
    }

    public func setFetchersAppEnabled(_ enabled: Bool) async {
        guard let store, !isUpdating else { return }
        isUpdating = true
        await store.setAppEnabled(enabled, capability: .fetchers)
        await refresh()
        isUpdating = false
    }

    public func setFetchersBotEnabled(_ enabled: Bool, teammateID expectedID: TeammateID? = nil) async {
        guard let store, let id = teammateID, !isUpdating,
              expectedID == nil || expectedID == id else { return }
        isUpdating = true
        await store.setBotEnabled(enabled, capability: .fetchers, teammateID: id)
        await refresh()
        isUpdating = false
    }

    public func setWorkAppEnabled(_ enabled: Bool) async {
        guard let store, !isUpdating else { return }
        isUpdating = true
        await store.setAppEnabled(enabled, capability: .work)
        await refresh()
        isUpdating = false
    }

    public func setWorkBotEnabled(_ enabled: Bool, teammateID expectedID: TeammateID? = nil) async {
        guard let store, let id = teammateID, !isUpdating,
              expectedID == nil || expectedID == id else { return }
        isUpdating = true
        await store.setBotEnabled(enabled, capability: .work, teammateID: id)
        await refresh()
        isUpdating = false
    }

    public func setWebAppEnabled(_ enabled: Bool, capability: AgenticWebCapability) async {
        guard let store, !isUpdating else { return }
        isUpdating = true
        await store.setAppEnabled(enabled, capability: .web(capability))
        await refresh()
        isUpdating = false
    }

    public func setWebBotEnabled(_ enabled: Bool, capability: AgenticWebCapability,
                                 teammateID expectedID: TeammateID? = nil) async {
        guard let store, let id = teammateID, !isUpdating,
              expectedID == nil || expectedID == id else { return }
        isUpdating = true
        await store.setBotEnabled(enabled, capability: .web(capability), teammateID: id)
        await refresh()
        isUpdating = false
    }
}

public struct AgenticJobPresentation: Equatable, Sendable {
    public let phase: AgenticJobPhase
    public let text: String
    public let approval: AgenticJobApproval?
    public let isSubmitting: Bool
    public let isDeciding: Bool
    /// What the job did without a card (each web search or page), oldest first.
    public let observations: [String]

    public init(phase: AgenticJobPhase, text: String, approval: AgenticJobApproval?,
                isSubmitting: Bool, isDeciding: Bool, observations: [String] = []) {
        self.phase = phase; self.text = text; self.approval = approval
        self.isSubmitting = isSubmitting; self.isDeciding = isDeciding; self.observations = observations
    }

    public var description: String {
        switch phase {
        case .preparing: "Preparing the sample-folder job…"
        case .working: "Working in the sample folder. Send a message to change direction."
        case .changingDirection: "Reading your correction; keeping completed work."
        case .waitingForApproval: isDeciding ? "Recording your decision…" : "Review this action before it continues."
        case .stopping: "Stopping this job and saving its outcome…"
        case .completed: "Job finished. Its result is saved in the conversation."
        case .stopped: "Job stopped. Saved work remains; nothing restarts automatically."
        case .failed(let explanation): explanation
        }
    }
}

/// UI ownership only. The service owns persistence, process admission and cleanup.
@MainActor
final class AgenticJobCoordinator {
    private struct Entry {
        let teammateID: TeammateID
        var access: AgenticJobAccess?
        var callbackID: UUID
        var progress: AgenticJobProgress?
        var submitting: UUID?
        var deciding: UUID?
        var stopping = false
        var failure: String?
    }
    private let service: any AgenticJobServing
    private let access: AgenticJobAccessStore
    private let changed: @MainActor () -> Void
    private let completed: @MainActor (UUID) -> Void
    private var entries: [UUID: Entry] = [:]
    private var observation: Task<Void, Never>?
    private var stopTasks: [UUID: Task<Void, Never>] = [:]
    private var shutdownTask: Task<Void, Never>?
    private var closing = false

    init(service: any AgenticJobServing, access: AgenticJobAccessStore,
         changed: @escaping @MainActor () -> Void,
         completed: @escaping @MainActor (UUID) -> Void = { _ in }) {
        self.service = service; self.access = access; self.changed = changed; self.completed = completed
        observation = Task { [weak self] in
            let changes = await access.changes()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.revalidateAccess()
            }
        }
    }

    deinit { observation?.cancel() }

    func presentation(for conversationID: UUID?) -> AgenticJobPresentation? {
        guard let id = conversationID, let entry = entries[id] else { return nil }
        let phase: AgenticJobPhase
        if entry.stopping { phase = .stopping }
        else if let failure = entry.failure { phase = .failed(failure) }
        else { phase = entry.progress?.phase ?? .preparing }
        return AgenticJobPresentation(phase: phase, text: entry.progress?.text ?? "",
            approval: entry.stopping || entry.submitting != nil ? nil : entry.progress?.approval,
            isSubmitting: entry.submitting != nil, isDeciding: entry.deciding != nil,
            observations: entry.progress?.observations ?? [])
    }

    func isActive(conversationID: UUID) -> Bool { presentation(for: conversationID)?.phase.isActive == true }

    func reserve(conversationID: UUID, teammateID: TeammateID, messageID: UUID) -> Bool {
        guard !closing else { return false }
        if var entry = entries[conversationID], isActive(conversationID: conversationID) {
            guard entry.teammateID == teammateID, entry.submitting == nil, !entry.stopping,
                  entry.progress?.phase.acceptsCorrections == true else { return false }
            entry.submitting = messageID; entry.deciding = nil
            entries[conversationID] = entry
        } else {
            entries[conversationID] = Entry(teammateID: teammateID, callbackID: messageID, submitting: messageID)
        }
        changed(); return true
    }

    func abandon(conversationID: UUID, messageID: UUID, explanation: String? = nil) {
        guard var entry = entries[conversationID], entry.submitting == messageID else { return }
        entry.submitting = nil
        if let explanation { entry.failure = explanation }
        else if entry.progress == nil { entries[conversationID] = nil; changed(); return }
        entries[conversationID] = entry; changed()
    }

    func submit(_ input: AgenticJobInput) async {
        let id = input.message.conversationID.rawValue, messageID = input.message.id.rawValue
        guard !closing, entries[id]?.submitting == messageID, entries[id]?.stopping != true else { return }
        let current = await access.current(teammateID: input.teammateID)
        guard !closing, entries[id]?.submitting == messageID, entries[id]?.stopping != true else { return }
        guard current.isEnabled, entries[id]?.access.map({ $0 == current }) ?? true else {
            abandon(conversationID: id, messageID: messageID,
                explanation: "Your message was saved. Sample-folder job access changed, so it was not sent to the job.")
            if entries[id]?.progress?.phase.isActive == true { stop(conversationID: id) }
            return
        }
        entries[id]?.access = current
        entries[id]?.callbackID = messageID
        do {
            _ = try await service.submit(input) { [weak self] update in
                await self?.receive(update, callbackID: messageID)
            }
            if entries[id]?.submitting == messageID { entries[id]?.submitting = nil }
            changed()
        } catch {
            guard !closing, entries[id]?.callbackID == messageID else { return }
            abandon(conversationID: id, messageID: messageID,
                explanation: "Your message was saved, but the job could not accept it. Nothing will be resent automatically.")
        }
    }

    private func receive(_ update: AgenticJobProgress, callbackID: UUID) {
        let id = update.conversationID.rawValue
        guard !closing, var entry = entries[id], entry.callbackID == callbackID else { return }
        if let previous = entry.progress {
            guard previous.runID == update.runID,
                  update.conversationGeneration >= previous.conversationGeneration else { return }
        }
        guard !entry.stopping || !update.phase.isActive else { return }
        let wasActive = entry.progress?.phase.isActive ?? true
        entry.progress = update; entry.failure = nil
        if !update.phase.isActive { entry.stopping = false; entry.submitting = nil; entry.deciding = nil }
        entries[id] = entry; changed()
        if wasActive && !update.phase.isActive { completed(id) }
    }

    func decide(_ approval: AgenticJobApproval, allow: Bool, conversationID: UUID) async {
        guard !closing, var entry = entries[conversationID], !entry.stopping,
              entry.submitting == nil, entry.deciding == nil, entry.progress?.approval == approval,
              entry.progress?.phase == .waitingForApproval, approval.expiresAt > Date() else { return }
        entry.deciding = approval.id; entries[conversationID] = entry; changed()
        do { try await service.decide(approval, allow: allow) }
        catch {
            if entries[conversationID]?.deciding == approval.id {
                entries[conversationID]?.failure = "The decision could not be confirmed. The job is stopping; do not repeat the action."
                stop(conversationID: conversationID)
            }
        }
        if entries[conversationID]?.deciding == approval.id { entries[conversationID]?.deciding = nil }
        changed()
    }

    func stop(conversationID: UUID) {
        guard !closing, entries[conversationID] != nil, stopTasks[conversationID] == nil else { return }
        entries[conversationID]?.stopping = true; entries[conversationID]?.deciding = nil
        changed()
        let service = service
        stopTasks[conversationID] = Task { [weak self] in
            await service.stop(conversationID: ConversationID(conversationID))
            guard let self else { return }
            if self.entries[conversationID]?.progress == nil {
                self.entries[conversationID]?.stopping = false
                self.entries[conversationID]?.submitting = nil
                self.entries[conversationID]?.failure = "Stopped before the job started. Any saved messages remain."
            }
            self.stopTasks[conversationID] = nil; self.changed()
        }
    }

    private func revalidateAccess() async {
        let active = entries.filter { $0.value.progress?.phase.isActive == true || $0.value.submitting != nil }
        for (id, entry) in active {
            let current = await access.current(teammateID: entry.teammateID)
            guard !closing else { return }
            if let admitted = entries[id]?.access, current != admitted { stop(conversationID: id) }
        }
    }

    func loadHistory(conversationID: UUID) async {
        guard !closing, entries[conversationID] == nil else { return }
        guard let history = try? await service.history(conversationID: ConversationID(conversationID)),
              let record = history.first, !closing, entries[conversationID] == nil else { return }
        let phase: AgenticJobPhase
        switch record.journal.state {
        case .succeeded: phase = .completed
        case .failed: phase = .failed("The previous job did not complete. Its saved conversation remains.")
        case .interrupted: phase = .stopped
        default: phase = .failed("This saved job has an unresolved outcome. It has not been restarted.")
        }
        entries[conversationID] = Entry(teammateID: record.journal.request.teammateID, callbackID: UUID(),
            progress: AgenticJobProgress(runID: record.id, conversationID: ConversationID(conversationID),
                phase: phase, conversationGeneration: record.state.conversationGeneration))
        changed()
    }

    func beginShutdown() {
        guard !closing else { return }
        closing = true; observation?.cancel()
        let service = service
        shutdownTask = Task { await service.shutdown() }
    }

    func flushForShutdown() async -> Bool {
        beginShutdown()
        await shutdownTask?.value
        for task in stopTasks.values { await task.value }
        return !Task.isCancelled
    }
}

struct AgenticJobStatusView: View {
    @ObservedObject var conversation: ConversationModel
    var body: some View {
        let _ = LayoutStormCounters.hit("jobStatus.body")
        VStack(alignment: .leading, spacing: 8) {
            if let state = conversation.agenticJobPresentation {
                HStack {
                    Text(state.description).font(.callout)
                    Spacer(minLength: 0)
                    if state.phase.isActive {
                        Button("Stop", action: conversation.stopCurrentTextReply)
                            .disabled(state.phase == .stopping)
                            .accessibilityIdentifier("agentic.job.stop")
                            .help("Stop this job and every worker it owns; keep saved work.")
                    }
                }
                if state.phase.isActive && !state.text.isEmpty {
                    ScrollView {
                        Text(state.text).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 96)
                }
                if !state.observations.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Web activity").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        ForEach(Array(state.observations.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption).lineLimit(2).truncationMode(.middle)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Web activity")
                    .accessibilityIdentifier("agentic.job.observations")
                }
                if let approval = state.approval {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(approval.title).font(.headline)
                        ScrollView {
                            Text(approval.detail).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                        // The detail's clamp, on the target too.
                        ApprovalTargetBox(target: "Destination: \(approval.target)")
                        Text("Review expires \(approval.expiresAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Approve") { conversation.decideAgenticJob(approval, allow: true) }
                                .accessibilityIdentifier("agentic.job.approve")
                            Button("Deny") { conversation.decideAgenticJob(approval, allow: false) }
                                .accessibilityIdentifier("agentic.job.deny")
                        }
                        .disabled(state.isDeciding || state.isSubmitting || approval.expiresAt <= Date())
                    }
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Job action approval")
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentic.job.status")
    }
}
