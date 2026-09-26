import Foundation
import OpenBotsDomain
import OpenBotsRuntime
import Testing
@testable import OpenBotsServices

private let browserServer = "openbots_" + String(repeating: "9f3a2b01", count: 8)

private func question(_ tool: String, _ input: [String: Any] = [:]) throws -> ClaudeTextPermissionRequest {
    ClaudeTextPermissionRequest(requestID: "req-1", toolUseID: "toolu_01",
        toolName: "mcp__\(browserServer)__\(tool)",
        inputJSON: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
}

private func card(_ decision: ClaudeTextWorkDecision) throws -> ClaudeTextWorkCard {
    guard case .ask(let card) = decision else {
        Issue.record("expected a card, got \(decision)")
        throw CancellationError()
    }
    return card
}

@Suite("What the card says when a bot wants to use its browser")
struct ClaudeTextConnectorApprovalPolicyTests {
    @Test("A card names the site and the act in the words a person would use")
    func cardsAreReadable() throws {
        let opened = try card(ClaudeTextBrowserApprovalPolicy.decide(
            try question("navigate_page", ["url": "https://example.com/pricing?ref=abc"]), botName: "Zed"))
        #expect(opened.title == "Open a web page")
        #expect(opened.target == "example.com/pricing")
        #expect(opened.detail.contains("Zed"))
        // The whole address is on the card, query and all: it is what the
        // site receives, private read or not.
        #expect(opened.detail.contains("“https://example.com/pricing?ref=abc”"), "\(opened.detail)")

        let typed = try card(ClaudeTextBrowserApprovalPolicy.decide(
            try question("fill", ["uid": "the search box", "value": "swift 6"]), botName: "Zed"))
        #expect(typed.title == "Type into the page")
        #expect(typed.target == "the search box")

        let clicked = try card(ClaudeTextBrowserApprovalPolicy.decide(
            try question("click", ["uid": "Submit"]), botName: "Zed"))
        #expect(clicked.title == "Click on the page")
        #expect(clicked.detail.contains("submit a form"))

        // Nowhere does a card fall back to the wire name.
        for name in [opened, typed, clicked] {
            #expect(!name.title.contains("mcp__"))
            #expect(!name.detail.contains("mcp__"))
            #expect(!name.activity.contains("mcp__"))
        }
    }

    @Test("Reading the page already on screen is quiet; reaching anything new is not")
    func quietReadsAreNarrow() throws {
        for tool in ["take_snapshot", "take_screenshot", "list_pages", "get_console_message"] {
            let decision = ClaudeTextBrowserApprovalPolicy.decide(try question(tool), botName: "Zed")
            guard case .allowQuietly(let activity) = decision else {
                Issue.record("\(tool) should be quiet"); continue
            }
            #expect(activity.contains("Zed"))
        }
        // Everything that opens a page, changes one, uploads, or runs code asks.
        for tool in ["navigate_page", "new_page", "click", "fill", "type_text", "press_key", "hover",
                     "drag", "upload_file", "evaluate_script", "handle_dialog", "install_extension",
                     "launch_pwa", "close_page", "lighthouse_audit", "performance_start_trace"] {
            let decision = ClaudeTextBrowserApprovalPolicy.decide(try question(tool), botName: "Zed")
            guard case .ask = decision else { Issue.record("\(tool) must ask"); continue }
        }
    }

    @Test("Running code in the page and handing a file to a site are named for what they are")
    func theSharpEdgesAreNamed() throws {
        let script = try card(ClaudeTextBrowserApprovalPolicy.decide(
            try question("evaluate_script", ["function": "() => document.cookie"]), botName: "Zed"))
        #expect(script.title == "Run code inside the page")
        #expect(script.kind == .productionChange)

        let upload = try card(ClaudeTextBrowserApprovalPolicy.decide(
            try question("upload_file", ["filePath": "/Users/x/passport.pdf"]), botName: "Zed"))
        #expect(upload.kind == .publish)
        #expect(upload.detail.contains("leaves the Mac"))

        let installed = try card(ClaudeTextBrowserApprovalPolicy.decide(
            try question("install_extension", ["name": "something"]), botName: "Zed"))
        #expect(installed.kind == .packageInstall)
        #expect(installed.detail.contains("outlasts the conversation"))
    }

    @Test("A tool this version has never heard of asks, and says so")
    func theDefaultDirectionIsToAsk() throws {
        let unknown = try card(ClaudeTextBrowserApprovalPolicy.decide(
            try question("teleport_the_page"), botName: "Zed"))
        #expect(unknown.title == "Use the browser")
        #expect(unknown.target == "teleport the page")
        #expect(unknown.detail.contains("does not know what that does"))
        // A later server can add tools. It cannot add a quiet one.
        #expect(!ClaudeTextBrowserApprovalPolicy.quietReads.contains("teleport_the_page"))
    }

    @Test("A connector tool is recognised by its namespace, whatever the server")
    func namespaceRecognition() throws {
        #expect(ClaudeTextConnectorApprovalPolicy.isConnectorTool("mcp__anything__at_all"))
        #expect(!ClaudeTextConnectorApprovalPolicy.isConnectorTool("Bash"))
        #expect(ClaudeTextConnectorApprovalPolicy.toolName(in: "mcp__\(browserServer)__navigate_page")
            == "navigate_page")
        #expect(ClaudeTextConnectorApprovalPolicy.toolName(in: "Bash") == "Bash")
    }
}

