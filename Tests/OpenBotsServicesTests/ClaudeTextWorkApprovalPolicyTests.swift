import Foundation
import OpenBotsDomain
import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

@Suite("Work approval policy: plain reads inside the folders pass, everything else asks")
struct ClaudeTextWorkApprovalPolicyTests {
    private let access = try! ClaudeTextWorkAccess(
        workingDirectoryURL: URL(fileURLWithPath: "/Users/x/OpenBots Next Preview Content/Bots/Yogurt"),
        additionalDirectoryURLs: [URL(fileURLWithPath: "/Users/x/Documents/Invoices")],
        protectedPaths: ["/Users/x/.ssh"])

    @Test("Read-only commands inside the folders are recognised",
          arguments: ["ls -la", "cat notes.md | head -20", "git status", "git log --oneline -n 5",
                      "grep -rn invoice .", "find . -name '*.md'", "wc -l notes.md", "ls /Users/x/Documents/Invoices",
                      "pwd", "cat notes.md | wc -c", "shasum report.pdf", "du -sh Archive", "git remote -v", "git branch --list",
                      "grep --include=*.md invoice .", "grep --file=/Users/x/Documents/Invoices/terms.txt -r .",
                      "grep -e invoice notes.md", "grep -o inv notes.md", "sort -k2 notes.md", "xxd -l 64 notes.md",
                      "uniq notes.md", "sort --check notes.md", "uniq -f 1 notes.md", "xxd -i -n foo notes.md",
                      "xxd -R never notes.md", "sort \"-k2\" notes.md", "sort -rn notes.md", "grep \"hello world\" notes.md",
                      "grep \"it's\" notes.md", "file notes.md", "cat notes.md | uniq -", "cat *.md", "ls a.*b",
                      "grep -E 'a.*b' notes.md", "ls [.][.]", "find . -name '*.md'", "cat notes.md | uniq", "cat notes.md | xxd -p"])
    func readOnly(command: String) {
        #expect(ClaudeTextWorkApprovalPolicy.isReadOnly(command, access: access), "\(command)")
    }

    @Test("Anything that writes, chains a writer, substitutes, climbs out or reaches a protected root asks",
          arguments: ["rm notes.md", "mv a.txt b.txt", "cat notes.md > out.txt", "ls; rm x", "ls && rm x",
                      "find . -delete", "find . -exec rm {} \\;", "cat ~/.ssh/id_rsa", "cat /etc/passwd",
                      "ls ../..", "sudo ls", "echo $(whoami)", "cat `ls`", "xargs rm", "git push", "git commit -m x",
                      "ls /Users/x/Documents", "python3 -c 'print(1)'", "ls &", "cat 'a b' > c", "touch new.txt", "",
                      "cat $HOME/Documents/x", "ls \"$HOME\"", "cat ${PWD}/notes.md", "grep --file=/Users/x/secret pat .",
                      "ls -C/Users/x", "git remote add origin x", "git tag v1", "git branch new", "mdfind invoice",
                      "grep --file=../../private/x pat .", "sort -o out.txt notes.md", "sort --files0-from=- notes.md",
                      "sort --compress-program=gzip notes.md", "xxd notes.md dump.txt", "rg --pre cat invoice .",
                      "sort -oout.txt notes.md", "sort --out=out.txt notes.md", "sort --o out.txt notes.md", "uniq notes.md out.txt",
                      "tree -o tree.txt", "find . -fprint list.txt", "yq -i '.a=1' config.yml", "yq '.a' config.yml",
                      "sort \"-o\" out.txt notes.md", "sort '--output=out.txt' notes.md", "find . \"-fprint\" list.txt",
                      "rg \"--pre\" cat invoice .", "sort -no out.txt notes.md", "sort -uo notes.md notes.md", "tree -ao t.txt",
                      "find . -files0-from list.txt",
                      // Partial quoting: bash joins the fragments, so each of these is the writing option.
                      "sort \"-o out\" notes.md", "sort '-'o out notes.md", "sort \"\"-o out notes.md", "sort \"-\"o out notes.md",
                      "sort '--outpu't=out notes.md", "sort '--output'\"\" out notes.md", "find . '-fprin't list.txt",
                      "find . -'fprint' list.txt", "rg -'-pre'=rm x .", "rg \"--\"pre=rm x .",
                      // A bare `-` is stdin, so the next word is the output file.
                      "uniq - out.txt", "xxd -p - out.bin", "cat notes.md | uniq - out.txt", "cat notes.md | xxd - dump.txt",
                      // `file -C` compiles a magic file into the working folder.
                      "file -C -m notes.md", "file --compile -m notes.md",
                      // Brace expansion is bash's, not this rule's: `{-ooutput.txt,notes.md}` is `-ooutput.txt notes.md`
                      // and `{/etc,}/passwd` is `/etc/passwd`; a brace anywhere asks (so does jq's object syntax).
                      "sort {-ooutput.txt,notes.md}", "sort {-o/tmp/x,notes.md}", "cat {/etc,}/passwd",
                      "git log {--output=/tmp/x,}", "jq '{name: .name}' notes.md",
                      // tree's long output flag; the pagers add nothing over cat and carry a shell escape.
                      "tree --output=t.txt", "tree --output t.txt", "less notes.md", "more notes.md",
                      // A glob component that can match `..` climbs out (bash 3.2: `.[.]`, `.?`, `.*`, `.[!a]` all match it).
                      "cat .[.]/secret.txt", "ls .[.]", "ls .?", "ls .*", "cat .[!a]/x", "find .[.] -name x",
                      "cat .[.]/.ssh/id_rsa", "ls -d .[.]", "echo .[.]/*", "realpath .[.]", "grep --file=.[.]/x notes.md",
                      // One glob word expands to two files, and the second is uniq's or xxd's output.
                      "uniq *.txt", "xxd *.txt", "xxd -r *.hex", "xxd -p *", "uniq notes?.txt", "xxd [ab].txt",
                      // rg runs the hostname program when a hyperlink needs it, and decompressors with -z.
                      "rg --hostname-bin=./x a .", "rg --hostname-bin ./x a .", "rg --color=always --hyperlink-format=default --hostname-bin=./run.sh a a.txt",
                      "rg -z foo .", "rg --search-zip foo .",
                      // zsh runs code in a glob qualifier or `=(…)`, and `=ls` names /bin/ls: parens and a leading `=` refuse.
                      "echo *(e:'rm x':)", "cat *(e:'touch P':)", "cat =(rm x)", "cat =ls", "ls (a|b).txt", "echo $(date)"])
    func notReadOnly(command: String) {
        #expect(!ClaudeTextWorkApprovalPolicy.isReadOnly(command, access: access), "\(command)")
    }

