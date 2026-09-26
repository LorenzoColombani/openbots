import CryptoKit
import Foundation
import OpenBotsDomain
import OpenBotsRuntime

/// Recognise a Bash call that runs a script file with an interpreter
/// already on the Mac, and shape the approval card (interpreter, script, folder).
public enum ClaudeTextRunCodePolicy: Sendable {
    public struct Invocation: Equatable, Sendable {
        public let interpreterLabel: String
        public let interpreterToken: String
        public let scriptPath: String
        public let scriptName: String
        public let workingFolderName: String
        /// The script's absolute path, resolved from the shell's folder.
        public let resolvedScriptPath: String
        /// The turn allowance key (this same file only), or nil when the
        /// script sits outside the bot's folders and must ask every time.
        public let allowanceKey: String?
    }

    /// The interpreters and runners a run card covers. `uv run` is included.
    private static let interpreterTokens: Set<String> = [
        "python3", "python", "node", "ruby", "swift", "uv"
    ]

    /// Script extensions we treat as a file run (not `python3 -c`).
    private static let scriptExtensions: Set<String> = [
        "py", "js", "mjs", "cjs", "ts", "rb", "swift"
    ]

    /// Python's own switches that take no value and change nothing outside the
    /// run (`python3 -u count.py`); `-X` and `-W` take one word after them.
    private static let pythonFlags: Set<String> = ["-u", "-B", "-O", "-OO", "-E", "-I", "-s", "-S", "-q", "-b", "-bb"]
    private static let pythonValueFlags: Set<String> = ["-X", "-W"]

    /// When the Bash command is one script run and nothing else that acts,
    /// return the structured invocation. The shapes are the ones Claude Code
    /// 2.1.280 sent (fixture `run-code-probe`): the run alone, a
    /// `cd` into one of the bot's folders before it, `2>&1`, and read-only
    /// commands after it or piped from it. Anything else is not a run card:
    /// the allowance a run card offers is keyed on the script, so a command
    /// that also deletes, writes or starts something in the background must
    /// never match it (`python3 a.py && rm -rf notes` once did).
    public static func parse(_ command: String, access: ClaudeTextWorkAccess) -> Invocation? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2_048,
              !ClaudeTextWorkApprovalPolicy.hasLineBreak(trimmed) else { return nil }
        // One run, read whole: a newline is a second command, `$` and backticks
        // substitute, `\` escapes, braces and parentheses expand or group, and a
        // redirection other than `2>&1` reads or writes a file.
        // `2>&1` only as a word of its own: `2>&1file` sends both streams to a file named 1file.
        let bare = trimmed.replacingOccurrences(of: #"(?<=\s)2>&1(?=\s|$)"#, with: " ", options: .regularExpression)
        for fragment in ["\n", "\r", "$", "`", "\\", "<", ">", "{", "}", "(", ")"] where bare.contains(fragment) {
            return nil
        }
        guard let segments = chainSegments(bare) else { return nil }
        var folder = access.workingDirectoryURL.standardizedFileURL.path
        var runWords: [String]?
        for (index, segment) in segments.enumerated() {
            let words = shellWords(segment)
            guard let first = words.first else { return nil }
            if first == "cd" {
                // Only first, and only into one of the bot's folders.
                guard index == 0, words.count == 2,
                      let moved = changedFolder(words[1], access: access) else { return nil }
                folder = moved
                continue
            }
            if interpreterTokens.contains(URL(fileURLWithPath: first).lastPathComponent) {
                guard runWords == nil else { return nil }
                runWords = words
                continue
            }
            guard ClaudeTextWorkApprovalPolicy.isReadOnly(segment, access: access) else { return nil }
        }
        guard let words = runWords, let (token, scriptIndex) = scriptPosition(words) else { return nil }
        let scriptRaw = words[scriptIndex]
        let ext = (scriptRaw as NSString).pathExtension.lowercased()
        guard scriptExtensions.contains(ext) || token == "uv" else { return nil }

        let resolved = resolveScriptPath(scriptRaw, from: folder)
        return Invocation(
            interpreterLabel: label(token),
            interpreterToken: token,
            scriptPath: scriptRaw,
            scriptName: URL(fileURLWithPath: scriptRaw).lastPathComponent,
            workingFolderName: ClaudeTextWorkApprovalPolicy.folderName(URL(fileURLWithPath: folder)),
            resolvedScriptPath: resolved,
            allowanceKey: allowanceKey(resolved, access: access)
        )
    }

