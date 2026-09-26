import Foundation
import CoreGraphics
import OpenBotsDomain
import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

private func macQuestion(_ tool: String, _ input: [String: Any] = [:]) throws -> ClaudeTextPermissionRequest {
    ClaudeTextPermissionRequest(requestID: "req-1", toolUseID: "toolu_01", toolName: "mcp__openbots_mac__\(tool)",
        inputJSON: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
}

/// A look at a named app this turn: a click on an element is judged only
/// after one, so the cards below that click by element
/// are decided after it.
private let lookedAtAnApp: MacControlLooks = {
    var looks = MacControlLooks()
    looks.record(tool: "see", inputJSON: Data(#"{"app_target":"TextEdit"}"#.utf8))
    return looks
}()

@Suite("Control this Mac: one card per reply to take control; unread arguments, screenshot paths and file panels refused; quits and opens it can name ask every time")
struct ClaudeTextMacControlApprovalPolicyTests {
    @Test("A screen or input call asks with the shared per-reply scope and never shows typed text")
    func takingControlAsksOncePerReply() throws {
        let click = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("click", ["query": "Send"]), botName: "Zed", layout: .ansi,
                                                              looks: lookedAtAnApp)
        guard case .ask(let card) = click else { Issue.record("a click asks"); return }
        #expect(card.title == "Let Zed control your Mac" && card.target == "click Send")
        #expect(card.turnScope == ClaudeTextMacControlApprovalPolicy.turnScope)
        #expect(card.activity == "Asked to click Send on this Mac")
        let type = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("type", ["text": "hunter2-secret", "app": "Safari"]), botName: "Zed", layout: .ansi)
        guard case .ask(let typed) = type else { Issue.record("typing asks"); return }
        #expect(typed.target == "type 14 characters in Safari")
        #expect(!typed.detail.contains("hunter2") && !typed.activity.contains("hunter2"))
        #expect(typed.turnScope == card.turnScope)
    }

    // The card once said "type 30 characters" and the user could not see what
    // they approved. The words go on the card the user reads, on one line and
    // quoted; the record keeps the count.
    @Test("A typing card shows the user the words, on one line and quoted, while its record keeps only the count")
    func aTypingCardShowsTheWords() throws {
        let cases: [(String, [String: Any], String)] = [
            ("type", ["text": "Hello from\nthe audit.", "app": "TextEdit"], "Hello from ⏎ the audit."),
            ("dialog", ["action": "input", "text": "Q3 plan", "app": "TextEdit"], "Q3 plan"),
            ("set_value", ["on": "T1", "value": "Lunch at one?"], "Lunch at one?"),
        ]
        for (tool, input, words) in cases {
            let decision = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed",
                                                                     layout: .ansi, looks: lookedAtAnApp)
            guard case .ask(let card) = decision else { Issue.record("\(tool) asks"); continue }
            #expect(card.words == words, "\(tool): \(String(describing: card.words))")
            #expect(!card.detail.contains(words) && !card.target.contains(words) && !card.activity.contains(words))
        }
    }

    // A character that draws nothing or reorders the line would make the card
    // show words other than the ones typed; the rule is the one Messages uses.
    @Test("Typing a character that draws nothing or reorders the line is refused; joined emoji still ask")
    func hiddenCharactersInTypedWordsAreRefused() throws {
        for text in ["abc\u{202E}fed", "See you at 8\u{200B}", "OK\u{E0031}\u{E0032}", "a\rb"] {
            for (tool, input) in [("type", ["text": text, "app": "TextEdit"] as [String: Any]),
                                  ("set_value", ["on": "T1", "value": text] as [String: Any]),
                                  ("dialog", ["action": "input", "text": text, "app": "TextEdit"] as [String: Any])] {
                let decision = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed",
                                                                         layout: .ansi, looks: lookedAtAnApp)
                guard case .denyQuietly(let reason, let activity) = decision else {
                    Issue.record("\(tool) \(text.unicodeScalars.map { String($0.value, radix: 16) }) must be refused"); continue
                }
                #expect(reason.contains("draws nothing or reorders"), "\(reason)")
                #expect(activity == "Blocked typing a character the card could not show on this Mac")
            }
        }
        let emoji = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("type", ["text": "👩‍💻 done\tnext\nline", "app": "TextEdit"]),
                                                              botName: "Zed", layout: .ansi)
        guard case .ask(let card) = emoji else { Issue.record("an emoji with a joiner asks"); return }
        #expect(card.words == "👩‍💻 done\tnext ⏎ line")
    }

    @Test("Words longer than the card holds are cut with an ellipsis, and a call that types nothing has none")
    func longWordsAreCut() throws {
        let long = String(repeating: "a", count: 600)
        let typed = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("type", ["text": long, "app": "TextEdit"]),
                                                              botName: "Zed", layout: .ansi)
        guard case .ask(let card) = typed else { Issue.record("typing asks"); return }
        #expect(card.words == String(repeating: "a", count: 400) + "…")
        let click = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("click", ["query": "Send"]), botName: "Zed",
                                                              layout: .ansi, looks: lookedAtAnApp)
        guard case .ask(let clicked) = click else { Issue.record("a click asks"); return }
        #expect(clicked.words == nil)
    }

    @Test("The bot is told that typing is not checked, to aim it at a field, and to look before saying it landed")
    func theNoteSaysTypingIsNotChecked() {
        let note = ClaudeTextConnectorRole.macControl.promptDescription
        #expect(note.contains("\"[ok] Typed\" means the keys were sent, not that they arrived"), "\(note)")
        #expect(note.contains("look at that app with inspect_ui or see"))
    }

    // The card that takes control, and the note the bot reads, both say a
    // sign-in is handed to the user rather than only stopped at.
    @Test("The control card and the bot's note send a sign-in, a password, a payment or a permission dialog to the user with hand_over_screen")
    func theWordingHandsTheScreenOver() throws {
        let click = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("click", ["query": "Send"]), botName: "Zed", layout: .ansi,
                                                              looks: lookedAtAnApp)
        guard case .ask(let card) = click else { Issue.record("a click asks"); return }
        #expect(card.detail.hasSuffix("Zed is told to hand you the screen for a sign-in, a password, a payment or a "
            + "permission dialog, and to stop and ask before a deletion."), "\(card.detail)")
        let note = ClaudeTextConnectorRole.macControl.promptDescription
        #expect(note.contains("call hand_over_screen with what he needs to do, make no other call until it returns"))
        #expect(note.contains("before a deletion, stop and ask him"))
        #expect(note.contains("or he has the screen"))
        #expect(!note.contains("stop and ask him instead"))
    }

    @Test("A screenshot written to a path is refused without a card")
    func screenshotPathsAreRefused() throws {
        for (tool, input) in [("see", ["path": "/Users/x/Documents/report.docx"]), ("see", ["path": "/tmp/a.png"])] {
            let decision = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", layout: .ansi)
            guard case .denyQuietly(let reason, _) = decision else { Issue.record("\(tool) \(input) must be refused"); return }
            #expect(reason.contains("Leave out the path"), "\(reason)")
        }
        let plain = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("see", ["app_target": "Finder"]), botName: "Zed", layout: .ansi)
        guard case .ask = plain else { Issue.record("a plain look asks"); return }
    }

    // Peekaboo 4.0.0 decodes capture's arguments with `.convertFromSnakeCase`
    // (CaptureTool+Request.swift), so `videoOut`, `Video_Out` and `video__out`
    // all bind to the file it writes, and `outputDir` and `OUTPUT_DIR` to the
    // folder it fills. A refusal keyed on exact spellings missed every one.
    @Test("Capture is not one of the tools, so no spelling of its file keys reaches Peekaboo")
    func captureIsRefusedWhateverTheSpelling() throws {
        let inputs: [[String: Any]] = [["videoOut": "/Users/x/Documents/report.pdf"], ["outputDir": "/Users/x/Documents"],
                                       ["OUTPUT_DIR": "/Users/x"], ["video__out": "/tmp/a.mp4"], ["Video_Out": "/tmp/b.mp4"],
                                       ["source": "Video", "input": "/Users/x/movie.mov"], [:]]
        for input in inputs {
            let decision = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("capture", input), botName: "Zed", layout: .ansi)
            guard case .denyQuietly = decision else { Issue.record("capture \(input) must be refused, got \(decision)"); continue }
        }
    }

    @Test("Input the app cannot read as an object is refused, never shown as a card about nothing")
    func unreadableInputIsRefused() throws {
        for bytes in ["not json", "[\"on\", \"B7\"]", "\"click\"", ""] {
            let request = ClaudeTextPermissionRequest(requestID: "req-1", toolUseID: "toolu_01",
                toolName: "mcp__openbots_mac__click", inputJSON: Data(bytes.utf8))
            let decision = ClaudeTextMacControlApprovalPolicy.decide(request, botName: "Zed", layout: .ansi)
            guard case .denyQuietly = decision else { Issue.record("\(bytes.debugDescription) must be refused, got \(decision)"); continue }
        }
    }

    @Test("An argument Peekaboo's own parser does not read for that tool is refused, never described on a card")
    func unreviewedArgumentsAreRefused() throws {
        // `click` reads no app, so "in Mail" would name a target the click never
        // uses; `see` reads no outputDir; Peekaboo reads keys exactly, so `Text`
        // and `Keys` are not `text` and `keys`.
        let refused: [(String, [String: Any], String)] = [
            ("click", ["on": "B7", "app": "Mail"], "app"), ("see", ["app_target": "Safari", "outputDir": "/tmp"], "outputDir"),
            ("type", ["text": "hi", "Text": "hunter2"], "Text"), ("press", ["Keys": ["cmd+q"]], "Keys"),
        ]
        for (tool, input, key) in refused {
            let decision = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", layout: .ansi)
            guard case .denyQuietly(let reason, let activity) = decision else {
                Issue.record("\(tool) \(input) must be refused, got \(decision)"); continue
            }
            #expect(reason.contains(key), "\(reason)")
            #expect(!activity.contains("hunter2"), "\(activity)")
        }
        let admitted: [(String, [String: Any])] = [("click", ["on": "B7"]), ("see", ["app_target": "Safari"]),
                                                   ("type", ["text": "hi"]), ("press", ["keys": ["cmd+c"]])]
        for (tool, input) in admitted {
            guard case .ask = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", layout: .ansi,
                                                                        looks: lookedAtAnApp) else {
                Issue.record("\(tool) \(input) reads only its own keys and asks"); continue
            }
        }
    }

    @Test("A connector call allowed for the turn is recorded by what it did, never by the hashed server key")
    func quietLinesNameTheTool() throws {
        let use = ClaudeTextToolUse(id: "toolu_01", toolName: "mcp__openbots_9f3a2b4c__inspect_ui", inputJSON: Data("{}".utf8))
        #expect(OfficialClaudeTextReplyService.activityLine(use, access: nil) == "Used inspect ui")
    }

    /// OpenBots Next as the policy sees it in these tests: process 4242, whose
    /// windows are 77 ("OpenBots Next") and 78 ("Kite"); window 90 is another app's.
    private let openBots = MacControlSelfIdentity(names: ["OpenBots Next"],
        bundleIdentifier: "com.lorenzocolombani.openbotsnext.preview", processIdentifier: 4242,
        windowOwner: { [77: 4242, 78: 4242, 90: 999][$0] }, windowTitles: { ["OpenBots Next", "Kite"] })

    private let openBotsInFront = MacControlSelfIdentity(names: ["OpenBots Next"],
        bundleIdentifier: "com.lorenzocolombani.openbotsnext.preview", processIdentifier: 4242,
        windowOwner: { [77: 4242, 78: 4242, 90: 999][$0] }, windowTitles: { ["OpenBots Next", "Kite"] },
        frontmostOwner: { 4242 })
    private let otherAppInFront = MacControlSelfIdentity(names: ["OpenBots Next"],
        bundleIdentifier: "com.lorenzocolombani.openbotsnext.preview", processIdentifier: 4242,
        windowOwner: { [77: 4242, 78: 4242, 90: 999][$0] }, windowTitles: { ["OpenBots Next", "Kite"] },
        frontmostOwner: { 999 })

    /// OpenBots Next beside the old OpenBots app (process 5151, window 55), with
    /// windows placed on screen: OpenBots Next at x 0–400, the old app at
    /// 400–600, another app beyond.
    private func besideTheOldApp(frontmost: Int32 = 999) -> MacControlSelfIdentity {
        MacControlSelfIdentity(names: ["OpenBots Next"],
            bundleIdentifier: "com.lorenzocolombani.openbotsnext.preview", processIdentifier: 4242,
            windowOwner: { [77: 4242, 55: 5151, 90: 999][$0] }, windowTitles: { ["OpenBots Next"] },
            frontmostOwner: { frontmost },
            otherNames: ["OpenBots"], otherBundleIdentifiers: ["com.lorenzocolombani.openbots"],
            otherProcesses: { [5151] },
            windowOwnersAt: { point in point.x < 400 ? [4242] : (point.x < 600 ? [5151] : [999]) })
    }

    /// A click-through overlay of another app (process 999)
    /// lies over OpenBots Next's window at x 0–400, so the front window under
    /// those points is not OpenBots'; beyond 400 only the other app is there.
    private func underAnOverlay() -> MacControlSelfIdentity {
        MacControlSelfIdentity(names: ["OpenBots Next"],
            bundleIdentifier: "com.lorenzocolombani.openbotsnext.preview", processIdentifier: 4242,
            windowOwner: { [77: 4242, 90: 999][$0] }, windowTitles: { ["OpenBots Next"] },
            frontmostOwner: { 999 },
            windowOwnersAt: { point in point.x < 400 ? [999, 4242] : [999] })
    }

    @Test("A point on an OpenBots window is refused under another app's overlay too, whatever lies in front")
    func pointsUnderAnOverlayAreRefused() throws {
        func decide(_ tool: String, _ input: [String: Any], _ identity: MacControlSelfIdentity) throws -> ClaudeTextWorkDecision {
            ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", identity: identity, layout: .ansi)
        }
        guard case .denyQuietly = try decide("click", ["coords": "100,50"], underAnOverlay()) else {
            Issue.record("a click on OpenBots under an overlay must be refused"); return
        }
        guard case .denyQuietly = try decide("drag", ["from_coords": "700,50", "to_coords": "100,50"], underAnOverlay()) else {
            Issue.record("a drag onto OpenBots under an overlay must be refused"); return
        }
        guard case .ask = try decide("click", ["coords": "700,50"], underAnOverlay()) else {
            Issue.record("a click on the other app asks"); return
        }
    }

    @Test("The old OpenBots app is refused like this one: by name, path, bundle id, pid, window and in front")
    func theOldAppIsRefused() throws {
        let identity = besideTheOldApp()
        let aimed: [(String, [String: Any])] = [
            ("app", ["action": "focus", "name": "OpenBots"]),
            ("app", ["action": "launch", "name": "/Applications/OpenBots.app"]),
            ("app", ["action": "launch", "bundleId": "com.lorenzocolombani.openbots"]),
            ("app", ["action": "focus", "name": "PID:5151"]),
            ("press", ["keys": ["return"], "pid": 5151]), ("type", ["text": "hi", "window_id": 55]),
            ("see", ["app_target": "PID:5151"]), ("see", ["app_target": "OpenBots"]),
        ]
        for (tool, input) in aimed {
            guard case .denyQuietly = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed",
                                                                               identity: identity, layout: .ansi) else {
                Issue.record("\(tool) \(input) reaches the old app and must be refused"); continue
            }
        }
        // With the old app in front, a call that names no app would land on it.
        guard case .denyQuietly = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("type", ["text": "hi", "foreground": true]),
            botName: "Zed", identity: besideTheOldApp(frontmost: 5151), layout: .ansi) else {
            Issue.record("typing with the old app in front must be refused"); return
        }
        guard case .ask = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("app", ["action": "focus", "name": "Safari"]),
            botName: "Zed", identity: identity, layout: .ansi) else { Issue.record("another app still asks"); return }
    }

    @Test("A click or drag at a point on an OpenBots window is refused; elsewhere it asks; a point it cannot place is refused")
    func pointsOnOpenBotsAreRefused() throws {
        let identity = besideTheOldApp()
        func decide(_ tool: String, _ input: [String: Any], _ id: MacControlSelfIdentity? = nil) throws -> ClaudeTextWorkDecision {
            ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", identity: id ?? identity, layout: .ansi)
        }
        for input in [["coords": "100,50"], ["coords": " 450 , 50 "], ["coords": "100,50", "coordinate_space": "global_display_points"],
                      ["coords": "700,50", "coordinate_space": "image_pixels", "coordinate_reference": "r1"],
                      ["coords": "0.5,0.5", "coordinate_space": "normalized", "coordinate_reference": "r1"],
                      ["coords": "seven,8"]] as [[String: Any]] {
            guard case .denyQuietly = try decide("click", input) else { Issue.record("click \(input) must be refused"); continue }
        }
        guard case .ask = try decide("click", ["coords": "700,50"]) else { Issue.record("a click on another app asks"); return }
        // A pid does not exempt the point: the click lands
        // at those coordinates, whatever process it names.
        guard case .denyQuietly = try decide("click", ["coords": "100,50", "pid": 999]) else {
            Issue.record("a click by pid on an OpenBots window must be refused"); return
        }
        guard case .ask = try decide("click", ["coords": "700,50", "pid": 999]) else { Issue.record("a click by pid elsewhere asks"); return }
        // A click naming no element and no point lands where the pointer is,
        // and the user answers its card with the mouse, so the pointer is on
        // OpenBots when it runs: it is refused wherever the pointer is now,
        // and the bot is told what to do instead.
        let bareWords = "Click or scroll on an element from a look at the app you mean, or give coords in global display points."
        for (tool, input) in [("click", [:]), ("click", ["double": true]), ("click", ["right": true, "pid": 999]),
                              ("scroll", ["direction": "down"]), ("scroll", ["direction": "up", "amount": 3])]
                as [(String, [String: Any])] {
            guard case .denyQuietly(let reason, let activity) = try decide(tool, input) else {
                Issue.record("a bare \(tool) \(input) must be refused"); continue
            }
            #expect(reason.hasSuffix(bareWords), "\(reason)")
            #expect(activity == "Blocked \(tool == "click" ? "a click" : "a scroll") at wherever the pointer is", "\(activity)")
        }
        // A point on an OpenBots window: the bot is told a way on.
        guard case .denyQuietly(let onOpenBots, _) = try decide("click", ["coords": "100,50"]) else {
            Issue.record("a click on OpenBots must be refused"); return
        }
        #expect(onOpenBots.hasSuffix("Click an element from a look at the app you mean instead."), "\(onOpenBots)")
        guard case .denyQuietly = try decide("drag", ["from_coords": "700,50", "to_coords": "100,50"]) else {
            Issue.record("a drag ending on OpenBots must be refused"); return
        }
        guard case .ask = try decide("drag", ["from_coords": "700,50", "to_coords": "800,50"]) else { Issue.record("a drag elsewhere asks"); return }
        guard case .denyQuietly(let dragOnOpenBots, _) = try decide("drag", ["from_coords": "700,50", "to_coords": "100,50"]) else {
            Issue.record("a drag ending on OpenBots must be refused"); return
        }
        #expect(dragOnOpenBots.hasSuffix("Drag between elements from a look at the app you mean instead."), "\(dragOnOpenBots)")
        // A scroll on an element is checked by the element rule, not refused here.
        guard case .ask = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("scroll", ["direction": "down", "on": "B1"]),
            botName: "Zed", identity: identity, layout: .ansi, looks: lookedAtAnApp) else {
            Issue.record("a scroll on an element of a named look asks"); return
        }
    }

    @Test("An element of a whole-screen look is refused, one of a look at a named app asks")
    func elementsOfAWholeScreenLookAreRefused() throws {
        func looks(_ calls: [[String: Any]], tool: String = "see") throws -> MacControlLooks {
            var looks = MacControlLooks()
            for call in calls { looks.record(tool: tool, inputJSON: try JSONSerialization.data(withJSONObject: call)) }
            return looks
        }
        func decide(_ tool: String, _ input: [String: Any], _ looks: MacControlLooks) throws -> ClaudeTextWorkDecision {
            ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", identity: otherAppInFront,
                                                      layout: .ansi, looks: looks)
        }
        let whole = try looks([[:]]), screen = try looks([["app_target": "screen:0"]])
        let named = try looks([["app_target": "TextEdit"]]), again = try looks([[:], ["app_target": "TextEdit"]])
        let elementCalls: [(String, [String: Any])] = [
            ("click", ["on": "B1"]), ("click", ["query": "Send"]), ("action", ["on": "B1", "action": "AXPress"]),
            ("set_value", ["on": "B2", "value": "x"]), ("type", ["text": "hi", "on": "T1"]), ("drag", ["from": "B1", "to": "B2"]),
        ]
        for (tool, input) in elementCalls {
            for refused in [whole, screen] {
                guard case .denyQuietly(let reason, _) = try decide(tool, input, refused) else {
                    Issue.record("\(tool) \(input) after a whole-screen look must be refused"); continue
                }
                #expect(reason.contains("app_target"))
            }
            // Before any look, only a click by element is refused.
            for fine in [named, again] + (tool == "click" ? [] : [MacControlLooks()]) {
                guard case .ask = try decide(tool, input, fine) else { Issue.record("\(tool) \(input) after \(fine) asks"); continue }
            }
        }
        // A click by element before any look: Peekaboo would take a look of its own.
        for input in [["query": "Send"], ["on": "B1"]] as [[String: Any]] {
            guard case .denyQuietly(let reason, let activity) = try decide("click", input, MacControlLooks()) else {
                Issue.record("click \(input) before any look must be refused"); continue
            }
            // True too when a named look is asked in the same batch and has
            // not finished yet.
            #expect(reason.hasPrefix("No look at a named app has finished in this reply yet."), "\(reason)")
            #expect(reason.hasSuffix("Look at the app you mean with see and its app_target, then click an element from that look."),
                    "\(reason)")
            #expect(activity == "Blocked a click on an element before a look at an app had finished")
        }
        // An element named beside coords is still an element, and its point is checked too.
        #expect(ClaudeTextMacControlApprovalPolicy.usesAnElement(tool: "click", input: ["on": "B1", "coords": "700,50"]))
        guard case .denyQuietly = try decide("click", ["on": "B1", "coords": "700,50"], whole) else {
            Issue.record("an element of a whole-screen look beside coords must be refused"); return
        }
        guard case .ask = try decide("click", ["query": "Send", "coords": "700,50"], named) else {
            Issue.record("an element of a named look beside coords asks"); return
        }
        // An older snapshot named by id after a whole-screen look this turn is refused too.
        guard case .denyQuietly = try decide("click", ["on": "B1", "snapshot": "s-1"], again) else {
            Issue.record("a named snapshot after a whole-screen look must be refused"); return
        }
        guard case .ask = try decide("click", ["on": "B1", "snapshot": "s-1"], named) else { Issue.record("a named snapshot of a named look asks"); return }
        // A look at the app in front, or at a window by id alone, counts as a
        // whole-screen look: answering its card brings
        // OpenBots to the front, so either can capture OpenBots' own window.
        #expect(try looks([["app_target": "frontmost"]]).latestWasAtANamedApp == false)
        #expect(try looks([["window_id": 90]], tool: "inspect_ui").latestWasAtANamedApp == false)
        #expect(try looks([["app_target": "TextEdit", "window_id": 90]]).latestWasAtANamedApp == true)
        guard case .denyQuietly = try decide("click", ["on": "B1"], try looks([["app_target": "frontmost"]])) else {
            Issue.record("an element of a look at the app in front must be refused"); return
        }
        #expect(try looks([["app_target": "menubar"]]).latestWasAtANamedApp == false)
    }

    @Test("The take-control card says what is refused, and a look's card still offers the turn")
    func takeControlCardNamesTheRefusal() throws {
        guard case .ask(let card) = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("see", ["app_target": "TextEdit"]),
            botName: "Zed", identity: otherAppInFront, layout: .ansi) else { Issue.record("a look asks"); return }
        #expect(card.offersTurnAllowance && card.turnScope == ClaudeTextMacControlApprovalPolicy.turnScope)
        #expect(card.detail.contains("Anything aimed at OpenBots' own windows is refused."), "\(card.detail)")
        let longName = String(repeating: "N", count: 60)
        guard case .ask(let long) = ClaudeTextMacControlApprovalPolicy.decide(
            try macQuestion("type", ["text": String(repeating: "t", count: 500), "app": "TextEdit"]),
            botName: longName, identity: otherAppInFront, layout: .ansi) else { Issue.record("typing asks"); return }
        // Never cut off by the card's own limit.
        #expect(long.detail.hasSuffix("stop and ask before a deletion."), "\(long.detail.suffix(120))")
    }

    /// Peekaboo sends a call that names no app to whatever is in front, and
    /// that is OpenBots Next while the user reads a reply or
    /// answers a card. Such a call could type into its composer or press its
    /// buttons under an allowance the user gave for something else.
    @Test("A call that names no app is refused while OpenBots Next is the app in front, and asks when it is not")
    func untargetedCallsAreRefusedWhileThisAppIsInFront() throws {
        let untargeted: [(String, [String: Any])] = [
            ("press", ["keys": ["cmd+return"], "foreground": true]), ("type", ["text": "send this", "foreground": true]),
            ("click", ["query": "Send"]), ("click", ["coords": "10,10"]), ("click", ["on": "B1"]),
            ("dialog", ["action": "click", "button": "Allow", "foreground": true]),
            ("window", ["action": "close", "foreground": true]),
            ("scroll", ["direction": "down", "amount": 3, "on": "B1"]), ("move", ["coordinates": "10,10"]),
            ("drag", ["from": "B1", "to": "B2"]),
            ("menu", ["action": "click", "path": "File > New"]),
            // An element from the last look is pressed and written into by these two,
            // which name no app either.
            ("action", ["on": "B1", "action": "AXPress"]), ("set_value", ["on": "B2", "value": "yes"]),
            ("see", ["app_target": "frontmost"]), ("see", [:]),
            ("see", [:]), ("inspect_ui", [:]), ("inspect_ui", ["app_target": "frontmost"]),
        ]
        for (tool, input) in untargeted {
            let decision = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", identity: openBotsInFront, layout: .ansi,
                looks: lookedAtAnApp)
            guard case .denyQuietly(let reason, let activity) = decision else {
                Issue.record("\(tool) \(input) names no app while OpenBots Next is in front and must be refused, got \(decision)"); continue
            }
            #expect(reason.contains("OpenBots") && activity.contains("OpenBots"), "\(reason) | \(activity)")
            guard case .ask = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", identity: otherAppInFront, layout: .ansi,
                looks: lookedAtAnApp) else {
                Issue.record("\(tool) \(input) asks when another app is in front"); continue
            }
        }
        // A look at the whole screen is not aimed here, and a call that names another app still asks.
        let allowed: [(String, [String: Any])] = [
            ("see", ["app_target": "screen"]), ("see", ["app_target": "Safari"]),
            ("press", ["keys": ["cmd+return"], "app": "Safari"]), ("type", ["text": "hello", "pid": 999]),
            ("window", ["action": "close", "app": "Safari"]),
        ]
        for (tool, input) in allowed {
            guard case .ask = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", identity: openBotsInFront, layout: .ansi,
                looks: lookedAtAnApp) else {
                Issue.record("\(tool) \(input) is not aimed at OpenBots Next and must ask"); continue
            }
        }
    }

    /// Only launch and open with `openTargets` were once
    /// sent to the Open card, so launching an app by its path rode an allowance
    /// the user gave for something else, though the row promises Peekaboo's own open
    /// asks every time.
    @Test("Launching an app by path or bundle file asks every time, like opening a link or a file")
    func launchingByPathAsksEveryTime() throws {
        for input in [["action": "launch", "name": "/Users/x/Downloads/Other.app"],
                      ["action": "launch", "name": "~/Downloads/Other.app"],
                      ["action": "launch", "name": " Other.app "],
                      ["action": "open", "name": "/Applications/Mail.app"]] as [[String: Any]] {
            guard case .ask(let card) = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("app", input), botName: "Zed", layout: .ansi) else {
                Issue.record("\(input) asks"); continue
            }
            #expect(card.title == "Open something on your Mac", "\(input) got \(card.title)")
            // No turn scope at all: this card can never be answered once for the reply.
            #expect(card.turnScope == nil, "\(input) must ask every time")
        }
        // Launching an app by name still rides the turn, as before.
        guard case .ask(let byName) = ClaudeTextMacControlApprovalPolicy.decide(
            try macQuestion("app", ["action": "launch", "name": "Mail"]), botName: "Zed", layout: .ansi) else {
            Issue.record("launching Mail by name asks"); return
        }
        #expect(byName.offersTurnAllowance && byName.turnScope == ClaudeTextMacControlApprovalPolicy.turnScope
                && byName.title == "Let Zed control your Mac", "\(byName.title)")
    }

    // Peekaboo resolves an app by PID:n, bundle id, exact name, exact executable
    // name, and then by any part of the name (ApplicationService+Discovery.swift),
    // so "openbots" or "Bots Ne" reach OpenBots Next as surely as its full name.
    @Test("A call aimed at OpenBots Next itself is refused, by every spelling Peekaboo would resolve to it")
    func callsAimedAtOpenBotsNextAreRefused() throws {
        let aimed: [(String, [String: Any])] = [
            ("app", ["action": "focus", "name": "OpenBots Next"]), ("app", ["action": "focus", "name": "openbots"]),
            ("app", ["action": "switch", "to": "Bots Ne"]), ("app", ["action": "focus", "name": " PID:4242"]),
            ("app", ["action": "launch", "bundleId": "com.lorenzocolombani.openbotsnext.preview"]),
            ("app", ["action": "launch", "name": "/Applications/OpenBots Next.app"]),
            ("press", ["keys": ["return"], "app": "OpenBots Next"]), ("press", ["keys": ["return"], "pid": 4242]),
            ("type", ["text": "yes", "window_id": 77, "foreground": true]), ("click", ["coords": "10,10", "pid": 4242]),
            ("see", ["app_target": "OpenBots Next:Kite"]), ("see", ["app_target": "pid:4242"]),
            ("see", ["app_target": "openbots next"]), ("inspect_ui", ["app_target": "Safari", "window_id": 78]),
            ("menu", ["action": "click", "app": "OpenBots Next", "path": "OpenBots Next > Settings…"]),
            ("dock", ["action": "right-click", "app": "OpenBots Next", "select": "Quit"]),
            ("drag", ["from": "B1", "to": "B2", "to_app": "OpenBots", "foreground": true]),
            ("dialog", ["action": "click", "button": "OK", "app": "OpenBots Next"]),
            ("window", ["action": "focus", "title": "kite"]), ("window", ["action": "minimize", "window_id": 77]),
            ("space", ["action": "move-window", "app": "OpenBots Next", "to": 2]),
            ("verify_state", ["pid": 4242, "predicates": [["kind": "window_exists", "expected": true]]]),
        ]
        for (tool, input) in aimed {
            let decision = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", identity: openBots, layout: .ansi)
            guard case .denyQuietly(let reason, let activity) = decision else {
                Issue.record("\(tool) \(input) aims at OpenBots Next and must be refused, got \(decision)"); continue
            }
            #expect(reason.contains("OpenBots") && activity.contains("OpenBots"), "\(reason) | \(activity)")
        }
        // The same calls aimed anywhere else still ask.
        let elsewhere: [(String, [String: Any])] = [
            ("app", ["action": "focus", "name": "Safari"]), ("app", ["action": "focus", "name": "PID:999"]),
            ("press", ["keys": ["return"], "pid": 999]), ("type", ["text": "yes", "window_id": 90, "foreground": true]),
            ("see", ["app_target": "Safari:Inbox"]), ("see", ["app_target": "frontmost"]),
            ("window", ["action": "focus", "title": "Inbox"]),
        ]
        for (tool, input) in elsewhere {
            guard case .ask = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", identity: openBots, layout: .ansi) else {
                Issue.record("\(tool) \(input) aims elsewhere and asks"); continue
            }
        }
    }

    // DialogTool's `file` action drives NSOpenPanel and NSSavePanel with a path,
    // a name and a button (DialogTool.swift): saving or opening a file by panel.
    @Test("The dialog tool's file action is refused, with or without a path")
    func dialogFileActionIsRefused() throws {
        for input in [["action": "file", "path": "/Users/x/Documents", "name": "report.pdf", "foreground": true],
                      ["action": "file", "foreground": true], ["action": " File ", "foreground": true]] as [[String: Any]] {
            let decision = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("dialog", input), botName: "Zed", layout: .ansi)
            guard case .denyQuietly = decision else { Issue.record("dialog \(input) must be refused, got \(decision)"); continue }
        }
        guard case .ask = ClaudeTextMacControlApprovalPolicy.decide(
            try macQuestion("dialog", ["action": "click", "button": "OK"]), botName: "Zed", layout: .ansi) else {
            Issue.record("a dialog button still asks"); return
        }
    }

    // Defence in depth only: the row no longer promises that nothing else can
    // quit an app. These are the ways Peekaboo itself spells a quit.
    @Test("Quitting through a shortcut, a menu or the Dock asks every time and never rides the turn's allowance")
    func quitThroughShortcutsMenusAndTheDockAsksEveryTime() throws {
        let quits: [(String, [String: Any])] = [
            ("press", ["keys": ["cmd+q"]]), ("press", ["key": "q", "modifiers": ["command"]]),
            ("press", ["keys": ["Tab", "CMD+Q"], "app": "Mail"]),
            ("menu", ["action": "click", "app": "Safari", "path": "Safari > Quit Safari"]),
            ("menu", ["action": "click", "app": "Mail", "item": "quit mail"]),
            ("dock", ["action": "right-click", "app": "Notes", "select": "Quit"]),
        ]
        for (tool, input) in quits {
            let decision = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", layout: .ansi)
            guard case .ask(let card) = decision else { Issue.record("\(tool) \(input) asks, got \(decision)"); continue }
            #expect(card.turnScope == nil, "\(tool) \(input) must not be covered by Allow for this turn")
        }
        let plain: [(String, [String: Any])] = [("press", ["keys": ["cmd+c"]]), ("press", ["key": "q"]),
                                                ("menu", ["action": "click", "app": "Mail", "path": "Edit > Copy"]),
                                                ("dock", ["action": "right-click", "app": "Notes", "select": "Options"])]
        for (tool, input) in plain {
            guard case .ask(let card) = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", layout: .ansi) else {
                Issue.record("\(tool) \(input) asks"); continue
            }
            #expect(card.turnScope == ClaudeTextMacControlApprovalPolicy.turnScope, "\(tool) \(input)")
        }
    }

    // Each line is what Peekaboo 4.0.0's own parser makes of the input: press
    // joins `modifiers` and `key` into one chord and repeats the whole sequence
    // `count` times; type clears before it types; drag prefers `to_coords` over
    // `to` and focuses `to_app`; right wins over double in a click.
    @Test("A card's line says what Peekaboo will actually do with the call")
    func cardLinesFollowPeekaboosParsing() throws {
        let lines: [(String, [String: Any], String)] = [
            ("press", ["key": "t", "modifiers": ["cmd", "shift"]], "press cmd+shift+t"),
            ("press", ["keys": ["cmd+v"], "count": 50], "press cmd+v 50 times"),
            ("press", ["keys": ["cmd+a", "Return"]], "press cmd+a, then return"),
            ("press", ["keys": ["Tab"], "app": "Mail", "window_title": "Inbox"], "press tab in Mail, window \"Inbox\""),
            ("type", ["text": "hi", "clear": true, "app": "Mail"], "clear the field, then type 2 characters in Mail"),
            ("type", ["clear": true, "app": "Mail"], "clear the field in Mail"),
            ("type", ["text": "line one\nline two", "on": "B4"], "type 17 characters, including 1 line break, into element B4"),
            ("drag", ["from": "B1", "to_coords": "300,400", "to": "B9", "to_app": "Finder", "modifiers": "cmd", "foreground": true],
             "drag B1 to the point 300,400, holding cmd, bringing Finder forward"),
            ("drag", ["from_coords": "10,20", "to": "Trash", "button": "right", "foreground": true],
             "drag the point 10,20 to Trash with the right button"),
            ("dock", ["action": "launch", "app": "Notes"], "open Notes from the Dock"),
            ("dock", ["action": "right-click", "app": "Notes", "select": "Options"], "right-click Notes in the Dock and choose Options"),
            ("dock", ["action": "hide"], "turn on the Dock's auto-hide"),
            ("dialog", ["action": "input", "text": "hunter2", "field": "Password", "clear": true, "foreground": true],
             "clear and type 7 characters into the dialog field Password"),
            ("dialog", ["action": "click", "button": "Don't Save", "app": "TextEdit"], "press Don't Save in a dialog in TextEdit"),
            ("click", ["on": "B7", "right": true, "double": true], "right-click element B7"),
            ("click", ["coords": "10,10", "foreground": true], "click the point 10,10"),
            ("set_value", ["on": "B2", "value": "secret"], "set element B2 to 6 characters of text"),
            ("set_value", ["on": "B3", "value": true], "set element B3 to on"),
            ("scroll", ["direction": "down", "amount": 5, "on": "B1"], "scroll down 5 times on element B1"),
            ("move", ["to": "center", "foreground": true], "move the pointer to the middle of the screen"),
            ("window", ["action": "close", "app": "Mail", "title": "Draft"], "close the window \"Draft\" of Mail"),
            ("space", ["action": "move-window", "app": "Notes", "to": 2, "follow": true],
             "move a window of Notes to desktop space 2 and follow it"),
            ("see", ["app_target": "Safari:Inbox"], "look at Safari, window Inbox"),
            ("sleep", ["duration": 2500], "wait 2.5 seconds"),
        ]
        for (tool, input, expected) in lines {
            guard case .ask(let card) = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", layout: .ansi,
                                                                                  looks: lookedAtAnApp) else {
                Issue.record("\(tool) \(input) asks"); continue
            }
            #expect(card.target == expected, "\(tool) \(input)")
            #expect(!card.detail.contains("hunter2") && !card.activity.contains("hunter2"))
        }
    }

    @Test("Keys pressed one by one are counted, never spelled out, so a password typed a key at a time stays off the card")
    func characterKeysAreCountedNotShown() throws {
        let decision = ClaudeTextMacControlApprovalPolicy.decide(
            try macQuestion("press", ["keys": ["h", "u", "n", "t", "e", "r", "2", "shift+1", "Return"]]), botName: "Zed", layout: .ansi)
        guard case .ask(let card) = decision else { Issue.record("a press asks"); return }
        #expect(card.target == "press 8 character keys, then return")
        for text in [card.target, card.detail, card.activity] { #expect(!text.contains("u, n") && !text.contains("hunter")) }
    }

    // Tachikoma's getString types a number as its digits and getStringArray
    // drops what is not text, so a card cannot describe either faithfully.
    @Test("Text that is not text, and lists holding anything but text, are refused")
    func nonTextValuesAreRefused() throws {
        let refused: [(String, [String: Any])] = [
            ("type", ["text": 12345, "app": "Mail"]), ("type", ["text": true, "app": "Mail"]),
            ("dialog", ["action": "input", "text": 4242, "foreground": true]),
            ("press", ["keys": ["cmd+a", 5]]), ("press", ["key": "q", "modifiers": ["cmd", 7]]),
            ("app", ["action": "open", "openTargets": ["https://example.com", 3]]),
            ("window", ["action": "list", "app": "Mail", "include_window_details": ["ids", 1]]),
        ]
        for (tool, input) in refused {
            let decision = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", layout: .ansi)
            guard case .denyQuietly = decision else { Issue.record("\(tool) \(input) must be refused, got \(decision)"); continue }
        }
    }

    @Test("A card that only waits, checks or lists offers no Allow for this turn, and an allowance given elsewhere still covers it")
    func onlyCallsThatSeeOrChangeTheMacOfferTheTurn() throws {
        let steps: [(String, [String: Any])] = [
            ("sleep", ["duration": 500]), ("permissions", [:]),
            ("verify_state", ["app": "Mail", "predicates": [["kind": "window_exists", "expected": true]]]),
            ("app", ["action": "list"]), ("window", ["action": "list", "app": "Mail"]), ("dock", ["action": "list"]),
            ("menu", ["action": "list", "app": "Mail"]), ("space", ["action": "list"]), ("dialog", ["action": "list"]),
        ]
        for (tool, input) in steps {
            guard case .ask(let card) = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", layout: .ansi) else {
                Issue.record("\(tool) \(input) asks"); continue
            }
            #expect(!card.offersTurnAllowance && card.turnScope == ClaudeTextMacControlApprovalPolicy.turnScope, "\(tool) \(input)")
        }
        for (tool, input) in [("see", [:]), ("dock", ["action": "hide"]), ("window", ["action": "focus", "app": "Mail"]),
                              // A state check that ends in a screenshot does see the user's screen.
                              ("verify_state", ["app": "Mail", "final_screenshot": true,
                                                "predicates": [["kind": "window_exists", "expected": true]]])] as [(String, [String: Any])] {
            guard case .ask(let card) = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", layout: .ansi) else {
                Issue.record("\(tool) \(input) asks"); continue
            }
            #expect(card.offersTurnAllowance, "\(tool) \(input)")
        }
    }

    @Test("The identity the app decides with is the running process, by its own name and number")
    func theCurrentIdentityIsThisProcess() throws {
        let current = MacControlSelfIdentity.current
        #expect(current.processIdentifier == getpid())
        #expect(current.isApplication("PID:\(getpid())") && current.isApplication(ProcessInfo.processInfo.processName))
        let pid = Int(getpid())
        let decision = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("press", ["keys": ["return"], "pid": pid]),
                                                                 botName: "Zed", layout: .ansi)
        guard case .denyQuietly = decision else { Issue.record("a press at this process must be refused, got \(decision)"); return }
    }

    @Test("Quitting apps and opening links or files ask every time; tools outside the reviewed list are refused")
    func consequentialAppActionsAskEveryTime() throws {
        // `all` is read only by the quit action (AppTool+Lifecycle.swift), so quitting everything is spelled with it.
        for input in [["action": "quit", "name": "Mail"], ["action": "quit", "all": true],
                      ["action": "open", "openTargets": ["https://example.com"]]] as [[String: Any]] {
            let decision = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("app", input), botName: "Zed", layout: .ansi)
            guard case .ask(let card) = decision else { Issue.record("\(input) asks"); return }
            #expect(card.turnScope == nil)
        }
        for tool in ["agent", "browser", "analyze", "clipboard", "paste", "shell", "image"] {
            let decision = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool), botName: "Zed", layout: .ansi)
            guard case .denyQuietly = decision else { Issue.record("\(tool) must be refused"); return }
        }
    }
}

