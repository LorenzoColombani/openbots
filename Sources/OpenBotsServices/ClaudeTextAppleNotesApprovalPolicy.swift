import Foundation
import OpenBotsDomain
import OpenBotsRuntime

/// What a bot asked to write in Apple Notes, read exactly as the Claude Desktop
/// extension's `server/index.js` (Notes 0.1.7) will
/// read it.
///
/// The extension is pinned and cannot be changed, so this is the only side
/// that checks anything, unlike the app's own Messages server, which checks
/// every text again. Where the extension coerces, this refuses: it takes any
/// JSON value for a folder and splices it into the AppleScript, so a number
/// there names a folder by its position; here a folder is a string or nothing.
/// Where the extension defaults, this shows the default: `folder || "Notes"`
/// for a new note, and `if (folder)` for a replacement, which is any folder.
public struct AppleNotesWriteProposal: Equatable, Sendable {
    public static let addTool = "add_note"
    public static let replaceTool = "update_note_content"

    public enum Kind: Equatable, Sendable { case add, replace }

    /// Counted in Unicode scalars. The approvals record keeps the first 2,000
    /// characters of a card's detail, and the longest heading either write
    /// builds, with a name and a folder at their limits, is under five hundred;
    /// `AppleNotesCardTests.theWorstCaseCardFitsTheRecord` pins it.
    public static let maximumTextScalars = 1_500
    public static let maximumNameScalars = 200
    public static let maximumFolderScalars = 100

    public let kind: Kind
    /// The new note's name, or the name of the note to replace.
    public let name: String
    /// Where a new note goes (never nil), or the folder a replacement looks
    /// in (nil: any folder).
    public let folder: String?
    public let text: String

    public enum Refusal: Error, Equatable, Sendable {
        case unreadableInput
        case unexpectedField(String)
        case missing(field: String)
        case notAString(field: String)
        case empty(field: String)
        case tooLong(field: String, scalars: Int, limit: Int)
        case notOneLine(field: String)
        case spaceAtAnEnd(field: String)
        case refusedCharacter(field: String, UInt32)
        case blankLineAtAnEnd
        case blankLinesInARow
        case endsWithWhitespace
        /// `<` or `&` in the text, which Notes reads as web markup.
        case markup
    }

    /// The field names each write takes, in the extension's own spelling.
    static func fields(_ kind: Kind) -> (name: String, text: String, folder: String) {
        switch kind {
        case .add: ("name", "content", "folder")
        case .replace: ("note_name", "new_content", "folder")
        }
    }

    public init(tool: String, input: [String: Any]?) throws {
        let kind: Kind
        switch tool {
        case Self.addTool: kind = .add
        case Self.replaceTool: kind = .replace
        default: throw Refusal.unreadableInput
        }
        guard let input else { throw Refusal.unreadableInput }
        let names = Self.fields(kind)
        let allowed = [names.name, names.text, names.folder]
        // Compared scalar for scalar, as the extension's JavaScript does.
        if let extra = input.keys.sorted().first(where: { key in
            !allowed.contains { $0.unicodeScalars.elementsEqual(key.unicodeScalars) }
        }) {
            throw Refusal.unexpectedField(extra)
        }
        func string(_ field: String) throws -> String {
            guard let value = input[field], !(value is NSNull) else { throw Refusal.missing(field: field) }
            guard let string = value as? String else { throw Refusal.notAString(field: field) }
            return string
        }
        let name = try string(names.name), text = try string(names.text)
        var folder: String?
        if let value = input[names.folder], !(value is NSNull) {
            guard let string = value as? String else { throw Refusal.notAString(field: names.folder) }
            folder = string.isEmpty ? nil : string
        }
        try Self.checkOneLine(name, field: names.name, limit: Self.maximumNameScalars)
        if let folder { try Self.checkOneLine(folder, field: names.folder, limit: Self.maximumFolderScalars) }
        try Self.checkText(text, field: names.text)
        self.kind = kind
        self.name = name
        self.folder = kind == .add ? (folder ?? "Notes") : folder
        self.text = text
    }

    /// A name or a folder: one line, no character the card would draw as
    /// nothing, and no space at either end, where the card's quotes would be
    /// the only sign of it.
    private static func checkOneLine(_ value: String, field: String, limit: Int) throws {
        let scalars = Array(value.unicodeScalars)
        guard !scalars.isEmpty else { throw Refusal.empty(field: field) }
        guard scalars.count <= limit else { throw Refusal.tooLong(field: field, scalars: scalars.count, limit: limit) }
        if scalars.contains(where: { $0.value == 0x0A || $0.value == 0x09 }) { throw Refusal.notOneLine(field: field) }
        if let refused = AppleMessagesSendProposal.firstRefused(in: scalars) {
            throw Refusal.refusedCharacter(field: field, refused.value)
        }
        if let first = scalars.first, let last = scalars.last,
           AppleMessagesSendProposal.isWhitespace(first.value) || AppleMessagesSendProposal.isWhitespace(last.value) {
            throw Refusal.spaceAtAnEnd(field: field)
        }
    }