    /// The interpreter and where the script sits in the run's words; nil for
    /// inline code (`-c`, `-m`, `-e`, a bare `-` reading a heredoc) or a switch
    /// this rule does not know.
    private static func scriptPosition(_ words: [String]) -> (String, Int)? {
        let token = URL(fileURLWithPath: words[0]).lastPathComponent
        var index = 1
        if token == "uv" {
            // `uv run script.py` or `uv run python script.py`
            guard words.count >= 3, words[1] == "run" else { return nil }
            index = interpreterTokens.contains(URL(fileURLWithPath: words[2]).lastPathComponent) ? 3 : 2
        } else if token == "python3" || token == "python" {
            while index < words.count, words[index].hasPrefix("-") {
                if pythonFlags.contains(words[index]) { index += 1 }
                else if pythonValueFlags.contains(words[index]) { index += 2 }
                else { return nil }
            }
        }
        guard index < words.count, !words[index].hasPrefix("-") else { return nil }
        return (token, index)
    }

    private static func label(_ token: String) -> String {
        switch token {
        case "python3", "python": "Python 3"
        case "node": "Node.js"
        case "ruby": "Ruby"
        case "swift": "Swift"
        case "uv": "uv"
        default: token
        }
    }

    /// The card's title for inline code (`python3 -c …`, `python3 - <<'EOF'`,
    /// `node -e …`): no script to name, so the interpreter is named instead.
    /// Nil for anything else. Inline code never gets an allowance.
    public static func inlineCodeTitle(_ command: String) -> String? {
        let firstLine = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        var segments = ClaudeTextWorkApprovalPolicy.commandSegments(firstLine)
        if let first = segments.first, shellWords(first).first == "cd" { segments.removeFirst() }
        guard let run = segments.first else { return nil }
        let words = shellWords(run)
        guard words.count >= 2 else { return nil }
        let token = URL(fileURLWithPath: words[0]).lastPathComponent
        guard token != "uv", interpreterTokens.contains(token), ["-c", "-e", "-"].contains(words[1]) else { return nil }
        return "Run \(label(token)) code"
    }

    /// The command split at `&&`, `||`, `|` and `;` outside quotes; nil when a
    /// lone `&` sends something to the background, which outlives the card.
    private static func chainSegments(_ command: String) -> [String]? {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        let characters = Array(command)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
                current.append(character)
            } else if character == "&" {
                guard next == "&" else { return nil }
                segments.append(current); current = ""; index += 1
            } else if character == "|" {
                segments.append(current); current = ""
                if next == "|" { index += 1 }
            } else if character == ";" {
                segments.append(current); current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        segments.append(current)
        let trimmed = segments.map { $0.trimmingCharacters(in: .whitespaces) }
        return trimmed.contains(where: \.isEmpty) ? nil : trimmed
    }

    /// Where a leading `cd` moves the shell, when that is one of the bot's
    /// folders; nil for anywhere else, `..` included.
    private static func changedFolder(_ raw: String, access: ClaudeTextWorkAccess) -> String? {
        guard !raw.contains(".."), !raw.hasPrefix("~") else { return nil }
        let path = raw.hasPrefix("/") ? raw : access.workingDirectoryURL.appendingPathComponent(raw).path
        let standardized = (path as NSString).standardizingPath
        let target = ClaudeTextWorkApprovalPolicy.realPath(standardized)
        let roots = [access.workingDirectoryURL] + access.grantedDirectoryURLs
        guard roots.contains(where: {
            let root = ClaudeTextWorkApprovalPolicy.realPath($0.path)
            return target == root || target.hasPrefix(root + "/")
        }), !ClaudeTextWorkApprovalPolicy.isDenied(target, access: access) else { return nil }
        return standardized
    }

