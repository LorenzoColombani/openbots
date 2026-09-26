import Foundation
import OpenBotsDomain
import OpenBotsRuntime

/// What the approval card says when a bot wants to use one of its connectors.
///
/// One convention to keep, set by the work policy and learned the hard way: a
/// card's `activity` line is written the moment the card goes up, before
/// the user has answered, so it says what the bot **asked** to do. The verdict line
/// that follows — "Approved: …" or "Denied: …" — is what says whether it
/// happened. A card that wrote the deed instead put "Sent mail from iCloud" in
/// the record of a send the user had just refused. Only a quiet decision may phrase
/// the deed, because a quiet decision is the deed.
///
/// The router is here rather than in the caller because the tool name alone
/// cannot answer it: a server's name is a hash of its identity, so
/// `mcp__openbots_9f3a2b…__get_messages` reads the same whether it came from
/// the browser or from Apple Mail. The turn's own selection knows, and says so
/// with its role.
public enum ClaudeTextConnectorApprovalPolicy {
    /// True for a tool name in a connector's namespace, whatever the server.
    public static func isConnectorTool(_ name: String) -> Bool { name.hasPrefix("mcp__") }

    /// The tool's own short name, without the `mcp__<server>__` prefix.
    public static func toolName(in name: String) -> String {
        guard let range = name.range(of: "__", options: .backwards) else { return name }
        return String(name[range.upperBound...])
    }

    /// The card for one call, in the words of the connector that will run it.
    ///
    /// A role the app has no words for does not fall back to the browser's
    /// copy — a card that confidently describes the wrong thing is worse than
    /// one that admits it does not know.
    public static func decide(_ request: ClaudeTextPermissionRequest, botName: String,
                              role: ClaudeTextConnectorRole?,
                              macLooks: MacControlLooks = MacControlLooks(),
                              macAfterTexts: Bool = false, macAfterChrome: Bool = false, macAfterOther: String? = nil, macReadBy: String? = nil,
                              macAfterLook: Bool = false,
                              chrome: ChromeControlContext? = nil,
                              browserAfterPrivateRead: Bool = false) -> ClaudeTextWorkDecision {
        switch role {
        case .browser:
            return ClaudeTextBrowserApprovalPolicy.decide(request, botName: botName,
                                                          afterPrivateRead: browserAfterPrivateRead)
        case .appleMailRead:
            return ClaudeTextAppleMailApprovalPolicy.decide(request, botName: botName)
        case .appleMailSend:
            return ClaudeTextAppleMailSendApprovalPolicy.decide(request, botName: botName)
        case .appleContactsRead:
            return ClaudeTextAppleContactsApprovalPolicy.decide(request, botName: botName)
        case .appleCalendarRead:
            return ClaudeTextAppleCalendarApprovalPolicy.decide(request, botName: botName)
        case .googleGmailReadDraft:
            return ClaudeTextGoogleGmailApprovalPolicy.decide(request, botName: botName)
        case .googleGmailSend:
            return ClaudeTextGoogleGmailSendApprovalPolicy.decide(request, botName: botName)
        case .googleCalendarRead:
            return ClaudeTextGoogleCalendarApprovalPolicy.decide(request, botName: botName)
        case .googleDriveRead:
            return ClaudeTextGoogleDriveApprovalPolicy.decide(request, botName: botName)
        case .appleMessages:
            return ClaudeTextAppleMessagesApprovalPolicy.decide(request, botName: botName)
        case .macControl:
            return ClaudeTextMacControlApprovalPolicy.decide(request, botName: botName, looks: macLooks,
                                                             afterTexts: macAfterTexts, afterChrome: macAfterChrome,
                                                             afterOther: macAfterOther, readBy: macReadBy,
                                                             afterLook: macAfterLook)
        case .appleNotes:
            return ClaudeTextAppleNotesApprovalPolicy.decide(request, botName: botName)
        case .chromeControl:
            // Without the context the app looks up first, nothing about the user's
            // Chrome is known, so the call is refused rather than guessed at.
            return ClaudeTextChromeControlApprovalPolicy.decide(request, botName: botName,
                context: chrome ?? ChromeControlContext(chromeIsOpen: false, grantsWeb: false))
        case nil:
            let tool = ClaudeTextBrowserApprovalPolicy.readable(toolName(in: request.toolName))
            return .ask(ClaudeTextWorkCard(
                title: "Use a connector", detail: String(("\(botName) wants to use \(tool). This version "
                    + "does not know what that does, so it asks.").scalarPrefix(600)),
                target: String(tool.scalarPrefix(200)), kind: .metadataMutation,
                activity: String("Asked to use \(tool)".scalarPrefix(200))))
        }
    }
}

/// Gmail reads are quiet after both switches are granted. Creating a draft is
/// the row's one mutation and asks every time, with every recipient visible.
/// There is intentionally no send case here: sending is the Gmail send row's,
/// with its own switch and capability (`ClaudeTextGoogleGmailSendApprovalPolicy`).
public enum ClaudeTextGoogleGmailApprovalPolicy {
    static let quietReads: Set<String> = [
        "gmail_account", "search_gmail", "read_gmail_message", "read_gmail_thread",
    ]

    static func decide(_ request: ClaudeTextPermissionRequest, botName: String) -> ClaudeTextWorkDecision {
        let tool = ClaudeTextConnectorApprovalPolicy.toolName(in: request.toolName)
        let input = (try? JSONSerialization.jsonObject(with: request.inputJSON)) as? [String: Any] ?? [:]
        if quietReads.contains(tool) {
            let line: String
            switch tool {
            case "gmail_account": line = "Checked the connected Gmail account"
            case "search_gmail": line = "Searched the OpenBots Gmail account"
            case "read_gmail_thread": line = "Read a thread in the OpenBots Gmail account"
            default: line = "Read a message in the OpenBots Gmail account"
            }
            return .allowQuietly(activity: line)
        }
        if tool == "create_gmail_draft" {
            guard let proposal = try? GoogleGmailDraftProposal(input: input) else {
                return .ask(ClaudeTextWorkCard(
                    title: "Fix the Gmail draft details",
                    detail: "The draft fields cannot be shown exactly and safely on this card, so "
                        + "OpenBots will refuse to save it. Ask the bot for fewer or shorter recipients "
                        + "a subject of at most \(GoogleGmailDraftProposal.maximumSubjectCharacters) characters, "
                        + "and words of at most \(GoogleGmailDraftProposal.maximumBodyScalars) characters with no "
                        + "hidden characters in them.",
                    target: "an invalid Gmail draft", kind: .metadataMutation,
                    activity: "Asked to save a Gmail draft whose fields were invalid"))
            }
            let bot = ClaudeTextAppleMailSendApprovalPolicy.fragment(botName, 60)
            return .ask(ClaudeTextWorkCard(
                title: "Save a draft in Gmail",
                // Every accepted address, every subject character and the
                // whole body are here, laid out as the Gmail send card lays
                // them out: the subject on its own labelled line, so a quote
                // mark in it cannot close a quotation in the app's sentence,
                // then the words after a blank line. The
                // proposal's own limits keep this inside the approvals record,
                // so no generic truncation helper may be introduced here.
                detail: "Nothing is sent. \(bot) wants to save a draft in the separate OpenBots "
                    + "Gmail account. \(proposal.recipientDescription).\nSubject: \(proposal.subject)"
                    + "\n\n" + proposal.body,
                target: "the OpenBots Gmail account",
                kind: .metadataMutation, activity: "Asked to save a draft in the OpenBots Gmail account"))
        }
        let readable = ClaudeTextBrowserApprovalPolicy.readable(tool)
        return .ask(ClaudeTextWorkCard(
            title: "Do something in the OpenBots Gmail account",
            detail: String(("\(botName) wants to use \(readable) in Gmail. This connector is limited to "
                + "reading and saving a new draft, so this asks before an unknown operation.").scalarPrefix(600)),
            target: String(readable.scalarPrefix(200)), kind: .send,
            activity: String("Asked to use \(readable) in Gmail".scalarPrefix(200))))
    }
}

/// The three Google Calendar operations are reads. Anything else asks and can
/// never be advertised by the app-owned server's closed tool list.
public enum ClaudeTextGoogleCalendarApprovalPolicy {
    static let quietReads: Set<String> = [
        "list_google_calendars", "search_google_events", "read_google_event",
    ]

    static func decide(_ request: ClaudeTextPermissionRequest, botName: String) -> ClaudeTextWorkDecision {
        let tool = ClaudeTextConnectorApprovalPolicy.toolName(in: request.toolName)
        if quietReads.contains(tool) {
            switch tool {
            case "list_google_calendars": return .allowQuietly(activity: "Listed the OpenBots Google calendars")
            case "search_google_events": return .allowQuietly(activity: "Read the OpenBots Google calendars")
            default: return .allowQuietly(activity: "Read one event in the OpenBots Google calendar")
            }
        }
        let readable = ClaudeTextBrowserApprovalPolicy.readable(tool)
        return .ask(ClaudeTextWorkCard(
            title: "Do something in Google Calendar",
            detail: String(("\(botName) wants to use \(readable) in the OpenBots Google Calendar. "
                + "This connector is supposed to read and nothing else, so this asks before it happens.").scalarPrefix(600)),
            target: String(readable.scalarPrefix(200)), kind: .send,
            activity: String("Asked to use \(readable) in Google Calendar".scalarPrefix(200))))
    }
}

