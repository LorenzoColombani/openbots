import CryptoKit
import Darwin
import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsRuntime

/// One Gmail message as the send card shows it and as Google receives it.
/// The card and the MIME writer read the same value, and
/// everything a card could not show exactly is refused rather than stripped or
/// cut: a plain ASCII address and nothing else, a one-line subject, and a body
/// under the same rules as a text in Messages (`AppleMessagesSendProposal`),
/// whose character and line rules this reuses.
public struct GoogleGmailSendProposal: Equatable, Sendable {
    public static let fields = ["body", "from", "subject", "to"]
    public static let maximumRecipients = 3
    public static let maximumAddressScalars = 100
    public static let maximumSubjectScalars = 120
    /// Counted in Unicode scalars, as Messages counts. The approvals record keeps
    /// the first 2,000 characters of the card's detail; the longest heading any
    /// accepted message builds is under 700, so 1,300 keeps every body whole on
    /// the record. `GoogleGmailSendTests.worstCaseFitsTheRecord` pins it.
    public static let maximumBodyScalars = 1_300

    public let from: String
    public let to: [String]
    public let subject: String
    public let body: String

    public enum Refusal: Error, Equatable, Sendable {
        case unreadableInput
        case unexpectedField(String)
        case missing(field: String)
        case notAString(field: String)
        case senderShape
        case recipientShape
        case tooManyRecipients
        case emptySubject
        case subjectTooLong(scalars: Int)
        case subjectShape
        case emptyBody
        case bodyTooLong(scalars: Int)
        case refusedCharacter(field: String, UInt32)
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
        let from = values["from"] ?? "", recipients = values["to"] ?? "",
            subject = values["subject"] ?? "", body = values["body"] ?? ""
        guard Self.isPlainAddress(from) else { throw Refusal.senderShape }

