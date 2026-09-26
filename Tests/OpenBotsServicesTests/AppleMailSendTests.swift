import Foundation
import OpenBotsDomain
import OpenBotsRuntime
import Testing
@testable import OpenBotsServices

private func sendLaunch(command: String = AppleMailSendPreparation.command,
                        transport: ConnectorTransport = .stdio) -> ConnectorLaunchConfiguration {
    ConnectorLaunchConfiguration(serverKey: "openbots_" + String(repeating: "d", count: 64),
        transport: transport, command: command, arguments: [])
}

private func sendQuestion(_ tool: String, _ input: [String: Any]) throws -> ClaudeTextPermissionRequest {
    ClaudeTextPermissionRequest(requestID: "req-9", toolUseID: "toolu_09",
        toolName: "mcp__openbots_" + String(repeating: "d", count: 64) + "__" + tool,
        inputJSON: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
}

private func askedCard(_ decision: ClaudeTextWorkDecision) throws -> ClaudeTextWorkCard {
    guard case .ask(let card) = decision else {
        Issue.record("expected a card, got \(decision)")
        throw CancellationError()
    }
    return card
}

/// The app's own sentence, which leads the card and is held to its 600
/// scalars; the mail's words follow it whole after a blank line, so the budget is a claim about this part alone.
private func sentence(_ card: ClaudeTextWorkCard) -> String {
    card.detail.components(separatedBy: "\n\n")[0]
}

@Suite("Sending mail as the user")
struct AppleMailSendTests {
    @Test("The sender ships in the bundle and its launch is node running that script")
    func theSenderShips() throws {
        let script = try #require(AppOwnedConnectorCatalog.appleMailSendScriptURL)
        #expect(script.lastPathComponent == "apple-mail-send.js")
        let preparation = AppleMailSendPreparation(scriptURL: script,
            interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")])
        let launch = sendLaunch()
        let server = try preparation.server(for: launch, profileURL: nil,
            temporaryDirectoryURL: FileManager().temporaryDirectory, fence: FenceProxyResource())
        #expect(server.role == .appleMailSend)
        #expect(server.arguments == [script.standardizedFileURL.path])
        #expect(server.environment == ["OPENBOTS_APP_NAME": "OpenBots Next"])
        // The app's own words need no marker, and there is nothing to reap.
        #expect(!server.program.isFenced)
        #expect(!ClaudeTextConnectorRole.appleMailSend.handsBackUntrustedMaterial)
        #expect(server.options.isEmpty)
        #expect(!preparation.needsOwnedProfile)
    }

    @Test("A build without the sender says so, and cannot be switched on")
    func aMissingSenderIsUnavailable() throws {
        let preparation = AppleMailSendPreparation(scriptURL: nil)
        #expect(throws: AppleMailSendPreparation.Failure.scriptMissing) {
            try preparation.resolve(sendLaunch())
        }
        let availability = try #require(preparation.availability(for: sendLaunch()))
        #expect(!availability.canBeEnabled)
        #expect(try #require(availability.reason).contains("missing the mail sender"))
    }

    @Test("No node is a needs-setup answer rather than a dead launch inside a turn")
    func noNodeIsNeedsSetup() throws {
        let preparation = AppleMailSendPreparation(
            scriptURL: AppOwnedConnectorCatalog.appleMailSendScriptURL, interpreterCandidateURLs: [])
        #expect(throws: AppleMailSendPreparation.Failure.interpreterMissing) {
            try preparation.resolve(sendLaunch())
        }
        #expect(try #require(preparation.availability(for: sendLaunch())).badge == "needs setup")
    }

    @Test("Another connector's row is not the sender's to answer")
    func anotherRowIsNotItsOwn() throws {
        let preparation = AppleMailSendPreparation()
        let reader = ConnectorLaunchConfiguration(serverKey: "openbots_x", transport: .stdio,
            command: AppOwnedConnectorCatalog.appleMailPackage, arguments: ["--read-only"])
        #expect(!preparation.prepares(reader))
        #expect(preparation.availability(for: reader) == nil)
        #expect(throws: AppleMailSendPreparation.Failure.notTheMailSender) {
            try preparation.resolve(reader)
        }
        #expect(throws: AppleMailSendPreparation.Failure.unsupportedTransport) {
            try preparation.resolve(sendLaunch(transport: .http))
        }
    }

    @Test("A send is never quiet, and its card names the account, the recipient and the subject")
    func theSendCardNamesWhatMatters() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("send_mail", ["account": "iCloud", "to": "alex@example.test",
                                           "subject": "Kite says hello", "body": "…"]),
            botName: "Kite", role: .appleMailSend))
        #expect(card.title == "Send mail as you")
        #expect(card.kind == .send)
        #expect(card.target.contains("alex@example.test") && card.target.contains("iCloud"))
        #expect(card.detail.contains("iCloud") && card.detail.contains("alex@example.test"))
        #expect(card.detail.contains("Kite says hello"))
        #expect(card.detail.contains("cannot be taken back"))
    }

    @Test("A send that names no account still shows a card, and the card says so")
    func anUnnamedAccountIsVisibleOnTheCard() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("send_mail", ["to": "someone@example.test", "subject": "No account"]),
            botName: "Kite", role: .appleMailSend))
        #expect(card.detail.contains("an account it did not name"))
        #expect(card.kind == .send)
    }

    @Test("A draft asks too, and says that nothing is sent")
    func aDraftAsksAndSaysNothingIsSent() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("draft_mail", ["account": "iCloud", "to": "alex@example.test",
                                            "subject": "Later"]),
            botName: "Kite", role: .appleMailSend))
        #expect(card.title == "Save a draft in your Mail")
        #expect(card.detail.contains("Nothing is sent"))
        #expect(card.kind == .metadataMutation)
    }

    @Test("Reading the names of the user's own accounts is quiet; anything unknown asks")
    func accountsAreQuietAndTheUnknownAsks() throws {
        let quiet = ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("list_mail_accounts", [:]), botName: "Kite", role: .appleMailSend)
        guard case .allowQuietly(let activity) = quiet else {
            Issue.record("listing accounts should be quiet, got \(quiet)"); return
        }
        #expect(activity.contains("mail accounts"))
        let unknown = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("something_new", [:]), botName: "Kite", role: .appleMailSend))
        #expect(unknown.kind == .send)
        #expect(unknown.detail.contains("does not know what that does"))
    }

    @Test("The shipped sender has no outbox left in it, and its own send path is direct")
    func theOutboxIsGone() throws {
        let script = try #require(AppOwnedConnectorCatalog.appleMailSendScriptURL)
        let source = try String(contentsOf: script, encoding: .utf8)
        // The card is the approval now; the queue and its executor are gone
        // rather than dormant, so there is no second path that could send.
        for absent in ["OPENBOTS_OUTBOX_DIR", "queueSend", "execute-send", "approvalFingerprint"] {
            #expect(!source.contains(absent), "the port still carries \(absent)")
        }
        // What must remain: the no-default-account rule, and the two verbs.
        #expect(source.contains("NO default sending account"))
        #expect(source.contains("send_mail") && source.contains("draft_mail")
                && source.contains("list_mail_accounts"))
    }
}

