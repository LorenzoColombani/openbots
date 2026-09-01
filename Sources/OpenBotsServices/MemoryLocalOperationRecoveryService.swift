import Foundation
import OpenBotsDomain

public enum MemoryLocalOperationRecoveryStatus: Equatable, Sendable {
    case completed, cancelled, unavailable, inProgress
}

/// Status only. Neither commands, memory bodies, filesystem paths nor provider
/// output can enter the startup report.
public struct MemoryLocalOperationRecoveryEntry: Equatable, Sendable {
    public let marker: MemoryLocalCorrectionRecoveryMarker
    public let state: MemoryLocalCorrectionState?
    public let failure: MemoryLocalCorrectionFailure?
}

public struct MemoryLocalOperationRecoveryReport: Equatable, Sendable {
    public let status: MemoryLocalOperationRecoveryStatus
    public let entries: [MemoryLocalOperationRecoveryEntry]
    public let hasMore: Bool

    public var recoveredCount: Int { entries.filter { $0.state == .acknowledged }.count }
    public var hasUnresolvedOperations: Bool {
        status != .completed || hasMore || entries.contains { $0.state != .acknowledged }
    }
    public var needsAttention: Bool { hasUnresolvedOperations }
    public var notice: String? {
        guard needsAttention else { return nil }
        switch status {
        case .unavailable:
            return "Saved local memory updates couldn't be checked. Their records are retained."
        case .cancelled:
            return "Checking saved local memory updates was interrupted. Some updates may still need attention."
        case .inProgress:
            return "Saved local memory updates are still being checked."
        case .completed:
            if entries.contains(where: { $0.state == .committedUnacknowledged }) {
                return "A local memory update is saved, but its chat acknowledgment is still unresolved. Other saved updates may also need attention."
            }
            if hasMore { return "More saved local memory updates still need to be checked. Their records are retained." }
            return "Some saved local memory updates couldn't be completed. Their records are retained."
        }
    }

    public static var unavailable: Self { .init(status: .unavailable, entries: [], hasMore: false) }
}

/// One finite startup pass through exact saved local commands. The concrete
/// correction service has no provider/fallback route and refuses disappeared or
/// changed markers instead of admitting a new command.
public actor MemoryLocalOperationRecoveryService {
    private let repository: any MemoryLocalCorrectionRepository
    private let corrections: MemoryLocalCorrectionService
    private var running = false
    private var completedReport: MemoryLocalOperationRecoveryReport?

    public init(repository: any MemoryLocalCorrectionRepository, corrections: MemoryLocalCorrectionService) {
        self.repository = repository; self.corrections = corrections
    }

    public func recover(limit: Int = 8) async -> MemoryLocalOperationRecoveryReport {
        if let completedReport { return completedReport }
        guard !running else { return .init(status: .inProgress, entries: [], hasMore: false) }
        running = true
        defer { running = false }
        let report = await perform(limit: limit)
        completedReport = report
        return report
    }

    private func perform(limit: Int) async -> MemoryLocalOperationRecoveryReport {
        guard (1...16).contains(limit) else { return .unavailable }
        if Task.isCancelled { return .init(status: .cancelled, entries: [], hasMore: false) }
        let page: MemoryLocalCorrectionRecoveryPage
        do { page = try await repository.recoverableMemoryLocalCorrections(limit: limit) }
        catch is CancellationError { return .init(status: .cancelled, entries: [], hasMore: false) }
        catch { return .unavailable }
        guard page.markers.count <= limit,
              Set(page.markers.map(\.userMessageID)).count == page.markers.count,
              Set(page.markers.map(\.operationID)).count == page.markers.count,
              page.markers.allSatisfy({ ($0.state == .admitted || $0.state == .committedUnacknowledged) && $0.revision > 0 }) else {
            return .unavailable
        }
        var entries: [MemoryLocalOperationRecoveryEntry] = []
        for marker in page.markers {
            if Task.isCancelled { return .init(status: .cancelled, entries: entries, hasMore: true) }
            // The returned service result is not proof of durability. Read back
            // the same row before reporting a recovered acknowledgement.
            _ = await corrections.recoverSavedOperation(marker)
            let record = try? await repository.memoryLocalCorrection(userMessageID: marker.userMessageID)
            guard let record,
                  record.request.userMessageID == marker.userMessageID,
                  record.request.operationID == marker.operationID,
                  record.request.authority.conversationID == marker.conversationID,
                  record.request.authority.teammateID == marker.teammateID else {
                entries.append(.init(marker: marker, state: nil, failure: nil))
                continue
            }
            entries.append(.init(marker: marker, state: record.state, failure: record.failure))
        }
        return .init(status: Task.isCancelled ? .cancelled : .completed, entries: entries, hasMore: page.hasMore)
    }
}
