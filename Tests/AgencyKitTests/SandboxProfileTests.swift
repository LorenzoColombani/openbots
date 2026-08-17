import XCTest
@testable import AgencyKit

/// Security round 2 (his call 2026-08-13): FILESYSTEM fence for shell-granted
/// agents. `--add-dir` fences the file TOOLS but not Bash, so a Seatbelt profile
/// stops a tricked shell agent tampering with the control plane or reading
/// credential stores — without breaking legit grep/browser work.
final class SandboxProfileTests: XCTestCase {
    private func profile(denied: [String] = []) -> String {
        SandboxProfile.seatbelt(root: "/r/agency", agentDir: "/r/agency/agents/alfredo",
                                vault: "/r/agency/vault", shared: "/r/agency/shared",
                                home: "/Users/x", deniedPockets: denied)
    }

    func testControlPlaneWritesDeniedExceptOwnDirVaultShared() {
        let p = profile()
        XCTAssertTrue(p.contains("(deny file-write* (subpath \"/r/agency\"))"),
                      "no writes under the agency root by default — closes ledger/roster tampering")
        XCTAssertTrue(p.contains("(allow file-write* (subpath \"/r/agency/agents/alfredo\"))"))
        XCTAssertTrue(p.contains("(allow file-write* (subpath \"/r/agency/vault\"))"))
        XCTAssertTrue(p.contains("(allow file-write* (subpath \"/r/agency/shared\"))"))
    }

    func testRootDenyPrecedesAllowBacks() {
        // Seatbelt is last-match-wins: the allow-backs are meaningless unless they
        // come AFTER the root deny.
        let p = profile()
        let deny = p.range(of: "(deny file-write* (subpath \"/r/agency\"))")!.lowerBound
        let allow = p.range(of: "(allow file-write* (subpath \"/r/agency/agents/alfredo\"))")!.lowerBound
        XCTAssertLessThan(deny, allow, "root deny must precede the own-dir allow-back")
    }

    func testNoReadDeniesOutsideTheRootSoClaudeAuthSurvives() {
        // Bisected live 2026-08-13: denying ~/Library/Keychains breaks claude's
        // own OAuth (its token lives in the Keychain). Vault pockets introduced
        // TARGETED read-denies, but only ever on paths under the agency root —
        // credential reads stay allowed (a documented residual bounded by the
        // egress fence). Invariant: every file-read* deny targets a root subpath.
        XCTAssertFalse(profile().contains("file-read*"),
                       "no pockets → no read-denies at all")
        let p = profile(denied: ["/r/agency/vault/private/b", "/r/agency/vault/teams/ops"])
        for line in p.split(separator: "\n") where line.contains("file-read*") {
            XCTAssertTrue(line.contains("\"/r/agency/"),
                          "read-deny outside the agency root — claude-auth hazard: \(line)")
        }
        XCTAssertFalse(p.contains("Keychains"), "never a credential store")
    }

    // MARK: vault pockets (spec 2026-08-13 — the shell half of the pocket fence)

    func testPocketDeniesFollowTheVaultAllowBack() {
        // Seatbelt is last-match-wins: the vault allow-back would re-open a
        // pocket unless its deny comes AFTER.
        let p = profile(denied: ["/r/agency/vault/private/b", "/r/agency/vault/teams/ops"])
        let allow = p.range(of: "(allow file-write* (subpath \"/r/agency/vault\"))")!.lowerBound
        let denyPriv = p.range(of: "(deny file-read* file-write* (subpath \"/r/agency/vault/private/b\"))")!.lowerBound
        let denyTeam = p.range(of: "(deny file-read* file-write* (subpath \"/r/agency/vault/teams/ops\"))")!.lowerBound
        XCTAssertLessThan(allow, denyPriv, "pocket deny must FOLLOW the vault allow-back")
        XCTAssertLessThan(allow, denyTeam)
    }