@Suite("Answering a message the user was sent")
struct AppleMailReplyTests {
    @Test("A reply's card names the message and the copy it answers")
    func theReplyCardNamesTheMessage() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("reply_mail", ["rfc_message_id": "abc@mail.example", "body": "On my way.",
                                            "account": "iCloud",
                                            "expect_subject": "OpenBots send test"]),
            botName: "Kite", role: .appleMailSend))
        #expect(card.title == "Reply as you")
        #expect(card.kind == .send)
        #expect(card.target == "OpenBots send test")
        #expect(card.detail.contains("OpenBots send test"))
        #expect(card.detail.contains("from whichever of your addresses that copy was sent to"))
        #expect(card.detail.contains("cannot be taken back"))
        #expect(card.activity.hasPrefix("Asked"))
    }

    /// `account` is required, and it is what picks
    /// which copy of a Message-ID is answered — the copy the user received, or the
    /// copy in Sent, which carry the same subject and cannot be told apart by
    /// `expect_subject`. It therefore decides which side of the conversation
    /// the reply goes out from, so it has to be on the card the user approves.
    @Test("The account that decides which copy is answered is on the card")
    func theReplyCardNamesTheAccount() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("reply_mail", ["rfc_message_id": "abc@mail.example", "body": "On my way.",
                                            "account": "Acme Works",
                                            "expect_subject": "OpenBots send test"]),
            botName: "Kite", role: .appleMailSend))
        #expect(card.detail.contains("answering the copy in your Acme Works account"))
    }

    @Test("A reply that names no account is not made to look like one that did")
    func theReplyCardSaysWhenNoAccountWasNamed() throws {
        for value in ["", "ask"] {
            var input: [String: Any] = ["rfc_message_id": "abc@mail.example", "body": "On my way.",
                                        "expect_subject": "OpenBots send test"]
            if !value.isEmpty { input["account"] = value }
            let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
                try sendQuestion("reply_mail", input), botName: "Kite", role: .appleMailSend))
            #expect(card.detail.contains("answering a copy in an account it did not name"))
            #expect(!card.detail.contains("your ask account"))
        }
    }

    @Test("A drafted reply asks too, and says nothing is sent")
    func theDraftedReplyCardSaysNothingIsSent() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("draft_reply", ["rfc_message_id": "abc@mail.example", "body": "Later.",
                                             "expect_subject": "OpenBots send test"]),
            botName: "Kite", role: .appleMailSend))
        #expect(card.title == "Save a reply as a draft")
        #expect(card.kind == .metadataMutation)
        #expect(card.detail.contains("Nothing is sent"))
    }

    @Test("The shipped sender can answer a message, and checks the claim before it writes anything")
    func theSenderCarriesTheReplyVerbs() throws {
        let source = try String(contentsOf: try #require(AppOwnedConnectorCatalog.appleMailSendScriptURL),
                                encoding: .utf8)
        #expect(source.contains("reply_mail") && source.contains("draft_reply"))
        // Mail's own verb, so the account is Mail's choice and not a guess.
        #expect(source.contains("set m to reply origMsg opening window false"))
        #expect(source.contains("reply to all true"))
        // The key is the globally unique Message-ID, not Mail's per-account
        // internal id — the behaviour itself is exercised in
        // AppleMailSendScriptTests, which runs the script.
        #expect(source.contains("rfc_message_id"))
        #expect(source.contains("normaliseSubject"))
        #expect(source.contains("nothing was written"))
        // The words go in through `properties`. Assigning `content` directly on
        // a message returned by `reply` is silently ignored by Mail, so every
        // reply this tool sent went out carrying only the signature — proved by
        // hand against the installed build, by saving the
        // reply as a draft and reading it back from the Drafts mailbox.
        // Scoped to the REPLY script rather than the whole file: the compose
        // path sets its own content in a `make new outgoing message` record
        // today, and a refactor there must not fail a test about replies.
        let reply = try #require(source.range(of: "const REPLY = `"))
        let replyScript = String(source[reply.upperBound...].prefix(while: { $0 != "`" }))
        #expect(replyScript.contains("set properties of m to {content:theBody}"))
        #expect(!replyScript.contains("set content of m to theBody"))
    }
}

