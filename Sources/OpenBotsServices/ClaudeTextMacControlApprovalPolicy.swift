import AppKit
import CoreGraphics
import Foundation
import OpenBotsDomain
import OpenBotsRuntime

/// Control this Mac: the old app's Peekaboo connector, carried over as a trial.
/// Taking control is asked once
/// per reply: every card of this connector shares one turn scope, so "Allow for
/// this turn" lets the bot keep seeing the screen, clicking and typing until the
/// reply ends, and Stop ends it at once.
///
/// What this policy holds, and nothing more: a call with an argument its tool
/// does not read is refused; Peekaboo's own ways of writing a screenshot to a
/// path or driving a save or open panel are refused; its app tool's quit,
/// relaunch and open ask every time, and so do the quits Peekaboo spells
/// directly (cmd+q, a menu item or a Dock menu item naming Quit). Under the
/// turn's allowance a click, a keystroke or another menu can still quit an
/// app, discard unsaved work, or open a link or a file — the row and the card
/// say so rather than promise otherwise. Handing the user the screen for a sign-in,
/// a password, a payment or a permission dialog is the bot's own call
/// (`hand_over_screen`); once it does, the service refuses every
/// call until the user hands back. Stopping before a deletion stays an instruction.
public enum ClaudeTextMacControlApprovalPolicy {
    /// Every tool the connector is launched with, and for each one exactly the
    /// argument keys Peekaboo 4.0.0's own parser reads for it, spelled the way
    /// it reads them: read from its source at the v4.0.0 tag
    /// (`Core/PeekabooCore/Sources/PeekabooAgentRuntime/MCP/Tools`). Every
    /// one of these tools reads its keys exactly — `ToolArguments.getString`
    /// and its siblings are plain lookups, and `verify_state`
    /// decodes with explicit coding keys — so exact matching is how Peekaboo
    /// itself binds them. A call carrying any other key is refused: a key this
    /// table does not name is a key no card here has been written for.
    ///
    /// `capture` is not here. It decodes with `.convertFromSnakeCase`, so
    /// `videoOut`, `Video_Out` and `video__out` all name the file it writes and
    /// `outputDir` the folder it fills; a card that reads "take a screenshot"
    /// cannot stand in front of that, and `see` takes screenshots.
    /// The agent, the browser driver, image analysis and the clipboard stay out.
    ///
    /// Nor is `image`: on Claude Code 2.1.280 its
    /// result reaches the bot as "Captured 1 image(s)" and no picture, so a call
    /// spends one of the CLI's sixteen rounds and shows nothing. `see` hands the
    /// picture back.
    static let reviewedArguments: [String: Set<String>] = [
        "action": ["on", "action", "snapshot"],
        "app": ["action", "name", "bundleId", "openTargets", "foreground", "force", "wait", "waitUntilReady",
                "waitForWindow", "newInstance", "all", "except", "to", "cycle"],
        // `wait_for` is in the tool's schema and its parser never reads it.
        "click": ["query", "on", "coords", "coordinate_space", "coordinate_reference", "snapshot", "wait_for",
                  "double", "right", "foreground", "background", "pid"],
        // Its `path`, `name`, `select` and `ensure_expanded` serve only the file
        // action, which is refused, so they are not admitted either.
        "dialog": ["action", "app", "pid", "window_id", "window_title", "window_index", "foreground", "button",
                   "text", "field", "field_index", "clear", "force"],
        "dock": ["action", "app", "select", "include_all"],
        "drag": ["from", "from_coords", "to", "to_coords", "to_app", "snapshot", "duration", "steps", "profile",
                 "modifiers", "button", "foreground"],
        "inspect_ui": ["app_target", "window_id", "snapshot", "web_focus", "max_depth", "max_elements", "max_children"],
        "menu": ["action", "app", "path", "item", "foreground"],
        "move": ["to", "coordinates", "id", "snapshot", "center", "smooth", "duration", "steps", "profile", "foreground"],
        "permissions": [],
        "press": ["keys", "key", "modifiers", "count", "delay", "hold", "app", "pid", "window_id", "window_title",
                  "window_index", "foreground"],
        "scroll": ["direction", "on", "snapshot", "amount", "delay", "smooth", "foreground"],
        "see": ["app_target", "window_id", "path", "snapshot", "annotate", "web_focus", "max_depth", "max_elements",
                "max_children"],
        "set_value": ["on", "value", "snapshot"],
        "sleep": ["duration"],
        "space": ["action", "to", "app", "window_title", "window_index", "to_current", "follow", "detailed"],
        "type": ["text", "on", "snapshot", "delay", "profile", "wpm", "clear", "foreground", "app", "pid", "window_id",
                 "window_title", "window_index"],
        "verify_state": ["app", "pid", "window_id", "window_title", "window_index", "predicates", "timeout_ms",
                         "stable_samples", "final_screenshot"],
        "window": ["action", "app", "title", "index", "window_id", "x", "y", "width", "height", "foreground",
                   "include_window_details"],
    ]

    /// The tools the connector is launched with (`PEEKABOO_ALLOW_TOOLS`): the
    /// reviewed table's own names, so the list Peekaboo exposes and the list
    /// this policy admits cannot drift apart.
    public static let allowedTools = reviewedArguments.keys.sorted()

    /// The one scope every Control this Mac card shares.
    public static let turnScope = ClaudeTextWorkTurnAllowance(toolName: "Control this Mac", folderPath: "your Mac")

    static let fileArguments: [String: Set<String>] = ["see": ["path"]]