    private func question(_ tool: String, _ input: [String: Any]) throws -> ClaudeTextPermissionRequest {
        ClaudeTextPermissionRequest(requestID: "r", toolUseID: "t", toolName: tool,
            inputJSON: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
    }

    @Test("A helper always asks with its full assignment and the inherited limits")
    func helperDecision() throws {
        let assignment = "Read the invoices, compare their totals, and return any differences."
        let decision = ClaudeTextWorkApprovalPolicy.decide(try question("Agent", [
            "subagent_type": "openbots-helper", "prompt": assignment, "description": "Compare invoices"
        ]), access: access, botName: "Yogurt")
        guard case .ask(let card) = decision else { Issue.record("a helper must ask"); return }
        #expect(card.title == "Start a helper for Yogurt")
        #expect(card.detail == assignment)
        #expect(card.target.contains("Same folders and permissions"))
        #expect(card.target.contains("8 turns") && card.target.contains("stops with this task"))
        #expect(card.activity == "Asked a helper to Compare invoices")
    }

    @Test("A move asks with a card that names the command and the folder; a listing passes quietly")
    func bashDecisions() throws {
        let move = ClaudeTextWorkApprovalPolicy.decide(try question("Bash", ["command": "mv a.txt Archive/a.txt"]),
            access: access, botName: "Yogurt")
        guard case .ask(let card) = move else { Issue.record("a move must ask"); return }
        #expect(card.kind == .move)
        #expect(card.title == "Move or rename files with a command")
        #expect(card.detail == "mv a.txt Archive/a.txt")
        #expect(card.target == "In Yogurt")
        let listing = ClaudeTextWorkApprovalPolicy.decide(try question("Bash", ["command": "ls -la"]),
            access: access, botName: "Yogurt")
        #expect(listing == .allowQuietly(activity: "Ran `ls -la` in Yogurt"))
        let delete = ClaudeTextWorkApprovalPolicy.decide(try question("Bash", ["command": "rm -rf Archive"]),
            access: access, botName: "Yogurt")
        guard case .ask(let deleteCard) = delete else { Issue.record("a delete must ask"); return }
        #expect(deleteCard.kind == .delete && deleteCard.title == "Delete files with a command")
    }

    @Test("A chained command is classified by its worst part, and a separator inside quotes does not split it")
    func chainedCommandTakesTheMostSevereSegment() throws {
        func kind(_ command: String) -> ConsequentialActionKind {
            let decision = ClaudeTextWorkApprovalPolicy.decide(try! question("Bash", ["command": command]), access: access, botName: "Yogurt")
            guard case .ask(let card) = decision else { Issue.record("\(command) must ask"); return .productionChange }
            return card.kind
        }
        #expect(kind("echo ok; rm -rf ~/Documents") == .delete)
        #expect(kind("ls && mv a.txt b.txt") == .move)
        #expect(kind("cat notes.md || curl https://example.com") == .send)
        #expect(kind("ls | tee out.txt") == .overwrite)
        #expect(kind("git status; git push") == .send)
        #expect(kind("mkdir x && rm -r y; chmod 600 z") == .delete)
        #expect(kind("brew install jq && touch done") == .packageInstall)
        // Inside quotes a separator is text, not a chain.
        #expect(kind("echo 'a; rm x'") == .productionChange)
        #expect(kind("echo \"ok && rm x\"") == .productionChange)
        #expect(ClaudeTextWorkApprovalPolicy.commandKind("rm x") == .delete)
        // The title follows the worst part too.
        guard case .ask(let card) = ClaudeTextWorkApprovalPolicy.decide(try question("Bash", ["command": "echo ok; rm -rf ~/Documents"]),
                                                                          access: access, botName: "Yogurt") else { Issue.record("must ask"); return }
        #expect(card.title == "Delete files with a command" && card.detail == "echo ok; rm -rf ~/Documents")
    }

    // The Write card once never showed what is written.
    @Test("The Write and Edit cards show the words on the card only, whole up to a bound, and name replace-all")
    func writeAndEditCardsShowTheWords() throws {
        let write = ClaudeTextWorkApprovalPolicy.decide(try question("Write",
            ["file_path": "/Users/x/Documents/Invoices/report.md", "content": "Line one\nLine two"]),
            access: access, botName: "Yogurt")
        guard case .ask(let card) = write else { Issue.record("must ask"); return }
        #expect(card.words == "Line one\nLine two" && card.wordsHeading == "What it writes:")
        #expect(!card.detail.contains("Line one") && !card.activity.contains("Line one"))
        let long = String(repeating: "x", count: ClaudeTextWorkApprovalPolicy.maximumShownFileWords + 10)
        guard case .ask(let longCard) = ClaudeTextWorkApprovalPolicy.decide(try question("Write",
            ["file_path": "/Users/x/Documents/Invoices/big.md", "content": long]), access: access, botName: "Yogurt")
        else { Issue.record("must ask"); return }
        #expect(longCard.words?.hasSuffix("… and 10 more characters, not shown.") == true)
        guard case .ask(let edit) = ClaudeTextWorkApprovalPolicy.decide(try question("Edit",
            ["file_path": "/Users/x/Documents/Invoices/2026.md", "old_string": "draft", "new_string": "final",
             "replace_all": true]), access: access, botName: "Yogurt") else { Issue.record("must ask"); return }
        #expect(edit.words == "Replace:\ndraft\n\nWith:\nfinal", "\(String(describing: edit.words))")
        #expect(edit.detail.contains("every place") && !edit.detail.contains("draft"), "\(edit.detail)")
    }

    @Test("A write names the file relative to the bot's folder; a read the CLI asks about is outside the folders")
    func fileDecisions() throws {
        // A write into the bot's own folder is quiet;
        // one into any other folder keeps its card.
        let write = ClaudeTextWorkApprovalPolicy.decide(try question("Write",
            ["file_path": "/Users/x/Documents/Invoices/report.md", "content": "Hello"]),
            access: access, botName: "Yogurt")
        guard case .ask(let card) = write else { Issue.record("a write outside the bot's folder must ask"); return }
        #expect(card.kind == .overwrite && card.title == "Create or replace a file")
        #expect(card.detail == "Invoices/report.md" && card.target == "5 bytes")
        let edit = ClaudeTextWorkApprovalPolicy.decide(try question("Edit",
            ["file_path": "/Users/x/Documents/Invoices/2026.md", "old_string": "a", "new_string": "b"]),
            access: access, botName: "Yogurt")
        guard case .ask(let editCard) = edit else { Issue.record("an edit must ask"); return }
        #expect(editCard.target == "Invoices/2026.md")
        let read = ClaudeTextWorkApprovalPolicy.decide(try question("Read", ["file_path": "/Users/x/Desktop/secret.txt"]),
            access: access, botName: "Yogurt")
        guard case .ask(let readCard) = read else { Issue.record("a read outside must ask"); return }
        #expect(readCard.title == "Read outside its folders" && readCard.detail == "/Users/x/Desktop/secret.txt")
        let search = ClaudeTextWorkApprovalPolicy.decide(try question("WebSearch", ["query": "swift 6.3"]),
            access: access, botName: "Yogurt")
        #expect(search == .allowQuietly(activity: "Searched swift 6.3"))
    }

    @Test("A write in the team's shared folder keeps its card and names the folder; the folder counts as granted for commands and for Allow for this turn")
    func sharedFolderDecisions() throws {
        let shared = "/Users/x/OpenBots Next Preview Content/Shared"
        let withShared = try ClaudeTextWorkAccess(
            workingDirectoryURL: URL(fileURLWithPath: "/Users/x/OpenBots Next Preview Content/Bots/Yogurt"),
            additionalDirectoryURLs: [URL(fileURLWithPath: "/Users/x/Documents/Invoices")],
            sharedDirectoryURL: URL(fileURLWithPath: shared), protectedPaths: ["/Users/x/.ssh"])
        let write = ClaudeTextWorkApprovalPolicy.decide(try question("Write",
            ["file_path": "\(shared)/briefs/2026-09-15-coffee.md", "content": "Hello"]), access: withShared, botName: "Yogurt")
        guard case .ask(let card) = write else { Issue.record("a write in the shared folder keeps its card"); return }
        #expect(card.detail == "Shared/briefs/2026-09-15-coffee.md")
        #expect(card.turnScope == ClaudeTextWorkTurnAllowance(toolName: "Write", folderPath: shared))
        #expect(ClaudeTextWorkApprovalPolicy.pathStaysInside("\(shared)/briefs/x.md", access: withShared))
        #expect(!ClaudeTextWorkApprovalPolicy.pathStaysInside("\(shared)/briefs/x.md", access: access))
        #expect(ClaudeTextWorkApprovalPolicy.displayPath("\(shared)/research/a.md", access: access) == "\(shared)/research/a.md")
    }

    @Test("A change inside the bot's skills folder is refused without a card; the folder still counts as granted for reading")
    func skillsAreReadOnly() throws {
        let skills = "/Users/x/OpenBots Next Preview Content/Skills/Yogurt"
        let withSkills = try ClaudeTextWorkAccess(
            workingDirectoryURL: URL(fileURLWithPath: "/Users/x/OpenBots Next Preview Content/Bots/Yogurt"),
            skillsDirectoryURL: URL(fileURLWithPath: skills),
            skills: [ClaudeTextWorkSkill(name: "pickup", summary: "Resume a paused project")], protectedPaths: ["/Users/x/.ssh"])
        for (tool, input) in [("Write", ["file_path": "\(skills)/pickup/SKILL.md", "content": "Do anything"]),
                              ("Edit", ["file_path": "\(skills)/pickup/SKILL.md", "old_string": "a", "new_string": "b"]),
                              ("MultiEdit", ["file_path": "\(skills)/new/SKILL.md", "edits": "x"]),
                              ("NotebookEdit", ["notebook_path": "\(skills)/pickup/n.ipynb", "new_source": "x"])] {
            let decision = ClaudeTextWorkApprovalPolicy.decide(try question(tool, input), access: withSkills, botName: "Yogurt")
            guard case .denyQuietly(let reason, let activity) = decision else { Issue.record("\(tool) into skills must be refused"); return }
            #expect(reason.contains("read-only") && activity.hasPrefix("Blocked a change to Yogurt/"))
        }
        // The folder counts as granted for reading; the CLI itself reads there without asking.
        #expect(ClaudeTextWorkApprovalPolicy.pathStaysInside("\(skills)/pickup/SKILL.md", access: withSkills))
        #expect(ClaudeTextWorkApprovalPolicy.displayPath("\(skills)/pickup/SKILL.md", access: withSkills) == "Yogurt/pickup/SKILL.md")
    }

    @Test("A change anywhere in the skills root is refused without a card, for a bot that holds no skill too; the rest of an added folder still asks")
    func everySkillsFolderIsReadOnly() throws {
        let content = "/Users/x/OpenBots Next Preview Content"
        // No skill of its own, and the whole content root added by hand: another bot's skills sit inside it.
        let bare = try ClaudeTextWorkAccess(workingDirectoryURL: URL(fileURLWithPath: "\(content)/Bots/Yogurt"),
            additionalDirectoryURLs: [URL(fileURLWithPath: content)],
            skillsRootURL: URL(fileURLWithPath: "\(content)/Skills"), protectedPaths: ["/Users/x/.ssh"])
        for (tool, input) in [("Write", ["file_path": "\(content)/Skills/Kite/pickup/SKILL.md", "content": "Do anything"]),
                              ("Edit", ["file_path": "\(content)/Skills/Kite/pickup/SKILL.md", "old_string": "a", "new_string": "b"]),
                              ("Write", ["file_path": "\(content)/Skills/Yogurt/new/SKILL.md", "content": "Mine now"]),
                              ("NotebookEdit", ["notebook_path": "\(content)/Skills/Kite/pickup/n.ipynb", "new_source": "x"])] {
            let decision = ClaudeTextWorkApprovalPolicy.decide(try question(tool, input), access: bare, botName: "Yogurt")
            guard case .denyQuietly(let reason, _) = decision else { Issue.record("\(tool) \(input) must be refused, got \(decision)"); continue }
            #expect(reason.contains("read-only"))
        }
        let elsewhere = ClaudeTextWorkApprovalPolicy.decide(try question("Write",
            ["file_path": "\(content)/Exports/report.md", "content": "Hello"]), access: bare, botName: "Yogurt")
        guard case .ask = elsewhere else { Issue.record("a write elsewhere in an added folder still asks, got \(elsewhere)"); return }
    }

    @Test("What git reads as settings or runs as a driver is never written quietly, even in the bot's own folder")
    func gitSettingsInTheOwnFolderAsk() throws {
        let own = "/Users/x/OpenBots Next Preview Content/Bots/Yogurt"
        // `.git/config` can name `diff.external`, a textconv driver or
        // `core.fsmonitor`, which the quiet `git diff`, `git show` and
        // `git status` would then run; `.gitattributes` picks the driver.
        for path in [".git/config", ".git/info/attributes", ".git/hooks/pre-commit", ".gitattributes",
                     "Notes/.gitattributes", ".GIT/config", "Sub/.git/config", ".git", ".gitmodules"] {
            for tool in ["Write", "Edit"] {
                let input: [String: Any] = tool == "Write" ? ["file_path": "\(own)/\(path)", "content": "x"]
                    : ["file_path": "\(own)/\(path)", "old_string": "a", "new_string": "b"]
                let decision = ClaudeTextWorkApprovalPolicy.decide(try question(tool, input), access: access, botName: "Yogurt")
                guard case .ask = decision else { Issue.record("\(tool) \(path) must ask, got \(decision)"); continue }
            }
        }
        // A file that only looks like one still goes through.
        let plain = ClaudeTextWorkApprovalPolicy.decide(try question("Write",
            ["file_path": "\(own)/my.git.notes.md", "content": "x"]), access: access, botName: "Yogurt")
        guard case .allowByFolderRule = plain else { Issue.record("an ordinary file stays quiet, got \(plain)"); return }
    }

    @Test("ps runs quietly only without an option that prints the environment",
          arguments: [("ps", true), ("ps -ax", true), ("ps -A", true), ("ps -E", false), ("ps -axE", false),
                      ("ps -e", false), ("ps e", false), ("ps -Ae", false), ("ps ww", false)])
    func psNeverPrintsTheEnvironment(command: String, quiet: Bool) {
        #expect(ClaudeTextWorkApprovalPolicy.isReadOnly(command, access: access) == quiet, "\(command)")
    }

    @Test("An edit inside the bot's own folder goes through quietly; anywhere else, and any command, still asks")
    func editsInsideTheBotsOwnFolderDecideQuietly() throws {
        let own = "/Users/x/OpenBots Next Preview Content/Bots/Yogurt"
        let write = ClaudeTextWorkApprovalPolicy.decide(try question("Write",
            ["file_path": "\(own)/report.md", "content": "Hello"]), access: access, botName: "Yogurt")
        guard case .allowByFolderRule(let activity, let record) = write else {
            Issue.record("a write in the bot's own folder is quiet"); return
        }
        #expect(activity == "Wrote report.md in Yogurt's folder")
        // The record still carries the whole card, so the approvals row is complete.
        #expect(record.title == "Create or replace a file" && record.detail == "Yogurt/report.md")
        #expect(record.target == "5 bytes" && record.kind == .overwrite)
        let nested = ClaudeTextWorkApprovalPolicy.decide(try question("Edit",
            ["file_path": "\(own)/Notes/todo.md", "old_string": "a", "new_string": "b"]),
            access: access, botName: "Yogurt")
        guard case .allowByFolderRule(let nestedActivity, _) = nested else {
            Issue.record("a nested edit in the bot's own folder is quiet"); return
        }
        #expect(nestedActivity == "Edited Notes/todo.md in Yogurt's folder")
        let notebook = ClaudeTextWorkApprovalPolicy.decide(try question("NotebookEdit",
            ["notebook_path": "\(own)/plots.ipynb", "new_source": "x"]), access: access, botName: "Yogurt")
        guard case .allowByFolderRule(let notebookActivity, _) = notebook else {
            Issue.record("a notebook in the bot's own folder is quiet"); return
        }
        #expect(notebookActivity == "Edited plots.ipynb in Yogurt's folder")
        // Another granted folder is not the bot's own folder.
        let added = ClaudeTextWorkApprovalPolicy.decide(try question("Edit",
            ["file_path": "/Users/x/Documents/Invoices/2026.md", "old_string": "a", "new_string": "b"]),
            access: access, botName: "Yogurt")
        guard case .ask = added else { Issue.record("an added folder still asks"); return }
        // A climb out of the folder, and a plain outside path.
        for escape in ["\(own)/../Yoghurt/report.md", "\(own)/..", "/Users/x/Desktop/report.md",
                       "~/report.md", "\(own)/.ssh/../../Yoghurt/x.md"] {
            let decision = ClaudeTextWorkApprovalPolicy.decide(try question("Write",
                ["file_path": escape, "content": "Hello"]), access: access, botName: "Yogurt")
            guard case .ask = decision else { Issue.record("\(escape) must ask"); return }
        }
        // A shell command that writes the same file is not an edit.
        for command in ["tee \(own)/report.md", "cp a.txt \(own)/report.md", "rm \(own)/report.md",
                        "mv a.txt b.txt", "echo hi > \(own)/report.md"] {
            let decision = ClaudeTextWorkApprovalPolicy.decide(try question("Bash", ["command": command]),
                access: access, botName: "Yogurt")
            guard case .ask = decision else { Issue.record("`\(command)` must ask"); return }
        }
    }

    @Test("A relative path never goes through quietly: the CLI resolves it against a shell folder a `cd` may have moved, so the card shows it as written and says so")
    func relativePathsAlwaysAsk() throws {
        let note = " · relative to the bot's shell folder, which OpenBots cannot see"
        let write = ClaudeTextWorkApprovalPolicy.decide(try question("Write",
            ["file_path": "notes.md", "content": "Hello"]), access: access, botName: "Yogurt")
        guard case .ask(let writeCard) = write else { Issue.record("a relative write must ask"); return }
        #expect(writeCard.detail == "notes.md" + note && writeCard.target == "5 bytes")
        #expect(writeCard.activity == "Asked to write notes.md" + note)
        // No "Allow for this turn": the card names no folder it could cover.
        #expect(writeCard.turnScope == nil)
        let edit = ClaudeTextWorkApprovalPolicy.decide(try question("Edit",
            ["file_path": "Notes/todo.md", "old_string": "a", "new_string": "b"]), access: access, botName: "Yogurt")
        guard case .ask(let editCard) = edit else { Issue.record("a relative edit must ask"); return }
        #expect(editCard.target == "Notes/todo.md" + note && editCard.turnScope == nil)
        let multi = ClaudeTextWorkApprovalPolicy.decide(try question("MultiEdit",
            ["file_path": "notes.md", "edits": []]), access: access, botName: "Yogurt")
        guard case .ask(let multiCard) = multi else { Issue.record("a relative multi-edit must ask"); return }
        #expect(multiCard.target == "notes.md" + note)
        let notebook = ClaudeTextWorkApprovalPolicy.decide(try question("NotebookEdit",
            ["notebook_path": "plots.ipynb", "new_source": "x"]), access: access, botName: "Yogurt")
        guard case .ask(let notebookCard) = notebook else { Issue.record("a relative notebook edit must ask"); return }
        #expect(notebookCard.target == "plots.ipynb" + note && notebookCard.detail == "plots.ipynb" + note)
        // `./` is relative too, and so is a spelling that repeats the folder's own name.
        for spelling in ["./notes.md", "Yogurt/notes.md", "Bots/Yogurt/notes.md"] {
            let decision = ClaudeTextWorkApprovalPolicy.decide(try question("Write",
                ["file_path": spelling, "content": "Hello"]), access: access, botName: "Yogurt")
            guard case .ask = decision else { Issue.record("\(spelling) must ask"); return }
        }
    }

    @Test("A hard link inside the bot's own folder still asks: one file under two names, and the other name may be anywhere")
    func hardLinkedTargetsStillAsk() throws {
        let root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextOwnFolder-\(UUID()).noindex", isDirectory: true)
        let own = root.appendingPathComponent("Bots/Yogurt")
        let outside = root.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("out".utf8).write(to: outside.appendingPathComponent("secret.md"))
        try FileManager.default.linkItem(at: outside.appendingPathComponent("secret.md"),
            to: own.appendingPathComponent("twin.md"))
        try Data("mine".utf8).write(to: own.appendingPathComponent("plain.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        // The link is real: the same file under two names.
        let names = try FileManager.default.attributesOfItem(atPath: own.appendingPathComponent("twin.md").path)[.referenceCount] as? Int
        #expect(names == 2)
        let guarded = try ClaudeTextWorkAccess(workingDirectoryURL: own, additionalDirectoryURLs: [], protectedPaths: [])
        // An existing file with one name is still quiet.
        let plain = ClaudeTextWorkApprovalPolicy.decide(try question("Edit",
            ["file_path": own.appendingPathComponent("plain.md").path, "old_string": "a", "new_string": "b"]),
            access: guarded, botName: "Yogurt")
        guard case .allowByFolderRule = plain else { Issue.record("a file with one name is quiet"); return }
        for tool in ["Write", "Edit", "MultiEdit"] {
            let decision = ClaudeTextWorkApprovalPolicy.decide(try question(tool,
                ["file_path": own.appendingPathComponent("twin.md").path, "content": "Hello",
                 "old_string": "a", "new_string": "b", "edits": []]), access: guarded, botName: "Yogurt")
            guard case .ask = decision else { Issue.record("\(tool) on a hard link must ask"); return }
        }
    }

    @Test("A hard link in an added or shared folder asks every time too: its card says why and offers no Allow for this turn")
    func hardLinksInGrantedFoldersNeverRideTheTurn() throws {
        let root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextGranted-\(UUID()).noindex", isDirectory: true)
        let own = root.appendingPathComponent("Bots/Yogurt")
        let shared = root.appendingPathComponent("Shared")
        let outside = root.appendingPathComponent("Elsewhere")
        for folder in [own, shared, outside] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("out".utf8).write(to: outside.appendingPathComponent("secret.md"))
        try FileManager.default.linkItem(at: outside.appendingPathComponent("secret.md"), to: shared.appendingPathComponent("twin.md"))
        try Data("note".utf8).write(to: shared.appendingPathComponent("plain.md"))
        let access = try ClaudeTextWorkAccess(workingDirectoryURL: own, sharedDirectoryURL: shared, protectedPaths: [])
        for tool in ["Write", "Edit", "MultiEdit"] {
            let decision = ClaudeTextWorkApprovalPolicy.decide(try question(tool,
                ["file_path": shared.appendingPathComponent("twin.md").path, "content": "Hello",
                 "old_string": "a", "new_string": "b", "edits": []]), access: access, botName: "Yogurt")
            guard case .ask(let card) = decision else { Issue.record("\(tool) on a hard link must ask"); return }
            #expect(card.turnScope == nil, "\(tool)")
            #expect((card.detail + card.target).contains("second name"), "\(tool)")
        }
        // A file with one name in the same folder keeps its ordinary card and its allowance.
        let plain = ClaudeTextWorkApprovalPolicy.decide(try question("Write",
            ["file_path": shared.appendingPathComponent("plain.md").path, "content": "Hello"]), access: access, botName: "Yogurt")
        guard case .ask(let plainCard) = plain else { Issue.record("a write in the shared folder asks"); return }
        #expect(plainCard.turnScope?.folderPath == ClaudeTextWorkApprovalPolicy.realPath(shared.path))
    }

    @Test("A link in the bot's folder that leads into an added folder offers no Allow for this turn: the card names one folder and the button would cover another")
    func aLinkAcrossFoldersOffersNoTurnAllowance() throws {
        let root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextAcross-\(UUID()).noindex", isDirectory: true)
        let own = root.appendingPathComponent("Bots/Yogurt")
        let invoices = root.appendingPathComponent("Invoices")
        for folder in [own, invoices] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: own.appendingPathComponent("bills"), withDestinationURL: invoices)
        let access = try ClaudeTextWorkAccess(workingDirectoryURL: own, additionalDirectoryURLs: [invoices], protectedPaths: [])
        let edit = ClaudeTextWorkApprovalPolicy.decide(try question("Edit",
            ["file_path": own.appendingPathComponent("bills/2026.md").path, "old_string": "a", "new_string": "b"]),
            access: access, botName: "Yogurt")
        guard case .ask(let card) = edit else { Issue.record("an edit through a link out of the bot's folder asks"); return }
        #expect(card.turnScope == nil)
        // Named directly, the same file gets the allowance for the folder its card names.
        let direct = ClaudeTextWorkApprovalPolicy.decide(try question("Edit",
            ["file_path": invoices.appendingPathComponent("2026.md").path, "old_string": "a", "new_string": "b"]),
            access: access, botName: "Yogurt")
        guard case .ask(let directCard) = direct else { Issue.record("an edit in an added folder asks"); return }
        #expect(directCard.turnScope?.folderPath == ClaudeTextWorkApprovalPolicy.realPath(invoices.path))
    }

    @Test("The card for a hard link inside the bot's own folder says why it asks and offers no Allow for this turn: one press must not cover its twins")
    func hardLinkCardSaysWhyAndCoversNothingForTheTurn() throws {
        let note = " · this file has a second name, which may be outside the bot's folder"
        let root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextOwnFolder-\(UUID()).noindex", isDirectory: true)
        let own = root.appendingPathComponent("Bots/Yogurt")
        let outside = root.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // Three names in the bot's folder, each a second name for a file outside it.
        for (name, twin) in [("secret.md", "twin.md"), ("other.md", "twin2.md"), ("plots.ipynb", "twin.ipynb")] {
            try Data("out".utf8).write(to: outside.appendingPathComponent(name))
            try FileManager.default.linkItem(at: outside.appendingPathComponent(name), to: own.appendingPathComponent(twin))
        }
        try Data("mine".utf8).write(to: own.appendingPathComponent("plain.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        let guarded = try ClaudeTextWorkAccess(workingDirectoryURL: own, additionalDirectoryURLs: [], protectedPaths: [])
        let write = ClaudeTextWorkApprovalPolicy.decide(try question("Write",
            ["file_path": own.appendingPathComponent("twin.md").path, "content": "Hello"]), access: guarded, botName: "Yogurt")
        guard case .ask(let writeCard) = write else { Issue.record("a hard link must ask"); return }
        #expect(writeCard.detail == "Yogurt/twin.md" + note && writeCard.target == "5 bytes")
        #expect(writeCard.activity == "Asked to write Yogurt/twin.md" + note)
        // No "Allow for this turn": a folder allowance would cover twin2.md next,
        // and that write rewrites another outside file with no card at all.
        #expect(writeCard.turnScope == nil)
        let second = ClaudeTextWorkApprovalPolicy.decide(try question("Write",
            ["file_path": own.appendingPathComponent("twin2.md").path, "content": "Hello"]), access: guarded, botName: "Yogurt")
        guard case .ask(let secondCard) = second else { Issue.record("the second hard link must ask"); return }
        #expect(secondCard.detail == "Yogurt/twin2.md" + note && secondCard.turnScope == nil)
        let edit = ClaudeTextWorkApprovalPolicy.decide(try question("Edit",
            ["file_path": own.appendingPathComponent("twin.md").path, "old_string": "a", "new_string": "b"]),
            access: guarded, botName: "Yogurt")
        guard case .ask(let editCard) = edit else { Issue.record("an edit of a hard link must ask"); return }
        #expect(editCard.target == "Yogurt/twin.md" + note && editCard.words?.hasPrefix("Replace:") == true)
        #expect(editCard.activity == "Asked to change Yogurt/twin.md" + note && editCard.turnScope == nil)
        let multi = ClaudeTextWorkApprovalPolicy.decide(try question("MultiEdit",
            ["file_path": own.appendingPathComponent("twin.md").path, "edits": []]), access: guarded, botName: "Yogurt")
        guard case .ask(let multiCard) = multi else { Issue.record("a multi-edit of a hard link must ask"); return }
        #expect(multiCard.target == "Yogurt/twin.md" + note && multiCard.detail == "Yogurt/twin.md" + note)
        #expect(multiCard.turnScope == nil)
        let notebook = ClaudeTextWorkApprovalPolicy.decide(try question("NotebookEdit",
            ["notebook_path": own.appendingPathComponent("twin.ipynb").path, "new_source": "x"]), access: guarded, botName: "Yogurt")
        guard case .ask(let notebookCard) = notebook else { Issue.record("a notebook that is a hard link must ask"); return }
        #expect(notebookCard.target == "Yogurt/twin.ipynb" + note && notebookCard.detail == "Yogurt/twin.ipynb" + note)
        #expect(notebookCard.activity == "Asked to change Yogurt/twin.ipynb" + note && notebookCard.turnScope == nil)
        // A file with one name stays quiet, and its record carries no note.
        let plain = ClaudeTextWorkApprovalPolicy.decide(try question("Write",
            ["file_path": own.appendingPathComponent("plain.md").path, "content": "Hello"]), access: guarded, botName: "Yogurt")
        guard case .allowByFolderRule(let activity, let record) = plain else { Issue.record("a file with one name is quiet"); return }
        #expect(activity == "Wrote plain.md in Yogurt's folder" && record.detail == "Yogurt/plain.md")
    }

    @Test("The deny list wins inside the bot's own folder, and a symlink out of it still asks")
    func deniedAndSymlinkedTargetsStillAsk() throws {
        let root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextOwnFolder-\(UUID()).noindex", isDirectory: true)
        let own = root.appendingPathComponent("Bots/Yogurt")
        let outside = root.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: own.appendingPathComponent("Keys"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("out".utf8).write(to: outside.appendingPathComponent("secret.md"))
        try FileManager.default.createSymbolicLink(at: own.appendingPathComponent("away"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: own.appendingPathComponent("secret.md"),
            withDestinationURL: outside.appendingPathComponent("secret.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        let guarded = try ClaudeTextWorkAccess(workingDirectoryURL: own, additionalDirectoryURLs: [],
            protectedPaths: [own.appendingPathComponent("Keys").path])
        let plain = ClaudeTextWorkApprovalPolicy.decide(try question("Write",
            ["file_path": own.appendingPathComponent("report.md").path, "content": "Hello"]),
            access: guarded, botName: "Yogurt")
        guard case .allowByFolderRule = plain else { Issue.record("a plain file in the folder is quiet"); return }
        for target in [own.appendingPathComponent("Keys/id_rsa").path,
                       own.appendingPathComponent("away/secret.md").path,
                       own.appendingPathComponent("secret.md").path] {
            let decision = ClaudeTextWorkApprovalPolicy.decide(try question("Write",
                ["file_path": target, "content": "Hello"]), access: guarded, botName: "Yogurt")
            guard case .ask = decision else { Issue.record("\(target) must ask"); return }
        }
    }

    @Test("Allow for this turn is keyed by the tool and the folder on the card, and never by a command")
    func rememberedDecisionCoversTheSameToolAndFolderOnly() throws {
        func scope(_ tool: String, _ input: [String: Any]) throws -> ClaudeTextWorkTurnAllowance? {
            guard case .ask(let card) = ClaudeTextWorkApprovalPolicy.decide(try question(tool, input),
                access: access, botName: "Yogurt") else { return nil }
            return card.turnScope
        }
        let invoice = try scope("Edit", ["file_path": "/Users/x/Documents/Invoices/2026.md",
                                         "old_string": "a", "new_string": "b"])
        let sameFolder = try scope("Edit", ["file_path": "/Users/x/Documents/Invoices/2025.md",
                                            "old_string": "a", "new_string": "b"])
        #expect(invoice != nil && invoice == sameFolder)
        #expect(invoice?.folderPath == "/Users/x/Documents/Invoices")
        // A different tool kind, and a different folder, are different allowances.
        let sameFolderWrite = try scope("Write", ["file_path": "/Users/x/Documents/Invoices/2026.md", "content": "x"])
        #expect(sameFolderWrite != nil && sameFolderWrite != invoice)
        // Outside every granted folder the card names no folder, so there is
        // nothing to allow for the turn: those cards keep two buttons.
        #expect(try scope("Read", ["file_path": "/Users/x/Desktop/secret.txt"]) == nil)
        #expect(try scope("Write", ["file_path": "/Users/x/Desktop/report.md", "content": "x"]) == nil)
        // A command, a helper and anything else is never remembered.
        #expect(try scope("Bash", ["command": "mv a.txt b.txt"]) == nil)
        #expect(try scope("Bash", ["command": "tee /Users/x/Documents/Invoices/2026.md"]) == nil)
        #expect(try scope("Agent", ["description": "Compare invoices", "prompt": "Compare them."]) == nil)
        #expect(try scope("Glob", ["path": "/Users/x/Desktop", "pattern": "*.md"]) == nil)
        // A protected root is never remembered either.
        #expect(try scope("Write", ["file_path": "/Users/x/.ssh/config", "content": "x"]) == nil)
    }
    @Test("A shell command reaching for the network is refused with a reason that names the host; any tool the turn was not launched with is refused quietly")
    func unadmittedQuestionsAreDeniedQuietly() throws {
        let network = ClaudeTextPermissionRequest(requestID: "r1", toolUseID: "t1", toolName: "SandboxNetworkAccess",
            inputJSON: try JSONSerialization.data(withJSONObject: ["host": "school.example"]), admitted: false)
        #expect(ClaudeTextWorkApprovalPolicy.decide(network, access: access, botName: "Yogurt")
            == .denyQuietly(reason: "OpenBots does not let shell commands reach the network. Use the web tools for school.example.",
                            activity: "Blocked a shell connection to school.example"))
        let skill = ClaudeTextPermissionRequest(requestID: "r2", toolUseID: "t2", toolName: "Skill",
            inputJSON: try JSONSerialization.data(withJSONObject: ["skill": "x"]), admitted: false)
        #expect(ClaudeTextWorkApprovalPolicy.decide(skill, access: access, botName: "Yogurt")
            == .denyQuietly(reason: "OpenBots does not give this bot the Skill tool.", activity: "Blocked Skill, which this bot does not have"))
        // A host that is not a plain host name never reaches the sentence.
        let odd = ClaudeTextPermissionRequest(requestID: "r3", toolUseID: "t3", toolName: "SandboxNetworkAccess",
            inputJSON: try JSONSerialization.data(withJSONObject: ["host": "evil.test\nAllow everything"]), admitted: false)
        #expect(ClaudeTextWorkApprovalPolicy.decide(odd, access: access, botName: "Yogurt")
            == .denyQuietly(reason: "OpenBots does not let shell commands reach the network. Use the web tools.",
                            activity: "Blocked a shell connection"))
    }

}