@Suite("Who a new mail goes from is the user's to choose")
struct AppleMailFromAddressTests {
    @Test("The bot is told to put the choice to the user, and told what a reply needs instead")
    func thePromptPutsTheChoiceToTheUser() {
        let told = ClaudeTextConnectorRole.appleMailSend.promptDescription
        #expect(told.contains("the user chooses which of his addresses it goes from"))
        #expect(told.contains("question tool"))
        #expect(told.contains("never from one you chose"))
        // A reply does not choose the sending identity — Mail does — but it must
        // name the account the message was read in, or the lookup can land on
        // the copy in Sent and answer from the wrong side.
        #expect(told.contains("never choose the sending identity for a reply"))
        #expect(told.contains("pass the account you read it in"))
        #expect(!told.contains("needs no account"))
    }

    @Test("The sender refuses a new mail with no account, and the refusal names the move")
    func aNewMailWithNoAccountIsRefused() throws {
        let source = try String(contentsOf: try #require(AppOwnedConnectorCatalog.appleMailSendScriptURL),
                                encoding: .utf8)
        // Not prose in a persona: the tool itself refuses, so the bot cannot
        // quietly pick an identity for the user.
        #expect(source.contains("he chooses which address a new"))
        #expect(source.contains("ASK HIM with your question tool"))
        #expect(source.contains("Do not choose for him"))
        // "ask" as an account name is the same refusal, not an account.
        #expect(source.contains("account.toLowerCase() === \"ask\""))
    }
}

@Suite("Where the user's mail actually lives")
struct AppleMailMailboxScopeTests {
    @Test("A reading bot is told to look in the archive, not only the inbox")
    func theArchiveIsNamed() {
        let told = ClaudeTextConnectorRole.appleMailRead.promptDescription
        // For many users the archive is where all mail goes once it has been
        // processed, and the reader's search defaults to
        // the inbox — which is how a search comes back empty and wrong.
        #expect(told.contains("ARCHIVE"))
        #expect(told.contains("defaults to INBOX"))
        #expect(told.contains("list_mailboxes"))
        #expect(told.contains("sent mailbox"))
        // And a nothing-found answer has to say where it looked.
        #expect(told.contains("say which mailboxes you actually looked in"))
    }
}

@Suite("More accounts than the question card can show")
struct AppleMailAccountCeilingTests {
    @Test("The bot is told the four-option ceiling and what to do about the rest")
    func theCeilingIsNamed() {
        let told = ClaudeTextConnectorRole.appleMailSend.promptDescription
        // A user can have six accounts; the CLI's question tool takes four
        // options. Two can only arrive through the card's own text box, so the bot
        // has to say that rather than quietly dropping them.
        #expect(told.contains("at most FOUR options"))
        #expect(told.contains("typed into the box"))
        #expect(told.contains("he types there as the account name"))
    }
}

@Suite("Everyone a send would reach")
struct AppleMailRecipientsOnTheCardTests {
    @Test("cc and bcc are on the card, because a copy the user cannot see is one they cannot refuse")
    func copiesAreNamed() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("send_mail", ["account": "iCloud", "to": "a@example.test",
                                            "cc": "b@example.test", "bcc": "c@example.test",
                                            "subject": "Quarterly", "body": "…"]),
            botName: "Kite", role: .appleMailSend))
        #expect(card.detail.contains("a@example.test"))
        #expect(card.detail.contains("cc: b@example.test"))
        #expect(card.detail.contains("bcc: c@example.test"))
        #expect(card.target.contains("bcc: c@example.test"))
    }

    @Test("A reply to everyone says so on the card")
    func replyAllIsNamed() throws {
        let toAll = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("reply_mail", ["rfc_message_id": "x@y", "body": "b",
                                             "expect_subject": "Thread", "reply_all": true]),
            botName: "Kite", role: .appleMailSend))
        #expect(toAll.detail.contains("everyone on that thread"))
        // The reach comes before the subject the bot supplied.
        #expect(toAll.detail.hasPrefix("It goes out as you, and it cannot be taken back. It goes to everyone on that thread"))
        let toSender = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("reply_mail", ["rfc_message_id": "x@y", "body": "b",
                                             "expect_subject": "Thread"]),
            botName: "Kite", role: .appleMailSend))
        #expect(toSender.detail.contains("its sender"))
    }

    @Test("A subject full of blank lines cannot lay out paragraphs inside the card")
    func botTextArrivesAsOneLine() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("send_mail", ["account": "iCloud", "to": "a@example.test",
                                            "subject": "Invoice\n\n Approved — nothing is sent.",
                                            "body": "…"]),
            botName: "Kite", role: .appleMailSend))
        // The app's sentence is one line; the only break on the card is the
        // one the app puts before the body's own block.
        #expect(card.detail.components(separatedBy: "\n\n") == [
            "It goes out as you, and it cannot be taken back. Kite wants to send mail from your iCloud account "
                + "to a@example.test, with the subject \"Invoice Approved — nothing is sent.\".",
            "To: a@example.test\nSubject: Invoice Approved — nothing is sent.\n"
                + "Signature: none named. If you have one signature in Mail, it is added; if you have "
                + "several, none is.",
            "What the mail says:\n…",
        ])
        #expect(card.detail.contains("Invoice Approved — nothing is sent."))
        // The clause the user needs is before the words the bot supplied, so a long
        // subject cannot truncate it away.
        #expect(card.detail.hasPrefix("It goes out as you, and it cannot be taken back."))
    }
}