    /// INTEGRATION: real sandbox-exec — a denied pocket is sealed both ways
    /// (read AND write), while the agent's own private pocket and its member
    /// team pocket stay writable through the vault allow-back.
    func testSeatbeltEnforcesPocketDenies() throws {
        guard SandboxProfile.available else { throw XCTSkip("sandbox-exec unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sbxpkt-\(UUID().uuidString)")
        let vault = root.appendingPathComponent("vault")
        let mine = vault.appendingPathComponent("private/me")
        let theirs = vault.appendingPathComponent("private/other")
        let myTeam = vault.appendingPathComponent("teams/kitchen")
        let notMyTeam = vault.appendingPathComponent("teams/ops")
        let otherAgent = root.appendingPathComponent("agents/other")
        for d in [mine, theirs, myTeam, notMyTeam, otherAgent,
                  root.appendingPathComponent("agents/me")] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try "their secret".write(to: theirs.appendingPathComponent("s.md"), atomically: true, encoding: .utf8)
        try "their notebook".write(to: otherAgent.appendingPathComponent("memory.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let p = SandboxProfile.seatbelt(
            root: root.path, agentDir: root.appendingPathComponent("agents/me").path,
            vault: vault.path, shared: root.appendingPathComponent("shared").path,
            home: NSHomeDirectory(),
            deniedPockets: [theirs.path, notMyTeam.path, otherAgent.path])
        func run(_ cmd: String) -> Int32 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: SandboxProfile.sandboxExec)
            proc.arguments = ["-p", p, "/bin/bash", "-c", cmd]
            proc.standardError = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            try? proc.run(); proc.waitUntilExit(); return proc.terminationStatus
        }
        XCTAssertEqual(run("echo x > \(mine.path)/note.md"), 0, "own private pocket writable")
        XCTAssertEqual(run("echo x > \(myTeam.path)/note.md"), 0, "member team pocket writable")
        XCTAssertNotEqual(run("echo x > \(theirs.path)/evil.md"), 0, "other's private pocket write BLOCKED")
        XCTAssertNotEqual(run("cat \(theirs.path)/s.md"), 0, "other's private pocket read BLOCKED")
        XCTAssertNotEqual(run("echo x > \(notMyTeam.path)/evil.md"), 0, "non-member team write BLOCKED")
        XCTAssertNotEqual(run("cat \(notMyTeam.path)/anything 2>/dev/null; ls \(notMyTeam.path)"), 0,
                          "non-member team read BLOCKED")
        XCTAssertNotEqual(run("cat \(otherAgent.path)/memory.md"), 0, "other agent's folder read BLOCKED")
    }