/// An ABC-AZERTY layout, read from key events:
/// the positions Peekaboo presses for a, q, z, w and m type q, a, w, z and a
/// comma there, and the digit row types symbols.
private let azerty = MacKeyboardLayout { code in
    let moved: [CGKeyCode: String] = [0x00: "q", 0x0C: "a", 0x06: "w", 0x0D: "z", 0x2E: ",", 0x29: "m",
                                      0x12: "&", 0x13: "é", 0x2B: ";", 0x2F: ":", 0x2C: "="]
    return moved[code] ?? MacKeyboardLayout.ansi.character(at: code)
}

@Suite("Control this Mac: Peekaboo presses keys by their place on a US keyboard, so a key that types something else on this Mac's layout is refused")
struct MacControlKeyboardLayoutTests {
    private func decide(_ tool: String, _ input: [String: Any], _ layout: MacKeyboardLayout) throws -> ClaudeTextWorkDecision {
        ClaudeTextMacControlApprovalPolicy.decide(try macQuestion(tool, input), botName: "Zed", layout: layout)
    }

    @Test("On AZERTY, select all would quit and undo would close: both refused, saying what would really be pressed")
    func misplacedShortcutsAreRefusedByName() throws {
        let cases: [([String: Any], String)] = [
            (["keys": ["cmd+a"]], "cmd+q"), (["key": "z", "modifiers": ["cmd"]], "cmd+w"),
            (["keys": ["Tab", "cmd+w"], "app": "Mail"], "cmd+z"), (["keys": ["cmd+q"]], "cmd+a"),
            (["keys": ["cmd+m"]], "cmd+,"), (["keys": ["cmd+1"]], "cmd+&"),
        ]
        for (input, pressed) in cases {
            guard case .denyQuietly(let reason, _) = try decide("press", input, azerty) else {
                Issue.record("\(input) must be refused on AZERTY"); continue
            }
            #expect(reason.contains("\"\(pressed)\""), "\(input): \(reason)")
        }
    }