@Suite("A card that cannot describe the input says so")
struct AppleMailUnreadableInputTests {
    @Test("Addresses in a shape the server refuses are named on the card, never omitted")
    func anUnreadableAddressListIsNamed() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("send_mail", ["account": "iCloud",
                                            "to": ["a@example.test", "b@example.test"],
                                            "bcc": ["hidden@example.test"],
                                            "subject": "Quarterly", "body": "…"]),
            botName: "Kite", role: .appleMailSend))
        // The server refuses this shape outright, so the card must not read as
        // though there were no recipients at all.
        #expect(card.detail.contains("a form this card cannot show"))
        #expect(card.detail.contains("bcc: an address list"))
    }

    @Test("A reply-all flag the server would refuse is not read as either answer")
    func anUnreadableReplyAllIsNamed() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("reply_mail", ["rfc_message_id": "x@y", "body": "b",
                                             "expect_subject": "Thread", "reply_all": "false"]),
            botName: "Kite", role: .appleMailSend))
        #expect(card.detail.contains("a set of recipients this card cannot show"))
        #expect(!card.detail.contains("its sender"))
    }

    @Test("A recipient list too long for the card says how many people it reaches")
    func aLongListIsSummarised() throws {
        // Nine addresses of the length a real company hands out. The first
        // version of this test used nine short ones, which fit — a fixture
        // built to a shape that helps, and the reason the clamp bug survived
        // it.
        let many = (1...9).map { "firstname.lastname\($0)@department.company.example" }
            .joined(separator: ", ")
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("send_mail", ["account": "iCloud", "to": many,
                                            "bcc": "hidden@example.test",
                                            "subject": "All hands", "body": "…"]),
            botName: "Kite", role: .appleMailSend))
        #expect(card.detail.contains("9 people (firstname.lastname1@department.company.example and 8 more)"))
        // The sentence counts them; the labelled lines under it name every one
        // so no address is only a number on the card.
        #expect(card.detail.contains("\n\nTo: " + many + "\nBcc: hidden@example.test\nSubject: All hands\n"),
                "\(card.detail)")
        // The blind copy is named in full even when the others cannot be, and
        // the clause the user needs is still on the card at the end of it.
        #expect(card.detail.contains("bcc: hidden@example.test"))
        #expect(card.detail.hasPrefix("It goes out as you, and it cannot be taken back."))
        #expect(card.detail.contains("with the subject \"All hands\""))
    }

    @Test("A list short enough to read in full is still read in full")
    func aShortListIsNotSummarised() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("send_mail", ["account": "iCloud",
                                            "to": "a@example.test, b@example.test, c@example.test",
                                            "cc": "d@example.test", "bcc": "hidden@example.test",
                                            "subject": "All hands", "body": "…"]),
            botName: "Kite", role: .appleMailSend))
        #expect(card.detail.contains("a@example.test, b@example.test, c@example.test"))
        #expect(card.detail.contains("cc: d@example.test"))
        #expect(card.detail.contains("bcc: hidden@example.test"))
        #expect(!card.detail.contains("people"))
    }

    @Test("\"ask\" is not one of the user's accounts, and the card does not present it as one")
    func askIsNotAnAccountName() throws {
        for tool in ["send_mail", "draft_mail"] {
            let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
                try sendQuestion(tool, ["account": "ask", "to": "a@example.test",
                                        "subject": "Quarterly", "body": "…"]),
                botName: "Kite", role: .appleMailSend))
            #expect(card.detail.contains("an account it did not name"))
            #expect(!card.detail.contains("your ask account"))
        }
    }

    /// The first version of this rule stripped every zero-width character,
    /// which took the joiner out of 👩‍💻 and the non-joiner out of Persian —
    /// and the card showed the same mangled words, so the user could not see
    /// it happen.
    @Test("A joiner is content, not a hiding place, and stays in what the user reads")
    func joinersSurvive() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("send_mail", ["account": "iCloud", "to": "a@example.test",
                                            "subject": "\u{1F469}\u{200D}\u{1F4BB} standup and \u{645}\u{6CC}\u{200C}\u{631}\u{648}\u{645}",
                                            "body": "…"]),
            botName: "Kite", role: .appleMailSend))
        #expect(card.detail.contains("\u{1F469}\u{200D}\u{1F4BB}"))
        #expect(card.detail.contains("\u{645}\u{6CC}\u{200C}\u{631}\u{648}\u{645}"))
    }

    @Test("Invisible characters cannot scramble what the user reads")
    func invisiblesAreStripped() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("send_mail", ["account": "iCloud", "to": "a@example.test",
                                            "subject": "Invoice\u{200b}\u{202e}reversed", "body": "…"]),
            botName: "Kite", role: .appleMailSend))
        #expect(!card.detail.contains("\u{200b}") && !card.detail.contains("\u{202e}"))
        #expect(card.detail.contains("Invoicereversed"))
    }
}

