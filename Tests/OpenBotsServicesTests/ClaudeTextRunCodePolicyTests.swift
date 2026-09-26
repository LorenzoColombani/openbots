import Foundation
import OpenBotsDomain
import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

@Suite("Run-code policy: script runs get the run card; installs are named")
struct ClaudeTextRunCodePolicyTests {
    private let access = try! ClaudeTextWorkAccess(
        workingDirectoryURL: URL(fileURLWithPath: "/Users/x/OpenBots Next Preview Content/Bots/Yogurt"),
        additionalDirectoryURLs: [URL(fileURLWithPath: "/Users/x/Documents/Invoices")],
        protectedPaths: ["/Users/x/.ssh"])

    private func question(_ command: String) throws -> ClaudeTextPermissionRequest {
        ClaudeTextPermissionRequest(requestID: "r", toolUseID: "t", toolName: "Bash",
            inputJSON: try JSONSerialization.data(withJSONObject: ["command": command], options: [.sortedKeys]))
    }

    @Test("python3 script.py becomes a run card naming interpreter, script and folder")
    func pythonScriptRunCard() throws {
        let fake = [ClaudeTextInterpreter(name: "Python 3", path: "/usr/bin/python3", kind: .python)]
        let decision = ClaudeTextRunCodePolicy.decide(
            "python3 sort_by_date.py", access: access, botName: "Yogurt", interpreters: fake)
        guard case .ask(let card) = decision else { Issue.record("must ask"); return }
        #expect(card.title == "Run sort_by_date.py")
        #expect(card.detail.contains("Interpreter: Python 3"))
        #expect(card.detail.contains("sort_by_date.py"))
        #expect(card.detail.contains("Folder: Yogurt"))
        #expect(card.target.contains("Python 3"))
        #expect(card.offersTurnAllowance == true)
        #expect(card.turnScope?.folderName == "sort_by_date.py")
        #expect(card.openablePath?.hasSuffix("sort_by_date.py") == true)
    }

    @Test("python3 -c is not a run-code card")
    func pythonDashCIsNotRunCode() {
        #expect(ClaudeTextRunCodePolicy.parse("python3 -c 'print(1)'", access: access) == nil)
    }

    @Test("Missing interpreter becomes a named install card, never silent")
    func missingInterpreterNamedInstall() {
        let decision = ClaudeTextRunCodePolicy.decide(
            "node crunch.js", access: access, botName: "Yogurt", interpreters: [])
        guard case .ask(let card) = decision else { Issue.record("must ask"); return }
        #expect(card.kind == .packageInstall)
        #expect(card.title == "Install Node.js")
        #expect(card.detail.contains("will not install"))
        #expect(card.offersTurnAllowance == false)
    }

    @Test("brew install jq names the package on the card")
    func namedBrewInstall() throws {
        let decision = ClaudeTextWorkApprovalPolicy.decide(
            try question("brew install jq"), access: access, botName: "Yogurt")
        guard case .ask(let card) = decision else { Issue.record("must ask"); return }
        #expect(card.kind == .packageInstall)
        #expect(card.title == "Install jq with Homebrew")
        #expect(card.target.contains("will not install this until you approve"))
    }

    @Test("Work approval routes a script run through the run card")
    func workApprovalRoutesRunCode() throws {
        // Without faking the catalog, /usr/bin/python3 usually exists on macOS CI/dev Macs.
        let decision = ClaudeTextWorkApprovalPolicy.decide(
            try question("python3 notes/sort.py"), access: access, botName: "Yogurt")
        guard case .ask(let card) = decision else { Issue.record("must ask"); return }
        #expect(card.title == "Run sort.py" || card.title.hasPrefix("Install "))
        if card.title == "Run sort.py" {
            #expect(card.openablePath != nil)
            #expect(card.turnScope != nil)
        }
    }
}

/// The shapes Claude Code 2.1.280 really sent when a work bot was
/// asked to write and run a script (fixture `claude-cli-2.1.280/run-code-probe`,
/// `bash-asks.json`), and what a rerun allowance must never cover.
@Suite("Run card on the real wire shapes")
struct ClaudeTextRunCodeWireShapeTests {
    private static let bot = "/private/tmp/run-code-probe.noindex/Bot"
    private let access = try! ClaudeTextWorkAccess(
        workingDirectoryURL: URL(fileURLWithPath: Self.bot),
        additionalDirectoryURLs: [URL(fileURLWithPath: "/Users/x/Documents/Invoices")],
        protectedPaths: ["/Users/x/.ssh"])
    private let python = [ClaudeTextInterpreter(name: "Python 3", path: "/usr/bin/python3", kind: .python)]

    private func run(_ command: String) -> ClaudeTextWorkCard? {
        guard case .ask(let card) = ClaudeTextRunCodePolicy.decide(
            command, access: access, botName: "Yogurt", interpreters: python) else { return nil }
        return card
    }

