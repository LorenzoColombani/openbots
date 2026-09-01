import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices

public enum ConversationComposerDraftStatus: Equatable, Sendable {
    case loading, unsaved, saving, saved, waitingForMessage, recovery, conflict, failed

    public var visibleLabel: String {
        switch self {
        case .loading: "Loading saved draft…"
        case .unsaved: "Draft not saved yet"
        case .saving: "Saving draft…"
        case .saved: "Draft saved"
        case .waitingForMessage: "Storing message; newer typing stays here"
        case .recovery: "Earlier message needs recovery"
        case .conflict: "Saved draft changed elsewhere"
        case .failed: "Draft needs attention"
        }
    }
}

/// An issued receipt for one synchronous composer clear. It authorizes no
/// deletion: the captured text remains draft authority until local send wins.
public struct ConversationDraftSubmissionToken: Equatable, Sendable {
    public let messageID: UUID
    public let conversationID: ConversationID
    public let rawText: String
    public let generation: UInt64
    fileprivate let nonce: UUID
}

/// Owns ordinary composer text for one immutable conversation, never card or
/// secret inputs. A debounce is not crash durability; only a save receipt is.
@MainActor
public final class ConversationComposerDraftModel: ObservableObject {
    public let conversationID: ConversationID
    @Published public private(set) var text = ""
    @Published public private(set) var status = ConversationComposerDraftStatus.loading
    @Published public private(set) var notice: String?
    @Published public private(set) var recoverableFailedText: String?
    @Published public private(set) var conflictingSavedText: String?
    @Published public private(set) var isSubmissionInFlight = false
    @Published public private(set) var isShuttingDown = false