/// The card's own text is clamped, so anything the bot supplies can push the
/// end of the sentence off the card. Counting addresses does not bound their
/// length: five ordinary company addresses in `to` and five in `cc` overrun
/// the clamp on their own, and the bcc — the one recipient the card exists to
/// reveal — would go with it.
@Suite("Nothing a bot supplies can push a recipient off the card")
struct AppleMailCardCannotHideARecipientTests {
    /// Five 46-character addresses and five of 48: the shape of
    /// `firstname.lastname@department.company.example`, an ordinary ten-person
    /// thread, and the exact size that escapes an address *count* cap.
    private static func ordinaryLongList() -> [String: Any] {
        let to = (1...5).map { "firstname.lastname\($0)@department.company.example" }
        let cc = (1...5).map { "othername.surname\($0)@department.subsidiary.example" }
        return ["account": "iCloud", "to": to.joined(separator: ", "),
                "cc": cc.joined(separator: ", "), "bcc": "hidden@example.test",
                "subject": "Quarterly numbers", "body": "…"]
    }

    @Test("Ten ordinary recipients cannot hide the blind copy")
    func aTenPersonThreadCannotHideTheBlindCopy() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("send_mail", Self.ordinaryLongList()),
            botName: "Kite", role: .appleMailSend))
        #expect(card.detail.contains("bcc: hidden@example.test"))
        // And the app's own last clause survives too, so the user is still told what
        // the mail is about.
        #expect(card.detail.contains("Quarterly numbers"))
    }

    @Test("No input at all, however hostile, can clamp a recipient off the card")
    func nothingCanClampARecipientAway() throws {
        let long = String(repeating: "z", count: 4_000)
        let hostile: [String: Any] = [
            "account": long,
            "to": (1...40).map { "\(long)\($0)@example.test" }.joined(separator: ", "),
            "cc": (1...40).map { "\(long)\($0)@example.test" }.joined(separator: ", "),
            "bcc": (1...40).map { "\(long)\($0)@example.test" }.joined(separator: ", "),
            "subject": long, "body": "…",
        ]
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("send_mail", hostile),
            botName: String(repeating: "B", count: 4_000), role: .appleMailSend))
        // The card never runs out of room, so the clamp never decides what the
        // user is told: the sentence is short enough by construction.
        #expect(sentence(card).unicodeScalars.count < 600)
        // Forty blind copies the user cannot see are forty they cannot refuse, so the
        // card says how many even when it cannot name them.
        #expect(card.detail.contains("bcc: 40 people"))
        #expect(card.detail.contains("with the subject"))
    }

    /// The detail's budgets were worked out on paper and the margin came to
    /// three characters. This pins it: a wording change that eats the margin
    /// re-opens the hidden-recipient bug silently otherwise.
    @Test("The longest card this input can build still fits, with the margin pinned")
    func theWorstCaseCardStillFits() throws {
        var worst = 0
        // The longest card lives where the address text sits right on its
        // budget and is still written out in full, so sweep across that edge
        // and across every way of splitting the text between `to` and `cc`.
        for total in stride(from: 170, through: 210, by: 1) {
            for toLength in stride(from: 20, through: total - 20, by: 7) {
                let ccLength = total - toLength
                let input: [String: Any] = [
                    "account": String(repeating: "A", count: 400),
                    "to": String(repeating: "a", count: toLength - 7) + "@x.test",
                    "cc": String(repeating: "b", count: ccLength - 7) + "@x.test",
                    "bcc": "hidden@example.test",
                    "subject": String(repeating: "S", count: 400), "body": "…",
                ]
                // Both tools that name recipients, because they share the
                // rendering and only one of them was swept.
                for tool in ["send_mail", "draft_mail"] {
                    let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
                        try sendQuestion(tool, input),
                        botName: String(repeating: "B", count: 200), role: .appleMailSend))
                    #expect(sentence(card).unicodeScalars.count < 600)
                    #expect(card.target.unicodeScalars.count < 200)
                    worst = max(worst, sentence(card).unicodeScalars.count)
                }
            }
        }
        // And the sweep really did reach the tight region — if a later change
        // moves the maximum somewhere else, this fails rather than passing for
        // the wrong reason.
        #expect(worst > 560, Comment(rawValue: "longest card built was \(worst)"))
    }

    @Test("Even recipients the card cannot read fit on the short target line")
    func unreadableRecipientsFitTheTargetLine() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("send_mail", ["account": String(repeating: "A", count: 400),
                                            "to": ["a@x.test"], "cc": ["b@x.test"],
                                            "bcc": ["c@x.test"],
                                            "subject": "Quarterly", "body": "…"]),
            botName: "Kite", role: .appleMailSend))
        #expect(card.target.unicodeScalars.count < 200)
        // The account the user is sending from survives on the short line too.
        #expect(card.target.contains("— from AAAA"))
        #expect(card.detail.contains("bcc: an address list it sent in a form this card cannot show"))
        // The short phrase has to fit a field's share of the target line whole,
        // or the reader sees it cut. It fits by two characters, which is why
        // this is pinned rather than left to the arithmetic. (The ellipsis on
        // this line belongs to the account, which is 400 characters here.)
        #expect(card.target.contains("bcc: a list this card cannot show"))
    }

    @Test("A single absurdly long address cannot hide the blind copy either")
    func oneEnormousAddressCannotHideTheBlindCopy() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("send_mail", ["account": "iCloud",
                                            "to": String(repeating: "a", count: 533) + "@example.test",
                                            "bcc": "hidden@example.test",
                                            "subject": "Quarterly numbers", "body": "…"]),
            botName: "Kite", role: .appleMailSend))
        #expect(sentence(card).unicodeScalars.count < 600)
        #expect(card.detail.contains("bcc: hidden@example.test"))
    }
}