    private func work(_ command: String) throws -> ClaudeTextWorkCard? {
        let question = ClaudeTextPermissionRequest(requestID: "r", toolUseID: "t", toolName: "Bash",
            inputJSON: try JSONSerialization.data(withJSONObject: ["command": command], options: [.sortedKeys]))
        guard case .ask(let card) = ClaudeTextWorkApprovalPolicy.decide(question, access: access, botName: "Yogurt")
        else { return nil }
        return card
    }

    @Test("The plain run the CLI sent, a script argument after it, gets the run card and its allowance")
    func plainRun() throws {
        let card = try #require(run("python3 Outbox/list_by_date.py ."))
        #expect(card.title == "Run list_by_date.py")
        #expect(card.offersTurnAllowance)
        #expect(card.turnScope?.folderPath == Self.bot + "/Outbox/list_by_date.py")
    }

    @Test("A cd into the bot's folder first and a read after still name the script, resolved from the cd")
    func cdThenRunThenRead() throws {
        let card = try #require(run("cd \"\(Self.bot)\" && python3 Outbox/bar_chart.py && ls -l Outbox"))
        #expect(card.title == "Run bar_chart.py")
        #expect(card.openablePath == Self.bot + "/Outbox/bar_chart.py")
        #expect(card.offersTurnAllowance)
        #expect(card.turnScope?.folderPath == Self.bot + "/Outbox/bar_chart.py")
    }

    @Test("A command chained after the run is never covered by the run's allowance")
    func chainedWriterAfterRun() throws {
        let approved = try #require(run("python3 sort.py")).turnScope
        #expect(approved != nil)
        #expect(ClaudeTextRunCodePolicy.parse("python3 sort.py && rm -rf notes", access: access) == nil)
        let chained = try #require(try work("python3 sort.py && rm -rf notes"))
        #expect(chained.kind == .delete)
        #expect(chained.turnScope == nil)
        #expect(chained.turnScope != approved)
    }

    @Test("A newline, a background run, a redirection or a substitution is not a run card")
    func notOneRun() {
        for command in ["python3 sort.py\nrm -rf notes", "python3 sort.py &", "nohup python3 count.py > /dev/null 2>&1 &",
                        "python3 sort.py > /Users/x/out.txt", "python3 sort.py < /Users/x/.ssh/id",
                        "python3 $(echo sort.py)", "python3 `echo sort.py`", "python3 sort.py; rm -rf notes",
                        "cd /etc && python3 sort.py", "cd .. && python3 sort.py"] {
            #expect(ClaudeTextRunCodePolicy.parse(command, access: access) == nil, "\(command)")
        }
    }

    @Test("2>&1 and a read-only pipe after the run are allowed")
    func stderrAndPipe() throws {
        let card = try #require(run("python3 Outbox/list_by_date.py 2>&1 | tail -20"))
        #expect(card.title == "Run list_by_date.py")
        #expect(card.turnScope != nil)
    }

    @Test("Python's own flags before the script are skipped")
    func pythonFlags() throws {
        #expect(try #require(run("python3 -u count.py")).title == "Run count.py")
        #expect(try #require(run("python3 -X utf8 -B count.py")).title == "Run count.py")
    }

    @Test("A script outside the bot's folders gets the card but no allowance: it asks every time")
    func outsideAsksEveryTime() throws {
        let card = try #require(run("python3 ../elsewhere/x.py"))
        #expect(card.title == "Run x.py")
        #expect(card.turnScope == nil)
        #expect(!card.offersTurnAllowance)
        let absolute = try #require(run("python3 /Users/x/Desktop/x.py"))
        #expect(absolute.turnScope == nil)
        let granted = try #require(run("python3 /Users/x/Documents/Invoices/total.py"))
        #expect(granted.turnScope?.folderPath == "/Users/x/Documents/Invoices/total.py")
    }