    /// The allowance key: the script's path as the disk knows it, when that
    /// sits inside one of the bot's folders and off the deny list; nil
    /// otherwise, so a run outside asks every time.
    /// "absent" for a script not on disk yet: once written, its bytes differ
    /// and the rerun asks. Nil (no allowance) for one over 16 MB or unreadable.
    static func scriptDigest(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return "absent" }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
              size.intValue <= 16 * 1024 * 1024,
              let bytes = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func allowanceKey(_ resolved: String, access: ClaudeTextWorkAccess) -> String? {
        let target = ClaudeTextWorkApprovalPolicy.realPath(resolved)
        let roots = [access.workingDirectoryURL] + access.grantedDirectoryURLs
        guard roots.contains(where: { target.hasPrefix(ClaudeTextWorkApprovalPolicy.realPath($0.path) + "/") }),
              !ClaudeTextWorkApprovalPolicy.isDenied(target, access: access) else { return nil }
        return target
    }

    /// The run card, or a named-install card when the interpreter is missing.
    public static func decide(_ command: String, access: ClaudeTextWorkAccess,
                              botName: String,
                              interpreters: [ClaudeTextInterpreter]? = nil) -> ClaudeTextWorkDecision? {
        guard let invocation = parse(command, access: access) else { return nil }
        // When the caller supplies a catalog (tests), trust only that list so
        // discovery stays injectable. Live calls omit it and resolve on the Mac.
        let available = interpreters ?? ClaudeTextInterpreterCatalog.resolve()
        let hasInterpreter = available.contains {
            URL(fileURLWithPath: $0.path).lastPathComponent == invocation.interpreterToken
                || $0.path == invocation.interpreterToken
        }
        if !hasInterpreter {
            let suggestion = ClaudeTextInterpreterCatalog.namedInstallSuggestion(
                forInterpreter: invocation.interpreterToken)
            return .ask(ClaudeTextWorkCard(
                title: suggestion.title,
                detail: suggestion.detail,
                target: "Needed to run \(invocation.scriptName) in \(invocation.workingFolderName)",
                kind: .packageInstall,
                activity: "Asked to install \(invocation.interpreterToken) before running \(invocation.scriptName)",
                turnScope: nil,
                offersTurnAllowance: false,
                openablePath: nil
            ))
        }

        let place = invocation.workingFolderName
        let shownPath = ClaudeTextWorkApprovalPolicy.displayPath(invocation.resolvedScriptPath, access: access)
        // Turn allowance keys on the script's real path so only a rerun of
        // this same file skips the card; a script outside the
        // bot's folders gets none and asks every time.
        // The interpreter is part of the key: an approval of `python3 x.py`
        // does not cover `uv run x.py`.
        // And the script's bytes: a rewrite after the approval asks again.
        // What stays open: a script that imports another file
        // the bot changed. A script that cannot be read or is over 16 MB gets
        // no allowance and asks every time; one not written yet is "absent".
        let scope = invocation.allowanceKey.flatMap { key -> ClaudeTextWorkTurnAllowance? in
            guard let digest = scriptDigest(key) else { return nil }
            return ClaudeTextWorkTurnAllowance(toolName: "Bash \(invocation.interpreterToken)", folderPath: key,
                                               contentDigest: digest)
        }
        let detail = """
        Interpreter: \(invocation.interpreterLabel) (\(invocation.interpreterToken))
        Script: \(shownPath)
        Folder: \(place)\(scope == nil ? "\nOutside the bot's folders: this asks every time." : "")

        Command:
        \(command)
        """
        return .ask(ClaudeTextWorkCard(
            title: "Run \(invocation.scriptName)",
            detail: detail,
            target: "\(invocation.interpreterLabel) · \(place)",
            kind: .productionChange,
            activity: "Asked to run \(invocation.scriptName) with \(invocation.interpreterLabel) in \(place)",
            turnScope: scope,
            offersTurnAllowance: scope != nil,
            openablePath: invocation.resolvedScriptPath
        ))
    }