    @Test("A letter pressed on its own is refused too, and never spelled in the reason, since it may be part of a password")
    func misplacedSingleKeysAreRefusedWithoutSpellingThem() throws {
        guard case .denyQuietly(let reason, _) = try decide("press", ["keys": ["h", "u", "n", "t", "e", "r", "a"]], azerty) else {
            Issue.record("a letter typed a key at a time that lands elsewhere must be refused"); return
        }
        #expect(!reason.contains("\"q\"") && !reason.contains("\"a\""), Comment(rawValue: reason))
    }

    @Test("Keys that sit in the same place still ask: copy, paste, save, new tab, Return, Tab and the arrows")
    func keysInTheSamePlaceStillAsk() throws {
        for keys in [["cmd+c"], ["cmd+v"], ["cmd+x"], ["cmd+s"], ["cmd+shift+t"], ["return"], ["tab"], ["down"],
                     ["escape"], ["space"]] {
            guard case .ask = try decide("press", ["keys": keys, "app": "TextEdit"], azerty) else {
                Issue.record("\(keys) sits in the same place on AZERTY and must still ask"); continue
            }
        }
    }

    @Test("Clearing a field presses cmd+a by place, so type and dialog with clear are refused on AZERTY and ask on a US layout")
    func clearingAFieldIsRefusedWhereSelectAllWouldQuit() throws {
        let clears: [(String, [String: Any])] = [
            ("type", ["text": "hi", "clear": true, "app": "TextEdit"]), ("type", ["clear": "true", "app": "TextEdit"]),
            ("dialog", ["action": "input", "text": "x", "clear": true, "app": "TextEdit"]),
        ]
        for (tool, input) in clears {
            guard case .denyQuietly(let reason, _) = try decide(tool, input, azerty) else {
                Issue.record("\(tool) \(input) must be refused on AZERTY"); continue
            }
            #expect(reason.contains("\"cmd+q\""), Comment(rawValue: reason))
            guard case .ask = try decide(tool, input, .ansi) else { Issue.record("\(tool) \(input) asks on US"); continue }
        }
        guard case .ask = try decide("type", ["text": "hi", "clear": false, "app": "TextEdit"], azerty) else {
            Issue.record("typing without clear still asks"); return
        }
    }