/// A budget counted in characters bounds nothing, because one character can
/// carry any number of scalars: a 600-character card carried 47,850 of them,
/// measured. So the budgets count Unicode scalars.
@Suite("A card's budget counts scalars, not characters")
struct AppleMailCardBudgetCountsScalarsTests {
    /// One base letter under 47,849 combining marks: a single character.
    private static let oneTallCharacter = "e" + String(repeating: "\u{0301}", count: 47_849)

    @Test("One character carrying thousands of scalars is cut like any other long value")
    func oneClusterIsCutByItsScalars() throws {
        let cut = ClaudeTextAppleMailSendApprovalPolicy.fragment("Invoice " + Self.oneTallCharacter, 120)
        #expect(cut.unicodeScalars.count <= 120)
        #expect(cut.hasSuffix("\u{2026}"))
        // What is kept is the start of what the bot sent, scalar for scalar.
        let kept = Array(cut.unicodeScalars.dropLast())
        #expect(Array(("Invoice " + Self.oneTallCharacter).unicodeScalars.prefix(kept.count)) == kept)
    }

    @Test("A cut keeps whole characters where they fit, so a letter never loses its accent")
    func aCutKeepsWholeCharacters() {
        // "aé" spelled with a combining acute, then "b": three characters of
        // four scalars. Cut to three, the "é" does not fit whole in the two
        // scalars before the ellipsis, so it goes whole rather than as a bare e.
        #expect(ClaudeTextAppleMailSendApprovalPolicy.fragment("ae\u{0301}b", 3)
            .unicodeScalars.elementsEqual("a\u{2026}".unicodeScalars))
        // And a value that fits is untouched.
        #expect(ClaudeTextAppleMailSendApprovalPolicy.fragment("ae\u{0301}b", 4)
            .unicodeScalars.elementsEqual("ae\u{0301}b".unicodeScalars))
    }

    @Test("A subject of one tall character cannot swell the detail or the target")
    func aTallSubjectIsBounded() throws {
        let cases: [(String, [String: Any])] = [
            ("send_mail", ["account": "iCloud", "to": "a@example.test", "subject": Self.oneTallCharacter,
                           "body": "b"]),
            ("reply_mail", ["rfc_message_id": "x@y", "account": "iCloud", "body": "b",
                            "expect_subject": Self.oneTallCharacter]),
        ]
        for (tool, input) in cases {
            let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
                try sendQuestion(tool, input), botName: Self.oneTallCharacter, role: .appleMailSend))
            let lead = card.detail.components(separatedBy: "\n\n")[0]
            #expect(lead.unicodeScalars.count <= 600, Comment(rawValue: "\(tool): \(lead.unicodeScalars.count)"))
            #expect(card.target.unicodeScalars.count <= 200,
                    Comment(rawValue: "\(tool): \(card.target.unicodeScalars.count)"))
            #expect(card.activity.unicodeScalars.count <= 200)
        }
    }

    /// The recipient rule chooses between naming every address and counting
    /// them by how long the addresses are. Measured in characters, a tall
    /// address passed as short, the full form went into the sentence, and the
    /// scalar clamp at its end cut off the blind copy.
    @Test("A tall address cannot push the blind copy off the card")
    func aTallAddressCannotHideTheBlindCopy() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("send_mail", ["account": "iCloud",
                                            "to": "a" + String(repeating: "\u{0301}", count: 3_000) + "@x.test",
                                            "bcc": "hidden@example.test",
                                            "subject": "Quarterly numbers", "body": "b"]),
            botName: "Kite", role: .appleMailSend))
        let lead = card.detail.components(separatedBy: "\n\n")[0]
        #expect(lead.unicodeScalars.count < 600)
        #expect(lead.contains("bcc: hidden@example.test"))
        #expect(lead.contains("with the subject \"Quarterly numbers\""))
        #expect(card.target.unicodeScalars.count <= 200)
        #expect(card.target.contains("bcc: hidden@example.test"))
    }
}

/// Two replies that carried no words at all were once approved with no way to
/// see it. The card shows the whole body in its scrolled box,
/// as the browser's card shows what it hands a site, and an empty body is said
/// in words.
@Suite("The mail card shows the words of the mail")
struct AppleMailCardShowsTheBodyTests {
    private static var everyTool: [(tool: String, input: [String: Any])] { [
        ("send_mail", ["account": "iCloud", "to": "a@example.test", "subject": "Quarterly"]),
        ("draft_mail", ["account": "iCloud", "to": "a@example.test", "subject": "Quarterly"]),
        ("reply_mail", ["rfc_message_id": "x@y", "account": "iCloud", "expect_subject": "Quarterly"]),
        ("draft_reply", ["rfc_message_id": "x@y", "account": "iCloud", "expect_subject": "Quarterly"]),
    ] }

    private static func card(_ tool: String, _ input: [String: Any], body: Any?) throws -> ClaudeTextWorkCard {
        var input = input
        if let body { input["body"] = body }
        return try askedCard(ClaudeTextConnectorApprovalPolicy.decide(try sendQuestion(tool, input),
                                                                      botName: "Kite", role: .appleMailSend))
    }

