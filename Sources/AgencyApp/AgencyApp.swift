import SwiftUI
import AppKit
import UserNotifications
import AgencyKit

@MainActor
final class AppState: ObservableObject {
    @Published var roster = Roster()
    @Published var selected: String? {
        didSet {
            if let s = selected, unread.remove(s) != nil { refreshBadge() }
        }
    }
    @Published var messages: [String: [ChatMessage]] = [:]
    @Published var streaming: [String: String] = [:]   // in-flight partial text per thread
    @Published var busy: Set<String> = []
    /// Live run handles per thread (HIS ORDER 2026-08-13: "THE ABILITY TO STOP
    /// AN AGENT"). Every send/relay/fork registers here; Stop cancels them all
    /// for the thread — cancellation propagates through the stream's
    /// onTermination into the runner's task and terminates the claude child.
    private var runningTasks: [String: [UUID: Task<Void, Never>]] = [:]

    /// Registers a task under one or more threads (a relay runs under both).
    private func track(_ task: Task<Void, Never>, threads: [String]) -> UUID {
        let id = UUID()
        for t in threads { runningTasks[t, default: [:]][id] = task }
        return id
    }
    private func untrack(_ id: UUID, threads: [String]) {
        for t in threads { runningTasks[t]?[id] = nil }
    }

    /// Stop everything running for this teammate. Partial output is kept (the
    /// stream's catch path already preserves it); the thread gets a visible ⏹.
    func stopRun(_ name: String) {
        let tasks = runningTasks[name] ?? [:]
        guard !tasks.isEmpty else { return }
        // Audit I5: Stop must not machine-gun the next queued item — pause the
        // thread's queue behind a visible Resume until Lorenzo says go.
        if !queued.items(for: name).isEmpty {
            queueHold.insert(name)
            refreshBadge()
        }
        for (_, t) in tasks { t.cancel() }
        let note = ChatMessage(author: "system", kind: .system,
                               text: "⏹ stopped by Lorenzo — the run was cancelled; whatever it wrote before stopping is kept.")
        try? log.append(note, thread: name)
        messages[name, default: []].append(note)
    }

    /// "+" hires a NEUTRAL teammate and starts its interview (his design
    /// 2026-08-13). No form: the teammate appears, introduces itself, and
    /// asks what it is for — with "configure manually" always on offer.
    func hireNeutral() {
        do {
            let a = try store.hireNeutralAgent()
            // SYNCHRONOUS roster refresh: reload() is detached, so the kickoff
            // below used to run before `roster` knew the new teammate — deliver
            // guards on the roster and silently bailed, and no interview ever
            // started (live 2026-08-13).
            roster = (try? store.loadRoster()) ?? roster
            messages[a.name] = []
            selected = a.name
            // The kickoff is app-authored and NOT shown as a message from
            // Lorenzo — he shouldn't see words he didn't type.
            deliver(ChatMessage(author: "system", kind: .system,
                                text: "[A new teammate was just created. Introduce yourself and begin the interview now.]"),
                    to: a.name)
        } catch { hireError = "\(error)" }
    }
    @Published var hireError: String?

    /// The interview's output: apply the profile, end interview mode, and say
    /// so in the thread. Called on every reply from a not-yet-onboarded agent.
    private func applyInterviewResult(_ reply: String, from name: String) {
        let onboarding = roster.agents.first(where: { $0.name == name })?.onboarded == false
        let profile = ProfileDirective.parse(reply)
        guard !profile.isEmpty else { return }
        // After onboarding a teammate may still restyle ITSELF (his report:
        // asking one to change its name did nothing) — but identity only.
        guard onboarding || profile.displayName != nil || profile.emoji != nil
                || profile.title != nil || profile.description != nil else { return }
        do {
            let a = try store.applyProfile(profile, to: name, identityOnly: !onboarding)
            roster = (try? store.loadRoster()) ?? roster
            if !profile.proposedConnectors.isEmpty {
                proposedConnectors[name] = profile.proposedConnectors
                notify(name, "needs access to work — tap to review")
                refreshBadge()
            }
            let note = ChatMessage(author: "system", kind: .system,
                text: onboarding
                    ? "✓ profile saved — \(a.display)\(a.title.map { ", \($0)" } ?? ""). Everything is editable in the profile, and they start fully sealed: no shell, web, or connectors until you grant them."
                    : "✓ profile updated — now \(a.emoji) \(a.display)\(a.title.map { ", \($0)" } ?? "").")
            try? log.append(note, thread: name)
            messages[name, default: []].append(note)
        } catch { hireError = "\(error)" }
    }