    @Test("A layout that cannot be read refuses every character key and still lets named keys ask")
    func anUnreadableLayoutFailsClosedForCharacterKeys() throws {
        let unreadable = MacKeyboardLayout { _ in nil }
        guard case .denyQuietly = try decide("press", ["keys": ["cmd+c"]], unreadable) else {
            Issue.record("cmd+c must be refused when the layout cannot be read"); return
        }
        guard case .ask = try decide("press", ["keys": ["return"], "app": "TextEdit"], unreadable) else {
            Issue.record("Return names no character and still asks"); return
        }
    }

    @Test("The US table matches Peekaboo 4.0.0's own key codes")
    func theUSTableMatchesPeekaboo() throws {
        #expect(MacKeyboardLayout.ansi.character(at: 0x00) == "a" && MacKeyboardLayout.ansi.character(at: 0x0C) == "q")
        #expect(MacKeyboardLayout.ansi.character(at: 0x2E) == "m" && MacKeyboardLayout.ansi.character(at: 0x1D) == "0")
    }
}

// After a look at the user's screen, what could carry the words it saw into
// another app asks every time; clicks keep Allow for this turn.
@Suite("After a look at the user's screen, typing, pasting and dragging ask every time; clicks keep the allowance")
struct MacControlTypingAfterALookTests {
    @Test("What carries words: typing, a dialog's input, set value, a character key (cmd+v too), Paste and a drag")
    func whatCarriesWords() {
        func carries(_ tool: String, _ input: [String: Any] = [:]) -> Bool {
            ClaudeTextMacControlApprovalPolicy.carriesWords(tool, input)
        }
        #expect(carries("type", ["text": "IBAN"]) && carries("set_value", ["on": "T1", "value": "x"]))
        #expect(carries("dialog", ["action": "input", "text": "x"]) && !carries("dialog", ["action": "click", "button": "OK"]))
        #expect(carries("press", ["keys": ["cmd+v"]]) && carries("press", ["keys": ["tab", "b"]]))
        #expect(carries("press", ["key": "v", "modifiers": ["cmd"]]) && carries("press", ["keys": ["space"]]))
        #expect(!carries("press", ["keys": ["tab", "return", "down"]]))
        #expect(carries("menu", ["action": "click", "app": "Safari", "path": "Edit > Paste"]))
        #expect(carries("menu", ["action": "click", "app": "Safari", "item": "Paste and Match Style"]))
        #expect(!carries("menu", ["action": "click", "app": "Safari", "path": "File > New Window"]))
        #expect(carries("drag", ["from": "T1", "to": "T2"]))
        // Copy then a click on Paste once moved words with no card.
        #expect(carries("menu", ["action": "click", "app": "Mail", "item": "Copy"]))
        #expect(carries("menu", ["action": "click", "app": "Mail", "path": "Edit > Cut"]))
        #expect(carries("click", ["query": "Paste", "app": "Safari"]) && carries("click", ["query": "copy link"]))
        #expect(carries("click", ["query": "Address bar", "right": true]))
        #expect(!carries("click", ["query": "Address bar", "app": "Safari"]) && !carries("click", ["query": "Copyright"]))
        for tool in ["click", "scroll", "move", "see", "window", "app", "sleep", "action", "dock", "space"] {
            #expect(!carries(tool, ["action": "focus"]), "\(tool)")
        }
    }

