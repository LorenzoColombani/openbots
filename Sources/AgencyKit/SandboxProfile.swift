import Foundation

/// macOS Seatbelt (`sandbox-exec`) profile for a SHELL-granted agent's run
/// (security round 2, his call 2026-08-13: FILESYSTEM fence — protect the
/// current roster without breaking it; the network fence can't fence a browser
/// agent and was deferred).
///
/// Why shell needs this: `--add-dir` fences the Read/Write/Edit TOOLS, but NOT
/// Bash. A shell-granted agent tricked by injected content could `rm`/`sed -i`
/// the provenance ledger (review C1), read Lorenzo's `~/.ssh`, or write into
/// another agent's folder — none of which the tool fence stops.
///
/// Design: "allow by default, deny the crown jewels" — NOT a full allowlist jail.
/// A jail would need to enumerate everything claude + Chromium + Homebrew tools
/// touch and would break the moment one path was missed (and re-break the transcript-grep
/// grep that shell exists FOR). Instead we carve out just what matters:
///   - no WRITES anywhere under the agency root except the agent's own dir + the
///     vault + shared/ (closes ledger/roster/cross-agent tampering — review C1);
///   - no WRITES to code-execution injection paths outside the root that Bash
///     could otherwise reach — hooks/skills/CLAUDE.md/settings under ~/.claude,
///     shell login scripts, ~/Library/LaunchAgents (review round 2, Important 1).
/// Everything else — reading transcripts anywhere, writing temp, driving a
/// browser profile, running brew tools — stays allowed, so legit work is intact.
///
/// NOT fenced (deliberate, bisected live 2026-08-13): credential READS. Denying
/// `~/Library/Keychains` BREAKS claude's own auth — its OAuth token lives in the
/// Keychain — so a shell agent can still read secrets. That is bounded by the
/// EGRESS residual: reading a secret is only harmful if it can leave, and the
/// egress fence (browser/network) is the deferred piece. Documented, not hidden.
public enum SandboxProfile {
    /// Seatbelt evaluates rules top-to-bottom, LAST match wins — so the allow-
    /// backs after the root deny must come after it.
    ///
    /// `deniedPockets` (vault pockets spec 2026-08-13): paths sealed BOTH ways
    /// (file-read* + file-write*) for this run — other agents' folders, other
    /// agents' vault/private/ pockets, and non-member vault/teams/ pockets.
    /// Bash isn't bound by the settings deny rules, so the pocket fence needs
    /// this shell half too. Targeted paths only, always under the agency root —
    /// NEVER a credential store (a ~/Library/Keychains read-deny breaks
    /// claude's own auth, bisected live 2026-08-13).
    /// The network fence rules (egress spec 2026-08-13): outbound only to the
    /// allowlist proxy's OWN loopback port (fence review I3: `localhost:*`
    /// would open every local service — an ssh -D tunnel or dev proxy on
    /// loopback would have been a zero-effort bypass). Scoped to `(remote ip)`
    /// so unix-socket traffic (mDNSResponder, system services) is untouched;
    /// last-match-wins puts the loopback allow after the deny. `localhost`
    /// covers 127.0.0.1 AND ::1 (verified live by the fence reviewer).
    static func networkSection(proxyPort: UInt16) -> String {
        """
        ; --- network egress fence (spec 2026-08-13): outbound only to the run's
        ; own allowlist proxy — no other road out, not even other loopback ports.
        (deny network-outbound (remote ip))
        (allow network-outbound (remote ip "localhost:\(proxyPort)"))
        """
    }

    /// Profile for a fenced NON-shell agent (nina/bruno class, and every
    /// fork): no Bash means the file fence is already structural — only the
    /// network needs Seatbelt.
    public static func networkOnly(proxyPort: UInt16) -> String {
        """
        (version 1)
        (allow default)
        \(networkSection(proxyPort: proxyPort))
        """
    }

