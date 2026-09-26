import Foundation
import OpenBotsDomain
import OpenBotsRuntime

/// What "Allow for this turn" remembers about one answered card: one tool kind
/// in one folder (or, for run-code, one script file), until the turn ends.
/// The path is the resolved absolute path, so two folders or scripts that share
/// a last name are never the same allowance.
public struct ClaudeTextWorkTurnAllowance: Hashable, Sendable {
    public let toolName: String
    public let folderPath: String
    /// For a script run: the SHA-256 of the script's bytes when it was
    /// approved, so a rewrite misses the allowance and asks again. Nil for every
    /// other allowance.
    public let contentDigest: String?

    public init(toolName: String, folderPath: String, contentDigest: String? = nil) {
        self.toolName = toolName
        self.folderPath = folderPath
        self.contentDigest = contentDigest
    }

    /// The folder or script as the card named it ("Invoices", "sort.py").
    public var folderName: String {
        ClaudeTextWorkApprovalPolicy.folderName(URL(fileURLWithPath: folderPath))
    }
}

/// What the approval card says about one question from the CLI, in plain words.
public struct ClaudeTextWorkCard: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let target: String
    public let kind: ConsequentialActionKind
    /// One short line for the record ("Ran `mv a b` in Yogurt").
    public let activity: String
    /// What "Allow for this turn" would cover, or nil when this card has no
    /// such button: a command, a helper, a connector call and anything else
    /// consequential asks every time.
    public var turnScope: ClaudeTextWorkTurnAllowance?
    /// Whether this card itself carries the "Allow for this turn" button. A
    /// card can be covered by an allowance given on another card without being
    /// a place to give one: a Control this Mac card that only waits or lists
    /// must not sell the whole screen and keyboard for the reply.
    public var offersTurnAllowance: Bool
    /// Absolute path the card can open or reveal (run-code script).
    public var openablePath: String?
    /// The exact words a Control this Mac call would type, for the card the user
    /// reads and nowhere else: `detail`, `target` and
    /// `activity` go on the record and keep only a count, so a password
    /// typed into a field is never stored.
    public var words: String?
    /// The line above `words` when they are a file's text rather than typing
    /// ("What it writes:"), drawn on its own lines. Nil keeps the typing form.
    public var wordsHeading: String?

    public init(title: String, detail: String, target: String, kind: ConsequentialActionKind,
                activity: String, turnScope: ClaudeTextWorkTurnAllowance? = nil, offersTurnAllowance: Bool = true,
                openablePath: String? = nil, words: String? = nil, wordsHeading: String? = nil) {
        self.title = title; self.detail = detail; self.target = target
        self.kind = kind; self.activity = activity; self.turnScope = turnScope
        self.offersTurnAllowance = offersTurnAllowance
        self.openablePath = openablePath
        self.words = words
        self.wordsHeading = wordsHeading
    }
}

public enum ClaudeTextWorkDecision: Equatable, Sendable {
    /// A plain read inside the bot's folders: allowed without a card, recorded.
    case allowQuietly(activity: String)
    /// An edit inside the bot's own working folder: done without a card, and still
    /// written to the approvals record, which is what the card carries here.
    case allowByFolderRule(activity: String, card: ClaudeTextWorkCard)
    case ask(ClaudeTextWorkCard)
    /// A question about a tool the turn never admitted: answered no by rule,
    /// with the sentence the model is shown and the line the record keeps.
    case denyQuietly(reason: String, activity: String)
}