/// Drive's three tools are reads under a permission that can write nothing.
/// Anything else asks, and the app-owned server can never advertise it.
public enum ClaudeTextGoogleDriveApprovalPolicy {
    static let quietReads: Set<String> = [
        "search_google_drive", "list_google_drive_folder", "read_google_drive_file",
    ]

    static func decide(_ request: ClaudeTextPermissionRequest, botName: String) -> ClaudeTextWorkDecision {
        let tool = ClaudeTextConnectorApprovalPolicy.toolName(in: request.toolName)
        switch tool {
        case "search_google_drive": return .allowQuietly(activity: "Searched the OpenBots Google Drive")
        case "list_google_drive_folder": return .allowQuietly(activity: "Listed a folder in the OpenBots Google Drive")
        case "read_google_drive_file": return .allowQuietly(activity: "Read a file in the OpenBots Google Drive")
        default:
            let readable = ClaudeTextBrowserApprovalPolicy.readable(tool)
            return .ask(ClaudeTextWorkCard(
                title: "Do something in Google Drive",
                detail: String(("\(botName) wants to use \(readable) in the OpenBots Google Drive. "
                    + "This connector is supposed to read and nothing else, so this asks before it happens.").scalarPrefix(600)),
                target: String(readable.scalarPrefix(200)), kind: .send,
                activity: String("Asked to use \(readable) in Google Drive".scalarPrefix(200))))
        }
    }
}