    public static func seatbelt(root: String, agentDir: String, vault: String,
                                shared: String, home: String,
                                deniedPockets: [String] = [],
                                networkProxyPort: UInt16? = nil) -> String {
        // Seatbelt matches the REAL path of a write target, so the profile MUST
        // use symlink-resolved paths, or a symlinked parent silently DEFEATS every
        // deny — a fail-OPEN fence, the worst outcome.
        func real(_ p: String) -> String { realPath(p) }
        func lit(_ p: String) -> String {
            "\"" + real(p).replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // Pocket denies must FOLLOW the vault allow-back (last-match-wins), or
        // the allow re-opens them. Sorted for a deterministic profile; the whole
        // section (header included) vanishes when there are no pockets to deny.
        let pocketSection = deniedPockets.isEmpty ? "" : """

        ; --- vault pockets (spec 2026-08-13): non-member pockets and other agents'
        ; folders, sealed both ways for THIS agent's run.
        """ + "\n" + deniedPockets.sorted()
            .map { "(deny file-read* file-write* (subpath \(lit($0))))" }
            .joined(separator: "\n")
        return """
        (version 1)
        (allow default)
        ; --- agency control plane: no writes under the root EXCEPT the agent's own
        ; folder, the vault, and shared/ — closes ledger/roster/cross-agent tampering.
        (deny file-write* (subpath \(lit(root))))
        (allow file-write* (subpath \(lit(agentDir))))
        (allow file-write* (subpath \(lit(vault))))
        (allow file-write* (subpath \(lit(shared))))\(pocketSection)
        ; --- code-execution injection paths (review round 2, Important 1): Bash is
        ; NOT bound by claude's Read/Edit deny rules, so a tricked shell agent could
        ; plant a hook / skill / CLAUDE.md / login script that then RUNS in Lorenzo's
        ; own Claude sessions and every future agent run. Deny writes to the specific
        ; config/startup paths claude does NOT write at runtime (bisected live — it
        ; writes ~/.claude/projects, todos, statsig, which stay allowed).
        (deny file-write* (subpath \(lit(home + "/.claude/skills"))))
        (deny file-write* (subpath \(lit(home + "/.claude/plugins"))))
        (deny file-write* (subpath \(lit(home + "/.claude/hooks"))))
        (deny file-write* (literal \(lit(home + "/.claude/settings.json"))))
        (deny file-write* (literal \(lit(home + "/.claude/settings.local.json"))))
        (deny file-write* (literal \(lit(home + "/.claude/CLAUDE.md"))))
        (deny file-write* (subpath \(lit(home + "/Library/LaunchAgents"))))
        (deny file-write* (literal \(lit(home + "/.zshrc"))))
        (deny file-write* (literal \(lit(home + "/.zprofile"))))
        (deny file-write* (literal \(lit(home + "/.bashrc"))))
        (deny file-write* (literal \(lit(home + "/.bash_profile"))))
        (deny file-write* (literal \(lit(home + "/.profile"))))
        """ + (networkProxyPort.map { "\n" + networkSection(proxyPort: $0) } ?? "")
    }

    /// Symlink-resolved path via libc realpath(3) — NOT
    /// URL.resolvingSymlinksInPath(), which does NOT resolve /var → /private/var
    /// (verified live 2026-08-13: it left the fence wide open under mktemp's
    /// /var/folders paths). realpath needs the path to exist, so a missing leaf
    /// (e.g. shared/) resolves via its deepest existing ancestor. Shared with
    /// AgentStore.pocketDenyRules — every fence path resolves the same way.
    static func realPath(_ p: String) -> String {
        if let r = realpath(p, nil) { defer { free(r) }; return String(cString: r) }
        let url = URL(fileURLWithPath: p)
        let parent = url.deletingLastPathComponent().path
        guard parent != p, !parent.isEmpty else { return p }
        // appendingPathComponent avoids the "//r" double-slash at the root.
        return (realPath(parent) as NSString).appendingPathComponent(url.lastPathComponent)
    }

    /// The system Seatbelt binary. Present on every macOS; a shell run must FAIL
    /// CLOSED (never launch unsandboxed) if it is somehow missing.
    public static let sandboxExec = "/usr/bin/sandbox-exec"

    public static var available: Bool {
        FileManager.default.isExecutableFile(atPath: sandboxExec)
    }
}
