import Foundation
import AgencyKit

let args = CommandLine.arguments
let store = AgentStore(rootURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

/// Plain sentences instead of `agentExists("alfredo")` enum dumps.
func describe(_ error: Error) -> String {
    switch error {
    case AgencyError.agentExists(let n):   return "an agent named '\(n)' already exists"
    case AgencyError.agentNotFound(let n): return "no such agent: \(n)"
    case AgencyError.invalidName(let n):   return "invalid name '\(n)' — use 1-32 lowercase letters, digits, - or _"
    case AgencyError.teamExists(let n):    return "a team named '\(n)' already exists"
    case AgencyError.teamNotFound(let n):  return "no such team: \(n)"
    case AgencyError.teamFull(let n):      return "team '\(n)' is full — a team holds at most 6 members (Grok's cap, adopted)"
    case AgencyError.instructionsTooLong(let n):
        return "standing instructions are \(n) characters — the cap is \(AgentStore.maxInstructions)"
    case AgencyError.rosterNewerSchema(let v):
        return "roster.json was written by a NEWER agency build (schema \(v)) — update this binary (rebuild app + CLI together); overwriting would silently drop fields and unfence pockets"
    default:                               return "\(error)"
    }
}

func agent(_ name: String) throws -> Agent {
    guard let a = try store.loadRoster().agents.first(where: { $0.name == name }) else {
        fputs("no such agent: \(name)\n", stderr); exit(1)
    }
    return a
}

func run() async throws {
    switch args.count > 1 ? args[1] : "" {
    case "create" where args.count >= 5:
        let a = try store.createAgent(name: args[2], emoji: args[3],
                                      role: args[4...].joined(separator: " "))
        print("created \(a.emoji) \(a.name) — \(a.role)")

    case "chat" where args.count >= 4:
        let a = try agent(args[2])
        let runner = SessionRunner(store: store)
        let log = MessageLog(store: store)
        let text = args[3...].joined(separator: " ")
        try log.append(ChatMessage(author: "lorenzo", kind: .user, text: text), thread: a.name)
        var final = ""
        for try await e in runner.send(text, to: a) {
            switch e {
            case .textDelta(let t): print(t, terminator: ""); fflush(stdout)
            case .resultText(let r, _): final = r
            case .sessionRolledOver(let reason):
                // Attempt 1's partial output is abandoned — mark the boundary so
                // the retry's stream doesn't read as a continuation of it.
                print("")
                fputs("[\(a.name)] session rolled over (\(reason)) — retrying fresh\n", stderr)
            case .runError(let detail):
                fputs("[\(a.name)] run error: \(detail)\n", stderr)
            case .egressDenied(let host, let port):
                fputs("[\(a.name)] 🚧 egress denied: the run tried to reach \(host):\(port) — the network fence refused it\n", stderr)
            case .lockWaiting:
                fputs("[\(a.name)] ⏳ waiting for this teammate's other run (app or CLI) to finish…\n", stderr)
            default: break
            }
        }
        print("")
        try log.append(ChatMessage(author: a.name, kind: .agent, text: final), thread: a.name)
        // The CLI does not execute RELAY directives (the app does) — a silent
        // no-op would contradict what every persona teaches, so say so.
        for d in RelayDirective.parse(final) {
            fputs("[\(a.name)] RELAY @\(d.target) found — the CLI does not deliver relays; send this from the app.\n", stderr)
        }

    case "ask" where args.count >= 5:
        let asker = try agent(args[2]); let target = try agent(args[3])
        let broker = HandoffBroker(store: store, runner: SessionRunner(store: store),
                                   log: MessageLog(store: store))
        let reply = try await broker.relay(question: args[4...].joined(separator: " "),
                                           from: asker, to: target)
        print("\(target.name) → \(asker.name): \(reply)")

    case "roster":
        for a in try store.loadRoster().agents {
            print("\(a.emoji) \(a.name) — \(a.role) [model: \(a.model ?? "default") | session: \(a.sessionID ?? "none")]")
        }

    case "refresh" where args.count >= 3:
        // Regenerate persona + per-agent settings from the current template/policy
        // (migrates agents created before a policy change; memory untouched).
        try store.refreshAgentConfig(name: args[2])
        print("refreshed persona + settings for \(args[2])")

    case "connectors" where args.count == 3:
        let a = try agent(args[2])
        print("granted to \(a.name): \((a.connectors ?? []).joined(separator: ", ").isEmpty ? "(none)" : (a.connectors ?? []).joined(separator: ", "))")
        print("catalog: \(Connector.catalog.map(\.id).joined(separator: ", "))")

    case "shell" where args.count >= 4:
        // agency-cli shell <agent> on|off — grep/ffmpeg/Homebrew access.
        // Anything but the exact words is an error, not a silent revoke
        // (reviewer #6: "shell alfredo yes" was quietly sealing the agent).
        guard args[3] == "on" || args[3] == "off" else {
            fputs("shell: expected 'on' or 'off', got '\(args[3])'\n", stderr)
            exit(1)
        }
        let a = try store.setShell(args[3] == "on", for: args[2])
        print("shell for \(a.name): \(a.shell == true ? "GRANTED" : "sealed")")

    case "web" where args.count >= 4:
        // agency-cli web <agent> on|off — WebSearch + WebFetch (egress path,
        // grant-gated off by default, security round 2026-08-13). Same exact-
        // word discipline as shell: a typo must never silently seal or open web.
        guard args[3] == "on" || args[3] == "off" else {
            fputs("web: expected 'on' or 'off', got '\(args[3])'\n", stderr)
            exit(1)
        }
        let a = try store.setWeb(args[3] == "on", for: args[2])
        print("web for \(a.name): \(a.web == true ? "GRANTED" : "sealed")")

    case "display" where args.count >= 3:
        // agency-cli display <name> [new display name…] — empty clears.
        // Display-ONLY (his call): the handle never moves; renaming the folder
        // would orphan the claude session (= memory loss).
        let a = try store.updateAgent(name: args[2],
                                      displayName: args[3...].joined(separator: " "))
        print("display name for @\(a.name): \(a.displayName ?? "(cleared — shows as \(a.display))")")

    case "google-account" where args.count >= 3:
        // agency-cli google-account <address> — the dedicated agency account
        // whose Gmail/Calendar the granted teammates act as.
        try store.setGoogleAccount(args[2])
        let creds = GoogleCredentials.client(root: store.rootURL) != nil
        print("agency Google account: \(args[2])")
        print("OAuth client in .secrets/: \(creds ? "found ✓" : "MISSING — drop the downloaded client JSON there")")

    case "google-account":
        print("agency Google account: \(store.googleAccount() ?? "(not set)")")
        print("OAuth client in .secrets/: \(GoogleCredentials.client(root: store.rootURL) != nil ? "found ✓" : "missing")")

    case "library" where args.count >= 2:
        // agency-cli library [add <path> | update <skill> | list]
        // The agency's canonical skills (structure audit R6): grants still
        // COPY into each agent's fence, but a fix can be re-pushed.
        switch args.count > 2 ? args[2] : "list" {
        case "add" where args.count >= 4:
            try store.addToLibrary(from: URL(fileURLWithPath: args[3]))
            print("added to the library: \(URL(fileURLWithPath: args[3]).lastPathComponent)")
        case "update" where args.count >= 4:
            let touched = try store.updateFromLibrary(args[3])
            print(touched.isEmpty ? "no teammate holds '\(args[3])' — nothing to update"
                                  : "re-pushed '\(args[3])' to: \(touched.joined(separator: ", "))")
        default:
            let skills = store.librarySkills()
            print(skills.isEmpty ? "(library empty — agency-cli library add <path>)"
                                 : skills.joined(separator: "\n"))
        }

    case "instructions" where args.count >= 3:
        // agency-cli instructions <name> [text…] — no text prints them,
        // empty text clears. Stored in the roster so persona regeneration
        // (every app launch) can never wipe them (structure audit R2).
        if args.count == 3 {
            let a = try agent(args[2])
            print(a.instructions ?? "(none)")
        } else {
            let a = try store.setInstructions(args[3...].joined(separator: " "), for: args[2])
            print("standing instructions for @\(a.name): \(a.instructions ?? "(cleared)")")
        }

    case "emoji" where args.count >= 4:
        // agency-cli emoji <name> <emoji> — bruno's had become a literal "e".
        let a = try store.updateAgent(name: args[2], emoji: args[3])
        print("emoji for @\(a.name): \(a.emoji)")

    case "fresh" where args.count >= 3:
        // agency-cli fresh <name> — new session AND a clean chat (his ask
        // 2026-08-13 #6): the old chat rotates into agents/.archived/threads/
        // (fence-sealed, read-only in the app's history menu). Notebook and
        // vault notes stay.
        try store.clearSessionID(for: args[2])
        let archived = try MessageLog(store: store).archiveThread(args[2])
        print("@\(args[2]) starts FRESH on the next message"
            + (archived.map { " — previous chat archived to \($0.lastPathComponent)" } ?? " (no chat to archive)"))

    case "archive" where args.count >= 3:
        // Archive = retire, never rm (his call): folders move to
        // agents/.archived/, fences regenerate, nothing is destroyed.
        let dest = try store.archiveAgent(args[2])
        print("archived @\(args[2]) → \(dest.path) (nothing deleted; roster row removed, fences regenerated)")

    case "team":
        // Vault pockets (spec 2026-08-13): teams are CLI-managed in v1.
        // team create <name> [member…] | team add <team> <agent> |
        // team remove <team> <agent> | team list
        // Bare `agency-cli team` lands in the inner default: team usage,
        // exit 1 (pocket review M3 — it used to exit 0 via the outer default).
        switch args.count > 2 ? args[2] : "" {
        case "create" where args.count >= 4:
            let t = try store.createTeam(args[3], members: Array(args.dropFirst(4)))
            print("created team \(t.name) [\(t.members.joined(separator: ", "))] — pocket: vault/teams/\(t.name)/")
        case "add" where args.count >= 5:
            print(try store.addTeamMember(args[4], to: args[3])
                ? "\(args[4]) joined \(args[3])"
                : "\(args[4]) is already in \(args[3]) — nothing changed")
        case "remove" where args.count >= 5:
            print(try store.removeTeamMember(args[4], from: args[3])
                ? "\(args[4]) left \(args[3]) (the pocket folder is untouched)"
                : "\(args[4]) wasn't in \(args[3]) — nothing changed")
        case "emoji" where args.count >= 5:
            let t = try store.setTeamEmoji(args[4], for: args[3])
            print("\(t.name) now shows \(t.emoji ?? "👥")")
        case "list":
            let teams = try store.listTeams()
            if teams.isEmpty { print("(no teams)") }
            for t in teams { print("\(t.emoji ?? "👥") \(t.name): \(t.members.isEmpty ? "(empty)" : t.members.joined(separator: ", "))") }
        default:
            fputs("usage: agency-cli team create <name> [member…] | add <team> <agent> | remove <team> <agent> | list\n", stderr)
            exit(1)
        }

    case "connectors" where args.count >= 5 && args[3] == "set":
        // agency-cli connectors <agent> set id1,id2  (or "none" to revoke all)
        let ids = args[4] == "none" ? [] : args[4].split(separator: ",").map(String.init)
        let a = try store.setConnectors(ids, for: args[2])
        print("granted to \(a.name): \((a.connectors ?? []).joined(separator: ", ").isEmpty ? "(none)" : (a.connectors ?? []).joined(separator: ", "))")

    default:
        print("""
        usage: agency-cli <command>
          create <name> <emoji> <role…>      chat <name> <msg…>
          ask <asker> <target> <q…>          roster
          refresh <name>                     archive <name>
          shell <name> on|off                web <name> on|off
          connectors <name> [set a,b|none]   team create|add|remove|list …
          display <name> [text]              emoji <name> <emoji>
          instructions <name> [text]         fresh <name>
          google-account [address]
        """)
    }
}

let sem = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
Task {
    do { try await run() } catch {
        // Non-zero on failure so scripts (and the phase-0 smoke) can actually detect it.
        fputs("error: \(describe(error))\n", stderr)
        exitCode = 1
    }
    sem.signal()
}
sem.wait()
exit(exitCode)