/// What the card says when a bot wants to send mail as the user.
///
/// Nothing here is ever quiet. A send leaves the Mac as the user, from an account
/// that is one of the user's several identities, so the card names the account, the
/// recipient and the subject — the three things the user needs to refuse it — then
/// the mail's own words whole (`words`), and a draft says plainly that
/// nothing is sent. The old app's rule stands:
/// there is no default account, and a send that does not name one is refused
/// before it reaches Mail.
public enum ClaudeTextAppleMailSendApprovalPolicy {
    static func decide(_ request: ClaudeTextPermissionRequest, botName: String) -> ClaudeTextWorkDecision {
        let tool = ClaudeTextConnectorApprovalPolicy.toolName(in: request.toolName)
        let input = (try? JSONSerialization.jsonObject(with: request.inputJSON)) as? [String: Any] ?? [:]
        // Every value that reaches the card from outside the app is bounded
        // before it enters the sentence, and the budgets below sum to less than
        // the card's own clamp, so no input can cut the app's words short.
        let botName = Self.fragment(botName, 60)
        let account = Self.fragment((input["account"] as? String) ?? "", 80)
        let subject = Self.fragment((input["subject"] as? String) ?? "", 120)
        switch tool {
        case "list_mail_accounts":
            // Reading the names of the user's own accounts sends nothing and changes
            // nothing; it is what the bot must do before it can name one.
            return .allowQuietly(activity: "Looked up your mail accounts")
        case "send_mail":
            // The script refuses `ask` as an account, so the card must not read
            // "from your ask account" as though it were one of the user's.
            let named = Self.namedAccount(account)
            let recipients = Self.recipients(input)
            // The target line is clamped harder than the detail is, so it is
            // rendered to its own budget rather than cut from the detail's.
            let brief = Self.recipients(input, budget: max(60, 190 - Self.size(named)))
            return .ask(card(
                title: "Send mail as you",
                target: brief.isEmpty ? named : "\(brief) — from \(named)",
                detail: "It goes out as you, and it cannot be taken back. \(botName) wants to send "
                    + "mail from your \(named) account to "
                    + "\(recipients.isEmpty ? "a recipient it did not name" : recipients)"
                    + ", with the subject \"\(subject.isEmpty ? "(none)" : subject)\".",
                kind: .send, activity: "Asked to send mail from \(named)",
                words: Self.envelope(input) + "\n\n" + Self.words(input, replying: false)))
        case "reply_mail", "draft_reply":
            // A reply answers from the
            // account the original was addressed to, because that is what Mail
            // itself does and what the user would do by hand. What the user needs on the
            // card is which message is being answered and how far the answer
            // goes, and the server refuses the whole thing if the subject on
            // the card and the subject on the message do not match exactly.
            //
            // The account belongs on this card too, though the card once said
            // it did not. Since `account` became required
            // it is the field that picks WHICH copy of a Message-ID is
            // answered — and the copy the user received and the copy in Sent carry
            // the same subject, so `expect_subject` cannot tell them apart.
            // The account therefore decides which side of the conversation the
            // reply goes out from, which is exactly the wrong-side defect that
            // rule was written to close. A field that decides the outcome is a
            // field the user has to be able to read.
            let about = Self.fragment((input["expect_subject"] as? String) ?? "", 140)
            let sending = tool == "reply_mail"
            let named = Self.namedAccount(account)
            let whichCopy = account.trimmingCharacters(in: .whitespaces).isEmpty
                || account.trimmingCharacters(in: .whitespaces).lowercased() == "ask"
                ? "answering a copy in \(named)"
                : "answering the copy in your \(named) account"
            // The server accepts only a real boolean here, so the card reads it
            // the same way: a JSON string "false" is neither true nor a shape
            // that will be sent, and the card must not guess between them.
            let flag = input["reply_all"]
            let everyone = (flag as? Bool) == true || (flag as? NSNumber)?.boolValue == true
            let unreadable = flag != nil && !(flag is NSNull) && !(flag is Bool) && !(flag is NSNumber)
            let reach = unreadable ? "a set of recipients this card cannot show"
                : (everyone ? "everyone on that thread" : "its sender")
            return .ask(card(
                title: sending ? "Reply as you" : "Save a reply as a draft",
                target: about.isEmpty ? "a message in your Mail" : about,
                // Everything the user needs comes before the words the bot supplied,
                // so a 400-character subject cannot clamp the reach off the end.
                detail: (sending ? "It goes out as you, and it cannot be taken back. "
                                 : "Nothing is sent. ")
                    + "It goes to \(reach), \(whichCopy), so it comes from whichever of your "
                    + "addresses that copy was sent to. "
                    + "\(botName) wants to \(sending ? "answer" : "draft an answer to") "
                    + "\(about.isEmpty ? "a message in your Mail" : "\"\(about)\"").",
                kind: sending ? .send : .metadataMutation,
                activity: sending ? "Asked to reply as you" : "Asked to draft a reply",
                words: Self.words(input, replying: true)))
        case "draft_mail":
            let named = Self.namedAccount(account)
            let recipients = Self.recipients(input)
            let brief = Self.recipients(input, budget: max(60, 190 - Self.size(named)))
            return .ask(card(
                title: "Save a draft in your Mail",
                target: brief.isEmpty ? named : "\(brief) — from \(named)",
                detail: "Nothing is sent. \(botName) wants to save a draft under your \(named) "
                    + "account to \(recipients.isEmpty ? "a recipient it did not name" : recipients)"
                    + ", subject \"\(subject.isEmpty ? "(none)" : subject)\".",
                kind: .metadataMutation, activity: "Asked to save a draft in your Mail",
                words: Self.envelope(input) + "\n\n" + Self.words(input, replying: false)))
        default:
            let readable = ClaudeTextBrowserApprovalPolicy.readable(tool)
            return .ask(card(
                title: "Do something in your Mail",
                target: readable,
                detail: "\(botName) wants to use \(readable) in your Mail. This version does not "
                    + "know what that does, so it asks.",
                kind: .send, activity: "Asked to use \(readable) in your mail"))
        }
    }

    /// The tools that put words into the user's Mail: a send and a reply leave the
    /// Mac, and a draft syncs to the account's server.
    static let writingTools: Set<String> = ["send_mail", "reply_mail", "draft_reply", "draft_mail"]
    static let secretRefusal = "This mail carries something the user gave as a secret earlier in this turn, "
        + "so nothing was sent or saved. Never put a secret he gave you into a mail."
    static let secretActivity = "Blocked a mail that carried a secret you gave"

    /// Whether a mail would carry a secret the user gave this turn, in any value it
    /// holds, by the rule a text in Messages follows (otherwise the card
    /// blanks it, and Mail would send the real value). An input that
    /// cannot be read counts too.
    static func carriesASecret(tool: String, _ inputJSON: Data, secrets: [String]) -> Bool {
        guard writingTools.contains(tool) else { return false }
        guard let input = (try? JSONSerialization.jsonObject(with: inputJSON)) as? [String: Any] else { return true }
        func strings(_ value: Any) -> [String] {
            switch value {
            case let text as String: [text]
            case let list as [Any]: list.flatMap(strings)
            case let object as [String: Any]: object.values.flatMap(strings)
            default: []
            }
        }
        let fields = strings(input)
        return secrets.filter { $0.count >= 4 }.contains { secret in
            fields.contains { $0.contains(secret) || ClaudeTextAppleMessagesApprovalPolicy.containsScalars($0, secret) }
        }
    }

    /// Everyone a send would reach, in the order the user reads them, and never a
    /// recipient left off the card: a bcc the user cannot see is a bcc the user cannot
    /// refuse.
    ///
    /// The card's own text is clamped, so this string has to be bounded here
    /// rather than there — whatever runs past the clamp is silence, and silence
    /// about a blind copy is the one thing this sentence exists to prevent. The
    /// first attempt bounded the *count* of addresses, which does not bound
    /// their length: five ordinary company addresses in `to` and five in `cc`
    /// overrun the clamp on their own, as running the card shows. So the rule is by characters, and it has
    /// two forms. While every address fits, the user reads every address. When they
    /// do not, each field says how many people it reaches and names the first —
    /// and the blind copies are named in full for as long as they fit, because
    /// that is the field the user most needs to see.
    static func recipients(_ input: [String: Any], budget: Int = 224) -> String {
        // Three fields, three separators of ", " between them.
        let perField = max(18, (budget - 4) / 3)
        var full: [String] = []
        var short: [String] = []
        for (label, key) in [("", "to"), ("cc: ", "cc"), ("bcc: ", "bcc")] {
            guard let value = input[key], !(value is NSNull) else { continue }
            // Only a string is a shape the server will accept, so anything else
            // is named as what it is rather than quietly left off the card.
            guard let text = value as? String else {
                full.append(label + "an address list it sent in a form this card cannot show")
                // Short enough for a field's share of the target line, which is
                // tighter than the detail's: the long phrase rendered three
                // times overran it.
                short.append(fragment(label + "a list this card cannot show", perField))
                continue
            }
            let addresses = oneLine(text).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let first = addresses.first else { continue }
            full.append(label + addresses.joined(separator: ", "))
            short.append(fragment(summarised(label: label, addresses: addresses,
                                             first: first, budget: perField), perField))
        }
        let everyAddress = full.joined(separator: ", ")
        // Measured in the card's own unit: counted in characters, a tall
        // address passed as short and the clamp cut the blind copy off.
        return size(everyAddress) <= budget ? everyAddress : short.joined(separator: ", ")
    }

    /// One field of the short form: the count always, the addresses when they
    /// fit. The count leads, so the piece can be read even where the addresses
    /// had to go.
    private static func summarised(label: String, addresses: [String],
                                   first: String, budget: Int) -> String {
        let counted = label + (addresses.count == 1 ? "1 person" : "\(addresses.count) people")
        if addresses.count == 1 {
            let named = label + first
            return size(named) <= budget ? named : counted
        }
        let sampled = counted + " (\(first) and \(addresses.count - 1) more)"
        return size(sampled) <= budget ? sampled : counted
    }

    /// Bot-supplied words go into app-authored prose, so they arrive as one
    /// line: a subject carrying blank lines could otherwise lay out paragraphs
    /// of its own inside the card.
    static func oneLine(_ value: String) -> String {
        // Split over scalars, not characters. Splitting over characters split
        // over grapheme clusters, so a combining mark whose base is a space
        // was eaten here and kept in the mail — a character in the mail and
        // not on the card, which is the whole thing this rule exists to
        // prevent.
        let visible = value.unicodeScalars.filter { !Self.isHidden($0) }
        return visible.split(whereSeparator: { $0.properties.isWhitespace })
            .map { String(String.UnicodeScalarView($0)) }
            .joined(separator: " ")
    }

    /// Characters that can reorder or hide what the user reads, and are never part of
    /// the words themselves.
    ///
    /// Two of the zero-width characters are NOT in here, and the distinction
    /// matters: U+200C and U+200D are content. The joiner is what makes
    /// 👩‍💻 one emoji rather than two and 👨‍👩‍👧 one family rather than three, and
    /// the non-joiner is orthographically required in Persian and Urdu, where
    /// dropping it from می‌روم spells a different word. Stripping them scrambled
    /// real subjects, and because the card and the mail were scrambled the same
    /// way the user had no way to notice. The script's own
    /// set is the same list, so the card and the mail still read alike.
    /// Addresses are a separate rule: they *refuse* every one of these,
    /// joiners included, because no address needs one.
    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B, 0x200E, 0x200F, 0x061C, 0xFEFF: return true
        case 0x202A...0x202E, 0x2060...0x2069: return true
        default: return false
        }
    }

    /// Bot-supplied words are cut where they enter the sentence, not where the
    /// sentence ends. The clamp at the end cuts the app's own prose — the part
    /// that says what is about to happen — so every value that comes from the
    /// model is given its own room first, and the sentence fits by
    /// construction. The ellipsis is there so a cut reads as a cut.
    ///
    /// The limit counts Unicode scalars, not characters. A character is a grapheme
    /// cluster and has no length limit: one base letter can carry any number of
    /// combining marks, and a 600-character card carried 47,850 scalars, measured. The
    /// cut keeps whole characters while they fit, so a letter never reaches the card
    /// without its accent; only a single character too long for the whole budget is cut
    /// between its scalars, and never inside one.
    static func fragment(_ value: String, _ limit: Int) -> String {
        let line = oneLine(value)
        guard line.unicodeScalars.count > limit else { return line }
        let room = max(0, limit - 1)
        var kept = "", used = 0
        for character in line {
            let size = character.unicodeScalars.count
            guard used + size <= room else { break }
            kept.append(character)
            used += size
        }
        if kept.isEmpty {
            kept = String(String.UnicodeScalarView(line.unicodeScalars.prefix(room)))
        }
        return kept + "\u{2026}"
    }

    /// How much room a value takes against a card's budget: its scalars, the
    /// unit `fragment` cuts by.
    static func size(_ value: String) -> Int { value.unicodeScalars.count }

    /// `words` is the mail's own body block, which follows the sentence whole
    /// and is never cut: the card's box scrolls, and Approve waits until its
    /// end has been in view.
    private static func card(title: String, target: String, detail: String,
                             kind: ConsequentialActionKind, activity: String,
                             words: String? = nil) -> ClaudeTextWorkCard {
        ClaudeTextWorkCard(title: title,
                           detail: fragment(detail, 600) + (words.map { "\n\n" + $0 } ?? ""),
                           target: fragment(target, 200), kind: kind,
                           activity: fragment(activity, 200))
    }

    static let noWords = "This mail has no words in it."

    /// A new mail's labelled lines, at the top of its block and shown whole.
    /// The sentence above is bounded, so past its budget it counts recipients and names
    /// only the first of each field; a second blind copy was a number there, and the
    /// subject was cut at 120 of the script's 400. Here every address, the whole
    /// subject and the signature are written out. Nothing new is refused: the last
    /// refusal rule added to this path broke ordinary sends, so the card shows more.
    ///
    /// The addresses are split as `recipients` splits them and the subject is
    /// flattened as the script's `oneLineSubject` flattens it, so these lines
    /// read what Mail is handed. The signature line says what the script's
    /// COMPOSE does: a named one is used, and with none named the user's only
    /// signature is added, or none when the user has several.
    static func envelope(_ input: [String: Any]) -> String {
        var lines: [String] = []
        for (label, key) in [("To", "to"), ("Cc", "cc"), ("Bcc", "bcc")] {
            let value = input[key]
            guard let value, !(value is NSNull) else {
                if key == "to" { lines.append("To: no one named") }
                continue
            }
            guard let text = value as? String else {
                lines.append("\(label): an address list it sent in a form this card cannot show")
                continue
            }
            let addresses = oneLine(text).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if addresses.isEmpty {
                if key == "to" { lines.append("To: no one named") }
                continue
            }
            lines.append("\(label): " + addresses.joined(separator: ", "))
        }
        switch input["subject"] {
        case let subject as String where !oneLine(subject).isEmpty: lines.append("Subject: " + oneLine(subject))
        case nil, is NSNull, is String: lines.append("Subject: (none)")
        default: lines.append("Subject: sent in a form this card cannot show")
        }
        switch input["signature"] {
        case let name as String where !oneLine(name).isEmpty: lines.append("Signature: " + oneLine(name))
        case nil, is NSNull, is String:
            lines.append("Signature: none named. If you have one signature in Mail, it is added; "
                + "if you have several, none is.")
        default: lines.append("Signature: sent in a form this card cannot show")
        }
        return lines.joined(separator: "\n")
    }

    /// The words of the mail, as the card shows them after its sentence. A user
    /// could approve a reply that carried no words at all and have no way to
    /// see it, so the whole body is shown, in
    /// the card's scrolled box, as the browser's card shows what it hands a
    /// site — and an empty one is said in words rather than left as a gap.
    ///
    /// The body keeps its line breaks, which is why it does not go through
    /// `oneLine`, and it loses exactly the characters every other field
    /// loses (`isHidden`), because those can reorder or hide what the user reads.
    /// The script strips the same set before the body reaches Mail, so the
    /// words on the card are the words sent (`AppleMailBodyReadsAlikeTests`).
    static func words(_ input: [String: Any], replying: Bool) -> String {
        guard let value = input["body"], !(value is NSNull) else { return noWords }
        // Only a string is a shape the server will send, so anything else is
        // named as what it is. It is not "no words": it may carry some.
        guard let text = value as? String else {
            return "The words of this mail came in a form this card cannot show."
        }
        let shown = visibleBody(text)
        guard !shown.unicodeScalars.allSatisfy(\.properties.isWhitespace) else { return noWords }
        return (replying ? "What the reply says (Mail puts the original below it):"
                         : "What the mail says:") + "\n" + shown
    }

    /// A body without the characters that hide or reorder words, and nothing
    /// else changed. The script's `visibleBody` is the same rule.
    static func visibleBody(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { !isHidden($0) }))
    }

    /// `ask` is the word the script tells a bot to use when it means "the user has
    /// not chosen yet", so it is never one of the user's accounts and the card must
    /// not present it as one.
    static func namedAccount(_ account: String) -> String {
        let trimmed = account.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "ask" else {
            return "an account it did not name"
        }
        return trimmed
    }
}

