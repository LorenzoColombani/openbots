import XCTest
@testable import AgencyKit

/// Group threads (R3 2026-08-14) — the kit half. The crux is the cursor/delta
/// machinery: members have independent sessions, so "a group chat" is only as
/// real as the deltas are correct. Every rule here traces to a named failure
/// mode from the plan's pressure-test.
final class TeamThreadsTests: XCTestCase {
    private func msg(_ author: String, _ kind: MessageKind, _ text: String) -> ChatMessage {
        ChatMessage(author: author, kind: kind, text: text)
    }

    // MARK: keys

    func testTeamKeyRoundTripAndValidation() {
        XCTAssertEqual(TeamThreads.key(for: "launch"), "#launch")
        XCTAssertEqual(TeamThreads.teamName(fromKey: "#launch"), "launch")
        XCTAssertFalse(TeamThreads.isTeamKey("bruno"), "agent handles are not team keys")
        XCTAssertNil(TeamThreads.teamName(fromKey: "bruno"))
        XCTAssertNil(TeamThreads.teamName(fromKey: "#../evil"), "traversal refused")
        XCTAssertNil(TeamThreads.teamName(fromKey: "#Bad Name"), "spaces refused")
    }

    // MARK: delta content rules

    func testDeltaExcludesOwnAuthoredMessages() {
        let log = [msg("lorenzo", .user, "plan the launch"),
                   msg("bruno", .agent, "my take"),
                   msg("nina", .agent, "nina's take")]
        let d = GroupPrompt.delta(log: log, cursor: 0, member: "bruno")
        XCTAssertEqual(d.included.map(\.author), ["lorenzo", "nina"],
                       "bruno's session already contains bruno's reply")
    }

    func testDeltaExcludesMirroredHandoffLegs() {
        // His call (question round): outcomes only — participants already have
        // the content (asker via parked reply, target via its session), so
        // including legs GUARANTEES duplicates.
        let log = [msg("lorenzo", .user, "go"),
                   msg("bruno", .relayOut, "→ Nina: check this"),
                   msg("nina", .relayIn, "checked"),
                   msg("nina", .agent, "done, posted results")]
        let d = GroupPrompt.delta(log: log, cursor: 0, member: "hermes")
        XCTAssertEqual(d.included.map(\.kind), [.user, .agent],
                       "relay legs never ride a delta")
        XCTAssertEqual(d.upTo, 4, "…but the cursor still advances past them")
    }

    func testDeltaIncludesLorenzoOtherMembersAndSystemNotes() {
        let log = [msg("lorenzo", .user, "q"),
                   msg("system", .system, "⚠️ note"),
                   msg("nina", .agent, "a")]
        let d = GroupPrompt.delta(log: log, cursor: 0, member: "bruno")
        XCTAssertEqual(d.included.count, 3)
    }

    func testDeltaMissingCursorDeliversOnlyLatestMessageAndFlagsJoin() {
        // The no-token-bomb rule: a lost cursor file must never replay the
        // whole history into one prompt.
        let log = (0..<50).map { msg("lorenzo", .user, "m\($0)") }
        let d = GroupPrompt.delta(log: log, cursor: nil, member: "bruno")
        XCTAssertEqual(d.included.map(\.text), ["m49"])
        XCTAssertTrue(d.joinedNow)
        XCTAssertEqual(d.upTo, 50)
    }

    func testDeltaStaleCursorBeyondLengthClampsSafely() {
        // Post-archive: the log restarted but an old cursor survived a race.
        let log = [msg("lorenzo", .user, "fresh start")]
        let d = GroupPrompt.delta(log: log, cursor: 40, member: "bruno")
        XCTAssertEqual(d.included, [], "clamped — no crash, no phantom slice")
        XCTAssertEqual(d.upTo, 1)
    }

    func testDeltaUpToIsLastIncludedIndexNotLiveLogEnd() {
        // The mid-run race: a reply landing AFTER the snapshot must ride the
        // NEXT delta. delta() is called on a snapshot; upTo covers exactly it.
        let snapshot = [msg("lorenzo", .user, "q1")]
        let d = GroupPrompt.delta(log: snapshot, cursor: 0, member: "bruno")
        XCTAssertEqual(d.upTo, 1)
        // nina's reply lands after the snapshot → next delta from 1 carries it.
        let grown = snapshot + [msg("nina", .agent, "landed late"),
                                msg("lorenzo", .user, "q2")]
        let next = GroupPrompt.delta(log: grown, cursor: d.upTo, member: "bruno")
        XCTAssertEqual(next.included.map(\.text), ["landed late", "q2"])
    }

    // MARK: prompt contract

    func testGroupPromptRenderCarriesMarkerMembersAndNewMessage() {
        let team = Team(name: "launch", members: ["bruno", "nina", "hermes"])
        let log = [msg("nina", .agent, "earlier thought"),
                   msg("lorenzo", .user, "ship it?")]
        let d = GroupPrompt.delta(log: log, cursor: 0, member: "bruno")
        let p = GroupPrompt.render(team: team, member: "bruno", delta: d,
                                   display: { $0.capitalized })
        XCTAssertTrue(p.contains("[Group thread #launch"), "the marker personas teach")
        XCTAssertTrue(p.contains("@nina") && p.contains("@hermes"))
        XCTAssertFalse(p.contains("@bruno"), "the member is 'you', not a mention")
        XCTAssertTrue(p.contains("[Nina] earlier thought"), "history labelled by display name")
        XCTAssertTrue(p.contains("[New message from Lorenzo to the group:]\nship it?"),
                      "the newest .user message is split out STRUCTURALLY")
    }

