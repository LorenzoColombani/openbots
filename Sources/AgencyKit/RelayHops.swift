import Foundation

/// How deep a relay chain may go, and what counts as "deep".
///
/// Lives in the kit, not the app, because the rule is subtle enough to have
/// shipped wrong and a comment is not a test. LIVE FAILURE 2026-08-13: Lorenzo
/// asked Riker for a panel ("have Sherlock think of a follow up, but also
/// invoke the right other bots"). Riker fanned out to three teammates,
/// collected the pitches, ran a second round of discussion — and was then
/// BLOCKED from relaying the chosen message to Hermes, the one relay that
/// actually mattered. The budget had been spent on fan-in wakes.
///
/// Three rules, and only the first costs anything:
///  1. A RELAY is a hop. A → B is one; B → C is two.
///  2. Fan-out WIDTH is free. Asking five teammates at once is one hop, not
///     five — sibling directives are all issued at the same depth.
///  3. A fan-in WAKE is free. Resuming an agent so it can read replies it
///     already paid for is the rest of that turn, not a new hop.
public enum RelayHops {
    /// Small enough that a two-agent ping-pong cannot silently burn plan usage,
    /// large enough for a panel that actually deliberates. With wakes charged
    /// (the old behaviour) the effective budget was half this.
    public static let limit = 6

    /// How many teammates one reply may address at once. Depth alone bounds
    /// the CHAIN but not the total number of runs, which grows as
    /// width^depth (review finding I-8) — six wide and six deep is already
    /// generous for a panel, and it makes the worst case finite in practice
    /// rather than only in principle. Overflow is reported, never dropped
    /// silently.
    public static let maxFanOut = 6

    /// Depth stamped on a relay issued by an agent currently at `depth`.
    public static func forRelay(from depth: Int) -> Int { depth + 1 }

    /// Depth stamped on the wake that hands an agent its replies. Unchanged —
    /// see rule 3.
    public static func forWake(at depth: Int) -> Int { depth }

    /// Whether an agent at `depth` may still issue a relay.
    public static func exhausted(at depth: Int) -> Bool { depth >= limit }
}