    /// Name what a package manager would install (never silent).
    public static func namedPackageInstallCard(command: String, place: String) -> ClaudeTextWorkCard {
        // The install part names the manager and the package, not the command's
        // first word: the CLI asked `python3 -m venv … && "…/venv/bin/pip" install requests`.
        let segment = ClaudeTextWorkApprovalPolicy.commandSegments(command)
            .first { ClaudeTextWorkApprovalPolicy.segmentKind($0) == .packageInstall } ?? command
        var words = shellWords(segment)
        if let first = words.first, !first.isEmpty { words[0] = URL(fileURLWithPath: first).lastPathComponent }
        // `python3 -m pip install x` is pip's own install.
        if words.count >= 3, ["python3", "python"].contains(words[0]), words[1] == "-m" {
            words = Array(words.dropFirst(2))
        }
        let manager = words.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "package manager"
        let package = namedPackage(from: words) ?? "software"
        let title: String
        switch manager {
        case "brew": title = "Install \(package) with Homebrew"
        case "pip", "pip3": title = "Install \(package) with \(manager)"
        case "npm", "pnpm", "yarn": title = "Install \(package) with \(manager)"
        case "uv": title = "Install \(package) with uv"
        case "gem": title = "Install \(package) with gem"
        case "cargo": title = "Install \(package) with cargo"
        default: title = "Install \(package) with \(manager)"
        }
        return ClaudeTextWorkCard(
            title: title,
            detail: command,
            target: "In \(place) · OpenBots will not install this until you approve",
            kind: .packageInstall,
            activity: "Asked to install \(package) with \(manager) in \(place)",
            turnScope: nil,
            offersTurnAllowance: false,
            openablePath: nil
        )
    }

    // MARK: - helpers

    private static func namedPackage(from words: [String]) -> String? {
        guard words.count >= 2 else { return nil }
        let manager = URL(fileURLWithPath: words[0]).lastPathComponent
        let rest = Array(words.dropFirst())
        // brew install jq / brew install --cask foo
        if manager == "brew", let installIdx = rest.firstIndex(of: "install") {
            let after = rest.suffix(from: installIdx + 1).filter { !$0.hasPrefix("-") }
            return after.first
        }
        // pip install requests / pip3 install -U requests
        if ["pip", "pip3"].contains(manager), rest.first == "install" {
            return rest.dropFirst().first { !$0.hasPrefix("-") }
        }
        // npm install lodash / npm i lodash
        if ["npm", "pnpm", "yarn"].contains(manager),
           let verb = rest.first, ["install", "i", "add"].contains(verb) {
            return rest.dropFirst().first { !$0.hasPrefix("-") }
        }
        // uv add foo / uv pip install foo
        if manager == "uv" {
            if rest.first == "add" {
                return rest.dropFirst().first { !$0.hasPrefix("-") }
            }
            if rest.count >= 2, rest[0] == "pip", rest[1] == "install" {
                return rest.dropFirst(2).first { !$0.hasPrefix("-") }
            }
        }
        if manager == "gem", rest.first == "install" {
            return rest.dropFirst().first { !$0.hasPrefix("-") }
        }
        if manager == "cargo", rest.first == "install" {
            return rest.dropFirst().first { !$0.hasPrefix("-") }
        }
        return rest.first { !$0.hasPrefix("-") && $0 != "install" && $0 != "add" }
    }

    private static func resolveScriptPath(_ raw: String, from folder: String) -> String {
        if raw.hasPrefix("/") { return (raw as NSString).standardizingPath }
        if raw.hasPrefix("~") { return (raw as NSString).expandingTildeInPath }
        return ((folder as NSString).appendingPathComponent(raw) as NSString).standardizingPath
    }

    /// Split a command into words respecting single and double quotes.
    static func shellWords(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        for character in command {
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