    func testGroupPromptRenderFlagsLateJoiner() {
        let team = Team(name: "launch", members: ["bruno", "nina"])
        let d = GroupPrompt.delta(log: [msg("lorenzo", .user, "hi")], cursor: nil, member: "bruno")
        let p = GroupPrompt.render(team: team, member: "bruno", delta: d, display: { $0 })
        XCTAssertTrue(p.contains("You joined this group thread now"))
    }

    // MARK: cursor store

    func testCursorStoreAdvanceIsMonotonicAndPersists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-tt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentStore(rootURL: root)
        let c = TeamCursorStore(store: store, team: "launch")
        c.advance("bruno", to: 5)
        c.advance("bruno", to: 3)   // stale write
        XCTAssertEqual(c.cursor(for: "bruno"), 5, "a stale write never regresses")
        // Fresh instance = re-read from disk.
        XCTAssertEqual(TeamCursorStore(store: store, team: "launch").cursor(for: "bruno"), 5)
    }

    func testCursorStoreInitializeIsFirstWriteWins() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-tt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let c = TeamCursorStore(store: AgentStore(rootURL: root), team: "t")
        c.initialize(member: "bruno", at: 7)
        c.initialize(member: "bruno", at: 99)   // must not clobber
        XCTAssertEqual(c.cursor(for: "bruno"), 7)
    }

    func testCursorStoreRemoveForgetsOneMember() throws {
        // Review minor: a member removed and later re-added is a LATE JOINER
        // (new-messages-only), never silently back-filled.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-tt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let c = TeamCursorStore(store: AgentStore(rootURL: root), team: "t")
        c.advance("bruno", to: 9)
        c.advance("nina", to: 4)
        c.remove(member: "bruno")
        XCTAssertNil(c.cursor(for: "bruno"))
        XCTAssertEqual(c.cursor(for: "nina"), 4, "only the removed member is forgotten")
    }

    func testCursorStoreResetClearsAllMembers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-tt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let c = TeamCursorStore(store: AgentStore(rootURL: root), team: "t")
        c.advance("bruno", to: 9)
        c.reset()
        XCTAssertNil(c.cursor(for: "bruno"), "archive restarts everyone")
    }
}

/// The dispatch rule: pure, so QueueScheduler stays untouched.
final class GroupDispatchTests: XCTestCase {
    private let team = Team(name: "launch", members: ["bruno", "nina"])

    func testTeamKeyBusyWhileAnyMemberBusyOrForking() {
        XCTAssertTrue(GroupDispatch.effectiveBusy(busy: ["bruno"], forking: [],
                                                  awaiting: [:], teams: [team]).contains("#launch"))
        XCTAssertTrue(GroupDispatch.effectiveBusy(busy: [], forking: ["nina"],
                                                  awaiting: [:], teams: [team]).contains("#launch"))
    }

    func testTeamKeyBusyWhileMemberAwaitedByAnotherThread() {
        // nina is a pending relay target of some other conversation — a group
        // send now would collide with the reply about to land.
        let e = GroupDispatch.effectiveBusy(busy: [], forking: [],
                                            awaiting: ["alfredo": ["nina"]], teams: [team])
        XCTAssertTrue(e.contains("#launch"))
    }

    func testTeamKeyIdleWhenAllMembersIdle() {
        let e = GroupDispatch.effectiveBusy(busy: ["hermes"], forking: [],
                                            awaiting: [:], teams: [team])
        XCTAssertFalse(e.contains("#launch"), "a non-member's business is irrelevant")
    }

    func testSharedMemberSerialisesTwoTeams() {
        let a = Team(name: "a", members: ["bruno", "nina"])
        let b = Team(name: "b", members: ["nina", "hermes"])
        // Team a mid-run: its members are awaited by "#a".
        let e = GroupDispatch.effectiveBusy(busy: ["bruno", "nina"], forking: [],
                                            awaiting: ["#a": ["bruno", "nina"]], teams: [a, b])
        XCTAssertTrue(e.contains("#b"), "nina is shared — team b must wait")
    }

    func testSchedulerHoldsSecondGroupSendBehindAwaiting() {
        // Integration with the UNTOUCHED QueueScheduler: a team head is plain
        // (target nil); a non-empty awaiting["#t"] blocks it, empty releases it.
        let head = QueueScheduler.Head(thread: "#launch", ts: Date(), target: nil)
        let held = QueueScheduler.dispatchable(heads: [head], busy: [],
                                               awaiting: ["#launch": ["bruno"]])
        XCTAssertTrue(held.isEmpty, "mid-run group blocks its own next send")
        let released = QueueScheduler.dispatchable(heads: [head], busy: [], awaiting: [:])
        XCTAssertEqual(released, ["#launch"])
    }
}