/// What the record says when a bot looks someone up in the user's Contacts.
///
/// Every tool this server has is a read, and the row's own switch is the
/// boundary: granting Contacts to a bot IS the decision that it may read the user's
/// address book, so a card per lookup would be a card the user answers the same way
/// every time. Harmless reads may be allowed per session, and that is why the row exists at all — a bot that has to interrupt
/// the user for permission to find an address the user has saved is no better than a bot
/// that asks the user for the address.
///
/// The server is the app's own, so its tool list is a fact of this build rather
/// than a package's changing surface. Anything not on that list still asks,
/// which is what a future write verb would hit.
///
/// A quiet decision *is* the deed, so these lines are written in the past
/// tense — unlike a card's activity line, which is written before the user answers
/// and therefore says what was asked.
public enum ClaudeTextAppleContactsApprovalPolicy {
    /// The two the app ships, taken from `apple-contacts.js`'s own `TOOLS`.
    static let quietReads: Set<String> = ["search_contacts", "read_contact"]

    static func decide(_ request: ClaudeTextPermissionRequest, botName: String) -> ClaudeTextWorkDecision {
        let tool = ClaudeTextConnectorApprovalPolicy.toolName(in: request.toolName)
        let input = (try? JSONSerialization.jsonObject(with: request.inputJSON)) as? [String: Any] ?? [:]
        if quietReads.contains(tool) {
            // A search says what was searched for: those words are the user's own
            // address book's, and the record sheet is more use naming them
            // than saying "a lookup". Bounded where they enter the sentence,
            // like every other value that reaches the user from a model. Reading one
            // card by its id says nothing of the sort — an id is not a name,
            // and printing it would fill the sheet with something unreadable.
            let query = ClaudeTextAppleMailSendApprovalPolicy.fragment(
                (input["query"] as? String) ?? "", 100)
            let line = tool == "search_contacts" && !query.isEmpty
                ? "Looked up \u{201C}\(query)\u{201D} in your contacts"
                : "Read a card in your contacts"
            return .allowQuietly(activity: ClaudeTextAppleMailSendApprovalPolicy.fragment(line, 200))
        }
        let readable = ClaudeTextBrowserApprovalPolicy.readable(tool)
        let target = ClaudeTextBrowserApprovalPolicy.describe(input) ?? readable
        return .ask(ClaudeTextWorkCard(
            title: "Do something in your contacts",
            detail: String(("\(botName) wants to use \(readable) in your Contacts. This connector is "
                + "supposed to be able to read and nothing else, so this asks before it happens.").scalarPrefix(600)),
            target: String(target.scalarPrefix(200)), kind: .send,
            activity: String("Asked to use \(readable) in your contacts".scalarPrefix(200))))
    }
}

/// The one shape a text may take on its way onto a card and out of the user's phone
/// number.
///
/// The card is drawn here, in Swift, and the text is sent by
/// `Resources/apple-messages.js`, from the same tool input. Where two languages
/// read one input, they have drifted: the mail card and the mail sender parted
/// over how each normalised a subject.
/// So nothing is normalised on either side. Every field is a string or the
/// send is refused; the recipient is never trimmed and must be plain ASCII in
/// one of two shapes; the text is shown and sent exactly as given, or refused
/// whole — a character is never stripped, because a text with a character
/// taken out is not the text the user approved. Every literal below is mirrored in
/// the script's `sendRefusal`, and `AppleMessagesScriptTests` sweeps the
/// characters Unicode itself calls separating, controlling, formatting,
/// combining or default-ignorable through both, asserting for each that both
/// refuse or that the text osascript receives, the input and the card's text
/// are one sequence of scalars.
public struct AppleMessagesSendProposal: Equatable, Sendable {
    /// Messages.sdef's whole `service type` enumeration, spelled as it spells
    /// them. There is no "auto": the card has to name the service.
    public static let services = ["iMessage", "RCS", "SMS"]
    /// Counted in Unicode scalars on both sides. The approvals record keeps the
    /// first 2,000 characters of the card's detail, a character is never fewer
    /// than one scalar, and the detail is a heading of under two hundred
    /// scalars, a blank line, then the text — so 1,800 keeps every text whole
    /// on the record. `AppleMessagesCardTests` pins the worst case.
    public static let maximumTextScalars = 1_800
    /// RFC 5321's longest forward path.
    public static let maximumRecipientLength = 254

    public let recipient: String
    public let service: String
    public let text: String

    /// The only fields a text takes. Anything else is refused, even a field the
    /// card could ignore: Foundation drops one leading U+FEFF from every key it
    /// reads, so `{"\u{FEFF}text": A, "text": B}` is one field here and two in
    /// the server, and a field the card never read is one it cannot show.
    public static let fields = ["recipient", "service", "text"]

    public enum Refusal: Error, Equatable, Sendable {
        case unreadableInput
        case unexpectedField(String)
        case missing(field: String)
        case notAString(field: String)
        case automaticService
        case unknownService
        case recipientShape
        case emptyText
        case textTooLong(scalars: Int)
        case refusedCharacter(UInt32)
        case blankLineAtAnEnd
        case blankLinesInARow
        case endsWithWhitespace
    }

    public init(input: [String: Any]) throws {
        if let extra = input.keys.sorted().first(where: { key in
            !Self.fields.contains { $0.unicodeScalars.elementsEqual(key.unicodeScalars) }
        }) {
            throw Refusal.unexpectedField(extra)
        }
        var values: [String: String] = [:]
        for field in Self.fields {
            guard let value = input[field], !(value is NSNull) else { throw Refusal.missing(field: field) }
            guard let string = value as? String else { throw Refusal.notAString(field: field) }
            values[field] = string
        }
        let recipient = values["recipient"] ?? "", service = values["service"] ?? "",
            text = values["text"] ?? ""
        // Compared scalar for scalar: Swift's `==` treats canonically equivalent
        // strings as equal, and JavaScript's `===` does not.
        guard !service.unicodeScalars.elementsEqual("auto".unicodeScalars) else {
            throw Refusal.automaticService
        }
        guard let named = Self.services.first(where: { $0.unicodeScalars.elementsEqual(service.unicodeScalars) })
        else { throw Refusal.unknownService }
        guard Self.isAddressable(recipient) else { throw Refusal.recipientShape }
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { throw Refusal.emptyText }
        let count = scalars.count
        guard count <= Self.maximumTextScalars else { throw Refusal.textTooLong(scalars: count) }
        if let refused = Self.firstRefused(in: Array(scalars)) {
            throw Refusal.refusedCharacter(refused.value)
        }
        if let shape = Self.lineShapeRefusal(Array(scalars)) { throw shape }
        // A space at the very end is one the user cannot see on the card, and the
        // approvals record, which trims both ends of a detail, would keep the
        // text without it.
        if let last = scalars.last, Self.isWhitespace(last.value) { throw Refusal.endsWithWhitespace }
        self.recipient = recipient
        self.service = named
        self.text = text
    }

