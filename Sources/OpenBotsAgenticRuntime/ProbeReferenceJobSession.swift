import OpenBotsExecutionRules
import ClaudeRuntimeProbeCore
import Foundation

public enum ProbeReferenceJobError: Error, Equatable, Sendable {
    case closed, invalidContext, limitExceeded, conversationInProgress
    case staleConversation, processGroupConflict, duplicateWorker, invalidControl
    case conversationCleanupFailed
}

/// An in-memory capability issued by one job owner. It cannot be reconstructed
/// from a generation or a provider-supplied session identifier.
public struct ProbeReferenceConversationTicket: Equatable, Sendable {
    public let conversationGeneration: UInt64
    public let sessionID: UUID
    fileprivate let ownerID: UUID
}

/// Data for a fresh conversational handler, not an approval or launch receipt.
/// Checkpoint references are recorded explicitly by the trusted job owner; raw
/// conversation events never add to this collection or resolve its references.
public struct ProbeReferenceConversationContext: Codable, Equatable, Sendable {
    public let originalTask: String
    public let corrections: [String]
    public let checkpointReferences: [String]
    public let conversationGeneration: UInt64
}

public struct ProbeReferenceJobCleanup: Equatable, Sendable {
    public let conversation: ProbeToolSessionCleanup?
    public let workers: [UUID: ProbeToolSessionCleanup]
    public let rejectedStartups: [Int32: ProbeToolSessionCleanup]
    public var allProcessGroupsGone: Bool {
        (conversation?.processGroupGone ?? true) && workers.values.allSatisfy(\.processGroupGone)
            && rejectedStartups.values.allSatisfy(\.processGroupGone)
    }
}

/// Probe-only lifecycle owner. The trusted caller serializes every operation,
/// including callbacks, redirects and Stop; this class is deliberately not
/// Sendable. Launch happens outside the owner. A pending ticket lets Stop or a
/// newer redirect invalidate startup before its already-launched handle arrives.
///
/// All processes use the existing ProbeToolSession implementation. Workers must
/// occupy distinct groups and outlive conversation redirects. There is no retry,
/// provider activation, containment claim or production executor here.
public final class ProbeReferenceJobSession {
    public static let maximumWorkers = 8
    public static let maximumCorrections = 16
    public static let maximumCheckpoints = 16
    public static let maximumConversationAttempts: UInt64 = 32

    public private(set) var conversationGeneration: UInt64 = 0
    private let ownerID = UUID()
    private let originalTask: String
    private var corrections: [String] = []
    private var checkpoints: [String] = []
    private var currentTicket: ProbeReferenceConversationTicket?
    private var conversation: ProbeToolSession?
    private var control: ProbeToolControlSession?
    private var workers: [UUID: ProbeToolSession] = [:]
    private var rejectedStartups: [Int32: ProbeToolSession] = [:]
    private var rejectedStartupCleanup: [Int32: ProbeToolSessionCleanup] = [:]
    private let cleanupSession: (ProbeToolSession) -> ProbeToolSessionCleanup
    private var stopped = false
    private var cleanupFailed = false
    private var cleanup: ProbeReferenceJobCleanup?

    public convenience init(originalTask: String) throws {
        try self.init(originalTask: originalTask, cleanupSession: { $0.stop() })
    }

    // Fault injection for cleanup evidence only; production always delegates
    // to the same ProbeToolSession process implementation.
    init(originalTask: String, cleanupSession: @escaping (ProbeToolSession) -> ProbeToolSessionCleanup) throws {
        guard Self.validText(originalTask, maximumBytes: 8_192) else { throw ProbeReferenceJobError.invalidContext }
        self.originalTask = originalTask
        self.cleanupSession = cleanupSession
    }

    public func beginConversation() throws -> ProbeReferenceConversationTicket {
        try requireOpen()
        guard currentTicket == nil, conversation == nil else { throw ProbeReferenceJobError.conversationInProgress }
        return try issueTicket()
    }