    @Test("The two installs the CLI asked for are named, with the package, from the install part")
    func installsNamed() throws {
        let module = try #require(try work("python3 -m pip install --user requests 2>&1 | tail -20"))
        #expect(module.kind == .packageInstall)
        #expect(module.title == "Install requests with pip")
        let venv = try #require(try work(
            "python3 -m venv \"$TMPDIR/venv\" 2>&1 | tail -5 && \"$TMPDIR/venv/bin/pip\" install --quiet requests 2>&1 | tail -20"))
        #expect(venv.kind == .packageInstall)
        #expect(venv.title == "Install requests with pip")
        #expect(venv.offersTurnAllowance == false)
    }

    @Test("Inline code names its interpreter on the card, and gets no allowance")
    func inlineCode() throws {
        let card = try #require(try work("python3 -c \"import requests; print(requests.__version__)\" 2>&1; echo \"---\"; ls"))
        #expect(card.title == "Run Python 3 code")
        #expect(card.turnScope == nil)
        let heredoc = try #require(try work("cd \"\(Self.bot)\" && python3 - <<'EOF'\nimport re\nprint(1)\nEOF"))
        #expect(heredoc.title == "Run Python 3 code")
    }

    @Test("A background run is refused before it starts, with the reason the bot is told")
    func backgroundRunRefused() throws {
        for command in ["cd \"\(Self.bot)/Outbox\" && nohup python3 count.py > /dev/null 2>&1 &\necho \"pid=$!\"",
                        "python3 count.py &", "nohup python3 count.py", "sleep 9 & rm x", "python3 a.py & disown"] {
            let question = ClaudeTextPermissionRequest(requestID: "r", toolUseID: "t", toolName: "Bash",
                inputJSON: try JSONSerialization.data(withJSONObject: ["command": command], options: [.sortedKeys]))
            guard case .denyQuietly(let reason, let activity) = ClaudeTextWorkApprovalPolicy.decide(
                question, access: access, botName: "Yogurt") else { Issue.record("not refused: \(command)"); continue }
            #expect(reason.contains("foreground"))
            #expect(activity.hasPrefix("Refused a background run"))
        }
        // `&&`, `2>&1` and `&>` are not the background.
        #expect(try work("python3 Outbox/list_by_date.py 2>&1 && ls") != nil)
        // An escaped quote does not hide a background run,
        // and `|&` pipes both streams in the foreground.
        #expect(ClaudeTextWorkApprovalPolicy.sendsToBackground("echo \"a\\\" b\" arg &"))
        #expect(!ClaudeTextWorkApprovalPolicy.sendsToBackground("python3 x.py |& tail -5"))
        #expect(!ClaudeTextWorkApprovalPolicy.sendsToBackground("echo 'a & b'"))
    }

    @Test("2>&1 counts only as a word of its own: 2>&1file writes a file named 1file")
    func stderrRedirectOnlyAsAWord() {
        #expect(ClaudeTextRunCodePolicy.parse("python3 sort.py 2>&1file", access: access) == nil)
        #expect(ClaudeTextRunCodePolicy.parse("python3 sort.py 2>&1", access: access) != nil)
    }

    /// A work turn's PATH reaches user-writable folders
    /// after the system ones, so a no-card name must be a system program.
    @Test("A no-card read runs only a program the system folders hold")
    func readOnlyNeedsASystemProgram() {
        let system = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        // git by the same rule.
        #expect(ClaudeTextWorkApprovalPolicy.isSystemProgram("git") == system.contains {
            FileManager.default.isExecutableFile(atPath: "\($0)/git") })
        #expect(!ClaudeTextWorkApprovalPolicy.isSystemProgram("/opt/homebrew/bin/rg"))
        for name in ["rg", "tree", "tac", "ls", "cat", "jq"] {
            let inSystem = system.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
            #expect(ClaudeTextWorkApprovalPolicy.isReadOnly("\(name) notes.md", access: access) == inSystem, "\(name)")
        }
    }

    @Test("A run's allowance names its interpreter: uv run of an approved python3 script asks again")
    func allowanceNamesTheInterpreter() throws {
        let uv = [ClaudeTextInterpreter(name: "uv", path: "/Users/x/.local/bin/uv", kind: .uv)] + python
        let approved = try #require(run("python3 Outbox/count.py")).turnScope
        guard case .ask(let other) = ClaudeTextRunCodePolicy.decide(
            "uv run Outbox/count.py", access: access, botName: "Yogurt", interpreters: uv) else {
            Issue.record("must ask"); return
        }
        #expect(other.turnScope != nil)
        #expect(other.turnScope != approved)
        #expect(try #require(run("python3 Outbox/count.py")).turnScope == approved)
    }

    @Test("uv run is a run, not an install")
    func uvRunIsNotInstall() {
        #expect(ClaudeTextWorkApprovalPolicy.commandKind("uv run --with requests fetch.py") != .packageInstall)
        #expect(ClaudeTextWorkApprovalPolicy.commandKind("uv add requests") == .packageInstall)
    }

    @Test("2>&1 does not split a command into segments")
    func stderrRedirectIsNotASeparator() {
        #expect(ClaudeTextWorkApprovalPolicy.commandSegments("ls 2>&1 | tail -3") == ["ls 2>&1", "tail -3"])
        #expect(ClaudeTextWorkApprovalPolicy.commandSegments("python3 x.py &> log.txt && ls") == ["python3 x.py &> log.txt", "ls"])
        #expect(ClaudeTextWorkApprovalPolicy.commandSegments("sleep 9 & rm x") == ["sleep 9", "rm x"])
    }

    // A command chained by a line break must not be titled by its first word.
    // Swift folds "\r\n" into one Character, so a Character-level check for "\n"
    // missed it and bash ran the second line. Closed in the app; whether Claude
    // Code would ask first is unproved.
    @Test("A CRLF line break never hides a second command from the read-only rule, the run rule or the title")
    func aCRLFNeverHidesASecondCommand() throws {
        for command in ["ls -la\r\nrm -rf Invoices", "ls\r\nrm -rf x", "ls\rrm x", "ls\u{2028}rm x", "ls\u{0085}rm x"] {
            #expect(!ClaudeTextWorkApprovalPolicy.isReadOnly(command, access: access), "\(command.debugDescription)")
            let request = ClaudeTextPermissionRequest(requestID: "r", toolUseID: "t", toolName: "Bash",
                inputJSON: try JSONSerialization.data(withJSONObject: ["command": command], options: [.sortedKeys]))
            let decision = ClaudeTextWorkApprovalPolicy.decide(request, access: access, botName: "Yogurt")
            if case .allowQuietly = decision { Issue.record("\(command.debugDescription) ran with no card") }
        }
        #expect(ClaudeTextRunCodePolicy.parse("python3 sort.py\r\nrm -rf notes", access: access) == nil)
        // A backslash escapes the CR, and the LF still ends the command in bash.
        #expect(ClaudeTextWorkApprovalPolicy.commandSegments("ls \\\r\nrm -rf x").count == 2)
        #expect(ClaudeTextWorkApprovalPolicy.commandKind("ls \\\r\nrm -rf x") == .delete)
    }

    @Test("A line break ends a segment, a backslash before it continues the line, and a tab separates words")
    func aLineBreakEndsASegment() {
        #expect(ClaudeTextWorkApprovalPolicy.commandSegments("echo ok\nrm -rf ~/Documents") == ["echo ok", "rm -rf ~/Documents"])
        #expect(ClaudeTextWorkApprovalPolicy.commandSegments("echo ok\r\nrm x") == ["echo ok", "rm x"])
        #expect(ClaudeTextWorkApprovalPolicy.commandSegments("ls \\\n  -la") == ["ls   -la"])
        #expect(ClaudeTextWorkApprovalPolicy.commandSegments("echo 'a\nb'") == ["echo 'a\nb'"])
        #expect(ClaudeTextWorkApprovalPolicy.commandKind("echo ok\nrm -rf ~/Documents") == .delete)
        #expect(ClaudeTextWorkApprovalPolicy.commandKind("echo ok;rm\t-rf x") == .delete)
    }
}