    static func decide(_ request: ClaudeTextPermissionRequest, botName: String,
                       identity: MacControlSelfIdentity = .current,
                       layout: MacKeyboardLayout = .current,
                       looks: MacControlLooks = MacControlLooks(),
                       afterTexts: Bool = false, afterChrome: Bool = false,
                       afterOther: String? = nil, readBy: String? = nil,
                       afterLook: Bool = false) -> ClaudeTextWorkDecision {
        // A page read in the user's Chrome fences the Mac the way their texts
        // do: typing it into another app would carry it out. So does any other
        // private read, named in `afterOther`.
        let fenced = afterTexts || afterChrome || afterOther != nil
        // After a look at the user's screen, what could carry its words into
        // another app asks every time; clicks keep the allowance.
        let tool = ClaudeTextConnectorApprovalPolicy.toolName(in: request.toolName)
        guard let reviewed = reviewedArguments[tool] else {
            return .denyQuietly(reason: "Control this Mac in OpenBots does not include \(tool).",
                                activity: String("Blocked \(tool) on this Mac".scalarPrefix(200)))
        }
        // Input this side cannot read is not an empty call: a card built from
        // nothing would put "click something" in front of whatever the tool
        // is actually handed.
        guard let input = (try? JSONSerialization.jsonObject(with: request.inputJSON)) as? [String: Any] else {
            return .denyQuietly(reason: "OpenBots could not read what this \(tool) call would do, so it did not run.",
                                activity: "Blocked \(readable(tool)) it could not read on this Mac")
        }
        // After a private read the card must show every word typed, as the
        // web and Browser cards show an address whole or refuse it: typing into a browser carries words out as a fetch does.
        if fenced || afterLook, let typed = typedText(tool, input), typedLine(typed).count > maximumShownTyping {
            return .denyQuietly(reason: "This reply read something private of his, so typing on his Mac goes ahead only "
                + "when its card can show every word, and this is longer than \(maximumShownTyping) characters. "
                + "Nothing was typed. Type it in shorter pieces, each on its own card.",
                activity: "Blocked typing too long to show whole on the card")
        }
        if let forbidden = fileArguments[tool], forbidden.contains(where: { present(input[$0]) }) {
            return .denyQuietly(
                reason: "Control this Mac does not write screenshots to a path. Leave out the path; the screenshot "
                    + "comes back in the reply.",
                activity: "Blocked \(readable(tool)) with a file path on this Mac")
        }
        // DialogTool's `file` action fills and presses a save or open panel.
        if tool == "dialog",
           peekabooString(input["action"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "file" {
            return .denyQuietly(
                reason: "Control this Mac does not fill in save or open panels. Ask him to choose the file himself.",
                activity: "Blocked a save or open panel on this Mac")
        }
        if let unexpected = input.keys.sorted().first(where: { !reviewed.contains($0) }) {
            let key = unexpected.split(whereSeparator: \.isNewline).joined(separator: " ")
            return .denyQuietly(
                reason: "Control this Mac in OpenBots does not pass \"\(key.prefix(60))\" to \(tool). "
                    + "Leave it out and use only the arguments the tool lists.",
                activity: "Blocked \(readable(tool)) with an argument it does not take on this Mac")
        }
        // Tachikoma's getString types a number as its digits and getStringArray
        // silently drops what is not text, so the card could not show what runs.
        if let key = valueTheCardCannotShow(tool, input) {
            return .denyQuietly(
                reason: "Control this Mac in OpenBots takes \"\(key)\" only as text. Pass it as a string, and every item of a list as a string.",
                activity: "Blocked \(readable(tool)) with a value it could not show on this Mac")
        }
        // The card shows the words the user approves, so a character that draws
        // nothing or reorders the line would show them other words than the
        // ones typed; the rule is the Messages card's.
        if let typed = typedText(tool, input),
           let hidden = AppleMessagesSendProposal.firstRefused(in: Array(typed.unicodeScalars)) {
            return .denyQuietly(
                reason: "Control this Mac does not type a character that draws nothing or reorders the line "
                    + "(U+\(String(format: "%04X", hidden.value))), since the card could not show it. Leave it out.",
                activity: "Blocked typing a character the card could not show on this Mac")
        }
        if tool == "press", pressedChords(input) == nil {
            return .denyQuietly(
                reason: "Peekaboo does not know one of those keys. Use keys like cmd+shift+t, Return or Tab.",
                activity: "Blocked a key press it could not read on this Mac")
        }
        if let reason = keyThatLandsElsewhere(tool, input, layout: layout) {
            return .denyQuietly(reason: reason,
                                activity: "Blocked a key that lands on a different key on this Mac's keyboard layout")
        }
        // Peekaboo runs with OpenBots Next's own Accessibility and Screen
        // Recording, so a call aimed at the app could press another bot's
        // approval card or flip a switch on an Access sheet. Defence in depth:
        // a click at coordinates or on an element from a whole-screen look
        // names no app, and nothing here can see where it lands.
        if identity.isTargeted(tool: tool, input: input) {
            return .denyQuietly(
                reason: "Control this Mac cannot act on OpenBots Next itself, nor on the old OpenBots app: their cards "
                    + "and switches are for him to answer. Leave OpenBots out of this call.",
                activity: "Blocked \(readable(tool)) aimed at OpenBots on this Mac")
        }
        // A point on the screen is refused when any OpenBots window holds it,
        // whatever lies in front, and an element from a look at the whole
        // screen can be one of OpenBots' own (a bot can never act inside
        // OpenBots itself).
        if let refusal = identity.pointRefusal(tool: tool, input: input) {
            return .denyQuietly(reason: refusal.reason, activity: refusal.activity)
        }
        if let refusal = elementRefusal(tool: tool, input: input, looks: looks) {
            return .denyQuietly(reason: refusal.reason, activity: refusal.activity)
        }
        // A call that names no app goes to whatever is in front, and that is
        // OpenBots Next while the user reads a reply or answers one of its
        // cards.
        if identity.landsOnThisApp(tool: tool, input: input) {
            return .denyQuietly(
                reason: "This call names no app, and OpenBots is the app in front, so it would land on OpenBots "
                    + "itself, whose cards and switches are for him to answer. Name the app to act on, by app or pid.",
                activity: "Blocked \(readable(tool)) with no app named while OpenBots was in front on this Mac")
        }
        let bot = String(botName.prefix(60))
        let action = description(tool, input)
        let action200 = String(action.scalarPrefix(200))
        let appAction = peekabooString(input["action"])
        if (tool == "app" && ["quit", "relaunch"].contains(appAction ?? "")) || spellsQuit(tool, input) {
            return .ask(ClaudeTextWorkCard(title: "Quit an app on your Mac",
                detail: String("\(bot) wants to \(action). Anything unsaved in that app may be lost. This asks every time.".scalarPrefix(600)),
                target: action200, kind: .productionChange, activity: String("Asked to \(action) on this Mac".scalarPrefix(200))))
        }
        // Only launch and open read openTargets (AppTool+Lifecycle.swift), and
        // both also take a path or a bundle file as the app to open, which opens
        // whatever is at that path rather than an app the user already has.
        if tool == "app", ["launch", "open"].contains(appAction ?? ""),
           present(input["openTargets"]) || namesAPath(peekabooString(input["name"])) {
            return .ask(ClaudeTextWorkCard(title: "Open something on your Mac",
                detail: String("\(bot) wants to \(action). Opening a link or a file can reach the internet or change what an app shows. This asks every time.".scalarPrefix(600)),
                target: action200, kind: .productionChange, activity: String("Asked to \(action) on this Mac".scalarPrefix(200))))
        }
        guard controlsTheMac(tool, input) else {
            // Waiting, checking permissions, listing and checking an app's state
            // neither see the user's screen nor change anything: covered by an
            // allowance already given, but never the card that gives one.
            return .ask(ClaudeTextWorkCard(title: "Let \(bot) use Control this Mac",
                detail: String("\(bot) wants to \(action). Approve lets this one step happen.".scalarPrefix(600)),
                target: action200, kind: .productionChange,
                activity: String("Asked to \(action) on this Mac".scalarPrefix(200)), turnScope: turnScope,
                offersTurnAllowance: false))
        }
        // Once this reply read the user's texts or their Chrome the service
        // offers no allowance, so the card must not describe one.
        let lookFencesThis = afterLook && !fenced && carriesWords(tool, input)
        let allowance: String = lookFencesThis
            ? "It looked at your screen earlier in this chat, so typing, copying, pasting and dragging in your apps "
                + "asks every time; other clicks still go ahead under Allow for this turn."
            : fenced
            ? (afterTexts ? "It asked to read your texts earlier in this chat, so each step on your Mac asks."
                : afterChrome ? "It read from your Chrome earlier in this chat, so each step on your Mac asks."
                : "\(readBy.map { "\($0) read" } ?? "It read") \(afterOther ?? "something of yours") earlier in this chat"
                    + (readBy == nil ? "" : " and handed the work on") + ", so each step on your Mac asks.")
            : "Allow for this turn lets \(bot) see your screen, click, type and press keys in your apps "
                + "until this reply ends, and Stop ends it at once; a click or a shortcut can then close or quit things, or "
                + "open a link."
        let refusal = "Anything aimed at OpenBots' own windows is refused."
        let handoff: String = "\(bot) is told to hand you the screen for a sign-in, a password, a payment or a "
            + "permission dialog, and to stop and ask before a deletion."
        return .ask(ClaudeTextWorkCard(title: "Let \(bot) control your Mac",
            detail: String("\(bot) wants to \(action). Approve lets this one action happen. \(allowance) \(refusal) \(handoff)".prefix(800)),
            target: action200, kind: .productionChange,
            activity: String("Asked to \(action) on this Mac".scalarPrefix(200)), turnScope: turnScope,
            offersTurnAllowance: !fenced && !lookFencesThis, words: typedWords(tool, input)))
    }

    /// The text `type`, a dialog's `input` or `set_value` would type, as given.
    static func typedText(_ tool: String, _ input: [String: Any]) -> String? {
        let typed: String?
        switch tool {
        case "type": typed = input["text"] as? String
        case "dialog": typed = peekabooString(input["action"]) == "input" ? input["text"] as? String : nil
        case "set_value": typed = input["value"] as? String
        default: typed = nil
        }
        return typed.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// What `type`, a dialog's `input` or `set_value` would type, on one line
    /// (a line break shows as ⏎, so the words cannot start a paragraph of
    /// their own on the card) and cut at 400 characters. Nil for any other call.
    static func typedWords(_ tool: String, _ input: [String: Any]) -> String? {
        guard let typed = typedText(tool, input) else { return nil }
        let line = typedLine(typed)
        return line.count > maximumShownTyping ? String(line.prefix(maximumShownTyping)) + "…" : line
    }

    /// How many characters of typing a card shows whole.
    static let maximumShownTyping = 400

    static func typedLine(_ typed: String) -> String {
        typed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: " ⏎ ")
    }

    /// An app named by where it sits rather than by its name: a path, a home
    /// path, or a bundle file. `launch` takes any of these (AppTool+Lifecycle).
    static func namesAPath(_ raw: String?) -> Bool {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.contains("/") || value.hasPrefix("~") || value.lowercased().hasSuffix(".app")
    }

    /// True for a call whose result brings the user's screen back to the model: a
    /// look, a read of an app's text, a state check, a click (which searches
    /// the screen's elements and names what it found), or a list of apps,
    /// windows, menus, Spaces or a dialog (a window's title can carry a mail's
    /// subject). Acting on an app, typing, keys, moving and waiting bring
    /// nothing back. After one, the web asks.
    static func bringsTheScreenBack(_ tool: String, _ input: [String: Any]) -> Bool {
        switch tool {
        case "see", "inspect_ui", "verify_state", "click": return true
        case "app", "window", "menu", "dock", "space", "dialog": return peekabooString(input["action"]) == "list"
        default: return false
        }
    }

    /// True for a call that could carry words into an app: typing, a dialog's
    /// input, setting a value, a key that types a character (with or without
    /// modifiers, so cmd+c and cmd+v), a menu item or a click naming Copy, Cut
    /// or Paste, a right-click (its menu holds them), and a drag (text drags
    /// between apps). After a look at the user's screen these ask every time.
    /// Clipboard tools are never launched. What stays open: a plain click at a spot where
    /// a Paste item happens to be drawn.
    static func carriesWords(_ tool: String, _ input: [String: Any]) -> Bool {
        func namesTheClipboard(_ keys: [String]) -> Bool {
            keys.contains { key in
                (peekabooString(input[key]) ?? "").lowercased()
                    .split(whereSeparator: { !$0.isLetter }).contains { ["copy", "cut", "paste"].contains($0) }
            }
        }
        switch tool {
        case "type", "set_value", "drag": return true
        case "dialog": return peekabooString(input["action"]) == "input"
        case "press": return (pressedChords(input) ?? []).contains { Chord.characterKeys.contains($0.key) }
                || pressedChords(input) == nil
        case "menu": return namesTheClipboard(["path", "item"])
        case "click": return peekabooBool(input["right"]) == true || namesTheClipboard(["query", "on"])
        default: return false
        }
    }

    /// True for a call that sees the user's screen or changes something on their Mac,
    /// the only kind of card that may offer Allow for this turn.
    static func controlsTheMac(_ tool: String, _ input: [String: Any]) -> Bool {
        switch tool {
        // A state check ends in a screenshot when it is asked for, and then it
        // does see the user's screen.
        case "verify_state": return peekabooBool(input["final_screenshot"]) == true
        case "sleep", "permissions": return false
        case "app", "window", "menu", "dock", "space", "dialog": return peekabooString(input["action"]) != "list"
        default: return true
        }
    }

    /// The quits Peekaboo spells outright: a cmd+q chord in `press`, and a menu
    /// or Dock menu item naming Quit. Defence in depth: a click on a Quit
    /// button, another app's own shortcut or a menu in another language still
    /// quits under the turn's allowance.
    static func spellsQuit(_ tool: String, _ input: [String: Any]) -> Bool {
        func namesQuit(_ key: String) -> Bool {
            peekabooString(input[key])?.range(of: "quit", options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        switch tool {
        case "press": return (pressedChords(input) ?? []).contains { $0.key == "q" && $0.modifiers.contains("cmd") }
        case "menu": return namesQuit("path") || namesQuit("item")
        case "dock": return namesQuit("select")
        default: return false
        }
    }

    /// The key whose value Peekaboo would read differently from what a card
    /// could show: typed text that is not text, or a list holding anything
    /// but text.
    static func valueTheCardCannotShow(_ tool: String, _ input: [String: Any]) -> String? {
        let textKeys: [String: [String]] = ["type": ["text"], "dialog": ["text"]]
        for key in textKeys[tool] ?? [] where input[key] != nil && !(input[key] is String) { return key }
        let listKeys: [String: [String]] = ["press": ["keys", "modifiers"], "app": ["openTargets"],
                                            "window": ["include_window_details"]]
        for key in listKeys[tool] ?? [] {
            guard let value = input[key] else { continue }
            guard let list = value as? [Any], list.allSatisfy({ $0 is String }) else { return key }
        }
        return nil
    }

    /// One chord as Peekaboo's `KeyboardChord(parsing:)` reads it: `+`-separated,
    /// trimmed and lowercased, known modifiers first, one known key last.
    struct Chord: Equatable {
        let modifiers: [String]
        let key: String

        /// A key that types a character: shown on a card only as a count, so a
        /// password pressed a key at a time never lands there.
        var typesACharacter: Bool {
            modifiers.allSatisfy { $0 == "shift" } && Chord.characterKeys.contains(key)
        }

        var shown: String { (modifiers + [key]).joined(separator: "+") }

        static let modifierNames = ["cmd": "cmd", "command": "cmd", "shift": "shift", "option": "alt", "alt": "alt",
                                    "ctrl": "ctrl", "control": "ctrl", "fn": "fn"]
        static let aliases = [
            "enter": "return", "esc": "escape", "backspace": "delete", "del": "delete", "spacebar": "space",
            "page_up": "pageup", "page_down": "pagedown", "forward_delete": "forwarddelete", "arrow_left": "left",
            "arrow_right": "right", "arrow_down": "down", "arrow_up": "up", "left_bracket": "leftbracket",
            "[": "leftbracket", "right_bracket": "rightbracket", "]": "rightbracket", "=": "equal", "-": "minus",
            "'": "quote", ";": "semicolon", "\\": "backslash", ",": "comma", "/": "slash", ".": "period",
            "`": "grave", "caps_lock": "capslock",
        ]
        static let characterKeys: Set<String> = {
            let letters: [String] = "abcdefghijklmnopqrstuvwxyz".map { String($0) }
            let digits: [String] = (0...9).map { String($0) }
            let symbols: [String] = ["space", "equal", "minus", "rightbracket", "leftbracket", "quote", "semicolon",
                                     "backslash", "comma", "slash", "period", "grave"]
            return Set(letters + digits + symbols)
        }()
        static let namedKeys: Set<String> = Set(["return", "tab", "delete", "escape", "capslock", "clear", "help", "home",
            "pageup", "forwarddelete", "end", "pagedown", "left", "right", "down", "up"]).union((1...12).map { "f\($0)" })

        init?(parsing raw: String) {
            let parts = raw.split(separator: "+", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard let last = parts.last, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
            let key = Chord.aliases[last] ?? last
            guard Chord.characterKeys.contains(key) || Chord.namedKeys.contains(key) else { return nil }
            var modifiers: [String] = []
            for part in parts.dropLast() {
                guard let modifier = Chord.modifierNames[part], !modifiers.contains(modifier) else { return nil }
                modifiers.append(modifier)
            }
            self.modifiers = modifiers
            self.key = key
        }
    }

    /// Peekaboo 4.0.0 presses a key by its place on a US keyboard
    /// (`HotkeyService+Planning.swift`: "a" is key code 0), and clearing a field
    /// in `type` or `dialog` presses cmd+a the same way. On an AZERTY Mac
    /// that place types q, so select all quits the app and cmd+z closes the
    /// window. A key whose place types something else
    /// here, or cannot be read, is refused before any card: the card would say
    /// one key and the Mac would get another.
    static func keyThatLandsElsewhere(_ tool: String, _ input: [String: Any], layout: MacKeyboardLayout) -> String? {
        func landed(_ chord: Chord) -> String? {
            guard let code = MacKeyboardLayout.ansiKeyCodes[chord.key],
                  layout.character(at: code) != MacKeyboardLayout.ansi.character(at: code) else { return nil }
            return layout.character(at: code).map { (chord.modifiers + [$0]).joined(separator: "+") } ?? "an unknown key"
        }
        if tool == "press" {
            for chord in pressedChords(input) ?? [] {
                guard let pressed = landed(chord) else { continue }
                // A key typed on its own may be one letter of a password.
                let asked = chord.typesACharacter ? "a character key" : "\"\(chord.shown)\""
                let arrives = chord.typesACharacter ? "a different character" : "\"\(pressed)\""
                return "Peekaboo presses keys by their place on a US keyboard, and this Mac uses another layout, so "
                    + "\(asked) would arrive as \(arrives). Nothing was pressed. Use the app's menu for a shortcut, "
                    + "or type the text instead."
            }
        }
        if ["type", "dialog"].contains(tool), peekabooBool(input["clear"]) == true,
           let pressed = landed(Chord(parsing: "cmd+a")!) {
            return "Clearing a field makes Peekaboo press \"cmd+a\" by its place on a US keyboard, which on this Mac's "
                + "layout is \"\(pressed)\". Nothing was typed. Leave out clear, and select the text with the app's "
                + "Edit menu first."
        }
        return nil
    }

    /// The chords `press` would send, as PressTool.parseChords reads them:
    /// `keys` when given, otherwise `modifiers` and `key` as one chord. Nil
    /// when one of them is not a chord Peekaboo knows.
    static func pressedChords(_ input: [String: Any]) -> [Chord]? {
        if let keys = input["keys"] as? [String] {
            let chords = keys.compactMap(Chord.init(parsing:))
            return chords.count == keys.count ? chords : nil
        }
        guard let key = peekabooString(input["key"]) else { return [] }
        let modifiers = input["modifiers"] as? [String] ?? []
        return Chord(parsing: (modifiers + [key]).joined(separator: "+")).map { [$0] }
    }

    static func present(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull: false
        case let text as String: !text.isEmpty
        case let list as [Any]: !list.isEmpty
        default: true
        }
    }

    static func readable(_ tool: String) -> String { tool.replacingOccurrences(of: "_", with: " ") }

    /// What the call does, in words, read the way each Peekaboo 4.0.0 tool's
    /// own parser reads its arguments (MCP/Tools at the v4.0.0 tag). Typed text
    /// and keys that type characters appear only as counts, so a password
    /// never lands on the card or in the record.
    static func description(_ tool: String, _ input: [String: Any]) -> String {
        func text(_ key: String, limit: Int = 80) -> String? { shown(peekabooString(input[key]), limit: limit) }
        func flag(_ key: String) -> Bool { peekabooBool(input[key]) == true }
        func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
        func other(_ action: String?, _ thing: String) -> String { "do \"\(shown(action) ?? "nothing")\" with \(thing)" }
        let target = inputTarget(input)
        switch tool {
        case "see":
            return "look at \(observed(input))" + (flag("web_focus") ? ", and may press into web content to read it" : "")
        case "inspect_ui":
            return "read the text on \(observed(input))" + (flag("web_focus") ? ", and may press into web content to read it" : "")
        case "click":
            // ClickRequest: coords, then on, then query; right wins over double.
            let verb = flag("right") ? "right-click" : flag("double") ? "double-click" : "click"
            let place = text("coords").map { "the point \($0)" } ?? text("on").map { "element \($0)" }
                ?? text("query") ?? "something"
            return "\(verb) \(place)" + (peekabooInt(input["pid"]).map { " in process \($0)" } ?? "")
        case "type":
            var steps: [String] = []
            if flag("clear") { steps.append("clear the field") }
            let into = (text("on").map { " into element \($0)" } ?? "") + target
            if let typed = input["text"] as? String, !typed.isEmpty {
                let breaks = typed.filter(\.isNewline).count
                steps.append("type \(plural(typed.count, "character"))"
                    + (breaks > 0 ? ", including \(plural(breaks, "line break"))" + (into.isEmpty ? "" : ",") : ""))
            }
            return (steps.isEmpty ? "type nothing" : steps.joined(separator: ", then ")) + into
        case "press":
            var pieces: [String] = []
            var characters = 0
            for chord in pressedChords(input) ?? [] {
                if chord.typesACharacter { characters += 1; continue }
                if characters > 0 { pieces.append(plural(characters, "character key")); characters = 0 }
                pieces.append(chord.shown)
            }
            if characters > 0 { pieces.append(plural(characters, "character key")) }
            let count = peekabooInt(input["count"]) ?? 1
            return "press \(pieces.isEmpty ? "nothing" : pieces.joined(separator: ", then "))"
                + (count == 1 ? "" : " \(count) times") + target
        case "set_value":
            let element = text("on").map { "element \($0)" } ?? "an element"
            switch input["value"] {
            case let typed as String: return "set \(element) to \(plural(typed.count, "character")) of text"
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
                return "set \(element) to \(number.boolValue ? "on" : "off")"
            case let number as NSNumber: return "set \(element) to \(number.stringValue)"
            default: return "set \(element) to a value"
            }
        case "action":
            return "perform \(text("action") ?? "an action") on \(text("on").map { "element \($0)" } ?? "an element")"
        case "scroll":
            let amount = peekabooNumber(input["amount"]).map { Int($0) } ?? 3
            return "scroll \(text("direction")?.lowercased() ?? "somewhere") \(amount == 1 ? "once" : "\(amount) times")"
                + (text("on").map { " on element \($0)" } ?? " at the pointer")
        case "drag":
            // DragLocationInput prefers the coordinates over the element.
            let from = text("from_coords").map { "the point \($0)" } ?? text("from") ?? "something"
            let to = text("to_coords").map { "the point \($0)" } ?? text("to") ?? "somewhere"
            return "drag \(from) to \(to)"
                + (text("modifiers").map { ", holding \($0)" } ?? "")
                + (peekabooString(input["button"])?.lowercased() == "right" ? " with the right button" : "")
                + (text("to_app").map { ", bringing \($0) forward" } ?? "")
        case "move":
            let aim = text("to") ?? text("coordinates")
            let place = flag("center") || aim?.lowercased() == "center" ? "the middle of the screen"
                : text("id").map { "element \($0)" } ?? aim.map { "the point \($0)" } ?? "somewhere"
            return "move the pointer to \(place)"
        case "menu":
            let app = text("app") ?? "an app"
            switch peekabooString(input["action"]) {
            case "list": return "read the menus of \(app)"
            case "click": return "choose \(shown(peekabooString(input["path"]) ?? peekabooString(input["item"])) ?? "a menu item") in \(app)"
            case let action: return other(action, "the menus of \(app)")
            }
        case "dialog":
            switch peekabooString(input["action"]) {
            case "click": return "press \(text("button") ?? "a button") in a dialog\(target)"
            case "input":
                let typed = (input["text"] as? String)?.count ?? 0
                let field = text("field").map { " \($0)" } ?? peekabooInt(input["field_index"]).map { " \($0)" } ?? ""
                return "\(flag("clear") ? "clear and type" : "type") \(plural(typed, "character")) into the dialog field\(field)\(target)"
            case "dismiss": return "dismiss a dialog" + (flag("force") ? " with Escape" : "") + target
            case "list": return "read what a dialog shows\(target)"
            case let action: return other(action, "a dialog") + target
            }
        case "window":
            let action = peekabooString(input["action"])
            if action == "list" { return "list the windows of \(text("app") ?? "an app")" }
            var window = peekabooInt(input["window_id"]).map { "window \($0)" }
                ?? text("title").map { "the window \"\($0)\"" } ?? peekabooInt(input["index"]).map { "window \($0)" } ?? "a window"
            if input["window_id"] == nil, let app = text("app") { window += " of \(app)" }
            func coordinate(_ key: String) -> String { peekabooNumber(input[key]).map(number) ?? "?" }
            switch action {
            case "close": return "close \(window)"
            case "minimize": return "minimize \(window)"
            case "restore": return "restore \(window)"
            case "maximize": return "maximize \(window)"
            case "move": return "move \(window) to \(coordinate("x")),\(coordinate("y"))"
            case "resize": return "resize \(window) to \(coordinate("width"))×\(coordinate("height"))"
            case "set-bounds":
                return "move \(window) to \(coordinate("x")),\(coordinate("y")) and resize it to \(coordinate("width"))×\(coordinate("height"))"
            case "focus": return "bring \(window) to the front"
            case let action: return other(action, window)
            }
        case "app":
            let name = text("name") ?? text("bundleId")
            let force = flag("force")
            switch peekabooString(input["action"]) {
            case "quit" where flag("all"):
                return "\(force ? "force quit" : "quit") every open app" + (text("except").map { " except \($0)" } ?? "")
            case "quit": return "\(force ? "force quit" : "quit") \(name ?? "an app")"
            case "relaunch": return "restart \(name ?? "an app")"
            case "launch", "open":
                let targets = input["openTargets"] as? [String] ?? []
                if !targets.isEmpty {
                    return "open \(shown(targets.prefix(3).joined(separator: ", "), limit: 120) ?? "")"
                        + (targets.count > 3 ? " and \(plural(targets.count - 3, "more item"))" : "")
                        + (name.map { " with \($0)" } ?? "")
                }
                return "open \(name ?? "an app")" + (flag("newInstance") ? " as a new copy" : "")
            case "focus": return "bring \(name ?? "an app") to the front"
            case "switch": return flag("cycle") ? "switch to the next app" : "switch to \(text("to") ?? "an app")"
            case "hide": return "hide \(name ?? "an app")"
            case "unhide": return "show \(name ?? "an app")"
            case "list": return "list the open apps"
            case let action: return other(action, name ?? "an app")
            }
        case "dock":
            let app = text("app") ?? "an app"
            switch peekabooString(input["action"]) {
            case "launch": return "open \(app) from the Dock"
            case "right-click": return "right-click \(app) in the Dock" + (text("select").map { " and choose \($0)" } ?? "")
            case "hide": return "turn on the Dock's auto-hide"
            case "show": return "turn off the Dock's auto-hide"
            case "list": return "list what is in the Dock"
            case let action: return other(action, "the Dock")
            }
        case "space":
            func space(_ key: String) -> String { peekabooNumber(input[key]).map { "desktop space \(Int($0))" } ?? "a desktop space" }
            switch peekabooString(input["action"]) {
            case "list": return "list the desktop spaces"
            case "switch": return "switch to \(space("to"))"
            case "move-window":
                return "move a window of \(text("app") ?? "an app") to \(flag("to_current") ? "this desktop space" : space("to"))"
                    + (flag("follow") ? " and follow it" : "")
            case let action: return other(action, "desktop spaces")
            }
        case "verify_state":
            let subject = text("app") ?? peekabooInt(input["pid"]).map { "process \($0)" } ?? "an app"
            return "check what \(subject) shows" + (flag("final_screenshot") ? " and take a screenshot" : "")
        case "sleep":
            let seconds = (peekabooNumber(input["duration"]) ?? 0) / 1_000
            return "wait \(number(seconds)) second\(seconds == 1 ? "" : "s")"
        case "permissions": return "check which Mac permissions it has"
        default: return readable(tool)
        }
    }

    /// A value as a card shows it: one line, clipped.
    static func shown(_ value: String?, limit: Int = 80) -> String? {
        guard let value else { return nil }
        let line = value.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    /// Where press, type and dialog send their input: app or pid, then one window.
    static func inputTarget(_ input: [String: Any]) -> String {
        var phrase = shown(peekabooString(input["app"])).map { " in \($0)" }
            ?? peekabooInt(input["pid"]).map { " in process \($0)" } ?? ""
        let window = shown(peekabooString(input["window_title"])).map { "window \"\($0)\"" }
            ?? peekabooInt(input["window_id"]).map { "window \($0)" }
            ?? peekabooInt(input["window_index"]).map { "window \($0)" }
        if let window { phrase += phrase.isEmpty ? " in \(window)" : ", \(window)" }
        return phrase
    }

    /// What see, image and inspect_ui look at, as ObservationTargetArgument reads it.
    static func observed(_ input: [String: Any]) -> String {
        let raw = peekabooString(input["app_target"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowercased = raw.lowercased()
        var place: String
        if raw.isEmpty || lowercased == "screen" {
            place = "the whole screen"
        } else if lowercased.hasPrefix("screen:") {
            place = "screen \(shown(String(raw.dropFirst(7)), limit: 20) ?? "?")"
        } else if lowercased == "frontmost" {
            place = "the app in front"
        } else if lowercased == "menubar" {
            place = "the menu bar"
        } else {
            let isProcess = lowercased.hasPrefix("pid:")
            let parts = raw.split(separator: ":", maxSplits: isProcess ? 2 : 1, omittingEmptySubsequences: false).map(String.init)
            place = isProcess ? "process \(shown(parts.count > 1 ? parts[1] : nil, limit: 20) ?? "?")" : shown(parts[0]) ?? "an app"
            if let window = shown(parts.count > (isProcess ? 2 : 1) ? parts.last : nil) { place += ", window \(window)" }
        }
        if let windowID = peekabooInt(input["window_id"]) { place += ", window \(windowID)" }
        return place
    }

    /// True when an observation names an app or a process, the only targets
    /// Peekaboo brings to the front before capturing.
    static func namesAnApp(_ input: [String: Any]) -> Bool {
        let raw = peekabooString(input["app_target"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return !raw.isEmpty && raw != "screen" && !raw.hasPrefix("screen:") && raw != "frontmost" && raw != "menubar"
    }
}

extension ClaudeTextMacControlApprovalPolicy {
    /// Peekaboo's text reader, mirrored (Tachikoma `ToolArguments.getString`):
    /// a number or a boolean is read as its text.
    static func peekabooString(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default: return nil
        }
    }

    /// Peekaboo's boolean reader, mirrored (`getBool`): "true", "yes" and "1"
    /// in any case, and any whole number but zero, read as true.
    static func peekabooBool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            return CFNumberIsFloatType(number) ? nil : number.int64Value != 0
        case let text as String: return ["true", "yes", "1"].contains(text.lowercased())
        default: return nil
        }
    }

    /// Peekaboo's number reader, mirrored (`getNumber`): numeric text counts.
    static func peekabooNumber(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }

    /// Peekaboo's integer reader, mirrored (`getInt`): a fraction is cut to a
    /// whole number and numeric text is read as one.
    static func peekabooInt(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            let double = number.doubleValue
            guard double.isFinite, abs(double) < 9.0e18 else { return nil }
            return Int(double)
        case let text as String: return Int(text)
        default: return nil
        }
    }
}

/// What this turn's looks at the screen were, so far as clicking on their
/// elements goes. Each turn's Peekaboo keeps its snapshots in a home of its
/// own, so an element can only come from a look taken in this turn.
public struct MacControlLooks: Equatable, Sendable {
    /// The latest look that went through: true when it was at an app named
    /// other than OpenBots, false when it took in the whole screen, nil before
    /// any look.
    public var latestWasAtANamedApp: Bool?
    /// Whether any look this turn took in the whole screen, OpenBots' own
    /// windows with it; an older snapshot can be named by its id.
    public var sawTheWholeScreen = false

    public init() {}

    /// A look at the whole screen, counted the moment it is let through:
    /// its result may come back in a batch after the next
    /// call is asked about, and the element rule must not wait on that. A
    /// look at a named app counts only when it finishes, since Peekaboo's
    /// latest snapshot is the look that finished last.
    public mutating func recordIfWholeScreen(tool: String, inputJSON: Data) {
        guard MacControlSelfIdentity.observationTools.contains(tool) else { return }
        let input = (try? JSONSerialization.jsonObject(with: inputJSON)) as? [String: Any] ?? [:]
        guard !ClaudeTextMacControlApprovalPolicy.namesAnApp(input) else { return }
        record(tool: tool, inputJSON: inputJSON)
    }

    /// A look that went through: `see` or `inspect_ui`, read from its input.
    public mutating func record(tool: String, inputJSON: Data) {
        guard MacControlSelfIdentity.observationTools.contains(tool) else { return }
        let input = (try? JSONSerialization.jsonObject(with: inputJSON)) as? [String: Any] ?? [:]
        // Only an app_target naming an app other than OpenBots (a look at
        // OpenBots is refused) counts as named. A look at "frontmost", or at a
        // window chosen by id alone, counts as a whole-screen look:
        // answering its card brings OpenBots to the front, so the app
        // in front can be OpenBots by the time it runs, and a window id is
        // checked when asked, not when captured. The empty target, "screen",
        // "screen:N" and "menubar" take in everything on show.
        let named = ClaudeTextMacControlApprovalPolicy.namesAnApp(input)
        latestWasAtANamedApp = named
        if !named { sawTheWholeScreen = true }
    }
}

/// Typing on the user's Mac that went through and that no look at its app
/// has followed. Peekaboo's "[ok] Typed" says the keys were sent, not where
/// they arrived: once thirty of them left TextEdit empty and the reply said "Done". A reply that ends with typing
/// still unchecked says so in the app's own words.
public struct MacControlTypingCheck: Equatable, Sendable {
    /// The apps typed into, as the calls named them, in order; "" for a call
    /// that named none (an element or a pid).
    public private(set) var unchecked: [String] = []

    public init() {}

    /// The calls that type: `type`, `set_value` and a dialog's `input`.
    public static func types(tool: String, inputJSON: Data) -> Bool {
        let input = (try? JSONSerialization.jsonObject(with: inputJSON)) as? [String: Any] ?? [:]
        return ClaudeTextMacControlApprovalPolicy.typedWords(tool, input) != nil
    }

    /// Typing that went through.
    public mutating func typed(tool: String, inputJSON: Data) {
        guard Self.types(tool: tool, inputJSON: inputJSON) else { return }
        let input = (try? JSONSerialization.jsonObject(with: inputJSON)) as? [String: Any] ?? [:]
        let app = ClaudeTextMacControlApprovalPolicy.peekabooString(input["app"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let named = app.uppercased().hasPrefix("PID:") ? "" : app
        if !unchecked.contains(where: { $0.caseInsensitiveCompare(named) == .orderedSame }) { unchecked.append(named) }
    }

    /// A look that went through: one at the whole screen checks everything,
    /// one at a named app checks that app and the typing that named none.
    public mutating func looked(tool: String, inputJSON: Data) {
        guard MacControlSelfIdentity.observationTools.contains(tool) else { return }
        let input = (try? JSONSerialization.jsonObject(with: inputJSON)) as? [String: Any] ?? [:]
        guard ClaudeTextMacControlApprovalPolicy.namesAnApp(input) else { unchecked.removeAll(); return }
        let target = ClaudeTextMacControlApprovalPolicy.peekabooString(input["app_target"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        unchecked.removeAll { $0.isEmpty || $0.caseInsensitiveCompare(target) == .orderedSame }
    }
}

extension ClaudeTextMacControlApprovalPolicy {
    /// Calls that act on an element of a snapshot rather than at a point. A
    /// click naming an element counts as one even with coords beside it:
    /// its point is checked as well, never instead.
    static func usesAnElement(tool: String, input: [String: Any]) -> Bool {
        func has(_ key: String) -> Bool { peekabooString(input[key]).map { !$0.isEmpty } ?? false }
        switch tool {
        case "click": return has("on") || has("query")
        case "action", "set_value", "scroll", "type": return has("on")
        case "drag": return (has("from") && !has("from_coords")) || (has("to") && !has("to_coords"))
        case "move": return has("id")
        default: return false
        }
    }

    /// An element from a look at the whole screen can be one of OpenBots' own
    /// buttons: such a call is refused, and the bot is told how to go on.
    ///
    /// A click by element before any look this turn is refused too:
    /// given a query and no snapshot, Peekaboo takes a look of its
    /// own, which can be the whole screen. A click `on` an element with no
    /// look has nothing to find, and is refused the same way for one rule.
    static func elementRefusal(tool: String, input: [String: Any],
                               looks: MacControlLooks) -> (reason: String, activity: String)? {
        guard usesAnElement(tool: tool, input: input) else { return nil }
        if tool == "click", looks.latestWasAtANamedApp == nil {
            // True too when a look at a named app is asked in the same batch
            // and has not finished yet.
            return ("No look at a named app has finished in this reply yet. Without one, Peekaboo would take a look "
                + "of its own, which can take in OpenBots' own windows, and Control this Mac never acts on OpenBots. Look at the "
                + "app you mean with see and its app_target, then click an element from that look.",
                "Blocked a click on an element before a look at an app had finished")
        }
        let namesASnapshot = peekabooString(input["snapshot"]).map { !$0.isEmpty } ?? false
        guard looks.latestWasAtANamedApp == false || (namesASnapshot && looks.sawTheWholeScreen) else { return nil }
        return ("That element comes from a look at the whole screen, which takes in OpenBots' own windows, and "
            + "Control this Mac never acts on OpenBots. Look again at the app you mean with see and its app_target, "
            + "then use an element from that look.",
            "Blocked \(readable(tool)) on an element of a whole-screen look")
    }
}

/// OpenBots Next as a target Peekaboo could be pointed at, and the arguments
/// through which Peekaboo 4.0.0 would reach it.
///
/// The matching is a superset of Peekaboo's own resolution, never a copy of
/// it: `ApplicationService.findApplication` takes `PID:n`, then an exact
/// bundle id, an exact name, an exact executable name, and then any part of a
/// name; `launch` also takes a path; `ObservationTargetArgument` reads
/// `App[:window]` and `PID:n[:window]`; a window id belongs to whichever
/// process owns it, and a title alone matches any window containing it.
public struct MacControlSelfIdentity: Sendable {
    let names: [String]
    let bundleIdentifier: String
    let processIdentifier: Int32
    /// The process owning a window, when there is one.
    let windowOwner: @Sendable (Int) -> Int32?
    /// The titles of this process's own windows.
    let windowTitles: @Sendable () -> [String]
    /// The process whose window is in front, when the window server says.
    let frontmostOwner: @Sendable () -> Int32?
    /// The old OpenBots app, which no bot may operate either (the two apps are
    /// not supposed to know each other): its names and bundle identifiers, and
    /// its running processes when a call is decided.
    let otherBundleIdentifiers: [String]
    let otherProcesses: @Sendable () -> Set<Int32>
    /// The processes owning every on-screen window whose bounds hold a point
    /// in global display points (top-left origin, as Peekaboo's bare
    /// coordinates are), at any layer; empty when none is there or the window
    /// server does not say. Every one, not the front one: a
    /// click-through overlay above an OpenBots window would otherwise mask it.
    let windowOwnersAt: @Sendable (CGPoint) -> Set<Int32>

    init(names: [String], bundleIdentifier: String, processIdentifier: Int32,
         windowOwner: @escaping @Sendable (Int) -> Int32?, windowTitles: @escaping @Sendable () -> [String],
         frontmostOwner: @escaping @Sendable () -> Int32? = { nil },
         otherNames: [String] = [], otherBundleIdentifiers: [String] = [],
         otherProcesses: @escaping @Sendable () -> Set<Int32> = { [] },
         windowOwnersAt: @escaping @Sendable (CGPoint) -> Set<Int32> = { _ in [] }) {
        self.names = (names + otherNames).filter { !$0.isEmpty }
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowOwner = windowOwner
        self.windowTitles = windowTitles
        self.frontmostOwner = frontmostOwner
        self.otherBundleIdentifiers = otherBundleIdentifiers.filter { !$0.isEmpty }
        self.otherProcesses = otherProcesses
        self.windowOwnersAt = windowOwnersAt
    }

    /// The old app, as its installed bundle names itself.
    static let oldAppNames = ["OpenBots"]
    static let oldAppBundleIdentifier = "com.lorenzocolombani.openbots"

    /// This app's process and the old app's, when it runs.
    func guardedProcesses() -> Set<Int32> { otherProcesses().union([processIdentifier]) }

    /// This running app, read from its own bundle and process; window facts
    /// come from the window server when a call is decided.
    static let current: MacControlSelfIdentity = {
        let info = Bundle.main.infoDictionary ?? [:]
        let bundleName = Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent : nil
        let names = [info["CFBundleDisplayName"] as? String, info["CFBundleName"] as? String,
                     info["CFBundleExecutable"] as? String, bundleName, ProcessInfo.processInfo.processName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let pid = getpid()
        let ownBundle = Bundle.main.bundleIdentifier ?? ""
        return MacControlSelfIdentity(names: Array(Set(names)).sorted(),
            bundleIdentifier: ownBundle, processIdentifier: pid,
            windowOwner: { windowID in
                guard windowID > 0, let id = CGWindowID(exactly: windowID),
                      let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
                      let window = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id })
                else { return nil }
                return (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            },
            windowTitles: {
                let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
                return windows.compactMap { window in
                    (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                        ? window[kCGWindowName as String] as? String : nil
                }
            },
            // The window server lists on-screen windows front to back; the first
            // ordinary one belongs to the app in front. Its owner needs no Screen
            // Recording, unlike a window's title.
            frontmostOwner: {
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                         kCGNullWindowID) as? [[String: Any]] ?? []
                return windows.first { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }
                    .flatMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }
            },
            otherNames: oldAppNames,
            // An app built from this repository under another name must not
            // count its own identifier as the old app's.
            otherBundleIdentifiers: ownBundle.caseInsensitiveCompare(oldAppBundleIdentifier) == .orderedSame
                ? [] : [oldAppBundleIdentifier],
            otherProcesses: {
                Set(NSRunningApplication.runningApplications(withBundleIdentifier: oldAppBundleIdentifier)
                    .map(\.processIdentifier))
            },
            // Every visible window whose bounds hold the point, whatever lies
            // in front of it; bounds and owners need no Screen Recording.
            windowOwnersAt: { point in
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                var owners = Set<Int32>()
                for window in windows {
                    if let alpha = window[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0 { continue }
                    guard let raw = window[kCGWindowBounds as String] as? NSDictionary,
                          let bounds = CGRect(dictionaryRepresentation: raw), bounds.contains(point),
                          let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
                    owners.insert(owner)
                }
                return owners
            })
    }()

    /// Why a call at a point is refused: the point is on a window of OpenBots
    /// (this app or the old one), it is given in a form this side cannot
    /// place, or there is no point and no element, so the call acts where the
    /// pointer is. Nil when the point is clear or the call has none.
    func pointRefusal(tool: String, input: [String: Any]) -> (reason: String, activity: String)? {
        let policy = ClaudeTextMacControlApprovalPolicy.self
        // A bare click or scroll acts where the pointer is when it runs, and
        // the user answers cards with the mouse, so by then the pointer can be on
        // OpenBots: checking it when the call is asked proves nothing. Both
        // are refused outright.
        let bare = (reason: "A click or scroll that names no element and no point acts wherever the pointer is when it "
            + "runs, which can be on OpenBots, since he answers cards with the mouse. "
            + "Click or scroll on an element from a look at the app you mean, or give coords in global display points.",
            activity: "Blocked \(tool == "click" ? "a click" : "a scroll") at wherever the pointer is")
        var points: [String] = []
        let onOpenBots: String
        switch tool {
        case "click":
            let element = ["on", "query"].contains { !(policy.peekabooString(input[$0]) ?? "").isEmpty }
            guard let coords = policy.peekabooString(input["coords"]), !coords.isEmpty else {
                return element ? nil : bare
            }
            // A pid does not exempt the point: it is no
            // proof of where the click lands.
            let space = policy.peekabooString(input["coordinate_space"])?.trimmingCharacters(in: .whitespaces).lowercased()
            guard space == nil || space == "" || space == "global_display_points" else {
                return ("Give coords as global display points (leave out coordinate_space), so OpenBots can check "
                    + "where the click lands: Control this Mac never acts on OpenBots' own windows.",
                    "Blocked a click at a point OpenBots could not place")
            }
            points = [coords]
            onOpenBots = "Click an element from a look at the app you mean instead."
        case "drag":
            points = ["from_coords", "to_coords"].compactMap { policy.peekabooString(input[$0]) }.filter { !$0.isEmpty }
            onOpenBots = "Drag between elements from a look at the app you mean instead."
        case "scroll":
            // No element: it scrolls wherever the pointer is.
            return (policy.peekabooString(input["on"]) ?? "").isEmpty ? bare : nil
        default:
            return nil
        }
        let guarded = guardedProcesses()
        for raw in points {
            guard let point = Self.point(raw) else {
                return ("OpenBots could not read the point \"\(raw.prefix(40))\". Give it as x,y in global display points.",
                        "Blocked \(ClaudeTextMacControlApprovalPolicy.readable(tool)) at a point OpenBots could not place")
            }
            if !guarded.isDisjoint(with: windowOwnersAt(point)) {
                // The refusal says a way on.
                return ("That point is on an OpenBots window, and Control this Mac never acts on OpenBots' own "
                    + "windows: their cards and switches are for him to answer. " + onOpenBots,
                    "Blocked \(ClaudeTextMacControlApprovalPolicy.readable(tool)) at a point on OpenBots")
            }
        }
        return nil
    }

    /// "x,y" as Peekaboo reads it: two numbers, spaces allowed around them.
    static func point(_ raw: String) -> CGPoint? {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]), x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static let loose: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// The tools whose arguments name an app Peekaboo resolves by identifier.
    static let applicationKeys: [String: [String]] = [
        "app": ["name", "bundleId", "to"], "dialog": ["app"], "dock": ["app"], "drag": ["to_app"], "menu": ["app"],
        "press": ["app"], "space": ["app"], "type": ["app"], "verify_state": ["app"], "window": ["app"],
    ]
    static let processKeyTools: Set<String> = ["click", "dialog", "press", "type", "verify_state"]
    static let windowKeyTools: Set<String> = ["dialog", "inspect_ui", "press", "see", "type", "verify_state", "window"]
    static let observationTools: Set<String> = ["inspect_ui", "see"]

    /// True when any argument of this call could make Peekaboo act on this app.
    func isTargeted(tool: String, input: [String: Any]) -> Bool {
        let policy = ClaudeTextMacControlApprovalPolicy.self
        for key in Self.applicationKeys[tool] ?? [] {
            if let identifier = policy.peekabooString(input[key]), isApplication(identifier) { return true }
        }
        let guarded = guardedProcesses()
        if Self.processKeyTools.contains(tool), let pid = policy.peekabooInt(input["pid"]),
           let process = Int32(exactly: pid), guarded.contains(process) {
            return true
        }
        if Self.windowKeyTools.contains(tool), let windowID = policy.peekabooInt(input["window_id"]),
           let owner = windowOwner(windowID), guarded.contains(owner) {
            return true
        }
        if Self.observationTools.contains(tool), let target = policy.peekabooString(input["app_target"]),
           isObservationTarget(target) {
            return true
        }
        // A window chosen by its title alone is any window whose title holds it.
        if tool == "window", input["app"] == nil, input["window_id"] == nil,
           let title = policy.peekabooString(input["title"]), !title.isEmpty {
            return windowTitles().contains { $0.range(of: title, options: Self.loose) != nil }
        }
        return false
    }

    /// The tools Peekaboo sends to the app in front when the call names none:
    /// keys and text with `foreground`, a click or a drag on an element from
    /// the last look or at coordinates, a dialog, a window, a menu bar.
    /// `action` presses an element and `set_value` writes into one, both from the
    /// last look and naming no app of their own.
    static let frontmostTools: Set<String> = ["action", "click", "dialog", "drag", "menu", "move", "press",
                                              "scroll", "set_value", "type", "window"]

    /// True for a call that would land on this app because it names no app and
    /// this app is in front. A look at the whole screen is not aimed here and
    /// is not counted; a look at "frontmost" is.
    func landsOnThisApp(tool: String, input: [String: Any]) -> Bool {
        guard let front = frontmostOwner(), guardedProcesses().contains(front) else { return false }
        let policy = ClaudeTextMacControlApprovalPolicy.self
        if Self.observationTools.contains(tool),
           policy.peekabooString(input["app_target"])?.trimmingCharacters(in: .whitespacesAndNewlines)
               .lowercased() == "frontmost" { return true }
        // A look with no target at all: refused here while this app is in front,
        // because what Peekaboo looks at then — the app in front or the whole
        // screen — is the one fact this repository cannot settle, and a look at
        // this app's window shows the user's cards and conversations.
        if Self.observationTools.contains(tool), input["app_target"] == nil { return true }
        guard Self.frontmostTools.contains(tool) else { return false }
        return !namesAnApp(tool: tool, input: input)
    }

    /// Whether the call names the app it acts on at all, by app identifier,
    /// process or window.
    private func namesAnApp(tool: String, input: [String: Any]) -> Bool {
        let policy = ClaudeTextMacControlApprovalPolicy.self
        for key in Self.applicationKeys[tool] ?? [] {
            if let value = policy.peekabooString(input[key]), !value.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        }
        if Self.processKeyTools.contains(tool), policy.peekabooInt(input["pid"]) != nil { return true }
        if Self.windowKeyTools.contains(tool), policy.peekabooInt(input["window_id"]) != nil { return true }
        return false
    }

    /// An app identifier as `findApplication` and `launch` would read it.
    func isApplication(_ raw: String) -> Bool {
        let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return false }
        if identifier.uppercased().hasPrefix("PID:"), let pid = Int32(identifier.dropFirst(4)), guardedProcesses().contains(pid) {
            return true
        }
        for bundle in [bundleIdentifier] + otherBundleIdentifiers where !bundle.isEmpty {
            if identifier.compare(bundle, options: Self.loose) == .orderedSame { return true }
        }
        // Any part of the name reaches it, and a path or a spelling that holds
        // the whole name ("/Applications/OpenBots Next.app") names it too.
        return names.contains { name in
            name.range(of: identifier, options: Self.loose) != nil || identifier.range(of: name, options: Self.loose) != nil
        }
    }

    /// `screen`, `screen:N`, `frontmost` and `menubar` name no app;
    /// `PID:n[:window]` and `App[:window]` do.
    func isObservationTarget(_ raw: String) -> Bool {
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = target.lowercased()
        guard !target.isEmpty, !lowercased.hasPrefix("screen:"),
              !["screen", "frontmost", "menubar"].contains(lowercased) else { return false }
        if lowercased.hasPrefix("pid:") {
            let parts = target.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            return parts.count >= 2 && Int32(parts[1]).map { guardedProcesses().contains($0) } == true
        }
        let application = target.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        return isApplication(application)
    }
}

/// What each key position types on the keyboard layout in use, with no
/// modifier held. Peekaboo's key table is written for the US layout.
public struct MacKeyboardLayout: Sendable {
    private let read: @Sendable (CGKeyCode) -> String?

    public init(_ read: @escaping @Sendable (CGKeyCode) -> String?) { self.read = read }

    public func character(at code: CGKeyCode) -> String? { read(code) }

    /// Peekaboo 4.0.0's key codes for every key that types a character
    /// (`HotkeyService+Planning.swift`, read at the v4.0.0 tag), with the character each types on a US keyboard.
    static let ansiTable: [String: (code: CGKeyCode, character: String)] = [
        "a": (0x00, "a"), "s": (0x01, "s"), "d": (0x02, "d"), "f": (0x03, "f"), "h": (0x04, "h"), "g": (0x05, "g"),
        "z": (0x06, "z"), "x": (0x07, "x"), "c": (0x08, "c"), "v": (0x09, "v"), "b": (0x0B, "b"), "q": (0x0C, "q"),
        "w": (0x0D, "w"), "e": (0x0E, "e"), "r": (0x0F, "r"), "y": (0x10, "y"), "t": (0x11, "t"), "1": (0x12, "1"),
        "2": (0x13, "2"), "3": (0x14, "3"), "4": (0x15, "4"), "6": (0x16, "6"), "5": (0x17, "5"), "equal": (0x18, "="),
        "9": (0x19, "9"), "7": (0x1A, "7"), "minus": (0x1B, "-"), "8": (0x1C, "8"), "0": (0x1D, "0"),
        "rightbracket": (0x1E, "]"), "o": (0x1F, "o"), "u": (0x20, "u"), "leftbracket": (0x21, "["), "i": (0x22, "i"),
        "p": (0x23, "p"), "l": (0x25, "l"), "j": (0x26, "j"), "quote": (0x27, "'"), "k": (0x28, "k"),
        "semicolon": (0x29, ";"), "backslash": (0x2A, "\\"), "comma": (0x2B, ","), "slash": (0x2C, "/"),
        "n": (0x2D, "n"), "m": (0x2E, "m"), "period": (0x2F, "."), "space": (0x31, " "), "grave": (0x32, "`"),
    ]
    static let ansiKeyCodes = ansiTable.mapValues(\.code)

    /// The US layout Peekaboo's table assumes.
    public static let ansi: MacKeyboardLayout = {
        let characters = Dictionary(uniqueKeysWithValues: ansiTable.values.map { ($0.code, $0.character) })
        return MacKeyboardLayout { characters[$0] }
    }()

    /// The layout in use now, read from a key event the way the window server
    /// builds one; safe off the main thread.
    public static let current = MacKeyboardLayout { code in
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else { return nil }
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &length,
                                       unicodeString: &characters)
        return length > 0 ? String(utf16CodeUnits: characters, count: length).lowercased() : nil
    }
}