    /// Notifications (his ask 2026-08-13, from the profile screenshot): a
    /// long run finishing is exactly the moment he's looked away. Per-agent
    /// toggle, default ON; posted only when Agency is NOT the frontmost app,
    /// so a notification never duplicates something he's watching happen.
    /// `thread` (R3): the thread the event LANDED in, when that isn't the
    /// agent's own — a member reply posted to a group thread he is watching
    /// must be suppressed by the GROUP being selected, not the member.
    func notify(_ agentName: String, _ body: String, thread: String? = nil) {
        guard roster.agents.first(where: { $0.name == agentName })?.notifications != false
        else { return }
        // Only suppress when he is ALREADY LOOKING at this teammate's thread
        // (his report 2026-08-13: no notifications from Hermes). The old rule
        // was "app not frontmost", which swallowed everything while he sat in
        // the app watching a DIFFERENT thread — the normal case for a relay
        // chain, where the teammate that finishes is not the one he opened.
        guard !(NSApp.isActive && selected == (thread ?? agentName)) else { return }
        let content = UNMutableNotificationContent()
        content.title = displayName(agentName)
        content.body = String(body.prefix(200))
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// One tap grants what the interview asked for — his decision, made
    /// where he already is, instead of a trip into the profile sheet.
    func grantProposed(_ name: String) {
        guard let ids = proposedConnectors[name] else { return }
        do {
            let existing = roster.agents.first { $0.name == name }?.connectors ?? []
            let a = try store.setConnectors(Array(Set(existing + ids)).sorted(), for: name)
            proposedConnectors[name] = nil
            roster = (try? store.loadRoster()) ?? roster
            let granted = (a.connectors ?? []).compactMap { Connector.byID($0)?.displayName }
            let note = ChatMessage(author: "system", kind: .system,
                text: "✓ granted: \(granted.joined(separator: ", ")). Shell and web access stay off — those are separate switches in the profile.")
            try? log.append(note, thread: name)
            messages[name, default: []].append(note)
        } catch { hireError = "\(error)" }
    }

    /// Why a teammate needs Lorenzo, if it does — ordered by urgency, since
    /// only the top reason is worth a badge. nil = nothing pending.
    func attention(_ name: String) -> String? {
        if interviewOptions[name]?.isEmpty == false { return "waiting for your answer" }
        if proposedConnectors[name]?.isEmpty == false { return "asking for access" }
        if queueHold.contains(name) { return "queue paused — resume it" }
        if unread.contains(name) { return "new reply" }
        return nil
    }

    /// Threads needing him, for the dock badge — group threads included (R3;
    /// attention() itself is pure dict lookups, key shape irrelevant).
    var attentionCount: Int {
        roster.agents.filter { attention($0.name) != nil }.count
            + (roster.teams ?? []).filter { attention(TeamThreads.key(for: $0.name)) != nil }.count
    }

    /// Dock badge + per-thread dots are the same signal (his ask): the app
    /// itself says how many teammates are waiting, from across the room.
    func refreshBadge() {
        let n = attentionCount
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    /// Persisted sidebar order (his ask 2026-08-13).
    func reorder(_ names: [String]) {
        guard let updated = try? store.reorderAgents(names) else { return }
        roster.agents = updated
    }

    /// The name humans see for a handle (item 6: rename is display-only).
    func displayName(_ handle: String) -> String {
        if let team = TeamThreads.teamName(fromKey: handle) {
            return roster.teams?.first { $0.name == team }.map { $0.name.capitalized }
                ?? team.capitalized
        }
        return roster.agents.first { $0.name == handle }?.display ?? handle.capitalized
    }

    /// The team behind a thread key, if any (R3).
    func team(forKey key: String) -> Team? {
        guard let name = TeamThreads.teamName(fromKey: key) else { return nil }
        return roster.teams?.first { $0.name == name }
    }

    /// Fresh session, session-scoped (his ask 2026-08-13 #6): new conversation
    /// AND a clean visible chat — the old one rotates into the read-only
    /// archive (browsable from the thread's clock menu). No-op mid-run.
    func freshSession(_ name: String) {
        guard !busy.contains(name), !forking.contains(name) else { return }
        try? store.clearSessionID(for: name)
        _ = try? log.archiveThread(name)
        messages[name] = []
        roster = (try? store.loadRoster()) ?? roster
    }

    /// Archive = retire, never delete (item 6, his call): folders move to
    /// dot-archive locations every remaining agent is standing-denied from.
    /// Returns false while the teammate is running — moving a live run's cwd
    /// out from under it is not a feature; stop it first.
    @discardableResult
    func archiveAgent(_ name: String) throws -> Bool {
        guard !busy.contains(name), !forking.contains(name) else { return false }
        _ = try store.archiveAgent(name)
        if selected == name { selected = nil }
        messages[name] = nil
        roster = (try? store.loadRoster()) ?? roster
        return true
    }
    @Published var showCreate = false
    @Published var showConnectors = false
    @Published var showNewTeam = false
    /// Messages typed while a teammate was busy — delivered FIFO as runs
    /// finish. Persisted on every change (Grok Bot's send-journal pattern);
    /// restored and re-delivered on launch.
    @Published var queued = SendQueue() {
        // Same cross-process guard as every other shared file (reviewer #6:
        // two app instances — dev build beside the installed one — would
        // otherwise clobber each other's journal).
        didSet {
            queueLock.withLock { queued.save(to: queueURL) }
            if queued.isEmpty { holdRestored = false }   // all ✕-removed → bar gone
        }
    }
    /// His ruling ("the bar", 2026-08-13): messages restored from a previous
    /// session do NOT auto-deliver — N unattended runs firing at once after a
    /// crash was the alternative. They wait behind a visible bar until he
    /// clicks Deliver (or removes them with ✕).
    @Published var holdRestored = false
    private var queueURL: URL {
        store.rootURL.appendingPathComponent(".queue.json")
    }
    private lazy var queueLock = FileLock(
        lockURL: store.rootURL.appendingPathComponent(".queue.lock"))
    /// Chain depth of queued agent-initiated relays (message id → hops so far).
    /// Transient bookkeeping — 0 / absent means Lorenzo typed it himself.
    private var relayDepth: [UUID: Int] = [:]
    /// The target handle resolved when a relay was ENQUEUED (audit I2/R3).
    /// Delivery uses this instead of re-parsing the text, so a display-name
    /// collision or a rename between enqueue and delivery cannot reroute it.
    private var resolvedTarget: [UUID: String] = [:]
    /// The team-thread key a queued relay ORIGINATED from (R3): a relay
    /// emitted during a group run, between two members, mirrors its legs into
    /// the group thread — "handoffs preserved in one thread".
    private var relayOrigin: [UUID: String] = [:]
    /// The launch sweep must run exactly once, after the FIRST reload lands.
    private var sweptOnLaunch = false
    /// The chain-depth rule and its rationale live in `RelayHops` (kit-side, so
    /// it is unit-tested — it shipped wrong once).
    static let maxRelayHops = RelayHops.limit

    let store: AgentStore
    let log: MessageLog
    /// Shared between direct sends and relays: one bubble per warning STATE.
    let rateGate = RateLimitGate()
    lazy var runner = SessionRunner(store: store)
    lazy var broker = HandoffBroker(store: store, runner: runner, log: log, rateGate: rateGate)
    /// Same store the broker uses to park relay replies — here it parks relay
    /// FAILURES for the author's next turn (reviewer #5 Important 4: a system
    /// bubble tells Lorenzo, but the agent's session believed the handoff
    /// happened).
    lazy var pending = PendingContext(store: store)
    /// Threads with a subagent fork in flight (drives the ⑂ working row).
    @Published var forking: Set<String> = []
    /// Fan-out bookkeeping (audit I1): source → targets whose replies are
    /// still out. The source is NOT busy while awaiting — that hold was why
    /// the librarian's second relay "sat until he intervened".
    @Published var awaiting: [String: Set<String>] = [:]
    /// Threads whose queue is paused after a Stop (audit I5): each Stop used
    /// to fire the NEXT queued item instantly — whack-a-mole. Visible resume.
    @Published var queueHold: Set<String> = []
    /// Transient visibility (his asks 2026-08-13): rolling thinking tail and
    /// the last tool line per thread. Never persisted.
    @Published var thinking: [String: String] = [:]
    @Published var activity: [String: String] = [:]
    /// Tappable answer cards for an interview question (his design: same UX
    /// as the Claude app). Transient — cleared as soon as one is used.
    @Published var interviewOptions: [String: [String]] = [:]
    /// Connectors the interview proposed for a teammate, awaiting HIS tap.
    /// An agent never grants itself capabilities — that is the whole fence
    /// design — but it shouldn't make him hunt through the profile either.
    @Published var proposedConnectors: [String: [String]] = [:]
    /// Threads with a reply he hasn't looked at yet (his ask 2026-08-13:
    /// "agents that require my attention" must be visible, not hunted for).
    @Published var unread: Set<String> = []
    /// Agent-initiated replies landed while fanned out (drives the fan-in wake).
    private var repliesLanded: [String: Int] = [:]
    /// Depth the fan-in wake run inherits (its own directives count onward).
    private var fanDepth: [String: Int] = [:]

    /// App-wide connector catalog state (inventory; grants live per agent).
    let catalog: ConnectorCatalog

    init() {
        let root = ProcessInfo.processInfo.environment["AGENCY_ROOT"]
            ?? "\(NSHomeDirectory())/Library/Application Support/Agency"
        store = AgentStore(rootURL: URL(fileURLWithPath: root))
        catalog = ConnectorCatalog(rootURL: URL(fileURLWithPath: root))
        log = MessageLog(store: store)
        // Messages queued when the app last quit come back — HELD behind the
        // restore bar, not auto-delivered (his ruling).
        queued = SendQueue.load(from: URL(fileURLWithPath: root).appendingPathComponent(".queue.json"))
        holdRestored = !queued.isEmpty
        reload()
        refreshAllOnLaunch()
        // Ask once, at launch — the toggle in each profile decides WHICH
        // teammates may post; this is just macOS permission.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard !granted else { return }
            // A silent denial means he never hears from anyone again — say so
            // once, in the app, rather than letting it look like a bug.
            Task { @MainActor in
                self.hireError = "macOS notifications are turned off for Agency — turn them on in System Settings → Notifications if you want teammates to reach you."
            }
        }
    }

    /// Launch-time config refresh (review M9 + CLAUDE.md's "the app's launch
    /// refresh"): a code change to the persona template or the deny/fence rules
    /// leaves existing agents' on-disk config stale until rewritten. Do it once
    /// at launch — best-effort per agent, off the main actor — so a policy change
    /// like this security round propagates without a manual `agency-cli refresh`
    /// per agent. refreshAgentConfig is idempotent and re-derives from the roster
    /// row, so grants (web/shell/connectors) are preserved.
    private func refreshAllOnLaunch() {
        let store = store
        Task.detached(priority: .utility) {
            let roster = (try? store.loadRoster()) ?? Roster()
            for a in roster.agents { try? store.refreshAgentConfig(name: a.name) }
        }
        // The sweep itself moved into reload()'s completion (review finding
        // I4): called here it ran against a still-EMPTY roster/messages —
        // reload() is detached — so both halves iterated nothing. The agent
        // half had been dead since reload went detached; the group half was
        // born dead. The first completed reload is the earliest moment the
        // sweep can actually see anything.
    }

    /// Audit I7: quitting (or crashing) DURING a relay left the source thread
    /// showing "→ target: …" with no reply, nothing queued, no pending note —
    /// an exchange that silently never happened. On launch, a thread whose
    /// last message is an unanswered outbound relay leg gets a marker, and
    /// the SOURCE AGENT gets a pending note so its session doesn't keep
    /// believing the handoff completed.
    private func sweepInterruptedRelays() {
        for agent in roster.agents {
            let thread = messages[agent.name] ?? []
            guard let last = thread.last, last.kind == .relayOut,
                  last.author == agent.name else { continue }
            let note = ChatMessage(author: "system", kind: .system,
                text: "⚠️ this handoff was interrupted when the app last quit — no reply ever came back. Re-send it if it still matters.")
            try? log.append(note, thread: agent.name)
            messages[agent.name, default: []].append(note)
            try? pending.add("""
            [Relay interrupted — from the app, not a teammate]
            Your last relay never completed: the app quit before a reply came back. Do not assume it was delivered.
            """, for: agent.name)
        }
        // Group half (R3): a team log ending on Lorenzo's message means the
        // app quit mid-group-turn. Cursor semantics make the recovery honest:
        // whoever never replied never advanced, so the message is re-carried
        // in their next delta automatically.
        for t in roster.teams ?? [] {
            let key = TeamThreads.key(for: t.name)
            guard messages[key]?.last?.kind == .user else { continue }
            let note = ChatMessage(author: "system", kind: .system,
                text: "⚠️ this group message was interrupted when the app last quit — anyone who didn't reply will receive it again with your next group message.")
            try? log.append(note, thread: key)
            messages[key, default: []].append(note)
        }
    }

    /// The restore bar's Deliver button.
    func deliverRestored() {
        holdRestored = false
        drainQueues()
    }

    /// Disk reads (roster under its flock, every thread's JSONL) happen OFF the
    /// main actor — a CLI holding the roster lock must never freeze the UI
    /// (review #1 minor, promoted per the fix-what-you-find rule).
    func reload() {
        let store = store, log = log
        Task.detached(priority: .userInitiated) {
            let roster = (try? store.loadRoster()) ?? Roster()
            var loaded: [String: [ChatMessage]] = [:]
            for a in roster.agents { loaded[a.name] = (try? log.load(thread: a.name)) ?? [] }
            for t in roster.teams ?? [] {
                let key = TeamThreads.key(for: t.name)
                loaded[key] = (try? log.load(thread: key)) ?? []
            }
            let msgs = loaded
            await MainActor.run {
                self.roster = roster
                self.messages = msgs
                if self.selected == nil { self.selected = roster.agents.first?.name }
                // Interrupted-run sweep, ONCE, at the first moment state is
                // actually populated (review finding I4 — in init it ran
                // against empty dicts and both halves iterated nothing).
                if !self.sweptOnLaunch {
                    self.sweptOnLaunch = true
                    self.sweepInterruptedRelays()
                    // Attachment retention (review M6): staged copies older
                    // than 30 days go quietly — a console line, not a thread
                    // note; nobody needs a bubble about housekeeping.
                    let swept = Attachments.sweep(root: self.store.rootURL)
                    if swept > 0 { print("agency: swept \(swept) stale attachment(s)") }
                }
                // Restored (or newly unblocked) queue items deliver as soon as
                // the roster is known — this is what re-delivers a persisted
                // queue on launch.
                self.drainQueues()
            }
        }
    }

    /// Parses "@target question" — the in-app context-transfer command.
    /// Handles AND display names resolve (his ask 2026-08-13); the tested
    /// logic lives in Mentions.resolveRelay.
    func parseRelay(_ text: String) -> (target: Agent, question: String)? {
        Mentions.resolveRelay(text: text, agents: roster.agents)
    }

    /// A message can go out NOW. Fan-out semantics (audit I1): a relay needs
    /// its TARGET idle and the source not mid-run — the source merely
    /// AWAITING other replies no longer blocks it. A plain message waits for
    /// its own thread's inbound replies (typed-order feel preserved).
    private func deliverable(_ text: String, thread name: String) -> Bool {
        let awaitedTargets = Set(awaiting.values.flatMap { $0 })
        if TeamThreads.isTeamKey(name) {
            // Group send (R3): every member must be free — and the text is
            // NEVER parsed as a relay ("@nina …" in a group is plain text to
            // everyone, his call). effectiveBusy folds busy+forking+awaited.
            return !GroupDispatch.effectiveBusy(busy: busy, forking: forking,
                                                awaiting: awaiting,
                                                teams: roster.teams ?? []).contains(name)
                && awaiting[name]?.isEmpty != false
        }
        if let (target, _) = parseRelay(text), target.name != name {
            return !busy.contains(name) && !busy.contains(target.name)
                && !awaitedTargets.contains(target.name)
        }
        return !busy.contains(name)
            && !awaitedTargets.contains(name)
            && awaiting[name]?.isEmpty != false
    }

    /// A finished run frees capacity — recheck every thread's HEAD, because a
    /// queued relay may have been waiting on the TARGET, not its own thread.
    /// FIFO per thread: the head is never skipped.
    private func drainQueues() {
        guard !holdRestored else { return }   // restored messages wait for the bar
        // Cross-process freshness (audit I8): another instance (dev build
        // beside the installed one) may have delivered or removed entries —
        // its journal is the shared truth; re-read before acting on ours.
        let disk = queueLock.withLock { SendQueue.load(from: queueURL) }
        if disk != queued { queued = disk }
        // The tested dispatch brain decides (QueueScheduler: global ts
        // fairness, fan-out, FIFO). Loop to a fixed point so consecutive
        // relay heads from one source fan out in a single drain.
        var dispatched = true
        while dispatched {
            dispatched = false
            let heads: [QueueScheduler.Head] = queued.threads.compactMap { t in
                guard !queueHold.contains(t), let h = queued.peek(t) else { return nil }
                // A group head is always plain — its text is never a relay.
                if TeamThreads.isTeamKey(t) { return .init(thread: t, ts: h.ts, target: nil) }
                // Resolved-at-enqueue target wins over re-parsing (R3).
                let target = resolvedTarget[h.id] ?? parseRelay(h.text).map(\.target.name)
                return .init(thread: t, ts: h.ts, target: target == t ? nil : target)
            }
            // Team keys become busy while any member is unavailable (R3) —
            // the scheduler itself stays untouched.
            let busyView = GroupDispatch.effectiveBusy(busy: busy, forking: forking,
                                                       awaiting: awaiting,
                                                       teams: roster.teams ?? [])
            for thread in QueueScheduler.dispatchable(heads: heads, busy: busyView, awaiting: awaiting) {
                guard let head = queued.peek(thread) else { continue }
                queued.dequeue(thread)
                if TeamThreads.isTeamKey(thread) {
                    relayDepth[head.id] = nil; relayOrigin[head.id] = nil
                    deliverGroup(head, to: thread)
                    dispatched = true
                    continue
                }
                let handle = resolvedTarget.removeValue(forKey: head.id)
                deliver(head, to: thread, depth: relayDepth.removeValue(forKey: head.id) ?? 0,
                        resolvedTarget: handle, origin: relayOrigin.removeValue(forKey: head.id))
                dispatched = true
            }
        }
    }

    /// Resume a queue paused by Stop (audit I5).
    func resumeQueue(_ name: String) {
        queueHold.remove(name)
        drainQueues()
    }

    /// FAN-IN (audit I1b, the Grok Bot semantic v1): when the LAST outstanding
    /// agent-initiated relay reply lands, the source wakes ONCE to synthesize —
    /// its parked replies ride the wake run's prompt as pending handoffs.
    /// Skipped when something is already queued (that run will consume the
    /// replies anyway) — never a doubled run.
    private func maybeWake(_ source: String) {
        guard awaiting[source] == nil,
              let n = repliesLanded[source], n > 0 else { return }
        repliesLanded[source] = nil
        let depth = fanDepth.removeValue(forKey: source) ?? 0
        guard queued.items(for: source).isEmpty, !queueHold.contains(source) else { return }
        let wake = ChatMessage(author: "system", kind: .system,
            text: "⏩ All \(n) relay repl\(n == 1 ? "y has" : "ies have") arrived — continue the task using them (they're included above as handoffs).")
        // A wake is free — see RelayHops rule 3.
        relayDepth[wake.id] = RelayHops.forWake(at: depth)
        queued.enqueue(wake, thread: source)
        // Caller's defer drains right after — the wake launches immediately
        // if the source is idle.
    }

    /// Bulk fresh sessions (his ask 2026-08-13, after stale sessions blocked
    /// the fan-out repro): reset the team without visiting each profile.
    /// Busy/forking teammates are skipped and reported, never interrupted.
    @discardableResult
    func freshSessions(_ names: [String]) -> (done: [String], skipped: [String]) {
        var done: [String] = [], skipped: [String] = []
        for n in names {
            if busy.contains(n) || forking.contains(n) { skipped.append(n); continue }
            freshSession(n)
            done.append(n)
        }
        return (done, skipped)
    }

    /// Live target visibility during a relay (audit I6): the target's stream
    /// lands in the same transient surfaces a direct send uses.
    private func relayStreamEvent(_ event: StreamEvent, target: String) {
        switch event {
        case .textDelta(let t): streaming[target, default: ""] += t
        case .messageBoundary: streaming[target] = ""
        case .thinkingDelta(let t):
            let rolled = (thinking[target] ?? "") + t
            thinking[target] = String(rolled.suffix(600))
        case .toolActivity(let line): activity[target] = line
        default: break
        }
    }

    func removeQueued(id: UUID, thread: String) {
        queued.remove(id: id, thread: thread)
        relayDepth.removeValue(forKey: id)
        resolvedTarget.removeValue(forKey: id)
        relayOrigin.removeValue(forKey: id)
        // Audit C1: ✕-removing a stuck head must UNSTICK the thread now — the
        // queue used to re-check only when some unrelated run finished.
        drainQueues()
    }

    /// RELAY directives in an agent's reply become queued relays FROM that
    /// agent (his rule: agents pass messages; the receiving agent thinks).
    /// Enqueued rather than sent directly so the busy/ordering machinery is
    /// the same one Lorenzo's own messages use.
    /// A group send (R3): Lorenzo's message fans out to every member in
    /// parallel; each reply lands in the TEAM thread as that member. Members
    /// have independent sessions — what makes this a real group chat is the
    /// DELTA each member's prompt carries (everything they haven't seen since
    /// their last group turn, per TeamCursorStore). Lorenzo is the fan-in: no
    /// maybeWake, no repliesLanded, no PendingContext (no team session exists).
    private func deliverGroup(_ msg: ChatMessage, to key: String) {
        guard let t = team(forKey: key) else { return }
        // Fresh roster (the runQueuedAsSubagent precedent): a member's
        // sessionID may have moved since our snapshot.
        let fresh = (try? store.loadRoster()) ?? roster
        let members = t.members.compactMap { m in fresh.agents.first { $0.name == m } }

        // Lorenzo's message persists FIRST, whatever else happens (review
        // finding I3: the zero-member early-return used to fire before this
        // append while send() had already returned true — the composer
        // cleared and his typed message was destroyed).
        try? log.append(msg, thread: key)
        messages[key, default: []].append(msg)

        // Degraded team (his assumption): deliver anyway, visibly — runtime
        // never bricks. Zero members is the one true dead end (message kept).
        if members.count < 2 {
            let note = ChatMessage(author: "system", kind: .system,
                text: members.isEmpty
                    ? "⚠️ #\(t.name) has no members — the message is kept in the thread but nobody received it. Add members in the team profile."
                    : "⚠️ #\(t.name) is down to one member — delivering, but a group of one is just a slow 1:1.")
            try? log.append(note, thread: key)
            messages[key, default: []].append(note)
            guard !members.isEmpty else { return }
        }

        // The delta snapshot comes from DISK, not messages[key] (review
        // finding C1 — Critical): the UI array is clobbered wholesale by
        // reload()'s detached read, and each member's defer fires one, so a
        // group send races N stale reads against N appends. Cursors must
        // index the LOG's order — the one space every append already agrees
        // on. messages[key] stays the UI's eventually-consistent view; it is
        // never the cursor space again.
        let snapshot = (try? log.load(thread: key)) ?? (messages[key] ?? [])
        let cursors = TeamCursorStore(store: store, team: t.name)

        for agent in members {
            let delta = GroupPrompt.delta(log: snapshot,
                                          cursor: cursors.cursor(for: agent.name),
                                          member: agent.name)
            let prompt = GroupPrompt.render(team: t, member: agent.name, delta: delta,
                                            display: { [weak self] in self?.displayName($0) ?? $0 })
            busy.insert(agent.name)
            awaiting[key, default: []].insert(agent.name)
            var taskID: UUID?
            let task = Task { @MainActor in
                defer {
                    if let id = taskID { untrack(id, threads: [agent.name, key]) }
                    busy.remove(agent.name)
                    awaiting[key]?.remove(agent.name)
                    if awaiting[key]?.isEmpty == true { awaiting[key] = nil }
                    streaming[agent.name] = nil
                    thinking[agent.name] = nil
                    activity[agent.name] = nil
                    drainQueues(); reload()
                }
                var final = ""
                var noted = Set<String>()   // one system notice per distinct thing
                @MainActor func notice(_ text: String, dedupe: String) {
                    guard noted.insert(dedupe).inserted else { return }
                    let m = ChatMessage(author: "system", kind: .system, text: text)
                    try? log.append(m, thread: key)
                    messages[key, default: []].append(m)
                }
                do {
                    for try await event in runner.send(prompt, to: agent) {
                        switch event {
                        case .resultText(let r, _): final = r
                        case .sessionRolledOver(let reason):
                            notice("↻ \(agent.display)'s previous session couldn't be resumed (\(reason)) — continued fresh during this group turn.",
                                   dedupe: "roll-\(agent.name)")
                        case .runError(let detail):
                            notice("⚠️ \(agent.display) hit a run error in the group turn: \(detail)",
                                   dedupe: "err-\(agent.name)-\(detail)")
                        case .rateLimit(let info):
                            if rateGate.shouldAnnounce(info) {
                                notice("⏳ Plan usage warning — \(info.humanSummary).", dedupe: "rate")
                            }
                        case .vaultProvenanceAlert(let line):
                            notice(line, dedupe: "prov-\(line)")
                        case .egressDenied(let host, let port):
                            if !EgressProxy.isRuntimeNoise(host: host) {
                                notice("🚧 egress denied: \(agent.display)'s group run tried to reach \(host):\(port) — the network fence refused it.",
                                       dedupe: "egress-\(agent.name)-\(host)")
                            }
                        default:
                            // Live typing shows in the MEMBER's 1:1 (the
                            // relay-path pattern) — the team thread has one
                            // awaiting chip, not N racing stream bubbles, and
                            // messages[key] must stay index-identical to the
                            // log or cursor arithmetic skews.
                            relayStreamEvent(event, target: agent.name)
                        }
                    }
                } catch is CancellationError {
                    let partial = streaming[agent.name] ?? ""
                    final = partial.isEmpty ? "" : partial + "\n\n⏹ (stopped here)"
                    if final.isEmpty {
                        notice("⏹ \(agent.display)'s group turn was stopped before any reply.",
                               dedupe: "stop-\(agent.name)")
                    }
                } catch {
                    let partial = streaming[agent.name] ?? ""
                    final = partial.isEmpty ? "" : partial + "\n\n⚠️ (run failed here: \(error.localizedDescription))"
                    if final.isEmpty {
                        notice("⚠️ \(agent.display)'s group turn failed: \(error.localizedDescription)",
                               dedupe: "fail-\(agent.name)")
                    }
                }
                if !final.isEmpty {
                    let reply = ChatMessage(author: agent.name, kind: .agent, text: final)
                    try? log.append(reply, thread: key)
                    messages[key, default: []].append(reply)
                    // Advance ONLY on a landed reply, and only to what this
                    // prompt actually covered — a teammate's reply that landed
                    // mid-run rides the NEXT delta.
                    cursors.advance(agent.name, to: delta.upTo)
                    // One compact line in the member's own thread (a full
                    // mirrored leg would false-trigger the interrupted-relay
                    // sweep and bloat the 1:1).
                    let gist = String(msg.text.prefix(80)) + (msg.text.count > 80 ? "…" : "")
                    let mirror = ChatMessage(author: "system", kind: .system,
                        text: "👥 #\(t.name) — replied in the group thread to Lorenzo's: “\(gist)”")
                    try? log.append(mirror, thread: agent.name)
                    messages[agent.name, default: []].append(mirror)
                    if selected != key { unread.insert(key) }
                    notify(agent.name, final, thread: key)
                    refreshBadge()
                    // A member may pass work on mid-group — keep the group
                    // origin so member↔member legs mirror into this thread.
                    processRelayDirectives(in: final, from: agent.name, depth: 0, origin: key)
                }
                roster = (try? store.loadRoster()) ?? roster
            }
            taskID = track(task, threads: [agent.name, key])
        }
    }

    /// Synchronous roster+messages refresh (R3): the sheet flows need the new
    /// team VISIBLE before the sheet closes — reload() is detached and races
    /// the dismissal (the interview-kickoff lesson, same cure).
    func reloadNow() {
        roster = (try? store.loadRoster()) ?? roster
        for t in roster.teams ?? [] {
            let key = TeamThreads.key(for: t.name)
            if messages[key] == nil { messages[key] = (try? log.load(thread: key)) ?? [] }
        }
    }

    /// Archive a group thread (R3): the transcript rotates into the sealed
    /// archive and every cursor resets — member SESSIONS are untouched (there
    /// is nothing to reset; a team has no session).
    func archiveTeamThread(_ key: String) {
        guard let t = team(forKey: key), awaiting[key]?.isEmpty != false else { return }
        _ = try? log.archiveThread(key)
        TeamCursorStore(store: store, team: t.name).reset()
        messages[key] = []
        unread.remove(key)
        refreshBadge()
    }

    private func processRelayDirectives(in reply: String, from author: String, depth: Int,
                                        origin: String? = nil) {
        let parsed = RelayDirective.parse(reply)
        // WIDTH cap (review finding I-8): depth is bounded, but width was not,
        // so worst-case runs grow as width^depth — and a reply that emitted a
        // relay per teammate every round would burn plan usage inside a budget
        // that looked bounded on paper. Never silently: the overflow is
        // reported to Lorenzo AND to the agent, which can re-send next turn.
        let fanOut = parsed.prefix(RelayHops.maxFanOut)
        if parsed.count > RelayHops.maxFanOut {
            let dropped = parsed.dropFirst(RelayHops.maxFanOut).map { "@\($0.target)" }
                .joined(separator: ", ")
            let msg = ChatMessage(author: "system", kind: .system,
                text: "🔗 \(author.capitalized) asked \(parsed.count) teammates at once — the first \(RelayHops.maxFanOut) were sent, \(dropped) were not.")
            try? log.append(msg, thread: author)
            messages[author, default: []].append(msg)
            try? pending.add("""
            [Relay delivery failure — from the app, not a teammate]
            You issued \(parsed.count) RELAY lines in one reply; only the first \(RelayHops.maxFanOut) were delivered. \
            These were NOT sent: \(dropped). Re-send them next turn if they still matter.
            """, for: author)
        }
        for d in fanOut {
            guard d.target != author else { continue }
            // Both halves must learn about a failure: the bubble tells
            // Lorenzo, the pending note tells the AGENT's next turn — its
            // session otherwise proceeds believing the handoff happened.
            func failed(_ bubble: String, agentNote: String) {
                let msg = ChatMessage(author: "system", kind: .system, text: bubble)
                try? log.append(msg, thread: author)
                messages[author, default: []].append(msg)
                try? pending.add("""
                [Relay delivery failure — from the app, not a teammate]
                \(agentNote)
                """, for: author)
            }
            guard roster.agents.contains(where: { $0.name == d.target }) else {
                failed("⚠️ \(author.capitalized) tried to relay to unknown teammate “@\(d.target)” — not sent.",
                       agentNote: "Your RELAY to @\(d.target) was NOT delivered: no teammate has that exact name. Check the Teammates list in your instructions and re-send with the exact name.")
                continue
            }
            guard !RelayHops.exhausted(at: depth) else {
                failed("🔗 relay chain stopped at \(Self.maxRelayHops) hops — \(author.capitalized)'s relay to @\(d.target) was not sent.",
                       agentNote: "Your RELAY to @\(d.target) was NOT delivered: the relay chain reached its \(Self.maxRelayHops)-hop limit. Ask Lorenzo directly if this handoff still matters.")
                continue
            }
            let m = ChatMessage(author: author, kind: .relayOut, text: "@\(d.target) \(d.message)")
            relayDepth[m.id] = RelayHops.forRelay(from: depth)
            // R3: remember the target we RESOLVED here, so delivery never
            // re-parses the text (a display-name collision could reroute it,
            // Mentions.resolveRelay longest-match rule).
            resolvedTarget[m.id] = d.target
            if let origin { relayOrigin[m.id] = origin }
            queued.enqueue(m, thread: author)
        }
    }

    /// His ask (2026-08-13): a queued message can become a subagent instead of
    /// waiting. Runs it on a FORKED copy of the busy teammate's session — full
    /// memory up to now, parallel execution, and a clearly labeled reply. The
    /// main session never learns what the fork did (vault writes excepted).
    func runQueuedAsSubagent(id: UUID, thread name: String) {
        // Fresh roster from DISK, not the in-memory copy (reviewer #5 minor):
        // during an agent's FIRST run the in-memory sessionID is still nil —
        // it's only refreshed after a run completes — but the init event has
        // already persisted it, and without it the "fork" would silently run
        // memoryless.
        let diskRoster = (try? store.loadRoster()) ?? roster
        guard let msg = queued.items(for: name).first(where: { $0.id == id }),
              let agent = diskRoster.agents.first(where: { $0.name == name }),
              parseRelay(msg.text) == nil else { return }   // relays wait their turn
        guard agent.sessionID != nil else {
            let note = ChatMessage(author: "system", kind: .system,
                text: "⑂ can't fork yet — \(name.capitalized) hasn't finished a first exchange, so there is no memory to copy. The message stays queued.")
            try? log.append(note, thread: name)
            messages[name, default: []].append(note)
            return
        }
        let forkDepth = relayDepth[id] ?? 0
        removeQueued(id: id, thread: name)
        let userMsg = ChatMessage(author: "lorenzo", kind: .user, text: msg.text)
        try? log.append(userMsg, thread: name)
        messages[name, default: []].append(userMsg)
        forking.insert(name)
        var forkTaskID: UUID?
        let forkTask = Task { @MainActor in
            defer {
                if let id = forkTaskID { untrack(id, threads: [name]) }
                forking.remove(name)
            }
            var final = ""
            do {
                for try await event in runner.send(msg.text, to: agent, forked: true) {
                    switch event {
                    case .resultText(let r, _): final = r
                    case .runError(let detail): if final.isEmpty { final = "⚠️ subagent run error: \(detail)" }
                    case .rateLimit(let info):
                        if rateGate.shouldAnnounce(info) {
                            let msg = ChatMessage(author: "system", kind: .system,
                                text: "⏳ Plan usage warning — \(info.humanSummary). Heavy tasks may be throttled.")
                            try? log.append(msg, thread: name)
                            messages[name, default: []].append(msg)
                        }
                    case .egressDenied(let host, let port):
                        // Forks are the ALWAYS-fenced class (fence review I4):
                        // without this case, the most-fenced runs were the ones
                        // whose denials never reached the thread. Same noise
                        // suppression as the main path.
                        if !EgressProxy.isRuntimeNoise(host: host) {
                            let msg = ChatMessage(author: "system", kind: .system,
                                text: "🚧 egress denied: the subagent run tried to reach \(host):\(port) — the network fence refused it.")
                            try? log.append(msg, thread: name)
                            messages[name, default: []].append(msg)
                        }
                    default: break
                    }
                }
            } catch is CancellationError {
                final = "⏹ subagent stopped by Lorenzo"
            } catch {
                final = "⚠️ subagent error: \(error.localizedDescription)"
            }
            if final.isEmpty { final = "⚠️ the subagent returned nothing" }
            let reply = ChatMessage(author: name, kind: .subagent, text: final)
            try? log.append(reply, thread: name)
            messages[name, default: []].append(reply)
            // A fork that follows its persona and ends with RELAY @…: honor
            // it like any other reply (reviewer #5 minor — silently ignoring
            // it contradicts what the persona teaches).
            // A fork's reply inherits the ORIGINATING message's hop depth
            // (audit M1): resetting to 0 handed every forked run a fresh
            // relay budget, so a ping-pong could out-live maxRelayHops.
            processRelayDirectives(in: final, from: name, depth: forkDepth)
            drainQueues()
        }
        forkTaskID = track(forkTask, threads: [name])
    }

    /// Returns false only when the agent is unknown. A busy teammate no longer
    /// refuses the message — it queues (his ask 2026-08-13) and the composer
    /// clears; delivery order within a thread is strictly typed order.
    /// The queue-empty check is load-bearing (reviewer #5 Critical 1): with a
    /// relay parked at the head waiting on a busy TARGET, this thread is idle —
    /// a fresh message must join the line behind it, not jump it.
    @discardableResult
    func send(_ text: String, to name: String, attachments: [URL] = []) -> Bool {
        // Existence guards BEFORE staging (review M3): a send refused for an
        // unknown target must not leave staged copies behind.
        let isTeam = TeamThreads.isTeamKey(name)
        if isTeam { guard team(forKey: name) != nil else { return false } }
        else { guard roster.agents.contains(where: { $0.name == name }) else { return false } }
        // Attachments (his ask 2026-08-14) stage BEFORE any routing so the
        // block rides the text through every path — direct, queued, relayed,
        // group — identically. A failed copy (symlink, oversized, unreadable)
        // refuses the send — composer keeps draft AND chips — rather than
        // shipping a message that points at a path which isn't there.
        var text = text
        if !attachments.isEmpty {
            do {
                let staged = try Attachments.stage(files: attachments,
                                                   thread: name, root: store.rootURL)
                // Trim covers the files-only send: an empty draft plus chips
                // must not open the message with the block's blank lines.
                text = (text + Attachments.promptBlock(for: staged))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                // Persisted like every other system note (review I1) — an
                // unlogged append vanishes on the next reload().
                let note = ChatMessage(author: "system", kind: .system,
                    text: "⚠️ couldn't stage attachment: \(error.localizedDescription) — nothing was sent")
                try? log.append(note, thread: name)
                messages[name, default: []].append(note)
                return false
            }
        }
        // Group thread (R3): must return TRUE on success — ThreadView.submit
        // only clears the draft on true, so a false here reads as a dead
        // composer.
        if isTeam {
            let msg = ChatMessage(author: "lorenzo", kind: .user, text: text)
            guard deliverable(text, thread: name), queued.items(for: name).isEmpty else {
                queued.enqueue(msg, thread: name)
                return true
            }
            deliverGroup(msg, to: name)
            return true
        }
        interviewOptions[name] = nil   // a card was tapped (or typed past)
        let msg = ChatMessage(author: "lorenzo", kind: .user, text: text)
        guard deliverable(text, thread: name), queued.items(for: name).isEmpty else {
            queued.enqueue(msg, thread: name)
            return true
        }
        deliver(msg, to: name)
        return true
    }

    /// The actual launch. Callers (send / drainQueues) have already verified
    /// deliverability — MainActor serialization means no interleaving between
    /// that check and the busy/awaiting inserts below. `depth` counts
    /// agent-initiated relay hops behind this message (0 = Lorenzo typed it).
    private func deliver(_ msg: ChatMessage, to name: String, depth: Int = 0,
                         resolvedTarget handle: String? = nil, origin: String? = nil) {
        guard let agent = roster.agents.first(where: { $0.name == name }) else { return }
        let text = msg.text

        // "@target question" in this thread = relay: THIS agent asks TARGET.
        // (@self falls through and is sent as an ordinary message.)
        // R3: when the target was resolved at ENQUEUE time, use that handle —
        // only the question is re-read from the text.
        let parsed: (target: Agent, question: String)? = {
            if let handle, let t = roster.agents.first(where: { $0.name == handle }) {
                return (t, parseRelay(text)?.question
                    ?? String(text.dropFirst(handle.count + 1)).trimmingCharacters(in: .whitespaces))
            }
            return handle == nil ? parseRelay(text) : nil   // resolved-but-gone = loud failure below
        }()
        if let (target, question) = parsed, target.name != name {
            // The broker's relayOut leg IS the record of this ask — logging the raw
            // "@target …" text as well rendered the same act twice (review #1 minor).
            // Show the leg immediately (transient); the final reload() replaces it
            // with the broker's persisted copy.
            messages[name, default: []].append(ChatMessage(
                author: name, kind: .relayOut, text: "→ \(target.display): \(question)"))
            // …and the TARGET's thread shows the inbound question NOW (audit
            // I6) — it used to stay blank until the final reload.
            messages[target.name, default: []].append(ChatMessage(
                author: name, kind: .relayIn, text: "← \(displayName(name)): \(question)"))
            // FAN-OUT (audit I1): only the TARGET goes busy. The source is
            // "awaiting" — visible, and free to fan further relays out.
            busy.insert(target.name)
            awaiting[name, default: []].insert(target.name)
            if msg.kind == .relayOut {   // agent-initiated → fan-in wake applies
                fanDepth[name] = max(fanDepth[name] ?? 0, depth)
            }
            var relayTaskID: UUID?
            let relayTask = Task { @MainActor in
                // drainQueues BEFORE reload: a drained PLAIN message appends to
                // the log synchronously, so reload's detached read includes it.
                defer {
                    if let id = relayTaskID { untrack(id, threads: [name, target.name]) }
                    busy.remove(target.name)
                    awaiting[name]?.remove(target.name)
                    if awaiting[name]?.isEmpty == true { awaiting[name] = nil }
                    streaming[target.name] = nil
                    thinking[target.name] = nil
                    activity[target.name] = nil
                    maybeWake(name)
                    drainQueues(); reload()
                }
                do {
                    // Live target visibility during the relay (audit I6).
                    let reply = try await broker.relay(question: question, from: agent, to: target,
                                                       onEvent: { [weak self] event in
                        Task { @MainActor in self?.relayStreamEvent(event, target: target.name) }
                    })
                    if msg.kind == .relayOut { repliesLanded[name, default: 0] += 1 }
                    // Handoffs preserved in one thread (R3, structure audit
                    // N4): a relay that ORIGINATED in a group run, between two
                    // members, mirrors compact legs into the group thread —
                    // Lorenzo sees the exchange where the work is happening.
                    // (.relayOut/.relayIn kinds are EXCLUDED from every
                    // member's delta, so nothing is delivered twice.)
                    if let origin, let t = team(forKey: origin),
                       t.members.contains(name), t.members.contains(target.name) {
                        let out = ChatMessage(author: name, kind: .relayOut,
                                              text: "→ \(target.display): \(question)")
                        let back = ChatMessage(author: target.name, kind: .relayIn, text: reply)
                        for leg in [out, back] {
                            try? log.append(leg, thread: origin)
                            messages[origin, default: []].append(leg)
                        }
                        if selected != origin { unread.insert(origin) }
                    }
                    // The END of a relay chain is exactly the moment he cares
                    // about, and it was the one path that never notified.
                    notify(target.name, reply)
                    if selected != target.name { unread.insert(target.name) }
                    refreshBadge()
                    // The TARGET's reply may itself pass something on ("ask her
                    // to pass it on to @Bruno" — his live chain): honor it, one
                    // hop deeper, keeping the group origin.
                    processRelayDirectives(in: reply, from: target.name, depth: depth,
                                           origin: origin)
                } catch is CancellationError {
                    notify(target.name, "the relay was stopped before it finished")
                    // Audit C2: the broker already parked honest notes for BOTH
                    // agents; make the stop visible in BOTH threads too.
                    for t in [name, target.name] {
                        let note = ChatMessage(author: "system", kind: .system,
                            text: "⏹ the relay \(displayName(name)) → \(displayName(target.name)) was stopped before it finished.")
                        try? log.append(note, thread: t)
                        messages[t, default: []].append(note)
                    }
                } catch {
                    // The broker parked the failure note for the source agent
                    // (audit C2); this is Lorenzo's visible half.
                    let err = ChatMessage(author: target.name, kind: .system,
                                          text: "⚠️ relay failed: \(error.localizedDescription)")
                    try? log.append(err, thread: name)
                    notify(name, "a relay to \(displayName(target.name)) failed")
                    refreshBadge()
                }
                roster = (try? store.loadRoster()) ?? roster
            }
            relayTaskID = track(relayTask, threads: [name, target.name])
            return
        }

        // Audit I2: an enqueue-time-validated agent relay that no longer
        // resolves (target archived / renamed since) must fail LOUDLY — the
        // old fall-through delivered "@bruno do X" to the SOURCE agent as a
        // message from Lorenzo: misdelivery plus misattribution plus a burned run.
        if msg.kind == .relayOut {
            let note = ChatMessage(author: "system", kind: .system,
                text: "⚠️ \(displayName(msg.author))'s queued relay could no longer be delivered (the teammate it named is gone) — not sent.")
            try? log.append(note, thread: name)
            messages[name, default: []].append(note)
            try? pending.add("""
            [Relay delivery failure — from the app, not a teammate]
            Your queued RELAY (“\(text)”) was NOT delivered: its target no longer exists on the roster.
            """, for: msg.author)
            drainQueues()
            return
        }

        // Wake turns (fan-in) and other system-authored deliveries log as
        // system, not as Lorenzo (audit I1b).
        let userMsg = msg.kind == .system ? msg
            : ChatMessage(author: "lorenzo", kind: .user, text: text)
        try? log.append(userMsg, thread: name)
        messages[name, default: []].append(userMsg)
        busy.insert(name)

        var sendTaskID: UUID?
        let sendTask = Task { @MainActor in
            defer {
                if let id = sendTaskID { untrack(id, threads: [name]) }
                busy.remove(name); streaming[name] = nil
                thinking[name] = nil; activity[name] = nil
                drainQueues()
            }
            var final = ""
            var noted = Set<String>()   // one-shot system notices per send
            @MainActor func notice(_ text: String, key: String) {
                guard noted.insert(key).inserted else { return }
                let msg = ChatMessage(author: "system", kind: .system, text: text)
                try? log.append(msg, thread: name)
                messages[name, default: []].append(msg)
            }
            do {
                for try await event in runner.send(text, to: agent) {
                    switch event {
                    case .textDelta(let t): streaming[name, default: ""] += t
                    case .thinkingDelta(let t):
                        // His ask: MORE of the thinking process — a rolling
                        // tail in a transient dimmed pane, never persisted.
                        if streaming[name, default: ""].isEmpty { streaming[name] = "…" }
                        let rolled = (thinking[name] ?? "") + t
                        thinking[name] = String(rolled.suffix(600))
                    case .toolActivity(let line):
                        activity[name] = line
                    case .messageBoundary:
                        // A new assistant message began — drop the previous one
                        // from the preview. Lorenzo doesn't want the agent's
                        // accumulated working narration, just what it's saying
                        // NOW; the final bubble is resultText alone anyway.
                        streaming[name] = ""
                    case .resultText(let r, _): final = r
                    case .sessionRolledOver(let reason):
                        // Discard attempt 1's partial output — otherwise the abandoned
                        // attempt splices onto the retry's answer and can be PERSISTED
                        // on the error path (review #3 I-3).
                        streaming[name] = ""
                        notice("↻ \(name.capitalized)'s previous session couldn't be resumed (\(reason)) — started a fresh one. Chat history and memory files are intact.", key: "rollover")
                    case .runError(let detail):
                        notice("⚠️ Claude reported a run error: \(detail)", key: "runerror")
                        notify(name, "hit a run error — it needs you")
                    case .lockWaiting:
                        // Item-6 debt: >10s behind another run of the SAME
                        // teammate looked like an unexplained stall.
                        notice("⏳ waiting for \(displayName(name))'s other run (app or CLI) to finish — this message goes next.",
                               key: "lockwait")
                    case .rateLimit(let info):
                        // One bubble per warning STATE, not per message: a
                        // standing seven_day warning was re-announcing on every
                        // send (his live complaint 2026-08-13). The gate is
                        // shared with the relay path. Key by state, not a fixed
                        // string (reviewer #5 minor): a warning→rejected
                        // escalation inside ONE run must not be swallowed by
                        // the per-send one-shot set.
                        if rateGate.shouldAnnounce(info) {
                            notice("⏳ Plan usage warning — \(info.humanSummary). Heavy tasks may be throttled.",
                                   key: "ratelimit-\(info.dedupeKey)")
                        }
                    case .vaultProvenanceAlert(let line):
                        // App-authored: a forged byline or a cross-agent overwrite
                        // the vault diff caught. Keyed by the line so distinct
                        // alerts all show but an identical one doesn't repeat.
                        notice(line, key: "prov-\(line)")
                    case .egressDenied(let host, let port):
                        // The egress fence refused a CONNECT — a fenced agent's
                        // process tried a non-allowlisted host (or an odd port
                        // on an allowed one). Visible, keyed per host so a
                        // retry loop doesn't flood the thread. Known claude-
                        // runtime telemetry (pypi/Datadog, phoned on EVERY run)
                        // is suppressed: blocked all the same, but a note per
                        // send would bury the real signal.
                        if !EgressProxy.isRuntimeNoise(host: host) {
                            notice("🚧 egress denied: this fenced teammate's run tried to reach \(host):\(port) — the network fence refused it.",
                                   key: "egress-\(host)")
                        }
                    default: break
                    }
                }
            } catch is CancellationError {
                // ⏹ Stop pressed — keep the partial, label it honestly.
                let partial = streaming[name] ?? ""
                final = partial.isEmpty ? "" : partial + "\n\n⏹ (stopped here)"
            } catch {
                // Keep whatever streamed before the failure — 2,000 tokens of
                // partial answer beats a bare error line (review #1 minor).
                let partial = streaming[name] ?? ""
                final = partial.isEmpty ? "⚠️ session error: \(error.localizedDescription)"
                                        : partial + "\n\n⚠️ session error: \(error.localizedDescription)"
            }
            if final.isEmpty { final = streaming[name] ?? "" }
            // Onboarding interview (his design): a PROFILE block ends interview
            // mode. Strip it from what Lorenzo reads — it's bookkeeping.
            applyInterviewResult(final, from: name)
            // Answer cards ride the reply as OPTION: lines — captured for the
            // UI, then stripped so the chat reads like a conversation.
            let unconfigured = roster.agents.first { $0.name == name }?.onboarded == false
            interviewOptions[name] = unconfigured ? InterviewOptions.parse(final) : nil
            if interviewOptions[name]?.isEmpty == false {
                notify(name, "is asking you a question")
                refreshBadge()
            }
            final = InterviewOptions.strip(ProfileDirective.strip(final))
            if !final.isEmpty {
                let reply = ChatMessage(author: name, kind: .agent, text: final)
                try? log.append(reply, thread: name)
                messages[name, default: []].append(reply)
                if selected != name { unread.insert(name) }
                notify(name, final)
                refreshBadge()
            }
            // Pass-through relays: a "RELAY @name: …" line in the reply is
            // executed by the app — the defer's drainQueues() delivers it as
            // soon as both sessions are free.
            processRelayDirectives(in: final, from: name, depth: depth)
            roster = (try? store.loadRoster()) ?? roster   // pick up new sessionID
        }
        sendTaskID = track(sendTask, threads: [name])
    }
}

/// A SwiftPM executable has no app bundle, so AppKit launches it as a background
/// process: the window appears but never takes focus and gets no menu bar.
/// Promoting to `.regular` makes `swift run AgencyApp` behave like a real app,
/// which the manual gates depend on.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AgencyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Agency") {
            VStack(spacing: 0) {
                if state.holdRestored, !state.queued.isEmpty {
                    HStack {
                        Image(systemName: "tray.full")
                        Text("\(state.queued.totalCount) message\(state.queued.totalCount == 1 ? "" : "s") queued from your last session — waiting for your go.")
                            .font(.callout)
                        Spacer()
                        Button("Deliver") { state.deliverRestored() }
                            .keyboardShortcut(.defaultAction)
                        Text("(or remove them with ✕ in their threads)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.yellow.opacity(0.15))
                }
                NavigationSplitView {
                    SidebarView(state: state)
                } detail: {
                    if let sel = state.selected {
                        ThreadView(state: state, thread: sel)
                    } else {
                        Text("Create an agent to begin").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: 720, minHeight: 480)
        }
    }
}