    /// A handle exactly as check_message_service prints one: `^\+?[0-9]{3,15}$`,
    /// or an ASCII address `^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]{1,63}(\.[A-Za-z0-9-]{1,63})+$`
    /// of at most 254 characters. Written as a scan rather than a regular
    /// expression on purpose: ICU's `$` also matches before a final line break,
    /// JavaScript's does not, and that is exactly the kind of difference this
    /// type exists to leave nowhere to live.
    static func isAddressable(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard !scalars.isEmpty, scalars.count <= maximumRecipientLength,
              scalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else { return false }
        return isPhoneNumber(scalars) || isEmailAddress(scalars)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { (0x30...0x39).contains(scalar.value) }
    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        isDigit(scalar) || (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    private static func isPhoneNumber(_ scalars: [Unicode.Scalar]) -> Bool {
        let digits = scalars.first == "+" ? scalars.dropFirst() : scalars[...]
        return (3...15).contains(digits.count) && digits.allSatisfy(isDigit)
    }

    private static func isEmailAddress(_ scalars: [Unicode.Scalar]) -> Bool {
        guard let at = scalars.firstIndex(of: "@"), scalars.lastIndex(of: "@") == at else { return false }
        let local = scalars[..<at]
        let domain = scalars[scalars.index(after: at)...]
        guard (1...64).contains(local.count),
              local.allSatisfy({ isLetterOrDigit($0) || "._%+-".unicodeScalars.contains($0) })
        else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            (1...63).contains(label.count) && label.allSatisfy { isLetterOrDigit($0) || $0 == "-" }
        }
    }

    /// The first character a text may not carry where it stands, or nil.
    ///
    /// Refused anywhere: controls other than tab and newline (carriage return
    /// included), DEL and the C1 controls (next line included), the line and
    /// paragraph separators, the interlinear annotation marks, and every
    /// character Unicode calls default-ignorable — the ones a renderer draws
    /// as nothing. Borrowing the mail card's hidden set, twenty characters,
    /// would let 4,154 default-ignorable ones pass both sides: tag characters after
    /// "OK" could spell a code the card draws as "OK". Messages keeps its own list
    /// rather than widening the mail card's, because that list is for STRIPPING a
    /// subject, where taking out a presentation selector or a joiner would change every
    /// emoji in it, and because the exceptions below depend on neighbours, which a test
    /// of one character at a time cannot see.
    ///
    /// Four are content, and only in their place:
    /// U+200C between letters of the scripts that spell words with it; U+200D
    /// between two emoji, looking past one presentation selector and one skin
    /// tone so ❤️‍🔥, 🏳️‍🌈 and 🧑🏽‍🤝‍🧑🏻 pass, or after a virama; U+FE0F only where it
    /// turns a text-drawn character into its emoji (❤️, 🏳️, and a keycap's digit,
    /// # or *), U+FE0E only where it turns an emoji into its text drawing. Beside
    /// anything else they draw nothing and can carry a code. Tag characters are
    /// content only inside the three flags Unicode spells with them: England,
    /// Scotland and Wales.
    ///
    /// Every literal is mirrored in `firstRefusedIndex` in apple-messages.js. The
    /// wire sweep holds the two sides together over the format characters and the
    /// default-ignorables; what a selector or a joiner may lean on is each side's
    /// own Unicode tables, checked against each other by
    /// `theTwoSidesReadTheSameEmoji`.
    static func firstRefused(in scalars: [Unicode.Scalar]) -> Unicode.Scalar? {
        let values = scalars.map(\.value)
        var flagTags = Set<Int>()
        for start in values.indices where values[start] == 0x1F3F4 {
            for tags in subdivisionFlagTags where start + tags.count < values.count
                && values[(start + 1)...(start + tags.count)].elementsEqual(tags) {
                flagTags.formUnion((start + 1)...(start + tags.count))
            }
        }
        for (index, value) in values.enumerated() where isRefusedAlone(value) {
            switch value {
            case 0x200C:
                // Persian, Urdu, Syriac, Mongolian and the Brahmic scripts spell
                // words with it. Between Latin letters it draws nothing, and a
                // six-digit code can hide in "See you at 8" that way, in a card
                // whose pixels are the plain sentence's.
                if index > 0, index + 1 < values.count,
                   joinsWords(values[index - 1]), joinsWords(values[index + 1]) { continue }
            case 0x200D:
                // One emoji of several, and the consonant clusters a virama joins.
                var before = index - 1
                if before >= 0, values[before] == 0xFE0E || values[before] == 0xFE0F { before -= 1 }
                if before >= 0, isVirama(values[before]) { continue }
                if before >= 0, values[before] >= 0x1F3FB, values[before] <= 0x1F3FF { before -= 1 }
                if before >= 0, index + 1 < values.count,
                   takesSelector(values[before]), takesSelector(values[index + 1]) { continue }
            case 0xFE0F:
                // Only where it changes the drawing: on a character Unicode draws
                // as text unless asked (❤️, 🏳️), or on a keycap's digit, # or *.
                // After a character already drawn as emoji it draws nothing, and
                // ten of those can carry a code.
                if index > 0, takesSelector(values[index - 1]), !drawnAsEmoji(values[index - 1]) { continue }
                if index > 0, isKeycapBase(values[index - 1]),
                   index + 1 < values.count, values[index + 1] == 0x20E3 { continue }
            case 0xFE0E:
                // The other way: only on a character Unicode draws as emoji.
                if index > 0, drawnAsEmoji(values[index - 1]) { continue }
            case 0xE0020...0xE007F:
                if flagTags.contains(index) { continue }
            default:
                break
            }
            return scalars[index]
        }
        return nil
    }

    /// The tags after U+1F3F4 in the three subdivision flags Unicode
    /// recommends, cancel tag included: gbeng, gbsct, gbwls.
    static let subdivisionFlagTags: [[UInt32]] = [
        [0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F],
        [0xE0067, 0xE0062, 0xE0073, 0xE0063, 0xE0074, 0xE007F],
        [0xE0067, 0xE0062, 0xE0077, 0xE006C, 0xE0073, 0xE007F],
    ]

    /// Unicode 16's Default_Ignorable_Code_Point, written out rather than read
    /// from `isDefaultIgnorableCodePoint`: Swift's tables and Node's ICU carry
    /// different Unicode versions, and a property that means two things on the
    /// two sides of a card is exactly the drift this type exists to prevent.
    static let defaultIgnorableRanges: [ClosedRange<UInt32>] = [
        0x00AD...0x00AD, 0x034F...0x034F, 0x061C...0x061C, 0x115F...0x1160, 0x17B4...0x17B5,
        0x180B...0x180F, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F, 0x3164...0x3164,
        0xFE00...0xFE0F, 0xFEFF...0xFEFF, 0xFFA0...0xFFA0, 0xFFF0...0xFFF8, 0x1BCA0...0x1BCA3,
        0x1D173...0x1D17A, 0xE0000...0xE0FFF,
    ]

    /// Refused wherever it stands, before the four exceptions are considered.
    static func isRefusedAlone(_ value: UInt32) -> Bool {
        switch value {
        case 0x09, 0x0A: return false
        // U+FFFC stands in for an attachment and U+2800 is an empty braille cell:
        // both take up space and draw nothing.
        case 0x00..<0x20, 0x7F...0x9F, 0x2028, 0x2029, 0x2800, 0xFFF9...0xFFFB, 0xFFFC: return true
        default: return defaultIgnorableRanges.contains { $0.contains(value) }
        }
    }

    /// Unicode's White_Space property, written out for the same reason.
    static func isWhitespace(_ value: UInt32) -> Bool {
        switch value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// A character a presentation selector or an emoji joiner may lean on: what
    /// Unicode calls an emoji, less the digits, # and *, which are emoji only as
    /// the base of a keycap. Each side reads its own Unicode tables here rather
    /// than a written-out one: they are held together by the wire sweep, and a
    /// difference between them refuses a text, never sends a different one.
    static func takesSelector(_ value: UInt32) -> Bool {
        guard !isKeycapBase(value), let scalar = Unicode.Scalar(value) else { return false }
        return scalar.properties.isEmoji
    }

    /// A character Unicode draws as an emoji unless it is asked for text.
    static func drawnAsEmoji(_ value: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(value) else { return false }
        return scalar.properties.isEmojiPresentation
    }

    /// The three characters a keycap is built on: 0-9, # and *.
    static func isKeycapBase(_ value: UInt32) -> Bool {
        value == 0x23 || value == 0x2A || (0x30...0x39).contains(value)
    }

    /// The letters of the scripts that spell words with a zero-width non-joiner:
    /// the Arabic family, Syriac, Thaana, N'Ko, Mongolian, Adlam and the Brahmic
    /// scripts. Mirrored in `JOINS_WORDS` in apple-messages.js.
    static let joiningScriptRanges: [ClosedRange<UInt32>] = [
        0x0600...0x06FF, 0x0700...0x074F, 0x0750...0x077F, 0x0780...0x07BF, 0x07C0...0x07FF,
        0x0840...0x085F, 0x0860...0x086F, 0x0870...0x089F, 0x08A0...0x08FF, 0x0900...0x0DFF,
        0x0F00...0x0FFF, 0x1000...0x109F, 0x1780...0x17FF, 0x1800...0x18AF, 0x1B00...0x1B7F,
        0xA800...0xA82F, 0xA980...0xA9DF, 0xFB50...0xFDFF, 0xFE70...0xFEFF,
        0x10AC0...0x10AFF, 0x10D00...0x10D3F, 0x10F30...0x10F6F, 0x11000...0x110CF,
        0x11100...0x1114F, 0x11180...0x111DF, 0x1E900...0x1E95F,
    ]

    static func joinsWords(_ value: UInt32) -> Bool {
        joiningScriptRanges.contains { $0.contains(value) }
    }

    /// The viramas that join consonants, where a joiner after one is spelling,
    /// not hiding. Mirrored in `VIRAMAS` in apple-messages.js.
    static let viramas: Set<UInt32> = [
        0x094D, 0x09CD, 0x0A4D, 0x0ACD, 0x0B4D, 0x0BCD, 0x0C4D, 0x0CCD, 0x0D4D, 0x0DCA,
        0x0E3A, 0x0F84, 0x1039, 0x17D2, 0x1B44, 0xA806, 0xA8C4, 0xA953, 0xABED, 0x11046,
    ]

    static func isVirama(_ value: UInt32) -> Bool { viramas.contains(value) }

    /// The text's lines as the card lays them out. The first and the last must
    /// hold something other than whitespace, and no two blank lines may follow
    /// each other: the card's box shows about six lines before it scrolls and
    /// a trackpad hides the scroller, so "Sure, see you then", forty line
    /// breaks and a second paragraph read as the first line alone. One blank line
    /// between paragraphs passes. Mirrored in `lineShapeRefusal` in apple-messages.js.
    static func lineShapeRefusal(_ scalars: [Unicode.Scalar]) -> Refusal? {
        var blankLines: [Bool] = []
        var blank = true
        for scalar in scalars {
            if scalar.value == 0x0A {
                blankLines.append(blank)
                blank = true
            } else if !isWhitespace(scalar.value) {
                blank = false
            }
        }
        blankLines.append(blank)
        if blankLines.first == true || blankLines.last == true { return .blankLineAtAnEnd }
        for index in blankLines.indices.dropFirst() where blankLines[index] && blankLines[index - 1] {
            return .blankLinesInARow
        }
        return nil
    }

    /// Lines as the card lays them out before any wrapping: one more than the
    /// line breaks.
    static func lineCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(1) { $1.value == 0x0A ? $0 + 1 : $0 }
    }
}

extension AppleMessagesSendProposal.Refusal {
    /// The sentence the model is shown when a rule refuses the send.
    var sentence: String {
        let tail = " Nothing was sent."
        switch self {
        case .unreadableInput:
            return "The text's details could not be read, so they cannot be shown on a card." + tail
        case .unexpectedField(let field):
            // Named printable-ASCII only, bounded: the name came from a model.
            let shown = field.unicodeScalars.prefix(40).map { scalar in
                (0x21...0x7E).contains(scalar.value) ? String(scalar) : String(format: "U+%04X", scalar.value)
            }.joined()
            return "`\(shown)` is not a field of a text: a text takes only recipient, service and text, and "
                + "a card cannot show anything else." + tail
        case .missing(let field):
            return "`\(field)` is required: a card cannot show a value that is not there." + tail
        case .notAString(let field):
            return "`\(field)` must be a string, and it arrived as something else, so it cannot be shown "
                + "on a card exactly." + tail
        case .automaticService:
            return "`service` cannot be \"auto\": he approves the service on the card, so call "
                + "check_message_service first and pass the service it names — iMessage, RCS or SMS." + tail
        case .unknownService:
            return "`service` must be exactly iMessage, RCS or SMS, as check_message_service names it." + tail
        case .recipientShape:
            return "`recipient` must be exactly the handle check_message_service returned: digits with an "
                + "optional leading +, or a plain email address, with no spaces, punctuation or letters "
                + "from other alphabets. Never a person's name." + tail
        case .emptyText:
            return "`text` is empty, so there is nothing to send." + tail
        case .textTooLong(let scalars):
            return "`text` is \(scalars) characters long and the limit is "
                + "\(AppleMessagesSendProposal.maximumTextScalars), so it cannot be shown to him whole. "
                + "Split it into shorter texts." + tail
        case .refusedCharacter(let value):
            return "`text` carries \(String(format: "U+%04X", value)), which the card cannot show as it "
                + "would be sent. Send it again without that character; a line break is fine as a plain "
                + "newline." + tail
        case .blankLineAtAnEnd:
            return "`text` begins or ends with a blank line, which the card shows as empty space. Send it "
                + "again without the blank line at the start or the end." + tail
        case .blankLinesInARow:
            return "`text` has two blank lines in a row, which can push words below what the card shows "
                + "at first. Use at most one blank line between paragraphs." + tail
        case .endsWithWhitespace:
            return "`text` ends with a space, which the card cannot show and its record would drop. Send it "
                + "again without the space at the end." + tail
        }
    }
}

/// What the card says when a bot wants to text someone as the user, and what the
/// record says when it reads the user's conversations.
///
/// The two reads are quiet: the row's own switch is the boundary, reading the user's
/// own messages is what the row is for, and checking which service reaches a
/// person sends nothing and is what every send needs first. The send is never
/// quiet. Its card names the recipient and the service and shows the exact
/// words with their line breaks — deliberately NOT through the mail card's
/// one-line fragments, which flatten a text and cut it at 600 characters. A
/// proposal the card could not show exactly is refused by rule, with a
/// "Blocked" line on the record, and never becomes a card at all.
public enum ClaudeTextAppleMessagesApprovalPolicy {
    /// The record's line for each read, with the person it names and without.
    /// The reads are exactly its keys, and `decide` finds a read here and
    /// nowhere else, so the set a test holds to the server's list is the set
    /// that decides (`decide` once switched on literals of its own).
    static let quietReadActivities: [String: (named: String, unnamed: String)] = [
        // A read covers only the chats the user chose for the bot, and the line
        // says so.
        "read_messages": (named: "Read your messages with ", unnamed: "Read your latest messages in the chats you chose"),
        "check_message_service": (named: "Checked which service reaches ",
                                  unnamed: "Checked which service reaches someone"),
    ]
    /// Taken from `apple-messages.js`'s own `TOOLS`; a test holds the two lists
    /// together.
    static var quietReads: Set<String> { Set(quietReadActivities.keys) }
    static let sendTool = "send_message"