    @Test("After a look, a typing card offers no allowance and says why; a click still offers it")
    func aTypingCardAfterALookOffersNoAllowance() throws {
        let type = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("type", ["text": "hello", "app": "Safari"]),
                                                             botName: "Zed", layout: .ansi, afterLook: true)
        guard case .ask(let typed) = type else { Issue.record("typing asks"); return }
        #expect(!typed.offersTurnAllowance, "\(typed.detail)")
        #expect(typed.detail.contains("looked at your screen") && typed.detail.contains("asks every time"), "\(typed.detail)")
        let click = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("click", ["query": "Send"]), botName: "Zed",
                                                              layout: .ansi, looks: lookedAtAnApp, afterLook: true)
        guard case .ask(let clicked) = click else { Issue.record("a click asks"); return }
        #expect(clicked.offersTurnAllowance && !clicked.detail.contains("looked at your screen"), "\(clicked.detail)")
    }

    @Test("After a look, typing longer than the card can show whole is refused")
    func longTypingAfterALookIsRefused() throws {
        let long = String(repeating: "a", count: ClaudeTextMacControlApprovalPolicy.maximumShownTyping + 1)
        let decision = ClaudeTextMacControlApprovalPolicy.decide(try macQuestion("type", ["text": long, "app": "Safari"]),
                                                                 botName: "Zed", layout: .ansi, afterLook: true)
        guard case .denyQuietly = decision else { Issue.record("\(decision)"); return }
    }
}
