import Foundation

/// The pure dispatch brain (coordination audit, improvement-plan step 2):
/// which queued heads may launch NOW, given who is busy and who is awaiting
/// replies. Extracted from the app so the rules that starved and stalled
/// threads (audit C1/I1/I3) live in TESTED code.
///
/// Rules encoded:
/// - FIFO per thread — only heads are eligible, never a skip.
/// - GLOBAL fairness (audit I3): heads compete by timestamp, not by the
///   accident of thread-name order.
/// - FAN-OUT (audit I1): a relay head needs its TARGET idle — the source
///   being merely "awaiting" other replies does not block it, so consecutive
///   relay heads to distinct idle targets all launch across drain passes.
/// - A PLAIN head needs its own thread idle AND not awaiting (replies land
///   before new work starts — preserves the typed-order feel).
public enum QueueScheduler {
    public struct Head: Equatable {
        public let thread: String
        public let ts: Date
        /// Relay target when the head is "@target question"; nil = plain.
        public let target: String?
        public init(thread: String, ts: Date, target: String?) {
            self.thread = thread; self.ts = ts; self.target = target
        }
    }

    /// Threads whose heads should dispatch in THIS pass, oldest head first.
    /// `busy` = live runs (sources of plain runs + relay targets);
    /// `awaiting` = source → targets still out (fan-out bookkeeping).
    public static func dispatchable(heads: [Head], busy: Set<String>,
                                    awaiting: [String: Set<String>]) -> [String] {
        var taken = busy
        // Targets already being awaited are mid-run (or about to reply) —
        // a second relay to the same target queues behind, FIFO for the target.
        for (_, targets) in awaiting { taken.formUnion(targets) }
        var out: [String] = []
        for head in heads.sorted(by: { $0.ts < $1.ts }) {
            if let target = head.target {
                // Relay: source must not itself be running (its live run may
                // still append directives that belong first), target must be
                // free and not already receiving.
                guard !busy.contains(head.thread), !taken.contains(target),
                      target != head.thread else { continue }
                taken.insert(target)
                out.append(head.thread)
            } else {
                // Plain: thread idle and no replies still inbound.
                guard !taken.contains(head.thread),
                      awaiting[head.thread]?.isEmpty != false else { continue }
                taken.insert(head.thread)
                out.append(head.thread)
            }
        }
        return out
    }
}