    static let cardTitle = "Send a text as you"
    /// The first line of every send card, and the only words on it the bot did
    /// not supply.
    static let consequence = "It goes out from your own number and cannot be taken back."
    /// The service on the card is what the send asks Messages for, not a
    /// promise, and every card says so. Into a conversation Messages already
    /// keeps, `send … to chat id` takes no service and Messages picks one
    /// itself; and the disabled RCS account cannot carry a first message, so
    /// an RCS text with no conversation goes through the SMS relay. The script
    /// reports a downgrade when it happens.
    static let serviceCaveat = "Messages may still send it on another service."
    static let rcsCaveat = "Messages may still send it as SMS."
    static let headingSeparator = "\n\n"

    /// Why a send was refused when the turn's secret scrub would have changed
    /// its card: the card would have shown `•••` while the text carried the
    /// secret itself.
    static let secretRefusal = "This text carries something the user gave as a secret earlier in this turn, "
        + "so the card could not show it exactly as it would be sent. Nothing was sent. Never put a secret "
        + "he gave you into a text."
    static let secretActivity = "Blocked a text that carried a secret you gave"
    static let refusalActivity = "Blocked a text whose details could not be shown exactly"

    /// Whether a text would send a secret the user gave this turn: in its words or as
    /// the number or address it goes to. Whole secrets only, of four characters
    /// or more as the blanking counts them, found either as characters (so a
    /// canonically equal spelling counts) or as scalars (so one with a mark
    /// added to its last letter counts). An input that cannot be read as a
    /// text counts too: it cannot be shown, so it is not sent.
    static func sendCarriesASecret(_ inputJSON: Data, secrets: [String]) -> Bool {
        guard let input = (try? JSONSerialization.jsonObject(with: inputJSON)) as? [String: Any],
              let proposal = try? AppleMessagesSendProposal(input: input) else { return true }
        return secrets.filter { $0.count >= 4 }.contains { secret in
            [proposal.text, proposal.recipient].contains { field in
                field.contains(secret) || containsScalars(field, secret)
            }
        }
    }

    static func containsScalars(_ field: String, _ secret: String) -> Bool {
        let haystack = Array(field.unicodeScalars), needle = Array(secret.unicodeScalars)
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { start in
            haystack[start..<(start + needle.count)].elementsEqual(needle)
        }
    }

    /// The most lines a text can have and go without a count. The card's box
    /// (`TextReplyApprovalCard` in OpenBotsRootView.swift) is 140 points of
    /// monospaced callout type, nine lines, and it holds the heading too: in
    /// the narrowest composer, a 280-point box, the heading wraps to three
    /// lines and its blank line takes a fourth, which leaves five for the
    /// text. One is kept in hand. `ApprovalCardReadingTests` renders the card
    /// to hold this number to the box.
    static let mostLinesWithoutACount = 4

    /// Everything on the card above the text itself. A text with more lines
    /// than fit whole under the heading says how many, in the app's words
    /// rather than the bot's. The longest heading any accepted input builds
    /// stays inside the room the record leaves beside a text of the maximum
    /// length; `AppleMessagesCardTests.theWorstCaseCardFitsTheRecord` pins it.
    static func detailHeading(service: String, text: String) -> String {
        var heading = consequence + " " + (service == "RCS" ? rcsCaveat : serviceCaveat)
        let lines = AppleMessagesSendProposal.lineCount(text)
        if lines > mostLinesWithoutACount { heading += " The text is \(lines) lines long." }
        return heading
    }

    static func card(for proposal: AppleMessagesSendProposal) -> ClaudeTextWorkCard {
        // Nothing here is clamped, and nothing needs to be: the proposal has
        // already bounded every value, and a cut would put words on the card
        // that are not the words sent.
        ClaudeTextWorkCard(
            title: cardTitle,
            detail: detailHeading(service: proposal.service, text: proposal.text) + headingSeparator + proposal.text,
            target: "\(proposal.recipient) on \(proposal.service)",
            kind: .send,
            activity: "Asked to text \(proposal.recipient)")
    }