    private let service: any ConversationDraftServing
    private let debounce: Duration
    private var editGeneration: UInt64 = 0
    private var persistedText = ""
    private var persistedRevision: UInt64 = 0
    private var hasLoaded = false
    public private(set) var hasConflict = false
    private var hasFailure = false
    private var isWriting = false
    private var activeSubmission: ConversationDraftSubmissionToken?
    private var persistedSubmissionNonce: UUID?
    private var debounceTask: Task<Void, Never>?
    private var loadTask: Task<Bool, Never>?
    private var writeTask: Task<Bool, Never>?
    private var shutdownTask: Task<Bool, Never>?
    private var shutdownFinished = false
    private var shutdownText: String?
    private var shutdownVisibleText: String?
    private var shutdownWriteStarted = false
    private var submissionWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        conversationID: ConversationID,
        service: any ConversationDraftServing,
        debounce: Duration = .milliseconds(250)
    ) {
        self.conversationID = conversationID
        self.service = service
        self.debounce = debounce
    }

    public var hasUnsavedChanges: Bool {
        isSubmissionInFlight || recoverableFailedText != nil || hasConflict || hasFailure
            || !sameBytes(text, persistedText) || (!hasLoaded && editGeneration > 0)
    }

    public var statusText: String { status.visibleLabel }
    public var isLoaded: Bool { hasLoaded }

    public var canBeginSubmission: Bool {
        !isShuttingDown && hasLoaded && !hasFailure && !isSubmissionInFlight && recoverableFailedText == nil && !hasConflict
            && text.utf8.count <= ConversationDraftSnapshot.maximumUTF8ByteCount
    }

    /// Called only for the ordinary composer binding. Equality is byte exact;
    /// synchronizing the already-cleared display does not clear draft authority.
    public func setText(_ value: String) {
        guard !isShuttingDown, !sameBytes(text, value) else { return }
        text = value
        editGeneration &+= 1
        if !hasConflict { hasFailure = false }
        if recoverableFailedText == nil, !hasConflict { notice = nil }
        refreshStatus()
        schedulePersistence()
    }

    public func load() async {
        guard !isShuttingDown, !Task.isCancelled else { return }
        _ = await ensureLoaded()
    }

    /// Freeze available text synchronously. No load, save or conflict resolution
    /// starts until the explicit shutdown flush; repeated calls do not recapture.
    public func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        // An untouched loading display is not an intentional empty draft.
        // Never replace an unknown saved value with that placeholder.
        shutdownText = hasLoaded || editGeneration > 0 ? desiredPersistenceText : nil
        shutdownVisibleText = text
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Joins already-issued local work and performs at most one save of frozen
    /// text. The application owns the finite deadline; this never vetoes Quit.
    public func flushForShutdown() async -> Bool {
        guard isShuttingDown, mayPublishAsyncResult else { return false }
        if let pending = shutdownTask {
            let result = await pending.value
            return mayPublishAsyncResult && result
        }
        let task = Task { [weak self] in
            guard let self, self.mayPublishAsyncResult else { return false }
            return await self.saveShutdownSnapshot()
        }
        shutdownTask = task
        let result = await task.value
        return mayPublishAsyncResult && result
    }

    /// Cancellation fences publication and follow-up work, not an arbitrary
    /// noncooperative service. An already-issued atomic save may still commit;
    /// the app terminates at its deadline and reconciles durable facts on reopen.
    public func finishShutdown() {
        beginShutdown()
        guard !shutdownFinished else { return }
        shutdownFinished = true
        debounceTask?.cancel()
        loadTask?.cancel()
        writeTask?.cancel()
        shutdownTask?.cancel()
        resumeSubmissionWaiters()
    }

    /// Used for ordinary explicit checkpoints. Pending messages, recovery text, or
    /// conflicts are not reported safe just because an older write completed.
    public func flush() async -> Bool {
        guard !isShuttingDown, !Task.isCancelled else { return false }
        debounceTask?.cancel()
        debounceTask = nil
        guard await ensureLoaded(), !isShuttingDown, mayPublishAsyncResult else { return false }
        guard !hasConflict else { return false }
        let stored = await persistLatest()
        return mayPublishAsyncResult && !isShuttingDown && stored && !hasUnsavedChanges
    }

    public func beginSubmission(messageID: UUID, rawText: String, allowsEmptyText: Bool = false) -> ConversationDraftSubmissionToken? {
        guard canBeginSubmission else { return nil }
        guard (allowsEmptyText || !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              rawText.utf8.count <= ConversationDraftSnapshot.maximumUTF8ByteCount else { return nil }
        setText(rawText)
        debounceTask?.cancel()
        debounceTask = nil
        let token = ConversationDraftSubmissionToken(
            messageID: messageID, conversationID: conversationID, rawText: rawText,
            generation: editGeneration, nonce: UUID()
        )
        activeSubmission = token
        persistedSubmissionNonce = nil
        isSubmissionInFlight = true
        // This is presentation only. desiredPersistenceText still returns the
        // captured raw draft, so the sync ConversationModel clear is a no-op.
        text = ""
        refreshStatus()
        return token
    }

    public func persistSubmission(_ token: ConversationDraftSubmissionToken) async -> Bool {
        guard !isShuttingDown, owns(token), await ensureLoaded(), mayPublishAsyncResult,
              owns(token), !hasConflict else { return false }
        let stored = await persistLatest()
        guard mayPublishAsyncResult else { return false }
        let confirmed = stored && owns(token) && sameBytes(persistedText, token.rawText)
        if confirmed { persistedSubmissionNonce = token.nonce }
        return confirmed
    }

    /// Call only after the captured local message is durably stored, before
    /// fixture streaming or runtime work. Newer edits become draft authority.
    public func completeSubmission(_ token: ConversationDraftSubmissionToken) async -> Bool {
        guard mayPublishAsyncResult, owns(token), persistedSubmissionNonce == token.nonce else { return false }
        activeSubmission = nil
        persistedSubmissionNonce = nil
        isSubmissionInFlight = false
        notice = nil
        if isShuttingDown { shutdownText = shutdownVisibleText }
        refreshStatus()
        resumeSubmissionWaiters()
        if isShuttingDown { return await flushForShutdown() }
        return await flush()
    }

    public func failSubmission(_ token: ConversationDraftSubmissionToken) {
        guard !shutdownFinished, owns(token) else { return }
        activeSubmission = nil
        persistedSubmissionNonce = nil
        isSubmissionInFlight = false
        if editGeneration == token.generation, text.isEmpty {
            text = token.rawText
            editGeneration &+= 1
            notice = "The message wasn’t stored. Its draft is restored here."
        } else {
            // Keep the old safety copy authoritative, and newer typing visible
            // but unsaved, until the user explicitly resolves this recovery.
            recoverableFailedText = token.rawText
            notice = "The earlier message wasn’t stored. Its text is kept separately; your newer draft has not replaced it. Recover or copy it before dismissing this notice."
        }
        if isShuttingDown { shutdownText = desiredPersistenceText }
        refreshStatus()
        resumeSubmissionWaiters()
        schedulePersistence()
    }

    /// Never overwrite newer text as a side effect of recovering an older send.
    @discardableResult
    public func restoreFailedText() -> Bool {
        guard !isShuttingDown, text.isEmpty, let recovered = recoverableFailedText, !isSubmissionInFlight else { return false }
        recoverableFailedText = nil
        setText(recovered)
        notice = "The earlier draft is restored here."
        return true
    }

    /// An explicit UI action after the user copied/recovered or chose to discard
    /// the earlier failed text. It never deletes a file or a stored message.
    public func acknowledgeFailedTextRecovery() {
        guard !isShuttingDown, recoverableFailedText != nil, !isSubmissionInFlight else { return }
        recoverableFailedText = nil
        notice = nil
        refreshStatus()
        schedulePersistence()
    }

    /// Conflict resolution is explicit. An in-flight reload cannot overwrite
    /// typing performed after the user requested it.
    public func reloadSavedDraft() async -> Bool {
        guard !isShuttingDown, !Task.isCancelled, hasConflict, !isSubmissionInFlight, recoverableFailedText == nil else { return false }
        let generation = editGeneration
        do {
            let saved = try await service.load(conversationID: conversationID)
            guard !isShuttingDown, mayPublishAsyncResult else { return false }
            guard valid(saved), generation == editGeneration else {
                notice = "Your draft changed while reloading. It remains here; choose again when ready."
                return false
            }
            adoptSavedMetadata(saved)
            text = persistedText
            editGeneration &+= 1
            hasConflict = false
            conflictingSavedText = nil
            hasFailure = false
            notice = nil
            refreshStatus()
            return true
        } catch {
            guard !isShuttingDown, mayPublishAsyncResult else { return false }
            notice = "OpenBots couldn’t reload the saved draft. Your text remains here."
            return false
        }
    }

    /// Reads the competing revision once, then makes one CAS attempt. A second
    /// conflict returns to review; it is never silently retried.
    public func keepThisDraft() async -> Bool {
        guard !isShuttingDown, !Task.isCancelled, hasConflict, !isSubmissionInFlight, recoverableFailedText == nil else { return false }
        do {
            let saved = try await service.load(conversationID: conversationID)
            guard !isShuttingDown, mayPublishAsyncResult else { return false }
            guard valid(saved) else { return false }
            adoptSavedMetadata(saved)
            hasConflict = false
            conflictingSavedText = nil
            hasFailure = false
            notice = nil
            return await persistLatest()
        } catch {
            guard !isShuttingDown, mayPublishAsyncResult else { return false }
            notice = "OpenBots couldn’t review the competing draft. Your text remains here."
            return false
        }
    }

    private var desiredPersistenceText: String {
        activeSubmission?.rawText ?? recoverableFailedText ?? text
    }

    private func owns(_ token: ConversationDraftSubmissionToken) -> Bool {
        token.conversationID == conversationID && activeSubmission?.nonce == token.nonce
    }

    private func schedulePersistence() {
        debounceTask?.cancel()
        guard !isShuttingDown, !hasConflict else { return }
        let delay = debounce
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard let self, !self.isShuttingDown, self.mayPublishAsyncResult else { return }
            _ = await self.ensureLoaded()
            guard !self.isShuttingDown, self.mayPublishAsyncResult else { return }
            _ = await self.persistLatest()
        }
    }

    private func ensureLoaded() async -> Bool {
        guard !isShuttingDown, mayPublishAsyncResult else { return false }
        if hasLoaded { return true }
        if let pending = loadTask {
            let result = await pending.value
            return mayPublishAsyncResult && result
        }
        let generation = editGeneration
        let task = Task { [weak self] in
            guard let self, !self.isShuttingDown, self.mayPublishAsyncResult else { return false }
            do {
                let saved = try await self.service.load(conversationID: self.conversationID)
                guard self.mayPublishAsyncResult else { return false }
                guard self.valid(saved) else {
                    self.failSafely("OpenBots couldn’t verify the saved draft. Your text remains here.")
                    return false
                }
                self.adoptSavedMetadata(saved)
                if self.editGeneration > 0, !self.persistedText.isEmpty,
                   !self.sameBytes(self.desiredPersistenceText, self.persistedText) {
                    self.hasConflict = true
                    self.conflictingSavedText = self.persistedText
                    self.notice = "A saved draft was found after you started typing. Both versions are preserved. Reload it or explicitly keep this draft."
                } else if generation == 0, self.editGeneration == generation, self.activeSubmission == nil {
                    self.text = self.persistedText
                }
                self.hasFailure = false
                self.refreshStatus()
                return true
            } catch {
                guard self.mayPublishAsyncResult else { return false }
                self.failSafely("OpenBots couldn’t load this draft. Your text remains here; try again.")
                return false
            }
        }
        loadTask = task
        let result = await task.value
        guard mayPublishAsyncResult else { return false }
        loadTask = nil
        return result
    }

    private func persistLatest() async -> Bool {
        guard !isShuttingDown, mayPublishAsyncResult, hasLoaded, !hasConflict else { return false }
        if let pending = writeTask {
            let result = await pending.value
            guard !isShuttingDown, mayPublishAsyncResult, result else { return false }
            // A value typed between a completed task and this continuation
            // still needs its own receipt; never call an old success current.
            if sameBytes(desiredPersistenceText, persistedText) { refreshStatus(); return true }
            return await persistLatest()
        }
        let task = Task { [weak self] in
            guard let self, !self.isShuttingDown, self.mayPublishAsyncResult else { return false }
            let result = await self.drainWrites()
            guard self.mayPublishAsyncResult else { return false }
            self.writeTask = nil
            return result
        }
        writeTask = task
        let result = await task.value
        return mayPublishAsyncResult && result
    }

    private func drainWrites() async -> Bool {
        guard !isShuttingDown, mayPublishAsyncResult else { return false }
        if hasFailure { notice = nil }
        hasFailure = false
        while !hasConflict, !isShuttingDown, mayPublishAsyncResult {
            let desired = desiredPersistenceText
            if sameBytes(desired, persistedText) { refreshStatus(); return true }
            guard await writeSnapshot(desired), mayPublishAsyncResult else { return false }
            // An old autosave may settle during grace, but only the explicit
            // shutdown pass may start a successor write after admission closes.
            if isShuttingDown { return sameBytes(desiredPersistenceText, persistedText) }
        }
        guard mayPublishAsyncResult else { return false }
        refreshStatus()
        return false
    }

    private var mayPublishAsyncResult: Bool { !shutdownFinished && !Task.isCancelled }

    private func saveShutdownSnapshot() async -> Bool {
        guard isShuttingDown, mayPublishAsyncResult else { return false }
        if let pending = loadTask {
            _ = await pending.value
            guard mayPublishAsyncResult else { return false }
        }
        if let pending = writeTask {
            _ = await pending.value
            guard mayPublishAsyncResult else { return false }
        }
        guard hasLoaded, !hasConflict, !hasFailure else { return false }
        if let pending = activeSubmission, !sameBytes(pending.rawText, persistedText) {
            guard await writeShutdownSnapshot(pending.rawText), mayPublishAsyncResult else { return false }
        }
        if activeSubmission != nil {
            await withCheckedContinuation { submissionWaiters.append($0) }
            guard mayPublishAsyncResult else { return false }
        }
        guard activeSubmission == nil, recoverableFailedText == nil, !hasConflict, !hasFailure,
              let desired = shutdownText else { return false }
        if !sameBytes(desired, persistedText) {
            guard await writeShutdownSnapshot(desired), mayPublishAsyncResult else { return false }
        }
        refreshStatus()
        return mayPublishAsyncResult && !hasUnsavedChanges
    }

    private func writeShutdownSnapshot(_ desired: String) async -> Bool {
        guard !shutdownWriteStarted, mayPublishAsyncResult else { return false }
        shutdownWriteStarted = true
        return await writeSnapshot(desired)
    }

    private func resumeSubmissionWaiters() {
        let waiting = submissionWaiters
        submissionWaiters = []
        waiting.forEach { $0.resume() }
    }

    /// One exact CAS attempt, shared by normal autosave and the bounded close
    /// pass. A late/cancelled receipt never publishes or schedules a retry.
    private func writeSnapshot(_ desired: String) async -> Bool {
        guard mayPublishAsyncResult else { return false }
        guard desired.utf8.count <= ConversationDraftSnapshot.maximumUTF8ByteCount else {
            failSafely("This draft is too large to save. Keep it below 1 MiB of text; your text remains here.")
            return false
        }
        let expected = persistedRevision
        isWriting = true
        refreshStatus()
        do {
            let saved = try await service.save(conversationID: conversationID, text: desired, expectedRevision: expected)
            guard mayPublishAsyncResult else { return false }
            isWriting = false
            guard valid(saved), expected < UInt64.max, saved.revision == expected + 1,
                  sameBytes(saved.text, desired) else {
                failSafely("OpenBots couldn’t verify the saved draft. Your text remains here.")
                return false
            }
            adoptSavedMetadata(saved)
            refreshStatus()
            return true
        } catch {
            guard mayPublishAsyncResult else { return false }
            isWriting = false
            if case ConversationDraftError.staleRevision = error {
                hasConflict = true
                notice = "This draft changed elsewhere. Reload the saved draft or explicitly keep this draft. Your text has not been replaced."
                refreshStatus()
            } else {
                failSafely("OpenBots couldn’t save this draft. Your text remains here; try again.")
            }
            return false
        }
    }

    private func valid(_ saved: ConversationDraftSnapshot?) -> Bool {
        guard let saved else { return true }
        return saved.conversationID == conversationID && saved.revision > 0
            && saved.text.utf8.count <= ConversationDraftSnapshot.maximumUTF8ByteCount
            && saved.updatedAt.timeIntervalSince1970.isFinite
    }

    private func adoptSavedMetadata(_ saved: ConversationDraftSnapshot?) {
        persistedText = saved?.text ?? ""
        persistedRevision = saved?.revision ?? 0
        hasLoaded = true
    }

    private func failSafely(_ message: String) {
        hasFailure = true
        notice = message
        refreshStatus()
    }

    private func refreshStatus() {
        if hasConflict { status = .conflict }
        else if hasFailure { status = .failed }
        else if recoverableFailedText != nil { status = .recovery }
        else if isSubmissionInFlight { status = .waitingForMessage }
        else if isWriting { status = .saving }
        else if !hasLoaded { status = editGeneration == 0 ? .loading : .unsaved }
        else { status = sameBytes(text, persistedText) ? .saved : .unsaved }
    }

    private func sameBytes(_ first: String, _ second: String) -> Bool {
        first.utf8.elementsEqual(second.utf8)
    }
}