    /// The text: the rules a text card holds a message to, for the same reason,
    /// and one more. The extension sets the note's `body`, which Notes reads as
    /// web markup, so the card could not show what Notes would: `hunter&#50;2`
    /// shows a secret the card never showed, `&#x200B;` a character the card's
    /// own rule refuses, and a tag whatever it draws or fetches. So a text is
    /// plain words: no `<` and no `&`.
    private static func checkText(_ text: String, field: String) throws {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { throw Refusal.empty(field: field) }
        guard scalars.count <= maximumTextScalars else {
            throw Refusal.tooLong(field: field, scalars: scalars.count, limit: maximumTextScalars)
        }
        if scalars.contains(where: { $0 == "<" || $0 == "&" }) { throw Refusal.markup }
        if let refused = AppleMessagesSendProposal.firstRefused(in: scalars) {
            throw Refusal.refusedCharacter(field: field, refused.value)
        }
        switch AppleMessagesSendProposal.lineShapeRefusal(scalars) {
        case .blankLineAtAnEnd: throw Refusal.blankLineAtAnEnd
        case .blankLinesInARow: throw Refusal.blankLinesInARow
        default: break
        }
        if let last = scalars.last, AppleMessagesSendProposal.isWhitespace(last.value) {
            throw Refusal.endsWithWhitespace
        }
    }

    /// Whether a write would put a secret the user gave this turn into their Notes: in
    /// its name, its folder or its text, found as a text card finds one. An
    /// input that cannot be read counts: it cannot be shown, so it is not written.
    public static func carriesASecret(tool: String, _ inputJSON: Data, secrets: [String]) -> Bool {
        guard let input = (try? JSONSerialization.jsonObject(with: inputJSON)) as? [String: Any],
              let proposal = try? AppleNotesWriteProposal(tool: tool, input: input) else { return true }
        let fields = [proposal.name, proposal.text] + (proposal.folder.map { [$0] } ?? [])
        return secrets.filter { $0.count >= 4 }.contains { secret in
            fields.contains { $0.contains(secret) || ClaudeTextAppleMessagesApprovalPolicy.containsScalars($0, secret) }
        }
    }
}

extension AppleNotesWriteProposal.Refusal {
    /// The sentence the model is shown when a rule refuses the write.
    func sentence(for kind: AppleNotesWriteProposal.Kind) -> String {
        let tail = " Nothing was written."
        let names = AppleNotesWriteProposal.fields(kind)
        switch self {
        case .unreadableInput:
            return "The note's details could not be read, so they cannot be shown on a card." + tail
        case .unexpectedField(let field):
            // Named printable-ASCII only, bounded: the name came from a model.
            let shown = field.unicodeScalars.prefix(40).map { scalar in
                (0x21...0x7E).contains(scalar.value) ? String(scalar) : String(format: "U+%04X", scalar.value)
            }.joined()
            return "`\(shown)` is not a field of this call: it takes only \(names.name), \(names.text) and "
                + "\(names.folder), and a card cannot show anything else." + tail
        case .missing(let field):
            return "`\(field)` is required: a card cannot show a value that is not there." + tail
        case .notAString(let field):
            return "`\(field)` must be a string, and it arrived as something else, so it cannot be shown on a "
                + "card exactly." + tail
        case .empty(let field):
            return "`\(field)` is empty." + tail
        case .tooLong(let field, let scalars, let limit):
            return "`\(field)` is \(scalars) characters long and the limit is \(limit), so it cannot be shown "
                + "to the user whole." + tail
        case .notOneLine(let field):
            return "`\(field)` must be one line: a line break or a tab in it cannot be shown on a card as it "
                + "would be written." + tail
        case .spaceAtAnEnd(let field):
            return "`\(field)` begins or ends with a space, which the card cannot show." + tail
        case .refusedCharacter(let field, let value):
            return "`\(field)` carries \(String(format: "U+%04X", value)), which the card cannot show as it "
                + "would be written. Write it again without that character; a line break in the text is fine "
                + "as a plain newline." + tail
        case .blankLineAtAnEnd:
            return "`\(names.text)` begins or ends with a blank line, which the card shows as empty space." + tail
        case .blankLinesInARow:
            return "`\(names.text)` has two blank lines in a row, which can push words below what the card "
                + "shows at first. Use at most one blank line between paragraphs." + tail
        case .endsWithWhitespace:
            return "`\(names.text)` ends with a space, which the card cannot show and its record would drop."
                + tail
        case .markup:
            return "`\(names.text)` carries < or &, and Notes reads a note's text as web markup, so the note would "
                + "not show what the card shows. Write it in plain words: \"and\" for &, \"less than\" for <." + tail
        }
    }
}

