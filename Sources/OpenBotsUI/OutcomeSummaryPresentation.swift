import Foundation
import OpenBotsDomain
import SwiftUI

/// A read-only, human-facing projection. It deliberately carries no record IDs,
/// revisions, lease tokens or private input text, and never changes saved state.
struct OutcomeSummaryPresentation: Equatable, Sendable {
    let title: String
    let result: String
    let attention: String?
    let nextStep: String
    let symbol: String

    var plainText: String { [title, result, attention, nextStep].compactMap { $0 }.joined(separator: "\n") }

    static func run(_ review: RunRecoveryReview, now: Date = Date()) -> Self {
        guard review.record.origin == .localFixture else {
            return .init(title: "This record needs another view", result: "This section only summarizes local demonstrations.",
                         attention: "No real work or delivery can be confirmed here.", nextStep: "Return to the conversation for its work status.", symbol: "info.circle")
        }
        let initial = review.inputs.first {
            $0.messageID == review.record.request.initiatingMessageID && $0.sequence == 1
        }
        let uncertain = review.inputs.contains { $0.state == .outcomeUnknown }
        let unconfirmed = review.inputs.contains { $0.state == .submitted }
        let attention: String? = uncertain
            ? "A message outcome is unknown. Nothing will be resent automatically."
            : unconfirmed ? "Your saved message has not been confirmed as received." : nil
        let active = [.queued, .starting, .running, .waitingForUser, .stopping].contains(review.record.state)
        if active, let expiry = review.record.lease?.expiresAt, expiry <= now {
            return .init(title: "This demo needs recovery", result: "Its time window ended before a final result was saved.",
                         attention: attention ?? "No completed work is confirmed.",
                         nextStep: "Choose Refresh, then Recover Expired Demos. Nothing restarts or resends automatically.", symbol: "exclamationmark.triangle")
        }
        switch review.record.state {
        case .queued:
            return .init(title: "Demo setup is incomplete", result: "The request is saved, but the demo is not ready.",
                         attention: attention, nextStep: review.record.lease == nil
                         ? "Choose Fail Demo to close this incomplete demonstration."
                         : "Choose Refresh to check whether setup has finished.", symbol: "clock")
        case .starting:
            return .init(title: "Demo setup is not finished", result: "No completed work is confirmed.",
                         attention: attention, nextStep: "Choose Refresh to check it, or Interrupt Demo to end this demonstration.", symbol: "clock")
        case .running, .waitingForUser:
            let acknowledged = initial?.state == .acknowledged
            return .init(title: acknowledged ? "Message received in demo" : "Demo waiting for confirmation",
                         result: acknowledged ? "Receipt was recorded, but that does not mean the work is finished."
                         : "The demo has no confirmed result yet.",
                         attention: attention,
                         nextStep: acknowledged ? "Choose Finish Demo to record its outcome, or Request Demo Stop."
                         : initial?.state == .submitted
                         ? "Choose Record Demo Acknowledgement before finishing, or Request Demo Stop."
                         : "Choose Refresh to check the message, or Request Demo Stop.", symbol: "text.bubble")
        case .stopping:
            return .init(title: "Demo stop requested", result: "A stop was requested for this local demonstration, not a real process.",
                         attention: attention, nextStep: "Choose Finish Demo Stop to record that it ended without completing the work.", symbol: "pause.circle")
        case .succeeded:
            return .init(title: "Demo marked finished", result: "A finished outcome was saved for the demo. No real work was performed.",
                         attention: attention, nextStep: "You can review this outcome or start another local demo.", symbol: "checkmark.circle")
        case .failed:
            return .init(title: "Demo did not finish", result: "A failure was saved. No successful work is confirmed.",
                         attention: attention, nextStep: "Review what was saved before starting another demo. Nothing restarts automatically.", symbol: "exclamationmark.triangle")
        case .interrupted:
            return .init(title: "Demo stopped before completion", result: "The saved outcome is an interruption, not successful work.",
                         attention: attention ?? (initial?.state == .acknowledged
                         ? "The message was received in the demo, but that is not a completed result." : nil),
                         nextStep: "Review what was saved before starting another demo. Nothing restarts automatically.", symbol: "pause.circle")
        }
    }

    static func proposal(_ record: ActionProposalRecord, isExpired: Bool) -> Self {
        if (record.state == .pending || record.state == .approved) && isExpired {
            return .init(title: "This review has expired", result: "Nothing was executed. This review can no longer authorize a demo approval.",
                         attention: "Its deadline has passed.", nextStep: "Choose Record Expiry or cancel it, then prepare a new proposal if needed.", symbol: "clock.badge.exclamationmark")
        }
        switch record.state {
        case .pending:
            return .init(title: "Ready for your decision", result: "No action has been taken.",
                         attention: "Check the exact target, contents and consequences below.",
                         nextStep: "Approve, deny or cancel this demo proposal.", symbol: "checkmark.shield")
        case .approved:
            return .init(title: "Approval saved — nothing executed", result: "Only your local demo decision was saved. No access was granted.",
                         attention: nil, nextStep: "Choose Cancel Demo Approval if you want to withdraw this decision.", symbol: "checkmark.circle")
        case .denied:
            return .init(title: "Proposal declined", result: "Your decision was saved. The proposed action was not performed.",
                         attention: nil, nextStep: "Prepare a new demo proposal only if you want to reconsider.", symbol: "xmark.circle")
        case .cancelled:
            return .init(title: "Proposal cancelled", result: "This review is closed. Nothing was executed and no access was granted.",
                         attention: nil, nextStep: "Prepare a new proposal if you still need a decision.", symbol: "minus.circle")
        case .expired:
            return .init(title: "Review expiry recorded", result: "This review is closed because its deadline passed. Nothing was executed.",
                         attention: nil, nextStep: "Prepare a new proposal if you still need a decision.", symbol: "clock")
        }
    }
}

/// Keep every approval-relevant byte visible even while technical metadata is
/// collapsed. This projection does not normalize or summarize the frozen text.
struct ApprovalReviewContent: Equatable, Sendable {
    let target: String
    let payload: String
    let consequence: String
    let expiresAt: Date

    init(_ record: ActionProposalRecord) {
        target = record.proposal.target
        payload = record.proposal.payload
        consequence = record.proposal.consequence
        expiresAt = record.proposal.expiresAt
    }
}

struct OutcomeSummaryView: View {
    let summary: OutcomeSummaryPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            Label(summary.title, systemImage: summary.symbol).font(.callout.weight(.semibold))
            Text(summary.result).font(.caption)
            if let attention = summary.attention {
                Text(attention).font(.caption).foregroundStyle(.secondary)
            }
            Text("Next: \(summary.nextStep)").font(.caption)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
