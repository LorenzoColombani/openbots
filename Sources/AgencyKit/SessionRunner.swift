import Foundation

public final class SessionRunner {
    private let store: AgentStore
    private let process: ProcessRunning
    private let executable: String

    /// Where the `claude` binary can live. A bundled .app inherits no shell PATH,
    /// so these are checked on disk rather than resolved via `which`.
    static let claudeCandidates = [
        "\(NSHomeDirectory())/.local/bin/claude",        // native installer
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        "\(NSHomeDirectory())/.claude/local/claude",
    ]

    public static func resolveClaudePath() -> String {
        claudeCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? claudeCandidates[0]
    }

    // Process-wide count of live NON-FORKED runs (review I1). Provenance's ground
    // truth — "the agent that ran wrote these files" — holds only when one run
    // writes the vault at a time. The app serialises sends per THREAD, not
    // globally, so a relay and a direct send to a different agent can overlap.
    // When they do we still RECORD the writes but mark them `concurrent` so they
    // are never flagged — a false forgery accusation from ordinary two-agent use
    // would corrode the one thing the ledger is for.
    private static let runCountLock = NSLock()
    private static var liveNonForkedRuns = 0
    private static func enterRun() -> Bool {
        runCountLock.lock(); defer { runCountLock.unlock() }
        liveNonForkedRuns += 1
        return liveNonForkedRuns > 1
    }
    private static func exitRun() {
        runCountLock.lock(); liveNonForkedRuns -= 1; runCountLock.unlock()
    }
    private static func runsContended() -> Bool {
        runCountLock.lock(); defer { runCountLock.unlock() }
        return liveNonForkedRuns > 1
    }

    private let pending: PendingContext
    /// Injectable so the FAIL-CLOSED refusal (a shell agent must never run when
    /// the sandbox is unavailable) is actually testable (review round 2, issue 5).
    private let sandboxAvailable: () -> Bool
    /// Starts the egress allowlist proxy for a FENCED run and returns its port
    /// plus a stopper. Injectable (like sandboxAvailable) so the fail-closed
    /// path — a fenced run must NEVER launch unfenced — is testable without
    /// breaking a real listener. The callback carries (host, port) — review M8.
    private let startEgressProxy: (@escaping @Sendable (String, UInt16) -> Void) throws -> (port: UInt16, stop: () -> Void)

    public init(store: AgentStore, process: ProcessRunning = ClaudeProcessRunner(),
                sandboxAvailable: @escaping () -> Bool = { SandboxProfile.available },
                startEgressProxy: ((@escaping @Sendable (String, UInt16) -> Void) throws -> (port: UInt16, stop: () -> Void))? = nil) {
        self.store = store
        self.process = process
        self.executable = Self.resolveClaudePath()
        self.pending = PendingContext(store: store)
        self.sandboxAvailable = sandboxAvailable
        self.startEgressProxy = startEgressProxy ?? { onDeny in
            let proxy = EgressProxy(onDeny: onDeny)
            let port = try proxy.start()
            return (port, { proxy.stop() })
        }
    }