private let mailServer = "openbots_" + String(repeating: "1c4d5e6f", count: 8)

private func mailQuestion(_ tool: String, _ input: [String: Any] = [:]) throws -> ClaudeTextPermissionRequest {
    ClaudeTextPermissionRequest(requestID: "req-2", toolUseID: "toolu_02",
        toolName: "mcp__\(mailServer)__\(tool)",
        inputJSON: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
}

@Suite("Which connector's words the card uses")
struct ConnectorApprovalRoutingTests {
    @Test("Reading the user's mail is quiet, and the line says mail rather than browser")
    func mailReadsAreQuiet() throws {
        for tool in ["search_messages", "get_messages", "get_thread", "list_accounts", "list_mailboxes",
                     "list_rules", "get_attachment_content", "list_templates", "get_template"] {
            let decision = ClaudeTextConnectorApprovalPolicy.decide(
                try mailQuestion(tool, ["query": "invoice"]), botName: "Canobi", role: .appleMailRead)
            guard case .allowQuietly(let activity) = decision else {
                Issue.record("\(tool) should be a quiet read, got \(decision)"); continue
            }
            #expect(activity.contains("mail") && !activity.contains("browser"))
        }
    }

    @Test("Anything the read-only reader is not supposed to be able to do asks, in mail's words")
    func anythingElseInMailAsks() throws {
        // The first four are mutating tools `--read-only` does not register, so
        // one arriving at all is a surprise worth a card rather than a shrug.
        // `render_template` is the tenth tool the installed server really does
        // register — it substitutes into a template rather than reading the
        // mailbox, so it asks too.
        for tool in ["update_message", "create_mailbox", "delete_draft", "save_attachments",
                     "render_template", "something_new"] {
            let decision = ClaudeTextConnectorApprovalPolicy.decide(
                try mailQuestion(tool), botName: "Canobi", role: .appleMailRead)
            let card = try card(decision)
            #expect(card.title == "Do something in your mail")
            #expect(card.kind == .send)
            #expect(card.detail.contains("Canobi") && !card.detail.contains("browser"))
        }
    }

    @Test("A connector this version has no words for asks without pretending it is the browser")
    func anUnknownConnectorNeverBorrowsBrowserCopy() throws {
        let card = try card(ClaudeTextConnectorApprovalPolicy.decide(
            try mailQuestion("send_mail", ["to": "someone@example.com"]), botName: "Canobi", role: nil))
        #expect(card.title == "Use a connector")
        #expect(card.detail.contains("send mail"))
        #expect(!card.detail.contains("browser") && !card.detail.contains("Mail"))
    }

    @Test("The browser's own card is unchanged by the routing")
    func theBrowserKeepsItsCard() throws {
        let card = try card(ClaudeTextConnectorApprovalPolicy.decide(
            try question("new_page", ["url": "https://example.com"]), botName: "Zed", role: .browser))
        #expect(card.title == "Open a web page")
        #expect(card.target == "example.com")
    }

    @Test("A turn with two connectors gives each tool its own connector's role")
    func theSelectionSaysWhichConnectorAToolCameFrom() throws {
        let browser = try ClaudeTextConnectorServer(name: browserServer, role: .browser,
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            entryPointURL: URL(fileURLWithPath: "/private/tmp/cache.noindex/chrome-devtools-mcp.js"),
            options: [.headless], environment: [:])
        let mail = try ClaudeTextConnectorServer(name: mailServer, role: .appleMailRead,
            program: .installedTool(URL(fileURLWithPath: "/Users/somebody/.local/bin/apple-mail-fast-mcp")),
            options: [.readOnly], environment: [:])
        let access = try ClaudeTextConnectorAccess(servers: [browser, mail])
        #expect(access.role(forToolNamed: "mcp__\(browserServer)__new_page") == .browser)
        #expect(access.role(forToolNamed: "mcp__\(mailServer)__get_messages") == .appleMailRead)
        // A name the turn does not admit has no role, and the caller denies it
        // before any card is built.
        #expect(access.role(forToolNamed: "mcp__openbots_deadbeef__get_messages") == nil)
        #expect(access.role(forToolNamed: "Bash") == nil)
    }
}

@Suite("What the record says while a card is still waiting")
struct ConnectorCardActivityContractTests {
    /// The app writes a card's activity line the moment the card goes up, so a
    /// card that phrases the deed puts a lie in the record of anything the
    /// user refuses. This is the invariant that catches it for every connector,
    /// including any added later.
    @Test("Every card a connector raises says what was asked, never what was done")
    func askedCardsNeverClaimTheDeed() throws {
        let browserTools = ["navigate_page", "new_page", "click", "hover", "fill", "type_text",
                            "upload_file", "evaluate_script", "handle_dialog", "install_extension",
                            "close_page", "resize_page", "something_new"]
        let mailReadTools = ["update_message", "create_mailbox", "render_template", "something_new"]
        let sendTools = ["send_mail", "draft_mail", "something_new"]
        func check(_ decision: ClaudeTextWorkDecision, _ label: String) {
            switch decision {
            case .allowQuietly, .allowByFolderRule:
                // A quiet decision IS the deed, so it may say so.
                break
            case .denyQuietly(_, let activity):
                #expect(activity.hasPrefix("Blocked"), "\(label) records \"\(activity)\" for a refusal by rule")
            case .ask(let card):
                #expect(card.activity.hasPrefix("Asked"),
                        "\(label) records \"\(card.activity)\" before the user has answered")
            }
        }
        for tool in browserTools {
            check(ClaudeTextConnectorApprovalPolicy.decide(try question(tool, ["url": "https://example.com"]),
                botName: "Zed", role: .browser), "browser/\(tool)")
        }
        for tool in mailReadTools {
            check(ClaudeTextConnectorApprovalPolicy.decide(try mailQuestion(tool),
                botName: "Kite", role: .appleMailRead), "mail-read/\(tool)")
        }
        for tool in sendTools {
            check(ClaudeTextConnectorApprovalPolicy.decide(
                try mailQuestion(tool, ["account": "iCloud", "to": "a@example.test", "subject": "s"]),
                botName: "Kite", role: .appleMailSend), "mail-send/\(tool)")
        }
        // A text, one the card could show, one it could not, and a tool the
        // Messages server has never announced.
        let text: [String: Any] = ["recipient": "+33612345678", "service": "SMS", "text": "On my way"]
        for (label, tool, input) in [("send", "send_message", text),
                                     ("refused", "send_message", ["recipient": "Charles", "service": "auto", "text": ""]),
                                     ("unknown", "something_new", text)] as [(String, String, [String: Any])] {
            check(ClaudeTextConnectorApprovalPolicy.decide(try mailQuestion(tool, input),
                botName: "Kite", role: .appleMessages), "messages/\(label)")
        }
        // And the unknown-role fallback, which has no connector of its own.
        check(ClaudeTextConnectorApprovalPolicy.decide(try mailQuestion("send_mail"),
            botName: "Kite", role: nil), "unknown role")
    }
}