    /// A failed launch retires only its pending ticket. Retained job state can
    /// be used by an explicitly requested later startup; nothing retries here.
    public func replacementFailed(for ticket: ProbeReferenceConversationTicket) throws {
        try requireCurrent(ticket)
        guard conversation == nil else { throw ProbeReferenceJobError.conversationInProgress }
        currentTicket = nil
    }

    public func redirect(correction: String) throws -> ProbeReferenceConversationTicket {
        try requireOpen()
        guard currentTicket != nil else { throw ProbeReferenceJobError.staleConversation }
        guard Self.validText(correction, maximumBytes: 2_048) else { throw ProbeReferenceJobError.invalidContext }
        guard corrections.count < Self.maximumCorrections,
              conversationGeneration < Self.maximumConversationAttempts else { throw ProbeReferenceJobError.limitExceeded }
        currentTicket = nil
        control?.stop()
        control = nil
        corrections.append(correction)
        if let conversation {
            let result = cleanupSession(conversation)
            guard result.processGroupGone else {
                // Retain the uncertain group for whole-job Stop and refuse a
                // replacement; worker ownership is unchanged.
                cleanupFailed = true
                throw ProbeReferenceJobError.conversationCleanupFailed
            }
            self.conversation = nil
        }
        return try issueTicket()
    }

    /// Transfers the handle on success. An unowned handle rejected here is
    /// stopped immediately, including late arrivals after Stop. A handle whose
    /// group is already owned is never stopped by a rejected attachment.
    public func attachConversation(_ transport: ProbeToolSession, for ticket: ProbeReferenceConversationTicket,
                                   control: ProbeToolControlSession? = nil) throws {
        guard !ownsGroup(transport.processGroupID) else { throw ProbeReferenceJobError.processGroupConflict }
        do {
            try requireCurrent(ticket)
            guard conversation == nil else { throw ProbeReferenceJobError.conversationInProgress }
            guard control == nil || control?.sessionID == ticket.sessionID else { throw ProbeReferenceJobError.invalidControl }
            conversation = transport
            self.control = control
        } catch {
            let result = cleanupSession(transport)
            rejectedStartupCleanup[transport.processGroupID] = result
            if !result.processGroupGone {
                rejectedStartups[transport.processGroupID] = transport
            }
            // A previously complete Stop receipt predates this late arrival.
            // The next Stop must include it and retry any unresolved teardown.
            cleanup = nil
            throw error
        }
    }

    /// A rejected registration leaves the new handle with its trusted caller.
    public func registerWorker(id: UUID, session: ProbeToolSession) throws {
        try requireOpen()
        guard workers[id] == nil else { throw ProbeReferenceJobError.duplicateWorker }
        guard workers.count < Self.maximumWorkers else { throw ProbeReferenceJobError.limitExceeded }
        guard !ownsGroup(session.processGroupID) else { throw ProbeReferenceJobError.processGroupConflict }
        workers[id] = session
    }

    public func workerProcessID(for id: UUID) -> Int32? { workers[id]?.processID }
    public func workerProcessGroupID(for id: UUID) -> Int32? { workers[id]?.processGroupID }

    /// Call only after the trusted owner records completed work. This method
    /// stores the reference's original bytes; it neither opens nor trusts files.
    public func recordCheckpoint(_ reference: String) throws {
        try requireOpen()
        guard Self.validText(reference, maximumBytes: 1_024) else { throw ProbeReferenceJobError.invalidContext }
        guard checkpoints.count < Self.maximumCheckpoints else { throw ProbeReferenceJobError.limitExceeded }
        guard !checkpoints.contains(where: { $0.utf8.elementsEqual(reference.utf8) }) else {
            throw ProbeReferenceJobError.invalidContext
        }
        checkpoints.append(reference)
    }

    public func context(for ticket: ProbeReferenceConversationTicket) throws -> ProbeReferenceConversationContext {
        try requireCurrent(ticket)
        return ProbeReferenceConversationContext(originalTask: originalTask, corrections: corrections,
            checkpointReferences: checkpoints, conversationGeneration: ticket.conversationGeneration)
    }