    @Test("The whole body is on the card, line breaks and all, after the app's own sentence")
    func theWholeBodyIsOnTheCard() throws {
        let body = "Hello Anna,\n\nThe numbers are attached.\n" + (1...200).map { "Line \($0) of the report." }
            .joined(separator: "\n") + "\n\nAlex"
        for (tool, input) in Self.everyTool {
            let card = try Self.card(tool, input, body: body)
            #expect(card.detail.hasSuffix("\n" + body), Comment(rawValue: tool))
            // The app's own sentence comes first and is still bounded; the
            // body follows it whole rather than being cut to the card's 600.
            let lead = card.detail.components(separatedBy: "\n\n")[0]
            #expect(lead.unicodeScalars.count < 600 && !lead.contains("Hello Anna"), Comment(rawValue: tool))
            #expect(card.detail.unicodeScalars.count > 4_000, Comment(rawValue: tool))
        }
    }

    @Test("A body with no words in it is said plainly, on every card")
    func anEmptyBodyIsSaid() throws {
        // Missing, empty, only spaces and breaks, and only characters that
        // draw nothing: each is a mail with no words in it.
        let empties: [Any?] = [nil, "", "   \n\n\t ", "\u{0085}", "\u{200B}\u{200E}\u{2060}"]
        for (tool, input) in Self.everyTool {
            for body in empties {
                let card = try Self.card(tool, input, body: body)
                #expect(card.detail.hasSuffix("\n\nThis mail has no words in it."),
                        Comment(rawValue: "\(tool), \(String(describing: body).debugDescription): \(card.detail)"))
            }
            // A body the server refuses for its shape is not called empty: the
            // card says it cannot show it.
            let unreadable = try Self.card(tool, input, body: ["a", "b"])
            #expect(!unreadable.detail.contains("no words"), Comment(rawValue: tool))
            #expect(unreadable.detail.contains("cannot show"), Comment(rawValue: tool))
        }
    }

    @Test("The body loses the characters that hide or reorder words, as the subject does, and keeps the joiners")
    func theBodyIsSanitisedLikeTheSubject() throws {
        let card = try Self.card("send_mail", Self.everyTool[0].input,
                                 body: "Pay \u{202E}evil\u{202C} now\u{200B}\n\u{2066}isolated\u{2069} \u{FEFF}"
                                    + "\u{1F469}\u{200D}\u{1F4BB} \u{645}\u{6CC}\u{200C}\u{631}\u{648}\u{645}")
        for hidden in ["\u{202E}", "\u{202C}", "\u{200B}", "\u{2066}", "\u{2069}", "\u{FEFF}"] {
            #expect(!card.detail.contains(hidden))
        }
        #expect(card.detail.hasSuffix("\nPay evil now\nisolated \u{1F469}\u{200D}\u{1F4BB} "
                                      + "\u{645}\u{6CC}\u{200C}\u{631}\u{648}\u{645}"))
    }
}

@Suite("Apple Mail never sends or saves a secret the user gave this turn")
struct AppleMailSecretTests {
    @Test("A secret in any field of a send, a reply or a draft is caught; a clean one is not")
    func secretsAreCaught() throws {
        let secret = "hunter2-secret"
        let base: [String: Any] = ["account": "iCloud", "to": ["ada@example.com"], "subject": "Hello",
                                   "body": "See you soon.", "expect_subject": "Hello", "message_id": "<a@b>"]
        for tool in ["send_mail", "reply_mail", "draft_reply", "draft_mail"] {
            for (field, value) in [("subject", "Re: \(secret)" as Any), ("body", "Here: \(secret)"),
                                   ("to", ["\(secret)@example.com"]), ("expect_subject", secret)] {
                var input = base; input[field] = value
                let data = try JSONSerialization.data(withJSONObject: input)
                #expect(ClaudeTextAppleMailSendApprovalPolicy.carriesASecret(tool: tool, data, secrets: [secret]),
                        "\(tool) \(field)")
            }
            let clean = try JSONSerialization.data(withJSONObject: base)
            #expect(!ClaudeTextAppleMailSendApprovalPolicy.carriesASecret(tool: tool, clean, secrets: [secret]), "\(tool)")
        }
        // Reading the user's accounts carries nothing out; anything unreadable counts.
        #expect(!ClaudeTextAppleMailSendApprovalPolicy.carriesASecret(tool: "list_mail_accounts", Data("{}".utf8), secrets: [secret]))
        #expect(ClaudeTextAppleMailSendApprovalPolicy.carriesASecret(tool: "send_mail", Data("not json".utf8), secrets: []))
    }
}

@Suite("Every card budget counts scalars, not Characters")
struct CardBudgetScalarTests {
    @Test("A cut keeps at most the budget in scalars, whatever one cluster carries")
    func scalarPrefixCountsScalars() {
        let tall = "a" + String(repeating: "\u{0301}", count: 5_000)
        #expect(tall.count == 1)
        #expect(String(tall.prefix(200)).unicodeScalars.count == 5_001, "the old cut kept the whole cluster")
        #expect(tall.scalarPrefix(200).unicodeScalars.count == 200)
        #expect("plain words".scalarPrefix(5) == "plain")
        #expect("short".scalarPrefix(200) == "short")
    }