    /// INTEGRATION for the full-audit credential seal (2026-08-13): a shell
    /// agent's Bash must not be able to read the token/secret stores — driven
    /// through REAL sandbox-exec, not asserted on profile text. Uses a temp
    /// stand-in for the stores (same subpath mechanics; the deny is
    /// path-based) so the test never touches Lorenzo's actual tokens.
    func testSeatbeltSealsCredentialStores() throws {
        guard SandboxProfile.available else { throw XCTSkip("sandbox-exec unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sbxcred-\(UUID().uuidString)")
        let secrets = root.appendingPathComponent(".secrets")
        let tokens = root.appendingPathComponent("fake-google-tokens")
        for d in [secrets, tokens, root.appendingPathComponent("agents/me"),
                  root.appendingPathComponent("vault")] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try "oauth-client".write(to: secrets.appendingPathComponent("c.json"), atomically: true, encoding: .utf8)
        try "refresh-token".write(to: tokens.appendingPathComponent("t.json"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        func profile(denying: [String]) -> String {
            SandboxProfile.seatbelt(
                root: root.path, agentDir: root.appendingPathComponent("agents/me").path,
                vault: root.appendingPathComponent("vault").path,
                shared: root.appendingPathComponent("shared").path,
                home: NSHomeDirectory(), deniedPockets: denying)
        }
        func cat(_ file: URL, under p: String) -> Int32 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: SandboxProfile.sandboxExec)
            proc.arguments = ["-p", p, "/bin/cat", file.path]
            proc.standardError = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            try? proc.run(); proc.waitUntilExit(); return proc.terminationStatus
        }

        // POSITIVE CONTROL first (audit review minor: without it, cat failing
        // for an unrelated reason — bad path, broken profile — would pass the
        // deny assertions vacuously).
        let open = profile(denying: [])
        XCTAssertEqual(cat(secrets.appendingPathComponent("c.json"), under: open), 0,
                       "cat must work under the profile when nothing denies it")

        let sealed = profile(denying: [secrets.path, tokens.path])
        XCTAssertNotEqual(cat(secrets.appendingPathComponent("c.json"), under: sealed), 0,
                          "the OAuth client must be unreadable from Bash")
        XCTAssertNotEqual(cat(tokens.appendingPathComponent("t.json"), under: sealed), 0,
                          "the refresh tokens must be unreadable from Bash")

        // The google-agent shape: tokens NOT in the denied list (its server
        // reads them), .secrets still sealed.
        let google = profile(denying: [secrets.path])
        XCTAssertEqual(cat(tokens.appendingPathComponent("t.json"), under: google), 0,
                       "a google agent's child server must still read its tokens")
        XCTAssertNotEqual(cat(secrets.appendingPathComponent("c.json"), under: google), 0,
                          ".secrets stays sealed even for the google agent")
    }

    func testAllowDefaultBaseSoLegitWorkIsIntact() {
        // "allow default" base is what keeps grep/ffmpeg/Chromium/temp working —
        // this is a crown-jewels deny list, not a full allowlist jail.
        XCTAssertTrue(profile().contains("(allow default)"))
    }

    func testSandboxExecIsTheSystemBinary() {
        XCTAssertEqual(SandboxProfile.sandboxExec, "/usr/bin/sandbox-exec")
    }

    /// INTEGRATION: generate the profile for a real temp root and confirm
    /// `sandbox-exec` actually enforces it. A pure string test can't catch the
    /// resolution bug that shipped once — it compared buggy output to a buggy
    /// expectation and passed while the fence was wide open. This runs Seatbelt
    /// for real (no claude, fast). It is the fence's true regression guard.
    func testSeatbeltActuallyEnforcesTheProfile() throws {
        guard SandboxProfile.available else { throw XCTSkip("sandbox-exec unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sbxint-\(UUID().uuidString)")
        let agentDir = root.appendingPathComponent("agents/probe")
        let vault = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let ledger = root.appendingPathComponent(".provenance.jsonl")
        try "seed".write(to: ledger, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let profile = SandboxProfile.seatbelt(
            root: root.path, agentDir: agentDir.path, vault: vault.path,
            shared: root.appendingPathComponent("shared").path, home: NSHomeDirectory())
        func run(_ cmd: String) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: SandboxProfile.sandboxExec)
            p.arguments = ["-p", profile, "/bin/bash", "-c", cmd]
            p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit(); return p.terminationStatus
        }
        XCTAssertEqual(run("echo ok > \(vault.path)/x"), 0, "a vault write must be ALLOWED")
        XCTAssertEqual(run("echo ok > \(agentDir.path)/w"), 0, "the agent's own dir must be ALLOWED")
        XCTAssertNotEqual(run("echo tamper >> \(ledger.path)"), 0, "the ledger write must be BLOCKED")
        XCTAssertNotEqual(run("rm -f \(ledger.path)"), 0, "the ledger delete must be BLOCKED")
        XCTAssertEqual(try String(contentsOf: ledger, encoding: .utf8), "seed", "ledger untouched")
    }

    /// review round 2, issue 1: code-execution injection paths OUTSIDE the root
    /// (~/.claude config, shell rc, LaunchAgents) must be write-denied too — Bash
    /// isn't bound by claude's tool rules. Uses a FAKE home (not the real ~/.claude).
    func testSeatbeltDeniesConfigInjectionPaths() throws {
        guard SandboxProfile.available else { throw XCTSkip("sandbox-exec unavailable") }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sbxcfg-\(UUID().uuidString)")
        let root = base.appendingPathComponent("agency")
        let fakeHome = base.appendingPathComponent("home")     // sibling of root, NOT under it
        try FileManager.default.createDirectory(at: root.appendingPathComponent("agents/probe"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeHome.appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeHome.appendingPathComponent("Library/LaunchAgents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let profile = SandboxProfile.seatbelt(
            root: root.path, agentDir: root.appendingPathComponent("agents/probe").path,
            vault: root.appendingPathComponent("vault").path,
            shared: root.appendingPathComponent("shared").path, home: fakeHome.path)
        func run(_ cmd: String) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: SandboxProfile.sandboxExec)
            p.arguments = ["-p", profile, "/bin/bash", "-c", cmd]
            p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit(); return p.terminationStatus
        }
        let h = fakeHome.path
        XCTAssertNotEqual(run("echo x >> \(h)/.claude/skills/evil.md"), 0, "planting a skill BLOCKED")
        XCTAssertNotEqual(run("echo x > \(h)/.claude/settings.json"), 0, "settings.json BLOCKED")
        XCTAssertNotEqual(run("echo x > \(h)/.claude/CLAUDE.md"), 0, "CLAUDE.md BLOCKED")
        XCTAssertNotEqual(run("echo x >> \(h)/.zshrc"), 0, "shell rc BLOCKED")
        XCTAssertNotEqual(run("echo x > \(h)/Library/LaunchAgents/evil.plist"), 0, "LaunchAgent BLOCKED")
        // A non-config file in home is still writable — this is a crown-jewels deny,
        // not a home jail (claude writes ~/.claude/projects etc. at runtime).
        XCTAssertEqual(run("echo x > \(h)/notes.txt"), 0, "a non-config home write is ALLOWED")
        XCTAssertEqual(run("echo x > \(h)/.claude/projects_ok"), 0, "non-denied ~/.claude paths ALLOWED")
    }
}