    public func initializeControl(for ticket: ProbeReferenceConversationTicket) throws {
        try withControl(for: ticket) { try $0.initializeAndSend(transport: $1) }
    }

    public func sendInput(id: UUID, text: String, for ticket: ProbeReferenceConversationTicket) throws {
        try withControl(for: ticket) { control, transport in
            do {
                let bytes = try control.inputRecord(id: id, text: text)
                try transport.sendRecord(bytes, timeout: 1)
                try control.markInputWritten(id)
            } catch { control.stop(); throw error }
        }
    }

    public func receive(_ record: Data, for ticket: ProbeReferenceConversationTicket) throws -> ProbeToolControlEvent {
        try withControl(for: ticket) { control, _ in try control.receive(record) }
    }

    public func approveAndSend(_ requestID: String, action: FrozenAction, receipt: ApprovalReceipt,
                               currentPolicyGeneration: UInt64, now: Date,
                               for ticket: ProbeReferenceConversationTicket) throws {
        try withControl(for: ticket) { control, transport in
            try control.approveAndSend(requestID, action: action, receipt: receipt,
                currentPolicyGeneration: currentPolicyGeneration, now: now, transport: transport)
        }
    }

    public func denyAndSend(_ requestID: String, for ticket: ProbeReferenceConversationTicket) throws {
        try withControl(for: ticket) { try $0.denyAndSend(requestID, transport: $1) }
    }

    @discardableResult
    public func stop() -> ProbeReferenceJobCleanup {
        if let cleanup, cleanup.allProcessGroupsGone { return cleanup }
        stopped = true
        currentTicket = nil
        control?.stop()
        control = nil
        let conversationCleanup = conversation.map(cleanupSession)
        var workerCleanup: [UUID: ProbeToolSessionCleanup] = [:]
        for (id, session) in workers { workerCleanup[id] = cleanupSession(session) }
        for (group, session) in rejectedStartups {
            let result = cleanupSession(session)
            rejectedStartupCleanup[group] = result
        }
        rejectedStartups = rejectedStartups.filter { rejectedStartupCleanup[$0.key]?.processGroupGone != true }
        let result = ProbeReferenceJobCleanup(conversation: conversationCleanup, workers: workerCleanup,
            rejectedStartups: rejectedStartupCleanup)
        cleanup = result
        return result
    }

    private func withControl<T>(for ticket: ProbeReferenceConversationTicket,
                                _ body: (inout ProbeToolControlSession, ProbeToolSession) throws -> T) throws -> T {
        try requireCurrent(ticket)
        guard let conversation, var control else { throw ProbeReferenceJobError.invalidControl }
        defer { self.control = control }
        return try body(&control, conversation)
    }

    private func issueTicket() throws -> ProbeReferenceConversationTicket {
        guard conversationGeneration < Self.maximumConversationAttempts else { throw ProbeReferenceJobError.limitExceeded }
        conversationGeneration += 1
        let ticket = ProbeReferenceConversationTicket(conversationGeneration: conversationGeneration,
            sessionID: UUID(), ownerID: ownerID)
        currentTicket = ticket
        return ticket
    }

    private func requireOpen() throws {
        guard !stopped else { throw ProbeReferenceJobError.closed }
        guard !cleanupFailed else { throw ProbeReferenceJobError.conversationCleanupFailed }
    }

    private func requireCurrent(_ ticket: ProbeReferenceConversationTicket) throws {
        try requireOpen()
        guard currentTicket == ticket else { throw ProbeReferenceJobError.staleConversation }
    }

    private func ownsGroup(_ group: Int32) -> Bool {
        conversation?.processGroupID == group || workers.values.contains(where: { $0.processGroupID == group })
            || rejectedStartups[group] != nil
    }

    private static func validText(_ text: String, maximumBytes: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= maximumBytes
            && !text.utf8.contains(0)
    }
}