        // Split on commas and trim plain spaces only: every other character is
        // part of an address and must pass the address rule.
        let to = recipients.split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " ")) }
        guard to.count <= Self.maximumRecipients else { throw Refusal.tooManyRecipients }
        guard to.allSatisfy(Self.isPlainAddress) else { throw Refusal.recipientShape }

        let subjectScalars = Array(subject.unicodeScalars)
        guard !subjectScalars.isEmpty else { throw Refusal.emptySubject }
        guard subjectScalars.count <= Self.maximumSubjectScalars else {
            throw Refusal.subjectTooLong(scalars: subjectScalars.count)
        }
        if let refused = subjectScalars.first(where: { $0.value == 0x09 || $0.value == 0x0A })
            ?? AppleMessagesSendProposal.firstRefused(in: subjectScalars) {
            throw Refusal.refusedCharacter(field: "subject", refused.value)
        }
        // A space at either end is one the user cannot see on the card.
        guard let first = subjectScalars.first, let last = subjectScalars.last,
              !AppleMessagesSendProposal.isWhitespace(first.value),
              !AppleMessagesSendProposal.isWhitespace(last.value) else { throw Refusal.subjectShape }

        let bodyScalars = Array(body.unicodeScalars)
        guard !bodyScalars.isEmpty else { throw Refusal.emptyBody }
        guard bodyScalars.count <= Self.maximumBodyScalars else {
            throw Refusal.bodyTooLong(scalars: bodyScalars.count)
        }
        if let refused = AppleMessagesSendProposal.firstRefused(in: bodyScalars) {
            throw Refusal.refusedCharacter(field: "body", refused.value)
        }
        switch AppleMessagesSendProposal.lineShapeRefusal(bodyScalars) {
        case .blankLineAtAnEnd?: throw Refusal.blankLineAtAnEnd
        case .some: throw Refusal.blankLinesInARow
        case nil: break
        }
        if let end = bodyScalars.last, AppleMessagesSendProposal.isWhitespace(end.value) {
            throw Refusal.endsWithWhitespace
        }
        self.from = from; self.to = to; self.subject = subject; self.body = body
    }

    /// A plain ASCII address as Messages accepts one, and no display name: a
    /// name is words a stranger can choose, and the card would have to show
    /// them exactly and encode them for the header.
    static func isPlainAddress(_ value: String) -> Bool {
        value.unicodeScalars.count <= maximumAddressScalars && value.contains("@")
            && AppleMessagesSendProposal.isAddressable(value)
    }

    /// The message as Google receives it. The body goes as base64 in lines of
    /// 76, so no mail system on the way can rewrap a long line and change what
    /// arrives; the subject goes as UTF-8 encoded words of at most 75
    /// characters, folded, as RFC 2047 asks.
    public var rawMessage: Data {
        var lines = ["From: \(from)", "To: \(to.joined(separator: ", "))"]
        let words = Self.encodedWords(subject)
        lines.append("Subject: " + words[0])
        lines += words.dropFirst().map { " " + $0 }
        lines += ["MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8",
                  "Content-Transfer-Encoding: base64", ""]
        let crlf = body.replacingOccurrences(of: "\n", with: "\r\n")
        lines += Data(crlf.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn,
                                                               .endLineWithLineFeed])
            .components(separatedBy: "\r\n")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// The raw message as Gmail's `raw` field takes it: base64url, unpadded.
    public var rawMessageBase64URL: String {
        rawMessage.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// What an approval is bound to: the SHA-256 of the exact bytes sent, in
    /// lowercase hex. The same input builds the same bytes on both sides of the
    /// card, whatever order its keys arrive in.
    public var digest: String {
        SHA256.hash(data: rawMessage).map { String(format: "%02x", $0) }.joined()
    }

    /// Whole scalars, at most 39 UTF-8 bytes each: base64 makes 52 characters
    /// of them and the markers 64, so even the first, after "Subject: ",
    /// keeps its line under the 78 RFC 5322 asks for.
    static func encodedWords(_ text: String) -> [String] {
        var chunks: [Data] = [], chunk = Data()
        for scalar in text.unicodeScalars {
            let bytes = Data(String(scalar).utf8)
            if chunk.count + bytes.count > 39 { chunks.append(chunk); chunk = Data() }
            chunk += bytes
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks.map { "=?UTF-8?B?\($0.base64EncodedString())?=" }
    }
}

extension GoogleGmailSendProposal.Refusal {
    /// The sentence the model is shown when a rule refuses the send.
    public var sentence: String {
        let tail = " Nothing was sent."
        func shown(_ field: String) -> String {
            field.unicodeScalars.prefix(40).map { scalar in
                (0x21...0x7E).contains(scalar.value) ? String(scalar) : String(format: "U+%04X", scalar.value)
            }.joined()
        }
        switch self {
        case .unreadableInput:
            return "The message's details could not be read, so they cannot be shown on a card." + tail
        case .unexpectedField(let field):
            return "send_gmail_message takes exactly from, to, subject and body; \"\(shown(field))\" is not "
                + "one of them." + tail
        case .missing(let field):
            return "`\(field)` is missing: send_gmail_message needs from, to, subject and body." + tail
        case .notAString(let field):
            return "`\(field)` must be text." + tail
        case .senderShape:
            return "`from` must be the connected account's address exactly as gmail_send_account names it." + tail
        case .recipientShape:
            return "`to` must be plain email addresses separated by commas, such as a@example.com, with no "
                + "names, angle brackets or letters from other alphabets, each at most "
                + "\(GoogleGmailSendProposal.maximumAddressScalars) characters." + tail
        case .tooManyRecipients:
            return "`to` can name at most \(GoogleGmailSendProposal.maximumRecipients) addresses, so the card "
                + "can show every one." + tail
        case .emptySubject:
            return "`subject` is empty; every message needs one." + tail
        case .subjectTooLong(let scalars):
            return "`subject` is \(scalars) characters long and the limit is "
                + "\(GoogleGmailSendProposal.maximumSubjectScalars)." + tail
        case .subjectShape:
            return "`subject` begins or ends with a space, which the card cannot show." + tail
        case .emptyBody:
            return "`body` is empty, so there is nothing to send." + tail
        case .bodyTooLong(let scalars):
            return "`body` is \(scalars) characters long and the limit is "
                + "\(GoogleGmailSendProposal.maximumBodyScalars), so it cannot be shown to him whole. "
                + "Make it shorter." + tail
        case .refusedCharacter(let field, let value):
            return "`\(field)` carries \(String(format: "U+%04X", value)), which the card cannot show as it "
                + "would be sent. Write it again without that character"
                + (field == "body" ? "; a line break is fine as a plain newline." : ", on one line.") + tail
        case .blankLineAtAnEnd:
            return "`body` begins or ends with a blank line, which the card shows as empty space." + tail
        case .blankLinesInARow:
            return "`body` has two blank lines in a row. Use at most one between paragraphs." + tail
        case .endsWithWhitespace:
            return "`body` ends with a space, which the card cannot show." + tail
        }
    }
}

/// The approvals Gmail send may act on: one file per approved message, named
/// by its digest, written by the app when the user presses Approve and removed by the
/// helper as it sends. Removal is the use, so an approval sends once; a digest
/// that is not here, or waited longer than `lifetime`, sends nothing.
///
/// The folder is inside the app's own Application Support root, which every
/// bot's shell is fenced out of (`BotWorkspaceService.protectedPaths`), so a
/// bot cannot write an approval of its own.
public struct GoogleGmailSendApprovalLedger: Sendable {
    public static let lifetime: TimeInterval = 10 * 60
    public let directory: URL

    public enum Failure: Error, Equatable, Sendable { case malformedDigest, unwritable }

    public init(directory: URL) { self.directory = directory }

    /// The one the app and the helper share, under this user's own home as the
    /// password database names it, never `$HOME`.
    public static func standard() -> GoogleGmailSendApprovalLedger {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) }
            ?? NSHomeDirectory()
        return .init(directory: directory(in: PreviewStorageLayout(
            homeDirectory: URL(fileURLWithPath: home, isDirectory: true),
            systemTemporaryDirectory: FileManager().temporaryDirectory)))
    }

    /// Inside the app's Application Support root, which
    /// `BotWorkspaceService.protectedPaths` fences every bot's shell out of.
    static func directory(in layout: PreviewStorageLayout) -> URL {
        layout.applicationSupportRoot.url
            .appending(path: "HighChurn.noindex", directoryHint: .isDirectory)
            .appending(path: "GmailSendApprovals", directoryHint: .isDirectory)
    }

    /// Whether a fresh approval for this digest is waiting, without using it.
    public func holds(_ digest: String, now: Date = Date()) -> Bool {
        guard Self.isDigest(digest) else { return false }
        var info = stat()
        guard lstat(directory.appendingPathComponent(digest).path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { return false }
        let age = now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
        return age >= -5 && age <= Self.lifetime
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Writes one approval. Old ones that were never used are cleared first.
    public func record(_ digest: String, now: Date = Date()) throws {
        guard Self.isDigest(digest) else { throw Failure.malformedDigest }
        let files = FileManager()
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch { throw Failure.unwritable }
        for name in (try? files.contentsOfDirectory(atPath: directory.path)) ?? [] where Self.isDigest(name) {
            let url = directory.appendingPathComponent(name)
            if let modified = (try? files.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
               now.timeIntervalSince(modified) > Self.lifetime {
                try? files.removeItem(at: url)
            }
        }
        let url = directory.appendingPathComponent(digest)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.unwritable }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else { throw Failure.unwritable }
        var times = [timespec(tv_sec: Int(now.timeIntervalSince1970), tv_nsec: 0),
                     timespec(tv_sec: Int(now.timeIntervalSince1970), tv_nsec: 0)]
        guard futimens(descriptor, &times) == 0 else { throw Failure.unwritable }
    }

    /// True once for a recorded, fresh approval: the file is removed first, and
    /// only a removal this call made counts.
    public func consume(_ digest: String, now: Date = Date()) -> Bool {
        guard Self.isDigest(digest) else { return false }
        let path = directory.appendingPathComponent(digest).path
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid()
        else { return false }
        guard unlink(path) == 0 else { return false }
        let written = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        let age = now.timeIntervalSince(written)
        return age >= -5 && age <= Self.lifetime
    }
}

/// What the card says when a bot wants to send from the OpenBots Gmail account.
/// The account check is quiet; a send asks every time, with the whole message;
/// a send the card could not show exactly is refused before any card.
public enum ClaudeTextGoogleGmailSendApprovalPolicy {
    public static let sendTool = "send_gmail_message"
    static let quietReads: Set<String> = ["gmail_send_account"]
    static let refusalActivity = "Asked to send a Gmail message the card could not show; refused"

    /// The same count Messages uses: more lines than fit under the heading say
    /// how many there are, in the app's words.
    ///
    /// The subject is the bot's words, so it stands last, on a line of its own
    /// under a label: in the middle of the app's sentence a quote mark in it
    /// could close the quotation and add a sentence that reads as the app's.
    static func heading(for proposal: GoogleGmailSendProposal) -> String {
        var heading = "Sends as soon as you approve, from \(proposal.from) to "
            + "\(proposal.to.joined(separator: ", "))."
        let lines = AppleMessagesSendProposal.lineCount(proposal.body)
        if lines > ClaudeTextAppleMessagesApprovalPolicy.mostLinesWithoutACount {
            heading += " The message is \(lines) lines long."
        }
        return heading + "\nSubject: " + proposal.subject
    }

    static let secretRefusal = "This message carries something the user gave as a secret earlier in this turn, "
        + "so the card could not show it exactly as it would be sent. Nothing was sent. Never put a secret "
        + "he gave you into an email."
    static let secretActivity = "Blocked a Gmail message that carried a secret you gave"
    static let unrecordedRefusal = "The approval could not be written, so nothing was sent. Tell him."

    /// Whether a message would send a secret the user gave this turn, in any of its
    /// four fields, by the rule a text in Messages follows. An input that
    /// cannot be read as a message counts too: it cannot be shown, so it is
    /// not sent.
    static func sendCarriesASecret(_ inputJSON: Data, secrets: [String]) -> Bool {
        guard let input = (try? JSONSerialization.jsonObject(with: inputJSON)) as? [String: Any],
              let proposal = try? GoogleGmailSendProposal(input: input) else { return true }
        return secrets.filter { $0.count >= 4 }.contains { secret in
            ([proposal.from, proposal.subject, proposal.body] + proposal.to).contains { field in
                field.contains(secret) || ClaudeTextAppleMessagesApprovalPolicy.containsScalars(field, secret)
            }
        }
    }

    /// The digest an approval of this call writes, or nil for anything that is
    /// not a send this row can make.
    static func approvedDigest(_ request: ClaudeTextPermissionRequest) -> String? {
        guard ClaudeTextConnectorApprovalPolicy.toolName(in: request.toolName) == sendTool,
              let input = (try? JSONSerialization.jsonObject(with: request.inputJSON)) as? [String: Any]
        else { return nil }
        return try? GoogleGmailSendProposal(input: input).digest
    }

    static func card(for proposal: GoogleGmailSendProposal) -> ClaudeTextWorkCard {
        // Nothing here is clamped: the proposal has bounded every value, and a
        // cut would put words on the card that are not the words sent.
        ClaudeTextWorkCard(
            title: "Send a Gmail message",
            detail: heading(for: proposal) + "\n\n" + proposal.body,
            target: proposal.to.joined(separator: ", "),
            kind: .send,
            activity: "Asked to send Gmail to \(proposal.to.joined(separator: ", "))")
    }

    static func decide(_ request: ClaudeTextPermissionRequest, botName: String) -> ClaudeTextWorkDecision {
        let tool = ClaudeTextConnectorApprovalPolicy.toolName(in: request.toolName)
        if quietReads.contains(tool) { return .allowQuietly(activity: "Checked the Gmail sending account") }
        if tool == sendTool {
            do {
                guard let input = (try? JSONSerialization.jsonObject(with: request.inputJSON)) as? [String: Any]
                else { throw GoogleGmailSendProposal.Refusal.unreadableInput }
                return .ask(card(for: try GoogleGmailSendProposal(input: input)))
            } catch let refusal as GoogleGmailSendProposal.Refusal {
                return .denyQuietly(reason: refusal.sentence, activity: refusalActivity)
            } catch {
                return .denyQuietly(reason: GoogleGmailSendProposal.Refusal.unreadableInput.sentence,
                                    activity: refusalActivity)
            }
        }
        let readable = ClaudeTextBrowserApprovalPolicy.readable(tool)
        return .ask(ClaudeTextWorkCard(
            title: "Do something with Gmail send",
            detail: String(("\(botName) wants to use \(readable) on the Gmail send row. This version does not "
                + "know what that does, so it asks.").scalarPrefix(600)),
            target: String(readable.scalarPrefix(200)), kind: .send,
            activity: String("Asked to use \(readable) on Gmail send".scalarPrefix(200))))
    }
}