    public static func arguments(for agent: Agent, prompt: String, vaultPath: String,
                                 forked: Bool = false) -> [String] {
        var args = ["-p"]
        if let sid = agent.sessionID {
            args += ["--resume", sid]
            // A fork copies the session's history into a NEW session id — the
            // parallel subagent path. Without a sid there is nothing to fork
            // and the flag is meaningless.
            if forked { args += ["--fork-session"] }
        }
        args += ["--output-format", "stream-json", "--include-partial-messages", "--verbose",
                 "--add-dir", vaultPath, "--permission-mode", "acceptEdits"]
        // Fencing, both halves (review #4 C2): --allowedTools only PRE-APPROVES
        // (it does not restrict what exists); --disallowedTools actually removes
        // the tool from the agent's context. Belt-and-braces with the bare
        // "Bash" deny rule in the per-agent settings.
        // Granted connectors add their mcp__<server> pre-approvals — required
        // headlessly, where permission prompts auto-deny.
        var tools = agent.allowedTools ?? AgentStore.defaultAllowedTools
        var disallowed = AgentStore.agentDisallowedTools
        for id in agent.connectors ?? [] {
            guard let connector = Connector.byID(id) else { continue }
            tools += connector.allowedTools
            // A connector may supersede one tool of a third-party server (the
            // iMessage extension's iMessage-only sender). Removing it from
            // context beats un-approving it: the agent never sees a name it
            // would otherwise reach for. Deny wins over the whole-server allow
            // of any OTHER granted connector too, which is the point.
            for t in connector.disallowedTools where !disallowed.contains(t) {
                disallowed.append(t)
            }
        }
        if forked {
            // Grok Bot's READONLY per-run mode, adopted: a fork answers in
            // PARALLEL with the main run — two unlocked writers on the same
            // vault files is a last-writer-wins race (reviewer #5 Important).
            // Forks read, search, and answer; writes wait their turn.
            // NotebookEdit/MultiEdit too (reviewer #6): they exist in the CLI's
            // context regardless of --allowedTools, and acceptEdits would
            // auto-approve them — a notebook edit is still a write.
            tools.removeAll { $0 == "Write" || $0 == "Edit" || $0.hasPrefix("mcp__") }
            // NotebookEdit/MultiEdit are in the BASE disallowed set since pocket
            // review I1 — append only what's missing so the CSV carries no dupes.
            for t in ["Write", "Edit", "NotebookEdit", "MultiEdit"] where !disallowed.contains(t) {
                disallowed.append(t)
            }
        }
        if agent.shell == true, !forked {
            // Shell is a GRANT (his order 2026-08-13, after a sealed agent
            // couldn't grep a research project's transcripts): grep/awk/ffmpeg/Homebrew
            // for agents whose job needs them. The settings-side deny is
            // lifted by the same grant (writeAgentSettingsUnlocked).
            tools.append("Bash")
            disallowed.removeAll { $0 == "Bash" }
        }
        if agent.web == true, !forked {
            // Web is a GRANT (security round 2026-08-13, his call): WebSearch +
            // WebFetch are an EGRESS path, off by default. Granted, both fence
            // halves lift together (this arg + the durable deny rule). NOT on
            // forks: a read-only parallel run stays purely local — no new door
            // out of the machine while the main run holds the session.
            for t in ["WebSearch", "WebFetch"] where !tools.contains(t) { tools.append(t) }
            disallowed.removeAll { $0 == "WebSearch" || $0 == "WebFetch" }
        }
        // Make the seal structural (review I2): a legacy roster row's stored
        // allowedTools can still name web/Bash from before those became grants,
        // and only deny-beats-allow was keeping them out. Drop anything that's
        // disallowed from the pre-approval list so a sealed agent's fence holds
        // by CONSTRUCTION, not by an ordering accident on the command line.
        tools.removeAll { disallowed.contains($0) }
        if !tools.isEmpty { args += ["--allowedTools", tools.joined(separator: ",")] }
        args += ["--disallowedTools", disallowed.joined(separator: ",")]
        // Connectors spec: teammates NEVER inherit Lorenzo's user-scope/plugin
        // MCP config — strict on every invocation, grants or not. The mcp.json
        // path is relative on purpose: cwd IS the agent's folder. Forks skip
        // connectors: read-only runs don't drive browsers.
        if !(agent.connectors ?? []).isEmpty, !forked {
            args += ["--mcp-config", ".claude/mcp.json"]
        }
        args += ["--strict-mcp-config"]
        if let model = agent.model { args += ["--model", model] }
        // "--" pins the prompt as a positional (review I4): without it a message
        // beginning with "-" is parsed as a flag by the claude CLI.
        args += ["--", prompt]
        return args
    }