@Suite("Interpreter catalog")
struct ClaudeTextInterpreterCatalogTests {
    @Test("Named install suggestions never claim a silent install")
    func suggestionsNameInstall() {
        let python = ClaudeTextInterpreterCatalog.namedInstallSuggestion(forInterpreter: "python3")
        #expect(python.title == "Install Python 3")
        #expect(python.detail.contains("will not install"))
        let node = ClaudeTextInterpreterCatalog.namedInstallSuggestion(forInterpreter: "node")
        #expect(node.title == "Install Node.js")
    }

    @Test("Resolve returns only executable paths")
    func resolveExecutables() {
        let found = ClaudeTextInterpreterCatalog.resolve()
        for item in found {
            #expect(FileManager.default.isExecutableFile(atPath: item.path), "\(item.path)")
        }
    }
}

/// "Allow for this turn" on a script must not cover a later version of that
/// file, or a bot could approve a harmless script and rewrite it before the
/// rerun. The allowance names the script's bytes.
@Suite("A run allowed for the turn covers that script as it was, not a rewrite")
struct RunAllowanceNamesTheScriptsBytesTests {
    @Test("Rewriting the script changes the allowance, so the rerun asks again; the same bytes keep it")
    func aRewriteAsksAgain() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("obrun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let access = try ClaudeTextWorkAccess(workingDirectoryURL: folder, additionalDirectoryURLs: [], protectedPaths: [])
        let python = [ClaudeTextInterpreter(name: "Python 3", path: "/usr/bin/python3", kind: .python)]
        let script = folder.appendingPathComponent("sort.py")
        func scope() throws -> ClaudeTextWorkTurnAllowance? {
            guard case .ask(let card) = ClaudeTextRunCodePolicy.decide("python3 sort.py", access: access,
                botName: "Yogurt", interpreters: python) else { Issue.record("must ask"); return nil }
            return card.turnScope
        }
        try Data("print('hello')\n".utf8).write(to: script)
        let first = try #require(try scope())
        #expect(first.folderName == "sort.py")
        #expect(try scope() == first)
        try Data("import shutil; shutil.rmtree('/tmp/x')\n".utf8).write(to: script)
        #expect(try scope() != first)
    }
}