    @Test("A card built from a tool's name stays in budget when the name is one tall cluster")
    func anUnknownToolCardStaysInBudget() throws {
        let tall = "z" + String(repeating: "\u{0301}", count: 5_000)
        let request = ClaudeTextPermissionRequest(requestID: "r", toolUseID: "t",
            toolName: "mcp__claude_extension_notes__\(tall)", inputJSON: Data("{}".utf8))
        let decision = ClaudeTextConnectorApprovalPolicy.decide(request, botName: "Kite", role: .appleNotes)
        guard case .ask(let card) = decision else { Issue.record("an unknown tool asks, got \(decision)"); return }
        #expect(card.detail.unicodeScalars.count <= 600 && card.target.unicodeScalars.count <= 200
                && card.activity.unicodeScalars.count <= 200, "\(card.detail.unicodeScalars.count)")
    }
}

/// The sentence is bounded, so past 224 scalars it counts the recipients and
/// names only the first of each field: a second blind copy was a number, and a
/// subject was cut at 120 of the script's 400. The labelled
/// lines at the top of the mail's block are shown whole, so every address, the
/// whole subject and the signature are on the card. The fix shows
/// everything rather than refusing more, because the last refusal rule added
/// to this path broke ordinary sends.
@Suite("Every address, the whole subject and the signature are on the mail card")
struct AppleMailCardNamesEverythingTests {
    private static let longTo = (1...5).map { "firstname.lastname\($0)@department.company.example" }
        .joined(separator: ", ")

    @Test("A second blind copy past the sentence's budget is named in full")
    func everyBlindCopyIsNamed() throws {
        for tool in ["send_mail", "draft_mail"] {
            let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
                try sendQuestion(tool, ["account": "iCloud", "to": Self.longTo,
                                        "cc": "colleague@department.company.example",
                                        "bcc": "first.hidden@example.test, second.hidden@example.test",
                                        "subject": "Quarterly", "body": "Hello"]),
                botName: "Kite", role: .appleMailSend))
            // The sentence had to count, so the header is the only place the
            // second blind copy can be read.
            #expect(sentence(card).contains("bcc: 2 people"), Comment(rawValue: "\(tool): \(sentence(card))"))
            #expect(card.detail.contains("\n\nTo: " + Self.longTo + "\n"
                + "Cc: colleague@department.company.example\n"
                + "Bcc: first.hidden@example.test, second.hidden@example.test\n"
                + "Subject: Quarterly\n"), Comment(rawValue: "\(tool): \(card.detail)"))
            // The header comes before the mail's own words.
            let header = try #require(card.detail.range(of: "\n\nTo: "))
            let words = try #require(card.detail.range(of: "What the mail says:\nHello"))
            #expect(header.lowerBound < words.lowerBound, Comment(rawValue: tool))
        }
    }

    @Test("A subject as long as the script accepts is shown whole")
    func theWholeSubjectIsShown() throws {
        let subject = (1...40).map { "Part \($0)," }.joined(separator: " ") + " end"
        #expect(subject.unicodeScalars.count > 300 && subject.unicodeScalars.count <= 400)
        for tool in ["send_mail", "draft_mail"] {
            let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
                try sendQuestion(tool, ["account": "iCloud", "to": "a@example.test",
                                        "subject": subject, "body": "Hello"]),
                botName: "Kite", role: .appleMailSend))
            #expect(card.detail.contains("\nSubject: " + subject + "\n"), Comment(rawValue: tool))
        }
    }

    @Test("The card says which signature Mail adds, as the script decides it")
    func theSignatureIsNamed() throws {
        for tool in ["send_mail", "draft_mail"] {
            let named = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
                try sendQuestion(tool, ["account": "iCloud", "to": "a@example.test", "subject": "Hi",
                                        "body": "Hello", "signature": "Work"]),
                botName: "Kite", role: .appleMailSend))
            #expect(named.detail.contains("\nSignature: Work\n\n"), Comment(rawValue: "\(tool): \(named.detail)"))
            for input: [String: Any] in [["signature": ""], ["signature": "   "], [:]] {
                let unnamed = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
                    try sendQuestion(tool, input.merging(["account": "iCloud", "to": "a@example.test",
                                                          "subject": "Hi", "body": "Hello"]) { a, _ in a }),
                    botName: "Kite", role: .appleMailSend))
                #expect(unnamed.detail.contains("\nSignature: none named. If you have one signature in Mail, "
                    + "it is added; if you have several, none is.\n\n"), Comment(rawValue: "\(tool): \(unnamed.detail)"))
            }
        }
        // A reply names no signature: Mail adds its own when it sends one.
        let reply = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("reply_mail", ["rfc_message_id": "x@y", "account": "iCloud",
                                             "expect_subject": "Hi", "body": "Hello"]),
            botName: "Kite", role: .appleMailSend))
        #expect(!reply.detail.contains("Signature:"))
    }

    @Test("A field in a shape the card cannot read is named, not left off")
    func anUnreadableFieldIsNamed() throws {
        let card = try askedCard(ClaudeTextConnectorApprovalPolicy.decide(
            try sendQuestion("send_mail", ["account": "iCloud", "to": "a@example.test",
                                            "bcc": ["hidden@example.test"], "subject": "Hi", "body": "Hello"]),
            botName: "Kite", role: .appleMailSend))
        #expect(card.detail.contains("\nBcc: an address list it sent in a form this card cannot show\n"),
                "\(card.detail)")
    }
}