    static func decide(_ request: ClaudeTextPermissionRequest, botName: String) -> ClaudeTextWorkDecision {
        let tool = ClaudeTextConnectorApprovalPolicy.toolName(in: request.toolName)
        let input = (try? JSONSerialization.jsonObject(with: request.inputJSON)) as? [String: Any]
        // The person a read names arrives from a model, so it is bounded where
        // it enters the record line, like every other such value.
        let named = (input?["recipient"] as? String).map {
            ClaudeTextAppleMailSendApprovalPolicy.fragment($0, 80)
        } ?? ""
        if let lines = quietReadActivities[tool] {
            return .allowQuietly(activity: named.isEmpty ? lines.unnamed : lines.named + named)
        }
        switch tool {
        case sendTool:
            do {
                guard let input else { throw AppleMessagesSendProposal.Refusal.unreadableInput }
                return .ask(card(for: try AppleMessagesSendProposal(input: input)))
            } catch let refusal as AppleMessagesSendProposal.Refusal {
                return .denyQuietly(reason: refusal.sentence, activity: refusalActivity)
            } catch {
                return .denyQuietly(reason: AppleMessagesSendProposal.Refusal.unreadableInput.sentence,
                                    activity: refusalActivity)
            }
        default:
            // Including whatever a later version of the server may add.
            let readable = ClaudeTextBrowserApprovalPolicy.readable(tool)
            return .ask(ClaudeTextWorkCard(
                title: "Do something in Messages",
                detail: String(("\(botName) wants to use \(readable) in your Messages. This version does "
                    + "not know what that does, so it asks.").scalarPrefix(600)),
                target: String(readable.scalarPrefix(200)), kind: .send,
                activity: String("Asked to use \(readable) in Messages".scalarPrefix(200))))
        }
    }
}

/// What the card says when a bot wants to read the user's calendar.
///
/// Reading the user's own calendar is what the row is FOR, and the row's own switch is
/// the boundary, so the three reads are harmless reads, allowed per session.
/// A card per lookup would be a card the user answers the same
/// way every time — and a bot that has to interrupt the user for permission to see
/// whether the user is free is no better than one that asks whether they are free.
///
/// The server is the app's own, so its tool list is a fact of this build rather
/// than a package's changing surface. Anything not on that list still asks,
/// which is what a future write verb would hit.
///
/// A quiet decision *is* the deed, so these lines are written in the past
/// tense — unlike a card's activity line, which is written before the user answers
/// and therefore says what was asked.
public enum ClaudeTextAppleCalendarApprovalPolicy {
    /// The three the app ships, taken from `apple-calendar.js`'s own `TOOLS`.
    static let quietReads: Set<String> = ["list_calendars", "search_events", "read_event"]

    static func decide(_ request: ClaudeTextPermissionRequest, botName: String) -> ClaudeTextWorkDecision {
        let tool = ClaudeTextConnectorApprovalPolicy.toolName(in: request.toolName)
        let input = (try? JSONSerialization.jsonObject(with: request.inputJSON)) as? [String: Any] ?? [:]
        if quietReads.contains(tool) {
            // The record sheet says WHICH days were read, because "read your
            // calendar" is the one thing every one of these lines would say and
            // a sheet of identical lines tells the user nothing. The dates are the user's
            // own calendar's, but they arrive here from a model, so they are
            // bounded where they enter the sentence like every other such value.
            let line: String
            switch tool {
            case "list_calendars":
                line = "Listed your calendars"
            case "search_events":
                let from = ClaudeTextAppleMailSendApprovalPolicy.fragment(
                    (input["from"] as? String) ?? "", 40)
                let to = ClaudeTextAppleMailSendApprovalPolicy.fragment(
                    (input["to"] as? String) ?? "", 40)
                if !from.isEmpty && !to.isEmpty {
                    line = "Read your calendar from \(from) to \(to)"
                } else if !from.isEmpty {
                    line = "Read your calendar from \(from)"
                } else {
                    line = "Read the week ahead in your calendar"
                }
            default:
                line = "Read one event in your calendar"
            }
            return .allowQuietly(activity: ClaudeTextAppleMailSendApprovalPolicy.fragment(line, 200))
        }
        let readable = ClaudeTextBrowserApprovalPolicy.readable(tool)
        let target = ClaudeTextBrowserApprovalPolicy.describe(input) ?? readable
        return .ask(ClaudeTextWorkCard(
            title: "Do something in your calendar",
            detail: String(("\(botName) wants to use \(readable) in your Calendar. This connector is "
                + "supposed to be able to read and nothing else, so this asks before it happens.").scalarPrefix(600)),
            target: String(target.scalarPrefix(200)), kind: .send,
            activity: String("Asked to use \(readable) in your calendar".scalarPrefix(200))))
    }
}

/// What the card says when a bot with Apple Mail wants to do something.
///
/// The reader is launched with `--read-only`, so the fourteen mutating tools do
/// not exist to be called. Reading the user's own mailbox is what the row is *for* and
/// the row's own switch is the boundary, so those reads are harmless reads,
/// allowed per session. Anything else on that namespace
/// asks, including whatever a later version of the package adds.
///
/// Driven against the installed pieces, the server
/// registers **ten** tools under `--read-only`, not the nine its own log line
/// claims: the tenth is `render_template`, which substitutes into a template
/// rather than reading the mailbox. It is deliberately not quiet — it is not a
/// read of the user's mail, so it asks like anything else.
public enum ClaudeTextAppleMailApprovalPolicy {
    /// The nine that read the user's mailbox, taken from version 0.10.2's own source
    /// and confirmed against the installed server's `tools/list`.
    static let quietReads: Set<String> = [
        "list_accounts", "list_rules", "list_mailboxes", "search_messages", "get_messages",
        "get_thread", "get_attachment_content", "list_templates", "get_template",
    ]

    static func decide(_ request: ClaudeTextPermissionRequest, botName: String) -> ClaudeTextWorkDecision {
        let tool = ClaudeTextConnectorApprovalPolicy.toolName(in: request.toolName)
        let input = (try? JSONSerialization.jsonObject(with: request.inputJSON)) as? [String: Any] ?? [:]
        if quietReads.contains(tool) {
            return .allowQuietly(activity: "Read \(botName)'s view of your mail")
        }
        let readable = ClaudeTextBrowserApprovalPolicy.readable(tool)
        let target = ClaudeTextBrowserApprovalPolicy.describe(input) ?? readable
        return .ask(ClaudeTextWorkCard(
            title: "Do something in your mail",
            detail: String(("\(botName) wants to use \(readable) in your Mail. The read-only reader is not "
                + "supposed to be able to change anything, so this asks before it happens.").scalarPrefix(600)),
            target: String(target.scalarPrefix(200)), kind: .send,
            activity: String("Asked to use \(readable) in your mail".scalarPrefix(200))))
    }
}

/// What the approval card says when a bot with a browser wants to do something.
///
/// Without this, a browser call would fall to the work policy's `default` and
/// the card would read `Use mcp__openbots_9f3a2b…__click` with the raw input
/// JSON underneath — accurate, and useless to decide from. The card has to say
/// what will happen in the words a person would use.
///
/// The direction of the default matters more than any single case: a tool this
/// version has never heard of asks, and says so plainly. A later server can add
/// tools; it cannot add a quiet one.
public enum ClaudeTextBrowserApprovalPolicy {
    /// Reading what is already on the screen. These reach nothing new — no
    /// network, no page change, no file — so they are harmless reads, allowed
    /// per session. Everything that opens a
    /// page, changes one, or touches the Mac asks every time.
    static let quietReads: Set<String> = [
        "take_snapshot", "take_screenshot", "list_pages", "select_page", "get_tab_id",
        "list_network_requests", "get_network_request", "get_console_message", "wait_for",
    ]