    /// `forked: true` runs the message on a COPY of the agent's session
    /// (--fork-session) as a parallel subagent. A fork must leave the main
    /// session completely untouched: no session-id writes, no rollover retry
    /// (a failed fork must never clear the MAIN session's id), no pending
    /// handoff consumption (that context belongs to the main session's next
    /// turn), and no session lock (the main run legitimately holds it — the
    /// fork only reads the transcript once at launch and writes elsewhere).
    public func send(_ prompt: String, to agent: Agent,
                     forked: Bool = false) -> AsyncThrowingStream<StreamEvent, Error> {
        // Anything a teammate handed this agent rides along with this message, so
        // the agent actually HAS what its log says it received. Two-phase (review
        // C1): begin() stages, commit() clears ONLY after the send succeeded — a
        // failed launch no longer destroys the handoff payload.
        // ALL prompt assembly (fork preamble, clock, staged handoffs) happens
        // inside the task after the flock — see audit I4 below.
        // pending.begin() moved INSIDE the task, after the flock (coordination
        // audit I4): staging out here let the app and the CLI, sending to the
        // same agent near-simultaneously, both read the pending notes before
        // either committed — the same handoff payload injected twice. The
        // flock serialises the runs; staging must sit behind it too.
        // The vault can be recreated if it ever goes missing — --add-dir with a
        // dead path would otherwise ride along on every send (review Minor 8).
        try? FileManager.default.createDirectory(at: store.vaultURL, withIntermediateDirectories: true)

        let cwd = store.agentDir(agent.name)
        let store = self.store
        let pending = self.pending
        let process = self.process
        let executable = self.executable
        let vaultPath = store.vaultURL.path
        let name = agent.name
        let finalPrompt = prompt
        let sandboxAvailable = self.sandboxAvailable
        return AsyncThrowingStream { continuation in
            let task = Task {
                // ONE live process per session, enforced across PROCESSES too:
                // the app's busy-guard covers its own sends, but the app and
                // agency-cli running together could still resume one session
                // twice. flock on a per-agent lock file serialises them —
                // LOCK_NB + sleep so no cooperative thread ever blocks.
                let lockPath = cwd.appendingPathComponent(".session.lock").path
                try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
                let lockFD = forked ? -1 : open(lockPath, O_CREAT | O_RDWR, 0o644)
                if lockFD < 0 && !forked {
                    fputs("agency: WARNING cannot open \(lockPath) (errno \(errno)) — session lock degraded\n", stderr)
                }
                if lockFD >= 0 {
                    var lockWaitNotified = false
                    let lockWaitStart = Date()
                    while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
                        // Only EWOULDBLOCK means "someone holds it" — anything else
                        // (EOPNOTSUPP on an exotic FS…) would spin forever at 5 Hz.
                        guard errno == EWOULDBLOCK else {
                            fputs("agency: WARNING flock failed (errno \(errno)) — session lock degraded\n", stderr)
                            break
                        }
                        if Task.isCancelled { break }
                        // Item-6 debt: >10s behind another run of the SAME
                        // teammate looked like an unexplained stall — say so once.
                        if !lockWaitNotified, Date().timeIntervalSince(lockWaitStart) > 10 {
                            lockWaitNotified = true
                            continuation.yield(.lockWaiting)
                        }
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                }
                defer { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
                // Cancelled while waiting for the lock? Do NOT launch: the builder
                // spawns a real process eagerly, and it would run without the lock
                // this loop exists to hold (review #4 I-3).
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                    return
                }

                // Handoff staging — behind the flock (audit I4, see above).
                let staged = forked ? nil : pending.begin(for: name)
                var finalPrompt = finalPrompt
                if let handed = staged {
                    finalPrompt = """
                    \(handed)---

                    \(finalPrompt)
                    """
                }
                // Agents have NO CLOCK (coordinator's vault report 2026-08-13:
                // sealed agents can't run `date`, so they INVENTED frontmatter
                // timestamps). Every run learns the real time up front.
                let clock = ISO8601DateFormatter()
                clock.timeZone = TimeZone.current
                clock.formatOptions = [.withInternetDateTime]
                finalPrompt = "[Context: the current date-time is \(clock.string(from: Date())) — use it for any timestamp you write.]\n\n"
                    + finalPrompt
                if forked {
                    // FIRST line, always — the persona on disk still teaches
                    // vault-writing (and possibly shell); without this
                    // preamble a fork burns turns attempting writes and
                    // reporting failures (reviewer #6 minor).
                    finalPrompt = """
                    [Read-only subagent run: file writing, editing, shell, and web are \
                    disabled for this turn — answer from reading and searching the local \
                    vault and workspace only. Do not apologize for this; just answer.]

                    \(finalPrompt)
                    """
                }

                // One roster read per run (vault pockets): feeds the sandbox's
                // pocket denies AND the team-aware provenance alert filter.
                let rosterAtLaunch = (try? store.loadRoster()) ?? Roster()

                // Vault provenance (security round 2026-08-13): snapshot the
                // vault just before the run, diff after it ends, and record every
                // write as authored by THIS agent — the one fact the child cannot
                // forge. Forks write nothing, so they're skipped. Concurrency
                // (review I1) is tracked so overlapping runs don't mis-attribute.
                let provenance = forked ? nil : VaultProvenance(rootURL: store.rootURL)
                let vaultBefore = provenance?.snapshot()
                let contendedAtStart = provenance != nil ? Self.enterRun() : false
                defer { if provenance != nil { Self.exitRun() } }
                // Commit once, at the run's terminal point — success OR failure
                // (review M5): a run that wrote files and then errored must not
                // leave those writes unrecorded (the next run's snapshot would
                // already contain them, hiding the write forever).
                func commitProvenance() {
                    guard let provenance, let vaultBefore else { return }
                    let contended = contendedAtStart || Self.runsContended()
                    let records = provenance.commit(previous: vaultBefore, by: name,
                                                    now: Date(), concurrent: contended)
                    let teams = rosterAtLaunch.teams ?? []
                    for r in records {
                        // A write inside a pocket the agent doesn't own is a
                        // fence breach even with no history (review I2 — a NEW
                        // file has previousAgent nil and no rewrite flag fires).
                        if VaultProvenance.isPocketBreach(r, teams: teams) {
                            continuation.yield(.vaultProvenanceAlert(VaultProvenance.pocketBreachAlert(r)))
                        // Team pockets are multi-writer by design — a member
                        // editing a fellow member's note must not raise a
                        // forgery-class alert (the record stays in the ledger;
                        // only the ALERT is filtered).
                        } else if r.isSuspicious,
                                  !VaultProvenance.isTeamCollaboration(r, teams: teams) {
                            continuation.yield(.vaultProvenanceAlert(r.humanAlert))
                        }
                    }
                }

                // Fence selection (filesystem: security round 2 · network:
                // egress spec 2026-08-13). A SHELL-granted agent's Bash is not
                // fenced by --add-dir → file profile. A run with no sanctioned
                // road to the open network (no web, no WIRED needsNetwork
                // connector, or any FORK) → network fence: Seatbelt denies all
                // non-proxy egress and the loopback allowlist proxy is the
                // only way out.
                let networkFenced = agent.isNetworkFenced(forked: forked)
                let fileFenced = agent.shell == true && !forked
                // Apple Events vs Seatbelt (verified live 2026-08-13): ANY
                // sandbox wrapper makes AppleScript fail with "privilege
                // violation (-10004)", because a sandboxed process cannot be
                // the TCC responsible process. No profile rule fixes it. So
                // the conflict is resolved EXPLICITLY, never silently:
                //  · no shell → drop the wrapper (the file fence for a
                //    shell-less agent is the settings deny rules + --add-dir,
                //    which still hold; the network fence keeps its proxy env,
                //    and a shell-less agent has no way to unset it);
                //  · WITH shell → keep the wrapper. The file fence and the
                //    vault pockets depend on it, and no connector is worth
                //    trading those away — the tools simply won't work, and we
                //    say so in the thread instead of failing cryptically.
                let appleEvents = !forked && agent.needsAppleEvents
                let skipSandbox = appleEvents && agent.shell != true
                if appleEvents, agent.shell == true {
                    continuation.yield(.runError(
                        "\(name) has both shell access and an AppleScript connector (iMessage/Notes/Mail/Office). "
                        + "macOS blocks AppleScript from sandboxed processes, and the sandbox is what fences a shell "
                        + "agent's files — so those tools will fail this run. Turn shell OFF for this teammate to use them."))
                }
                // Proxy FIRST (fence review I3): the Seatbelt allow is scoped
                // to the proxy's own port — `localhost:*` would have opened
                // every local service (an ssh -D tunnel = zero-effort bypass) —
                // so the profile needs the port before it can be built.
                // Fail CLOSED: no proxy → no fenced run. Every denial the
                // proxy makes surfaces live as a thread note.
                var proxyStop: (() -> Void)?
                var proxyEnv: [String: String] = [:]
                var proxyPort: UInt16?
                if networkFenced {
                    do {
                        let (port, stop) = try startEgressProxy { host, deniedPort in
                            continuation.yield(.egressDenied(host: host, port: deniedPort))
                        }
                        proxyStop = stop
                        proxyPort = port
                        let url = "http://127.0.0.1:\(port)"
                        // Upper+lowercase both: different HTTP stacks read
                        // different spellings. NO_PROXY emptied — an inherited
                        // exemption must not turn into a direct connect the
                        // Seatbelt half then kills.
                        proxyEnv = ["HTTPS_PROXY": url, "HTTP_PROXY": url,
                                    "https_proxy": url, "http_proxy": url,
                                    "NO_PROXY": "", "no_proxy": ""]
                    } catch {
                        continuation.yield(.runError(
                            "egress proxy failed to start — refusing to run fenced \(name) unfenced"))
                        continuation.finish()
                        return
                    }
                }
                defer { proxyStop?() }
                var sandboxProfile: String?
                switch (fileFenced, proxyPort) {
                case (true, let port):
                    sandboxProfile = SandboxProfile.seatbelt(
                        root: store.rootURL.path, agentDir: cwd.path, vault: vaultPath,
                        shared: store.rootURL.appendingPathComponent("shared").path,
                        home: NSHomeDirectory(),
                        deniedPockets: store.deniedPocketPaths(for: name, roster: rosterAtLaunch),
                        networkProxyPort: port)
                case (false, .some(let port)):
                    sandboxProfile = SandboxProfile.networkOnly(proxyPort: port)
                case (false, nil):
                    sandboxProfile = nil
                }
                if skipSandbox { sandboxProfile = nil }
                // Fail CLOSED (review C1): a fenced agent must NEVER run
                // unfenced. sandbox-exec ships with macOS — this only fires if
                // it's somehow gone. (The defer above stops the proxy.)
                if sandboxProfile != nil, !sandboxAvailable() {
                    continuation.yield(.runError(
                        "sandbox-exec unavailable — refusing to run \(name) without its fence"))
                    continuation.finish()
                    return
                }

                var attempt = agent
                var rolledOver = false
                while true {
                    let args = Self.arguments(for: attempt, prompt: finalPrompt,
                                              vaultPath: vaultPath, forked: forked)
                    // Sandboxed runs invoke `sandbox-exec -p <profile> claude …`;
                    // the profile is inherited by every Bash child of claude.
                    let (exec, runArgs): (String, [String]) = sandboxProfile.map {
                        (SandboxProfile.sandboxExec, ["-p", $0, executable] + args)
                    } ?? (executable, args)
                    let lines = process.runLines(executable: exec, arguments: runArgs, cwd: cwd,
                                                 extraEnvironment: proxyEnv)
                    let knownSID = attempt.sessionID
                    var sawEvent = false      // any session/result event this attempt
                    var sawResult = false
                    do {
                        for try await line in lines {
                            guard let event = StreamEvent.parse(line: line) else { continue }
                            // A fork's session ids belong to the throwaway copy —
                            // persisting one would hijack the MAIN conversation.
                            if case .resultText(_, let sid) = event {
                                sawEvent = true; sawResult = true
                                if !forked, sid != knownSID { try? store.setSessionID(sid, for: name) }
                            }
                            if case .sessionStarted(let sid) = event {
                                sawEvent = true
                                if !forked, knownSID == nil { try? store.setSessionID(sid, for: name) }
                            }
                            continuation.yield(event)
                        }
                        // Delivered = the process completed AND produced a result.
                        if staged != nil, sawResult { pending.commit(for: name) }
                        // Record what this run wrote (regardless of sawResult — a
                        // write is a write); suspicious ones surface as a thread
                        // note, the full history lands in the ledger regardless.
                        commitProvenance()
                        continuation.finish()
                        return
                    } catch {
                        // Session rollover (review #1 I4): the stored id points at a
                        // conversation claude no longer has. Preconditions (review #3
                        // I-1): only when this attempt actually RESUMED something
                        // (knownSID != nil) and died before any session/result event —
                        // stderr is a shared, inherited channel, so the phrase alone
                        // must never wipe a live conversation.
                        // Never on a fork: rollover clears the MAIN session's id,
                        // and a failed throwaway copy must not cost the original
                        // conversation.
                        if let failure = error as? ProcessFailure,
                           !forked, !rolledOver, knownSID != nil, !sawEvent,
                           failure.stderr.contains("No conversation found with session ID") {
                            rolledOver = true
                            try? store.clearSessionID(for: name)
                            attempt.sessionID = nil
                            let reason = failure.stderr
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .components(separatedBy: "\n").first ?? "session unresumable"
                            continuation.yield(.sessionRolledOver(reason: reason))
                            continue
                        }
                        // The run wrote files and then failed — record them before
                        // exiting (review M5), else they vanish from the ledger.
                        commitProvenance()
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            // Propagate consumer cancellation (review I1): without this, quitting
            // the app mid-stream leaves the inner task iterating and the claude
            // child running orphaned.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