/// A connector read let through quietly is written in its own words, and when
/// it fails the record says that read did not happen, in the same words. A
/// quiet line whose verb the record could not turn fell back to the tool's
/// name: a live Drive read once recorded "Failed to use
/// search google drive". Every quiet read of every role is swept here, so a
/// line added later with a new verb fails this test instead of the record.
@Suite("A failed quiet connector read is said in its own words")
struct ConnectorFailureLineTests {
    private static let server = "openbots_" + String(repeating: "5b", count: 32)

    private static func quietLines() throws -> [(role: ClaudeTextConnectorRole, tool: String, line: String)] {
        let roles: [(ClaudeTextConnectorRole, Set<String>)] = [
            (.browser, ClaudeTextBrowserApprovalPolicy.quietReads),
            (.appleMailRead, ClaudeTextAppleMailApprovalPolicy.quietReads),
            (.appleMailSend, ["list_mail_accounts"]),
            (.appleContactsRead, ClaudeTextAppleContactsApprovalPolicy.quietReads),
            (.appleCalendarRead, ClaudeTextAppleCalendarApprovalPolicy.quietReads),
            (.googleGmailReadDraft, ClaudeTextGoogleGmailApprovalPolicy.quietReads),
            (.googleCalendarRead, ClaudeTextGoogleCalendarApprovalPolicy.quietReads),
            (.googleDriveRead, ClaudeTextGoogleDriveApprovalPolicy.quietReads),
            (.appleMessages, ClaudeTextAppleMessagesApprovalPolicy.quietReads),
        ]
        // With the inputs a read names someone or something by, and without.
        let inputs: [[String: Any]] = [[:], [
            "query": "Anna", "recipient": "+33612345678", "url": "https://example.com/a",
            "from": "2026-09-22T00:00:00Z", "to": "2026-09-29T00:00:00Z",
        ]]
        var lines: [(ClaudeTextConnectorRole, String, String)] = []
        for (role, tools) in roles {
            for tool in tools.sorted() {
                for input in inputs {
                    let request = ClaudeTextPermissionRequest(requestID: "req-5b", toolUseID: "toolu_5b",
                        toolName: "mcp__\(server)__\(tool)",
                        inputJSON: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
                    guard case .allowQuietly(let line) = ClaudeTextConnectorApprovalPolicy.decide(
                        request, botName: "Kite", role: role) else {
                        Issue.record("\(role) \(tool) is listed as a quiet read and asked"); continue
                    }
                    lines.append((role, tool, line))
                }
            }
        }
        return lines
    }

    @Test("Every quiet read of every connector turns into its own failure line")
    func everyQuietReadHasItsOwnFailureLine() throws {
        let lines = try Self.quietLines()
        #expect(lines.count > 40)
        for (role, tool, line) in lines {
            let use = ClaudeTextToolUse(id: "toolu_5b", toolName: "mcp__\(Self.server)__\(tool)",
                                        inputJSON: Data("{}".utf8))
            let failure = OfficialClaudeTextReplyService.failureLine(use, quiet: line, access: nil)
            let first = line.prefix(1).lowercased() + line.dropFirst()
            #expect(!failure.hasPrefix("Failed to use "), "\(role) \(tool): \(failure)")
            #expect(failure.hasPrefix("Failed to ") && failure.count > "Failed to ".count, "\(role) \(tool)")
            // Only the verb changes; the rest of the line is the quiet line's own.
            let rest = line.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            #expect(failure.hasSuffix(rest), "\(role) \(tool): \(failure) from \(first)")
        }
    }

    @Test("The Drive search that failed live reads as a search that did not happen")
    func theLiveDriveFailureReadsPlainly() {
        let use = ClaudeTextToolUse(id: "toolu_5b", toolName: "mcp__\(Self.server)__search_google_drive",
                                    inputJSON: Data("{}".utf8))
        #expect(OfficialClaudeTextReplyService.failureLine(use, quiet: "Searched the OpenBots Google Drive",
                                                           access: nil)
                == "Failed to search the OpenBots Google Drive")
        #expect(OfficialClaudeTextReplyService.failureLine(use, quiet: "Listed a folder in the OpenBots Google Drive",
                                                           access: nil)
                == "Failed to list a folder in the OpenBots Google Drive")
    }
}