    /// `afterPrivateRead`: the bot read something private of the user's earlier
    /// in this reply. Then whatever a call hands the site (an address, typed words, a
    /// key, a pop-up's answer, a file's path) is shown whole on the card, or
    /// the call is refused; code run in the page and tools this version does
    /// not know are refused.
    static func decide(_ request: ClaudeTextPermissionRequest, botName: String,
                       afterPrivateRead: Bool = false) -> ClaudeTextWorkDecision {
        let tool = ClaudeTextConnectorApprovalPolicy.toolName(in: request.toolName)
        let input = (try? JSONSerialization.jsonObject(with: request.inputJSON)) as? [String: Any] ?? [:]
        // Bounded here, so a long path in the card's own sentence cannot take
        // the room the address after it needs.
        let page = Self.page(in: input).map { ClaudeTextAppleMailSendApprovalPolicy.fragment($0, 200) }

        if quietReads.contains(tool) {
            return .allowQuietly(activity: "Looked at \(page ?? "the page") in \(botName)'s browser")
        }
        if tool == "navigate_page" || tool == "new_page", let refusal = Self.addressRefusal(input) {
            return .denyQuietly(reason: refusal.reason, activity: refusal.activity)
        }
        let leaving = Self.outgoing(tool, input)
        if afterPrivateRead {
            if let refusal = Self.privateReadRefusal(tool, leaving) {
                return .denyQuietly(reason: refusal, activity: Self.privateReadActivity)
            }
        }
        // What leaves, on the card: whole after a private read (checked just
        // above to fit), cut with a visible "…" otherwise.
        let shown = Self.shownOutgoing(tool, leaving, whole: afterPrivateRead)
        func card(title: String, target: String, detail: String, kind: ConsequentialActionKind,
                  activity: String) -> ClaudeTextWorkCard {
            // The card's own words carry model text (an element's name), so
            // they are bounded on their own; what leaves follows, whole.
            let lead = ClaudeTextAppleMailSendApprovalPolicy.fragment(detail, 600)
            return Self.card(title: title, target: target, detail: lead + shown, kind: kind, activity: activity,
                             whole: afterPrivateRead)
        }

        switch tool {
        case "navigate_page", "new_page":
            return .ask(card(title: "Open a web page", target: page ?? "a web page",
                detail: "\(botName) wants to open \(page ?? "a web page") in its own browser window.",
                kind: .metadataMutation, activity: "Asked to open \(page ?? "a page")"))
        case "click", "click_at", "hover", "drag", "press_key":
            return .ask(card(title: "Click on the page", target: describe(input) ?? "the page",
                detail: "\(botName) wants to \(tool == "hover" ? "hover over" : "click") "
                    + "\(describe(input) ?? "something on the page"). This can submit a form or "
                    + "start something on the site.",
                kind: .send, activity: "Asked to click on the page"))
        case "fill", "fill_form", "type_text":
            return .ask(card(title: "Type into the page", target: describe(input) ?? "a form",
                detail: "\(botName) wants to type into \(describe(input) ?? "a form on the page"). "
                    + "Check what it is about to enter before you allow it.",
                kind: .send, activity: "Asked to type into the page"))
        case "upload_file":
            return .ask(card(title: "Upload a file to the site", target: (input["filePath"] as? String) ?? "a file",
                detail: "\(botName) wants to hand a file to the website. "
                    + "It leaves the Mac if you allow this.",
                kind: .publish, activity: "Asked to hand a file to the site"))
        case "evaluate_script":
            return .ask(card(title: "Run code inside the page", target: page ?? "the page",
                detail: "\(botName) wants to run its own code inside \(page ?? "the page"). "
                    + "That can do anything the site itself could do.",
                kind: .productionChange, activity: "Asked to run code in the page"))
        case "handle_dialog":
            return .ask(card(title: "Answer a pop-up on the page", target: describe(input) ?? "a pop-up",
                detail: "\(botName) wants to answer a pop-up the site opened.",
                kind: .send, activity: "Asked to answer a pop-up"))
        case "install_extension", "uninstall_extension", "reload_extension", "trigger_extension_action",
             "install_pwa", "uninstall_pwa", "launch_pwa":
            return .ask(card(title: "Change what the browser has installed", target: describe(input) ?? tool,
                detail: "\(botName) wants to change the browser's own installed pieces. "
                    + "This outlasts the conversation.",
                kind: .packageInstall, activity: "Asked to change the browser's installed pieces"))
        case "close_page", "resize_page", "emulate":
            return .ask(card(title: "Change the browser window", target: page ?? "the browser",
                detail: "\(botName) wants to change its browser window.",
                kind: .metadataMutation, activity: "Asked to change the browser window"))
        default:
            // Including everything a later version of the server may add.
            return .ask(card(title: "Use the browser", target: readable(tool),
                detail: "\(botName) wants to use \(readable(tool)) in its browser. "
                    + "This version does not know what that does, so it asks.",
                kind: .metadataMutation, activity: "Asked to use \(readable(tool)) in the browser"))
        }
    }

    // MARK: - Saying it plainly

    private static func card(title: String, target: String, detail: String,
                             kind: ConsequentialActionKind, activity: String, whole: Bool) -> ClaudeTextWorkCard {
        // A cut shows its "…", so a card never looks whole when it is not.
        ClaudeTextWorkCard(title: title,
                           detail: whole ? detail : ClaudeTextAppleMailSendApprovalPolicy.fragment(detail, 600),
                           target: ClaudeTextAppleMailSendApprovalPolicy.fragment(target, 200), kind: kind,
                           activity: ClaudeTextAppleMailSendApprovalPolicy.fragment(activity, 200))
    }

    static let privateReadActivity = "Blocked a browser step that could not show what it hands the site"
    static let notAWebAddressActivity = "Blocked opening an address that is not a web page"
    static let initScriptActivity = "Blocked opening a page with the bot's own code in it"

    /// Why an address may not be opened, or nil. The bot's browser opens what
    /// Chrome's `open_url` opens: an http or https address that names a site.
    /// A `javascript:` or `data:` address runs or draws what it carries, a
    /// `file:` address reads the Mac, and none of them has a site the card can
    /// name, so they are refused rather than described. Back,
    /// forward and reload name no address and are not affected.
    static func addressRefusal(_ input: [String: Any]) -> (reason: String, activity: String)? {
        // navigate_page's `initScript` is code the server runs in every page
        // it opens (chrome-devtools-mcp's evaluateOnNewDocument). The card
        // shows the address and not the code, and after a private read code
        // in the page is refused, so it is refused here in every case; code
        // in the page goes through evaluate_script and its own card.
        if let script = input["initScript"], !(script is NSNull), (script as? String)?.isEmpty != true {
            return ("Opening a page with initScript runs your own code in it, which the card cannot show. "
                + "Open the page without initScript; to run code in a page, use evaluate_script, which asks "
                + "on its own card. Nothing was opened.", initScriptActivity)
        }
        guard let value = input["url"], !(value is NSNull) else { return nil }
        let refusal = "Your browser opens only web addresses that start with http:// or https:// and "
            + "name a site, such as https://example.com. Nothing was opened."
        guard let address = value as? String, let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              address.lowercased().hasPrefix(scheme + "://"),
              let host = components.host, !host.isEmpty else { return (refusal, notAWebAddressActivity) }
        return nil
    }

    /// The most a card shows whole of what a call hands the site, after a
    /// private read: with the card's own words it stays inside the approvals
    /// record's 2,000 characters.
    static let maximumWholeScalars = 1_200

    /// What a call hands the site, in the order the card shows it.
    static func outgoing(_ tool: String, _ input: [String: Any]) -> [(label: String, value: String)] {
        var leaving: [(String, String)] = []
        switch tool {
        case "navigate_page", "new_page":
            if let url = input["url"] as? String { leaving.append(("the address", url)) }
        case "fill", "type_text", "fill_form":
            for key in ["value", "text"] { if let value = input[key] as? String { leaving.append(("it would type", value)) } }
            if let elements = input["elements"] as? [[String: Any]] {
                leaving += elements.compactMap { ($0["value"] as? String).map { ("it would type", $0) } }
            }
        case "press_key":
            if let key = input["key"] as? String { leaving.append(("the key", key)) }
        case "handle_dialog":
            if let text = input["promptText"] as? String { leaving.append(("its answer", text)) }
        case "upload_file":
            if let path = input["filePath"] as? String { leaving.append(("the file", path)) }
        default:
            break
        }
        return leaving
    }

    /// Why a call may not go ahead after a private read, or nil.
    static func privateReadRefusal(_ tool: String, _ leaving: [(label: String, value: String)]) -> String? {
        let why = "This reply read something private of his (his texts, Chrome, Mail, contacts, calendars, notes, Gmail or Drive), so a step in your browser goes ahead only when its card "
            + "can show him everything it hands the site."
        switch tool {
        case "evaluate_script":
            return why + " Code run inside a page can send anything, and a card cannot show that. Nothing was run."
        case "navigate_page", "new_page", "click", "click_at", "hover", "drag", "press_key", "fill", "fill_form",
             "type_text", "upload_file", "handle_dialog", "install_extension", "uninstall_extension",
             "reload_extension", "trigger_extension_action", "install_pwa", "uninstall_pwa", "launch_pwa",
             "close_page", "resize_page", "emulate":
            break
        default:
            return why + " This version does not know what \(readable(tool)) hands the site. Nothing was done."
        }
        let total = leaving.reduce(0) { $0 + $1.value.unicodeScalars.count }
        let shownAsWritten = leaving.allSatisfy {
            ClaudeTextAppleMailSendApprovalPolicy.oneLine($0.value) == $0.value && !$0.value.isEmpty
        }
        guard total <= maximumWholeScalars, shownAsWritten else {
            return why + " What this one hands the site is longer than \(maximumWholeScalars) characters, or "
                + "carries line breaks, doubled spaces or hidden characters, which a card cannot show as sent. "
                + "Nothing was done."
        }
        return nil
    }

    /// What leaves, as the card's closing words.
    static func shownOutgoing(_ tool: String, _ leaving: [(label: String, value: String)], whole: Bool) -> String {
        guard !leaving.isEmpty else { return "" }
        // An address shows with its query before a private read too: the
        // query is what the site receives, and the card once kept only the
        // site and path. A long one is cut with its "…".
        let parts = leaving.map { item in
            "\(item.label): “\(whole ? item.value : ClaudeTextAppleMailSendApprovalPolicy.fragment(item.value, 200))”"
        }
        return " " + parts.joined(separator: "; ").prefix(1).uppercased() + parts.joined(separator: "; ").dropFirst() + "."
    }

    /// The page a call names, as a person reads it: the site, not the query
    /// string. Page content is untrusted, so this is only ever shown, never
    /// treated as authority for anything.
    static func page(in input: [String: Any]) -> String? {
        for key in ["url", "pageUrl", "href"] {
            guard let raw = input[key] as? String, let url = URL(string: raw), let host = url.host else { continue }
            let path = url.path
            return path.isEmpty || path == "/" ? host : host + path
        }
        return nil
    }

    /// What a call points at, in whatever words the call itself offered.
    static func describe(_ input: [String: Any]) -> String? {
        for key in ["uid", "selector", "element", "text", "value", "name", "filePath", "label"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        if let page = page(in: input) { return page }
        return nil
    }

    /// `navigate_page` reads as "navigate page", which is what a person says.
    static func readable(_ tool: String) -> String {
        tool.replacingOccurrences(of: "_", with: " ")
    }
}