/// The rule for the chat path: harmless read-only commands inside the
/// bot's folders may be allowed for the session; a Write, Edit, MultiEdit or
/// NotebookEdit inside the bot's own folder goes through without a card, unless its
/// target is protected, relative or a file with a second name; anything else that
/// changes files, runs a command with effects, or reaches outside those folders
/// asks. The CLI asks only about what its own rules would prompt for, so a plain
/// Read inside the folders never gets here; one that does is outside them.
public enum ClaudeTextWorkApprovalPolicy {
    /// Commands that only read, when every path they name stays inside the
    /// granted folders and nothing redirects, substitutes or chains a writer.
    /// This list is the only thing that lets a shell command the CLI asks about
    /// run without a card (the CLI is launched with `autoAllowBashIfSandboxed`
    /// off), so it errs strict: a brace, a parenthesis, a `$`, a backslash, a
    /// word opening with `=` or a glob that could reach `..` asks even when the
    /// spelling was harmless (`grep -E 'a{2}'`, `ls (a|b).txt`, jq objects). The
    /// CLI's shell may be zsh, where `*(e:'cmd':)` and `=(cmd)` run code and
    /// `=ls` names /bin/ls, or bash 3.2, where `.[.]` is `..`; both are refused.
    static let readOnlyCommands: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "rg", "find", "pwd", "echo", "printf",
        "file", "stat", "du", "df", "date", "which", "whoami", "uname", "tree", "sort", "uniq", "cut", "tr",
        "basename", "dirname", "readlink", "realpath", "diff", "cmp", "md5", "shasum", "xxd", "hexdump",
        "mdls", "sw_vers", "true", "false", "test", "[", "column", "nl", "tac", "rev", "fold",
        "strings", "jq", "od", "ps"
    ]
    static let readOnlyGitSubcommands: Set<String> = ["status", "log", "diff", "show", "branch", "ls-files", "rev-parse",
                                                       "remote", "blame", "describe", "tag"]
    /// Subcommands that only read when they take no target: `git remote add`,
    /// `git tag v1` and `git branch new` all write.
    static let argumentlessGitSubcommands: Set<String> = ["remote", "tag", "branch"]
    /// Options of allowlisted commands that write a file or run a program,
    /// by command, matched on the option's name before any `=`: a long one by
    /// any unambiguous abbreviation getopt would take (`--out=`, `--o`); a
    /// short one by its letter anywhere in a cluster for getopt-style commands
    /// (`-no`, `-oFILE`), and by prefix for whole-word primaries (`find`, `file`).
    static let writingOptionsByCommand: [String: [String]] = [
        "sort": ["-o", "--output", "--compress-program", "--files0-from"],
        "tree": ["-o", "--output"],
        "find": ["-fprint", "-fprintf", "-fls", "-fprint0", "-files0-from"],
        "file": ["-C", "--compile"],
        "rg": ["--pre", "--pre-glob", "--hostname-bin", "-z", "--search-zip"]
    ]
    /// getopt-style commands, where `-no` is the cluster `-n -o`; find's
    /// primaries are whole words and are matched by prefix instead.
    static let clusterCommands: Set<String> = ["sort", "tree", "uniq", "xxd", "rg"]
    /// Commands whose second positional word is an output file.
    static let onePositionalCommands: Set<String> = ["uniq", "xxd"]
    /// Short flags of those commands that take a value, so the value is not
    /// counted as a positional path (`xxd -l 64 notes.md`).
    static let valueFlagsByCommand: [String: Set<String>] = ["xxd": ["-l", "-s", "-c", "-g", "-o", "-n", "-R"],
                                                            "uniq": ["-f", "-s"]]

    /// The word as the shell hands it to the command: every quote removed, since
    /// `\` and `$` are refused outright, so no quote can be escaped or hide a
    /// value. `"-o"`, `"-o out`, `'-'o` and `so"rt"` are `-o`, `-o`, `-o`, `sort`.
    /// Over-strict only when one quote kind sits inside the other, the safe way.
    static func unquoted(_ word: String) -> String {
        word.filter { $0 != "\"" && $0 != "'" }
    }

    /// A host name as a sentence may carry it: letters, digits, dots and
    /// hyphens, at most 253 bytes. Anything else stays out of the words.
    static func isPlainHost(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 253 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 46 || $0 == 45
        }
    }

    static func isWritingOption(_ word: String, command: String) -> Bool {
        guard let writing = writingOptionsByCommand[command] else { return false }
        let name = word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? word
        for option in writing {
            if option.hasPrefix("--") {
                // `--o`, `--out`, `--output` all reach --output; `--` alone does not.
                if name.hasPrefix("--"), name.count > 2, option.hasPrefix(name) { return true }
            } else if clusterCommands.contains(command), !name.hasPrefix("--"), option.count == 2 {
                // A writing letter anywhere in a cluster: `-no`, `-uo`, `-oFILE`.
                if name.dropFirst().contains(option.dropFirst()) { return true }
            } else if name.hasPrefix(option) { return true }
        }
        return false
    }
    static let listingGitFlags: Set<String> = ["-v", "--list", "-a", "--all"]

    /// The pseudo-tool the CLI asks about when a sandboxed shell command
    /// reaches for a host (2.1.272). The web switches are the only door
    /// out, so the answer is no, and the sentence points at that door.
    static let sandboxNetworkToolName = "SandboxNetworkAccess"

    public static func decide(_ request: ClaudeTextPermissionRequest, access: ClaudeTextWorkAccess,
                              botName: String) -> ClaudeTextWorkDecision {
        let input = (try? JSONSerialization.jsonObject(with: request.inputJSON) as? [String: Any]) ?? [:]
        guard request.admitted else {
            if request.toolName == sandboxNetworkToolName {
                if let host = input["host"] as? String, isPlainHost(host) {
                    return .denyQuietly(reason: "OpenBots does not let shell commands reach the network. Use the web tools for \(host).",
                                        activity: "Blocked a shell connection to \(host)")
                }
                return .denyQuietly(reason: "OpenBots does not let shell commands reach the network. Use the web tools.",
                                    activity: "Blocked a shell connection")
            }
            return .denyQuietly(reason: "OpenBots does not give this bot the \(request.toolName) tool.",
                                activity: "Blocked \(request.toolName), which this bot does not have")
        }
        let place = folderName(access.workingDirectoryURL)
        // The skills folder is read-only whatever the CLI asks: a change there
        // is refused outright, never offered as a card to approve.
        if ["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(request.toolName),
           let raw = input["file_path"] as? String ?? input["notebook_path"] as? String,
           isInsideSkills(raw, access: access) {
            return .denyQuietly(reason: "Skills are read-only. Tell the user what should change in the skill instead.",
                                activity: "Blocked a change to \(displayPath(raw, access: access)): skills are read-only")
        }
        switch request.toolName {
        case "Bash":
            let command = (input["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = command.isEmpty ? "(empty command)" : command
            // What a turn starts ends with it: the app reaps the CLI's tree at
            // every turn's end. A background run would be killed a moment after
            // the bot said it was running, so it is refused before it starts,
            // and the bot is told why.
            if sendsToBackground(command) {
                return .denyQuietly(reason: Self.backgroundReason,
                                    activity: "Refused a background run: `\(clip(shown))` in \(place)")
            }
            if isReadOnly(command, access: access) {
                return .allowQuietly(activity: "Ran `\(clip(shown))` in \(place)")
            }
            // A script run gets the run card (interpreter, script, folder).
            if let run = ClaudeTextRunCodePolicy.decide(command, access: access, botName: botName) {
                return run
            }
            let kind = commandKind(command)
            if kind == .packageInstall {
                return .ask(ClaudeTextRunCodePolicy.namedPackageInstallCard(command: shown, place: place))
            }
            // Inline code names its interpreter; a worse part keeps its own title.
            let named = kind == .productionChange ? ClaudeTextRunCodePolicy.inlineCodeTitle(command) : nil
            return .ask(ClaudeTextWorkCard(title: named ?? title(for: kind, tool: "Bash"),
                detail: shown, target: "In \(place)", kind: kind,
                activity: "Asked to run `\(clip(shown))` in \(place)"))
        case "Agent":
            let description = input["description"] as? String ?? "Help with this task"
            let prompt = input["prompt"] as? String ?? description
            return .ask(ClaudeTextWorkCard(title: "Start a helper for \(botName)",
                detail: prompt,
                target: "Same folders and permissions · up to \(ClaudeTextHelperPolicy.maximumTurns) turns · stops with this task",
                kind: .productionChange, activity: "Asked a helper to \(clip(description))"))
        case "Write":
            let raw = input["file_path"] as? String
            let (path, scope) = editTarget(toolName: "Write", path: raw, access: access)
            let content = input["content"] as? String ?? ""
            let bytes = content.utf8.count
            // The text goes on the card only, never the record.
            let card = ClaudeTextWorkCard(title: "Create or replace a file", detail: path,
                target: bytes > 0 ? "\(bytes) bytes" : "Empty file", kind: .overwrite,
                activity: "Asked to write \(path)", turnScope: scope,
                words: bytes > 0 ? shownFileWords(content) : nil, wordsHeading: bytes > 0 ? "What it writes:" : nil)
            if isInsideOwnFolder(raw, access: access) {
                return .allowByFolderRule(activity: "Wrote \(ownFolderPath(raw, access: access)) in \(owner(botName, access))'s folder",
                    card: card)
            }
            return .ask(card)
        case "Edit", "MultiEdit":
            let raw = input["file_path"] as? String
            let (path, scope) = editTarget(toolName: request.toolName, path: raw, access: access)
            // The old and new text go on the card only, whole up to a bound,
            // never the record; replace-all is named.
            var words: String?
            if let old = input["old_string"] as? String, let new = input["new_string"] as? String {
                words = shownFileWords("Replace:\n\(old)\n\nWith:\n\(new)")
            }
            let everywhere = (input["replace_all"] as? Bool) == true
            let detail = everywhere ? "\(path) — in every place the text appears" : path
            let card = ClaudeTextWorkCard(title: "Change a file", detail: detail, target: path, kind: .overwrite,
                activity: "Asked to change \(path)", turnScope: scope,
                words: words, wordsHeading: words == nil ? nil : "The change:")
            if isInsideOwnFolder(raw, access: access) {
                return .allowByFolderRule(activity: "Edited \(ownFolderPath(raw, access: access)) in \(owner(botName, access))'s folder",
                    card: card)
            }
            return .ask(card)
        case "NotebookEdit":
            let raw = input["notebook_path"] as? String
            let (path, scope) = editTarget(toolName: "NotebookEdit", path: raw, access: access)
            let card = ClaudeTextWorkCard(title: "Change a notebook", detail: path, target: path, kind: .overwrite,
                activity: "Asked to change \(path)", turnScope: scope)
            if isInsideOwnFolder(raw, access: access) {
                return .allowByFolderRule(activity: "Edited \(ownFolderPath(raw, access: access)) in \(owner(botName, access))'s folder",
                    card: card)
            }
            return .ask(card)
        case "Read", "Glob", "Grep", "LSP":
            let raw = input["file_path"] as? String ?? input["path"] as? String
            let path = displayPath(raw, access: access)
            // Only a read of one named file can be remembered: Glob and Grep are
            // given a folder already, so the folder they name is not a narrowing.
            return .ask(ClaudeTextWorkCard(title: "Read outside its folders", detail: path, target: path,
                kind: .metadataMutation, activity: "Asked to read \(path)",
                turnScope: request.toolName == "Read" ? turnScope(toolName: "Read", path: raw, access: access) : nil))
        case "WebSearch", "WebFetch":
            // Pre-approved by the web switches; if the CLI still asks, the
            // answer the switches already gave stands.
            let what = input["query"] as? String ?? input["url"] as? String ?? request.toolName
            return .allowQuietly(activity: "\(request.toolName == "WebSearch" ? "Searched" : "Fetched") \(clip(what))")
        default:
            return .ask(ClaudeTextWorkCard(title: "Use \(request.toolName)", detail: clip(String(decoding: request.inputJSON, as: UTF8.self), 800),
                target: place, kind: .productionChange, activity: "Asked to use \(request.toolName)"))
        }
    }

    /// How much of a file's text a Write or Edit card shows.
    public static let maximumShownFileWords = 4_000

    static func shownFileWords(_ text: String) -> String {
        guard text.count > maximumShownFileWords else { return text }
        return String(text.prefix(maximumShownFileWords))
            + "\n… and \(text.count - maximumShownFileWords) more characters, not shown."
    }

    /// Whether any scalar breaks a line. Swift folds "\r\n" into one Character,
    /// so `contains("\n")` is false for it while bash runs the second
    /// line. Every command rule asks this, never `contains`.
    public static func hasLineBreak(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
    }

    /// True only for a single simple read-only command, or a pipe or chain of
    /// them, with no redirection, substitution, background job, sudo or
    /// interpreter, and every path staying inside the granted folders.
    public static func isReadOnly(_ command: String, access: ClaudeTextWorkAccess) -> Bool {
        guard !command.isEmpty, command.utf8.count <= 2_048, !hasLineBreak(command) else { return false }
        // Braces are bash's expansion, not this rule's: `{-ooutput.txt,notes.md}` and
        // `{/etc,}/passwd` would pass as one harmless word each. Like `$` and `\`,
        // they are refused wholesale.
        let forbiddenFragments = [">", "<", "$(", "`", "&", "\n", ";", "\\", "{", "}", "(", ")", "sudo", "xargs", "-exec", "-delete",
                                  "--delete", "-ok", "eval", "exec", "source"]
        for fragment in forbiddenFragments where command.contains(fragment) { return false }
        for segment in command.components(separatedBy: "|") {
            let words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                .filter { !$0.isEmpty }.map(unquoted)
            guard let first = words.first, !first.isEmpty else { return false }
            if first == "git" {
                guard isSystemProgram("git"), words.count >= 2, readOnlyGitSubcommands.contains(words[1]),
                      !words.dropFirst(2).contains(where: { $0.hasPrefix("-") && $0 != "--oneline" && $0 != "--stat" && $0 != "-p" && $0 != "--name-only" && $0 != "-v" && $0 != "-n" && !listingGitFlags.contains($0) }) else { return false }
                if argumentlessGitSubcommands.contains(words[1]),
                   words.dropFirst(2).contains(where: { !listingGitFlags.contains($0) }) { return false }
            } else {
                guard readOnlyCommands.contains(first), isSystemProgram(first) else { return false }
                if first == "find", words.contains(where: { $0.hasPrefix("-exec") || $0 == "-delete" || $0 == "-ok" }) { return false }
                // Only a dashed cluster of listing flags: `-E` (and `-e` or a
                // bare `e` in the legacy syntax) prints every listed process's
                // environment, tokens included.
                if first == "ps", words.count > 2
                    || words.dropFirst().contains(where: { !Self.isQuietPsCluster($0) }) { return false }
            }
            if onePositionalCommands.contains(first) {
                var positionals = 0
                var skipNext = false
                for word in words.dropFirst() {
                    if skipNext { skipNext = false; continue }
                    // A bare `-` is stdin: a positional, not an option (`uniq - out.txt` writes out.txt).
                    if word == "-" { positionals += 1; continue }
                    if word.hasPrefix("-") { skipNext = valueFlagsByCommand[first]?.contains(word) ?? false; continue }
                    // One glob word is any number of files, and the second file is the output (`uniq *.txt` overwrote b.txt).
                    if word.contains(where: { "*?[".contains($0) }) { return false }
                    positionals += 1
                }
                if positionals > 1 { return false }
            }
            for word in words.dropFirst() {
                // A variable or a home shortcut could name anything on the Mac.
                if word.contains("$") || word.contains("~") { return false }
                if word.hasPrefix("-") {
                    // Options that write a file or run a program are not reading.
                    if isWritingOption(word, command: first) { return false }
                    // `--file=../x` or `--file=/path` names a place after the `=`,
                    // judged like any path; any other slash inside an option
                    // (`-C/path`) is a path this rule cannot read.
                    if let equals = word.firstIndex(of: "=") {
                        let value = String(word[word.index(after: equals)...])
                        guard pathStaysInside(value, access: access) else { return false }
                    } else if word.contains("/") { return false }
                    continue
                }
                guard pathStaysInside(word, access: access) else { return false }
            }
        }
        return true
    }

    /// A word that looks like a path must resolve inside the bot's folders. A
    /// relative word stays inside the working folder when no component is `..`
    /// and no glob component could expand to it (bash 3.2 matches `..` with
    /// `.[.]`, `.?`, `.*` and `.[!a]`; a bracket never matches the leading dot,
    /// so `[.][.]` cannot); an absolute or `~` path must sit under a granted folder.
    static func pathStaysInside(_ word: String, access: ClaudeTextWorkAccess) -> Bool {
        let token = word.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        if token.contains("..") { return false }
        // `~` is a home, `=ls` is zsh for /bin/ls: either names a place outside.
        if token.hasPrefix("~") || token.hasPrefix("=") { return false }
        for component in token.split(separator: "/") where component.contains(where: { "*?[".contains($0) }) {
            if String(component).withCString({ fnmatch($0, "..", FNM_PERIOD) == 0 }) { return false }
        }
        guard token.hasPrefix("/") else { return true }
        let granted = [access.workingDirectoryURL] + access.grantedDirectoryURLs
        return granted.contains { token == $0.path || token.hasPrefix($0.path + "/") }
    }

    /// The bot in the possessive of the quiet line ("in Yogurt's folder"); the
    /// folder's own name when the turn carries no bot name.
    static func owner(_ botName: String, _ access: ClaudeTextWorkAccess) -> String {
        botName.isEmpty ? folderName(access.workingDirectoryURL) : botName
    }

    /// The path as the disk knows it: every symlink in the part that exists
    /// resolved, and the part that does not exist yet appended unchanged, so a
    /// file the bot is about to create is judged by the folder it lands in.
    /// Returns the path itself when nothing on the way resolves.
    static func realPath(_ path: String) -> String {
        var tail: [String] = []
        var current = path
        // 4,096 bytes of path cannot hold more components than this.
        for _ in 0..<512 {
            if let resolved = current.withCString({ realpath($0, nil) }) {
                defer { free(resolved) }
                var url = URL(fileURLWithPath: String(cString: resolved))
                for component in tail.reversed() { url.appendPathComponent(component) }
                return url.path
            }
            let url = URL(fileURLWithPath: current)
            let parent = url.deletingLastPathComponent().path
            guard parent != current, !parent.isEmpty else { break }
            tail.append(url.lastPathComponent)
            current = parent
        }
        return path
    }

    /// The resolved target of a file tool when its path sits inside the bot's
    /// own working folder and nowhere else; nil otherwise. An added folder is
    /// not the bot's own folder; a `..` or `.` component, a `~`, a symlink that
    /// points out of the folder and anything under the deny list all fail here.
    /// A file that does not exist yet is inside when its folder is. A relative
    /// path fails too: the CLI places it against its own shell folder, which a
    /// `cd` in an earlier command may have moved anywhere, so joining it onto
    /// the bot's folder here would judge a path the CLI never writes.
    static func ownFolderTarget(_ raw: String?, access: ClaudeTextWorkAccess) -> String? {
        guard let raw, raw.hasPrefix("/"), raw.utf8.count <= 4_096 else { return nil }
        // A resolved path never shows these, so they are refused as written.
        guard !raw.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let target = realPath(raw)
        guard target.hasPrefix(realPath(access.workingDirectoryURL.path) + "/") else { return nil }
        return isDenied(target, access: access) ? nil : target
    }

    /// True when a file tool's target is inside the bot's own working folder
    /// (`ownFolderTarget`) and may go through without a card. A file the disk knows
    /// under a second name (a hard link) fails: the other name may be outside the
    /// folder, and a write here rewrites it there as well.
    static func isInsideOwnFolder(_ raw: String?, access: ClaudeTextWorkAccess) -> Bool {
        guard let target = ownFolderTarget(raw, access: access) else { return false }
        return !hasSecondName(target) && !isGitSetting(target, in: access)
    }

    /// True for what git reads as settings, drivers or hooks: anything under a
    /// `.git`, and a `.gitattributes` or `.gitmodules` file. Written quietly,
    /// `.git/config` could name `diff.external`, a textconv driver or
    /// `core.fsmonitor`, and the quiet `git diff`, `git show` or `git status`
    /// would run it. Compared without
    /// case, as the Mac's disk compares names.
    static func isGitSetting(_ target: String, in access: ClaudeTextWorkAccess) -> Bool {
        let root = realPath(access.workingDirectoryURL.path)
        let relative = target.hasPrefix(root + "/") ? String(target.dropFirst(root.count + 1)) : target
        let parts = relative.split(separator: "/").map { $0.lowercased() }
        return parts.contains(".git") || [".gitattributes", ".gitmodules"].contains(parts.last ?? "")
    }

    /// One `ps` option word that only lists: a dash and listing letters, never
    /// `e` or `E` (the environment), nor an option that takes a value.
    static func isQuietPsCluster(_ word: String) -> Bool {
        let letters = word.dropFirst()
        return word.hasPrefix("-") && !letters.isEmpty && letters.allSatisfy { "AacCfhjlmMrSTuvwXx".contains($0) }
    }

    /// True for the one target `isInsideOwnFolder` turns away for its second
    /// name alone: the card it gets says so (`secondNameNote`).
    static func hasSecondNameInsideOwnFolder(_ raw: String?, access: ClaudeTextWorkAccess) -> Bool {
        guard let target = ownFolderTarget(raw, access: access) else { return false }
        return hasSecondName(target)
    }

    /// True for a plain file that exists under more than one name. `realPath`
    /// has already followed every symlink, so a second name left at this point
    /// is a hard link, and no path check can say where its other names sit. A
    /// folder is left out: its link count counts its entries, not other names.
    static func hasSecondName(_ resolved: String) -> Bool {
        var info = stat()
        guard stat(resolved, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink > 1
    }

    /// The spellings one path goes by, for a fence compared by prefix: as
    /// written with `.` and `..` taken out, with every symlink
    /// followed, and each of those without the firmlinked data volume's prefix
    /// (`/System/Volumes/Data/Users/x` is `/Users/x`, and `realpath` keeps
    /// whichever it was given). Temporary paths need both sides: `/tmp` and
    /// `/var` are written one way and resolve to `/private/…`.
    static let dataVolume = "/System/Volumes/Data"

    static func spellings(_ path: String) -> Set<String> {
        func onDataVolume(_ spelling: String) -> String {
            if spelling == dataVolume { return "/" }
            return spelling.hasPrefix(dataVolume + "/") ? String(spelling.dropFirst(dataVolume.count)) : spelling
        }
        let lexical = BotWorkspaceService.lexicalPath(path)
        let resolved = realPath(lexical)
        return [lexical, onDataVolume(lexical), resolved, onDataVolume(resolved)]
    }

    /// True when any spelling of `path` is any spelling of one of `roots`, or
    /// sits under it.
    static func isAtOrUnder(_ path: String, anyOf roots: [String]) -> Bool {
        let own = spellings(path)
        return roots.contains { root in
            spellings(root).contains { fence in own.contains { $0 == fence || $0.hasPrefix(fence + "/") } }
        }
    }

    /// The deny list wins over every rule here, including a protected root that
    /// sits inside the bot's own folder.
    /// Compared by every spelling: `realpath` keeps the
    /// data volume's spelling of a path it is given, so a target written
    /// `/System/Volumes/Data/Users/…` is still under a root written `/Users/…`.
    static func isDenied(_ resolved: String, access: ClaudeTextWorkAccess) -> Bool {
        isAtOrUnder(resolved, anyOf: access.protectedPaths)
    }

    /// The target as the quiet line names it: what follows the bot's own folder
    /// ("notes.md", "Notes/todo.md").
    static func ownFolderPath(_ raw: String?, access: ClaudeTextWorkAccess) -> String {
        guard let raw else { return "(no path)" }
        let home = access.workingDirectoryURL.path
        if raw.hasPrefix(home + "/") { return clip(String(raw.dropFirst(home.count + 1)), 300) }
        return clip(raw, 300)
    }

    /// The folder "Allow for this turn" would cover for one call: the granted
    /// folder the target sits in, and only that. It is the folder the card
    /// itself names, because `displayPath` writes the target as that folder and
    /// what follows it ("Invoices/2026.md"). A target outside every granted
    /// folder gets no allowance: the card shows it as a bare path, naming no
    /// folder, so a button covering its whole directory would promise more than
    /// the user read — and would widen access past the grant. A named file
    /// only, and never one under the deny list.
    static func turnScope(toolName: String, path: String?,
                          access: ClaudeTextWorkAccess) -> ClaudeTextWorkTurnAllowance? {
        guard ["Write", "Edit", "MultiEdit", "NotebookEdit", "Read"].contains(toolName),
              let path, path.hasPrefix("/"), path.utf8.count <= 4_096,
              !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let roots = [access.workingDirectoryURL] + access.grantedDirectoryURLs
        // The folder the card names is the one the path is written under; a link
        // that leads from there into another granted folder would make the button
        // cover a folder the card never named, so it offers none.
        guard let named = roots.firstIndex(where: { path.hasPrefix($0.path + "/") }) else { return nil }
        let target = realPath(path)
        guard !isDenied(target, access: access),
              let landed = roots.firstIndex(where: { target.hasPrefix(realPath($0.path) + "/") }),
              landed == named else { return nil }
        return ClaudeTextWorkTurnAllowance(toolName: toolName, folderPath: realPath(roots[landed].path))
    }

    /// True when one of the system folders, which lead a work turn's PATH and
    /// which no process of the user's can write, holds a program by this name. The
    /// no-card list trusts a command by its name, and a work turn's PATH goes on
    /// to user-writable folders (Homebrew's, ~/.local/bin), where `rg`, `tree`
    /// and `tac` would be found if planted.
    static func isSystemProgram(_ name: String) -> Bool {
        guard !name.contains("/") else { return false }
        return ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].contains {
            FileManager.default.isExecutableFile(atPath: "\($0)/\(name)")
        }
    }

    static let backgroundReason = "Run it in the foreground and wait for it. Anything started in the background "
        + "is stopped when this turn ends, so it would not keep running."

    /// True when the command starts something meant to outlive it: a lone `&`
    /// outside quotes (not `&&`, `2>&1` or `&>`), or `nohup`, `setsid` or
    /// `disown` as a command's first word.
    static func sendsToBackground(_ command: String) -> Bool {
        let characters = Array(command)
        var quote: Character?
        var escaped = false
        for (index, character) in characters.enumerated() {
            // A backslash takes the next character literally, outside quotes and
            // inside double ones; inside single quotes it is itself.
            if escaped { escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            if character == "'" || character == "\"" { quote = character; continue }
            guard character == "&" else { continue }
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            // `&&` chains, `2>&1` and `&>` redirect, `|&` pipes both streams.
            if previous == "&" || next == "&" || previous == ">" || next == ">" || previous == "|" { continue }
            return true
        }
        return command.split(whereSeparator: \.isNewline).flatMap { commandSegments(String($0)) }.contains { segment in
            let first = segment.split(separator: " ").first.map { URL(fileURLWithPath: unquoted(String($0))).lastPathComponent }
            return ["nohup", "setsid", "disown"].contains(first ?? "")
        }
    }

    /// A chained command (`echo ok; rm -rf ~/Documents`) is classified by its
    /// worst part, because the card's title and the permanent approval row
    /// carry the kind: read by its first word alone, that command was "Run a
    /// command". Segments split on `;`, `&&`, `||` and `|` outside quotes.
    static func commandKind(_ command: String) -> ConsequentialActionKind {
        let kinds = commandSegments(command).map(segmentKind)
        return kinds.max(by: { severity($0) < severity($1) }) ?? .productionChange
    }

    /// Worst first: what leaves the Mac or destroys, then what changes access
    /// or installs, then what writes or moves, then anything else.
    static func severity(_ kind: ConsequentialActionKind) -> Int {
        switch kind {
        case .delete: 7
        case .send: 6
        case .permissionChange: 5
        case .packageInstall: 4
        case .overwrite: 3
        case .move: 2
        default: 0
        }
    }

    /// The command split at its chain operators outside single and double
    /// quotes; a separator inside quotes is text.
    static func commandSegments(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var previous: Character?
        let characters = Array(command)
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
                current.append(character)
            } else if hasLineBreak(String(character)) {
                // A line break ends a segment as `;` does.
                // Only a backslash before a bare LF continues the line: before
                // CRLF it escapes the CR, and the LF still ends the command.
                if previous == "\\" && character == "\n" { current.removeLast() }
                else { segments.append(current); current = "" }
            } else if character == "&" && (previous == ">" || next == ">") {
                // `2>&1` and `&>` are redirections, not separators.
                current.append(character)
            } else if character == ";" || character == "|" || character == "&" {
                // `&&`, `||` and `;` end a segment; a lone `|` does too. A
                // lone `&` (background) ends one as well.
                if !(character == previous && (character == "&" || character == "|")) {
                    segments.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
            previous = character
        }
        segments.append(current)
        return segments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func segmentKind(_ command: String) -> ConsequentialActionKind {
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // The program by its own name: `"$TMPDIR/venv/bin/pip"` is pip.
        let first = words.first.map { URL(fileURLWithPath: unquoted($0)).lastPathComponent } ?? ""
        switch first {
        case "python3", "python":
            // `python3 -m pip install x` installs; anything else it runs is a command.
            if words.count > 3, words[1] == "-m", ["pip", "pip3"].contains(words[2]),
               ["install", "download"].contains(words[3]) { return .packageInstall }
            return .productionChange
        case "uv":
            // `uv run x.py` runs; `uv add`, `uv pip install`, `uv tool install` and `uv sync` install.
            if words.count > 1, ["add", "pip", "tool", "sync"].contains(words[1]) { return .packageInstall }
            return .productionChange
        case "rm", "rmdir", "trash", "unlink", "shred": return .delete
        case "mv": return .move
        case "cp", "rsync", "tee", "touch", "mkdir", "ln", "dd", "tar", "unzip", "zip": return .overwrite
        case "chmod", "chown", "chflags", "xattr": return .permissionChange
        case "brew", "npm", "pip", "pip3", "gem", "cargo", "pnpm", "yarn", "port": return .packageInstall
        case "git":
            if words.count > 1, ["push", "remote", "send-email"].contains(words[1]) { return .send }
            return .overwrite
        case "curl", "wget", "mail", "sendmail", "osascript", "open": return .send
        default: return .productionChange
        }
    }

    static func title(for kind: ConsequentialActionKind, tool: String) -> String {
        switch kind {
        case .delete: "Delete files with a command"
        case .move: "Move or rename files with a command"
        case .overwrite: "Copy or write files with a command"
        case .permissionChange: "Change permissions with a command"
        case .packageInstall: "Install software with a command"
        case .send: "Send or reach outside with a command"
        default: "Run a command"
        }
    }

    /// A relative path is shown as written, with a note that it is the CLI's
    /// shell folder, not a folder OpenBots can name, that decides where it lands.
    static let relativePathNote = " · relative to the bot's shell folder, which OpenBots cannot see"

    /// A hard link inside the bot's own folder is shown with a note saying why
    /// a card came up for the bot's own folder at all: the disk knows the file
    /// under another name, and no path check can say where that name sits.
    static let secondNameNote = " · this file has a second name, which may be outside the bot's folder"

    /// What an edit card shows as its path, and what "Allow for this turn"
    /// would cover. A hard link inside the bot's own folder carries
    /// `secondNameNote` and gets no allowance at all: the folder allowance
    /// would cover its twins for the rest of the turn, and each of those
    /// writes rewrites some other name with no card.
    static func editTarget(toolName: String, path raw: String?,
                           access: ClaudeTextWorkAccess) -> (shown: String, turnScope: ClaudeTextWorkTurnAllowance?) {
        let shown = displayPath(raw, access: access)
        if hasSecondNameInsideOwnFolder(raw, access: access) { return (shown + secondNameNote, nil) }
        // The same holds in an added folder or the shared folder: an allowance
        // for the folder would cover the file's twins wherever they are.
        if let raw, raw.hasPrefix("/"), hasSecondName(realPath(raw)) { return (shown + grantedSecondNameNote, nil) }
        return (shown, turnScope(toolName: toolName, path: raw, access: access))
    }

    /// The note for a hard link outside the bot's own folder.
    static let grantedSecondNameNote = " · this file has a second name, which may be outside this folder"

    static func displayPath(_ raw: String?, access: ClaudeTextWorkAccess) -> String {
        guard let raw, !raw.isEmpty else { return "(no path)" }
        guard raw.hasPrefix("/") || raw.hasPrefix("~") else { return clip(raw, 300) + relativePathNote }
        let home = access.workingDirectoryURL.path
        if raw.hasPrefix(home + "/") {
            return "\(folderName(access.workingDirectoryURL))/\(raw.dropFirst(home.count + 1))"
        }
        for folder in access.grantedDirectoryURLs where raw.hasPrefix(folder.path + "/") {
            return "\(folderName(folder))/\(raw.dropFirst(folder.path.count + 1))"
        }
        return clip(raw, 300)
    }

    static func folderName(_ url: URL) -> String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }

    /// Whether a path lands in the skills root, any bot's skills, or in the
    /// bot's own skills folder for an access built without a root; judged on
    /// the disk's own spelling so a link into it counts, a relative path as written.
    static func isInsideSkills(_ raw: String, access: ClaudeTextWorkAccess) -> Bool {
        guard let skills = access.readOnlyDirectoryURL else { return false }
        let root = realPath(skills.path)
        let target = raw.hasPrefix("/") ? realPath(raw) : raw
        return target == root || target.hasPrefix(root + "/") || raw.hasPrefix(skills.path + "/")
    }

    static func clip(_ text: String, _ limit: Int = 160) -> String {
        let oneLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return oneLine.count <= limit ? oneLine : String(oneLine.prefix(limit - 1)) + "…"
    }
}