/// What the card says when a bot wants to use Apple Notes, through the Claude
/// Desktop extension.
///
/// The two reads are quiet: the row's own switch is the boundary, and reading
/// the user's notes is what the row is for. The two writes always ask, with the note's
/// name, its folder and the exact text, and a replacement says plainly that
/// everything the note held goes, and that the note is found by its name alone.
/// A write the card could not show exactly is refused by rule and never
/// becomes a card.
public enum ClaudeTextAppleNotesApprovalPolicy {
    /// The pinned extension's two reads; `AppleNotesCardTests` holds these and
    /// the two writes to the tools the reviewed manifest announces.
    static let quietReads: Set<String> = ["list_notes", "get_note_content"]

    static let refusalActivity = "Blocked a note whose details could not be shown exactly"
    static let secretRefusal = "This note carries something the user gave as a secret earlier in this turn, so "
        + "the card could not show it exactly as it would be written. Nothing was written. Never put a secret the user "
        + "gave you into a note."
    static let secretActivity = "Blocked a note that carried a secret you gave"

    static func card(for proposal: AppleNotesWriteProposal) -> ClaudeTextWorkCard {
        // Nothing here is clamped, and nothing needs to be: the proposal has
        // bounded every value, and a cut would put words on the card that are
        // not the words written. The record lines take a bounded fragment.
        let lines = AppleMessagesSendProposal.lineCount(proposal.text)
        let count = lines > ClaudeTextAppleMessagesApprovalPolicy.mostLinesWithoutACount
            ? " The text is \(lines) lines long." : ""
        let recorded = ClaudeTextAppleMailSendApprovalPolicy.fragment(proposal.name, 80)
        switch proposal.kind {
        case .add:
            let folder = proposal.folder ?? "Notes"
            return ClaudeTextWorkCard(
                title: "Add a note",
                detail: "Adds a new note named “\(proposal.name)” to the folder “\(folder)” in your Notes.\(count)"
                    + ClaudeTextAppleMessagesApprovalPolicy.headingSeparator + proposal.text,
                target: "“\(proposal.name)” in “\(folder)”",
                kind: .metadataMutation,
                activity: "Asked to add the note “\(recorded)”")
        case .replace:
            let place = proposal.folder.map { " in the folder “\($0)”" } ?? ", in any folder"
            return ClaudeTextWorkCard(
                title: "Replace a note's text",
                detail: "Replaces everything in the first note Notes finds named “\(proposal.name)”\(place) "
                    + "(capital letters may differ). What it holds now is not kept.\(count)"
                    + ClaudeTextAppleMessagesApprovalPolicy.headingSeparator + proposal.text,
                target: "“\(proposal.name)”" + (proposal.folder.map { " in “\($0)”" } ?? ""),
                kind: .overwrite,
                activity: "Asked to replace the text of the note “\(recorded)”")
        }
    }

    static func decide(_ request: ClaudeTextPermissionRequest, botName: String) -> ClaudeTextWorkDecision {
        let tool = ClaudeTextConnectorApprovalPolicy.toolName(in: request.toolName)
        let input = (try? JSONSerialization.jsonObject(with: request.inputJSON)) as? [String: Any]
        // What a read names arrives from a model, so it is bounded where it
        // enters the record line.
        func named(_ field: String) -> String {
            (input?[field] as? String).map { ClaudeTextAppleMailSendApprovalPolicy.fragment($0, 80) } ?? ""
        }
        switch tool {
        case "list_notes":
            let folder = named("folder")
            return .allowQuietly(activity: folder.isEmpty ? "Listed your notes" : "Listed your notes in “\(folder)”")
        case "get_note_content":
            let name = named("note_name")
            return .allowQuietly(activity: name.isEmpty ? "Read one of your notes" : "Read your note “\(name)”")
        case AppleNotesWriteProposal.addTool, AppleNotesWriteProposal.replaceTool:
            let kind: AppleNotesWriteProposal.Kind = tool == AppleNotesWriteProposal.addTool ? .add : .replace
            do {
                return .ask(card(for: try AppleNotesWriteProposal(tool: tool, input: input)))
            } catch let refusal as AppleNotesWriteProposal.Refusal {
                return .denyQuietly(reason: refusal.sentence(for: kind), activity: refusalActivity)
            } catch {
                return .denyQuietly(reason: AppleNotesWriteProposal.Refusal.unreadableInput.sentence(for: kind),
                                    activity: refusalActivity)
            }
        default:
            // Including whatever a later version of the extension may add: a
            // later version is not the reviewed one, and does not launch, but
            // the card does not rely on that.
            let readable = ClaudeTextBrowserApprovalPolicy.readable(tool)
            return .ask(ClaudeTextWorkCard(
                title: "Do something in Notes",
                detail: String(("\(botName) wants to use \(readable) in your Notes. This version does not know "
                    + "what that does, so it asks.").scalarPrefix(600)),
                target: String(readable.scalarPrefix(200)), kind: .overwrite,
                activity: String("Asked to use \(readable) in Notes".scalarPrefix(200))))
        }
    }
}
