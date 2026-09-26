import Foundation

// Bots that hire bots. A bot whose hire switch is on, with the
// app-wide hire switch on, may ask the app for a new teammate from its own
// reply. The app creates it; the bot only asks. Everything here is pure: the
// request as the tool's arguments carry it, the ledger that holds one reply to
// three calls, the sentences the model and the person read, and the creature a
// new bot is born with. The old app's rules are kept (HireDirective, HireGate):
// the hirer writes the seat, long text is clipped rather than refused, and a
// refusal is reported, never dropped.

/// A bot's seat: the work that is theirs by default, the work they hand to a
/// named teammate instead, who they work with, and what they bring back rather
/// than deciding alone. A hirer writes it at hire time; the person edits it in
/// the profile. A hired bot never writes its own.
public struct TeammateSeat: Codable, Equatable, Sendable {
    /// The old app's cap for one seat field (`AgentStore.maxSeatField`).
    public static let maximumFieldLength = 600
    public let purview: String?
    public let never: String?
    public let interfaces: String?
    public let escalate: String?

    public init(purview: String? = nil, never: String? = nil, interfaces: String? = nil,
                escalate: String? = nil) throws {
        self.purview = try DomainText.optional(purview, field: "seat purview", maximum: Self.maximumFieldLength)
        self.never = try DomainText.optional(never, field: "seat never", maximum: Self.maximumFieldLength)
        self.interfaces = try DomainText.optional(interfaces, field: "seat interfaces", maximum: Self.maximumFieldLength)
        self.escalate = try DomainText.optional(escalate, field: "seat escalate", maximum: Self.maximumFieldLength)
    }

    public var isEmpty: Bool { purview == nil && never == nil && interfaces == nil && escalate == nil }
}

/// Why one hire call was refused. Each is said to the model as the tool's
/// result and to the person in the note, so a hire never vanishes unexplained.
public enum TeammateHireRefusal: Error, Equatable, Sendable {
    /// The bot's own hire switch or the app-wide one is off, read at the call.
    case switchedOff
    /// The call did not come from the bot's own reply: a helper, or a call
    /// the turn never announced.
    case notTheBot
    /// The reply has already made its three hire calls.
    case tooManyCalls
    /// The same call arrived again while its first answer was being made.
    case alreadyInHand
    /// The arguments were not one object of the text fields the tool takes.
    case malformed
    case invalidHandle
    /// The handle is one of the transcript's own author labels.
    case reservedHandle
    case missingPurpose
    /// Another active bot holds the name, under the one name rule.
    case nameTaken(existingName: String)
    /// An archived bot holds the name: a hire is stricter than the New Bot
    /// sheet, because a newcomer with it would block that bot's restore.
    case nameArchived(existingName: String)
    /// The hirer or its conversation is no longer there to hire from.
    case hirerUnavailable
    /// The new teammate could not be saved.
    case notCreated

    /// The few words the note in the conversation gives for this refusal.
    public var reason: String {
        switch self {
        case .switchedOff: "hiring is switched off for this bot"
        case .notTheBot: "only the bot itself can hire, never a helper"
        case .tooManyCalls: "a reply can make at most three hire calls"
        case .alreadyInHand: "that hire was already being made"
        case .malformed: "the request was not in the tool's shape"
        case .invalidHandle: "the handle was not one plain word"
        case .reservedHandle: "the handle is a name the conversation shows for the app or the person"
        case .missingPurpose: "it did not say what the teammate is for"
        case .nameTaken(let existingName): "a bot named \(TeammateHireText.oneLine(existingName)) already exists"
        case .nameArchived(let existingName): "an archived bot is named \(TeammateHireText.oneLine(existingName))"
        case .hirerUnavailable: "the bot could no longer hire here"
        case .notCreated: "OpenBots could not create the teammate"
        }
    }

    /// What the model reads as the tool's result: the refusal and what to do.
    var toolResultText: String {
        switch self {
        case .switchedOff:
            "Hire refused: hiring is switched off for this bot."
        case .notTheBot:
            "Hire refused: only the bot itself can hire, from its own reply, never a helper."
        case .tooManyCalls:
            "Hire refused: a reply can make at most three hire calls, and this reply has made them."
        case .alreadyInHand:
            "Hire refused: that hire was already being made."
        case .malformed:
            "Hire refused: the tool takes text fields only: handle and purpose, and optionally instructions, purview, never, interfaces and escalate."
        case .invalidHandle:
            "Hire refused: a handle is one word of at most 32 letters, digits, hyphens or underscores, starting with a letter."
        case .reservedHandle:
            "Hire refused: OpenBots and You are the names the conversation shows for the app and the person. Pick another handle."
        case .missingPurpose:
            "Hire refused: say in purpose what the new teammate is for."
        case .nameTaken(let existingName):
            "Hire refused: a bot named \(TeammateHireText.oneLine(existingName)) already exists. Pick another handle, or hand the work to \(TeammateHireText.oneLine(existingName))."
        case .nameArchived(let existingName):
            "Hire refused: an archived bot is named \(TeammateHireText.oneLine(existingName)), and the person may bring it back. Pick another handle."
        case .hirerUnavailable:
            "Hire refused: this bot can no longer hire in this conversation."
        case .notCreated:
            "Hire refused: OpenBots could not create the teammate."
        }
    }
}

/// One teammate a hire created.
public struct TeammateHire: Equatable, Sendable {
    public let teammateID: TeammateID
    public let name: String
    public let purpose: String
    /// True when the hire came from a team conversation and the newcomer joined that team.
    public let joinedTeam: Bool
    /// True when the hire came from a team conversation and joining it failed;
    /// the hire stands.
    public let couldNotJoinTeam: Bool

    public init(teammateID: TeammateID, name: String, purpose: String, joinedTeam: Bool, couldNotJoinTeam: Bool = false) {
        self.teammateID = teammateID; self.name = name; self.purpose = purpose; self.joinedTeam = joinedTeam
        self.couldNotJoinTeam = couldNotJoinTeam
    }

    /// The purpose as an app-authored line carries it: one line in quotation
    /// marks, its own quotation marks and backslashes escaped. The model wrote
    /// it, so it must never read as a sentence of the app's own.
    public var quotedPurpose: String { TeammateHireText.quoted(purpose) }
}

/// How one hire call ended.
public enum TeammateHireOutcome: Equatable, Sendable {
    case hired(TeammateHire)
    case refused(TeammateHireRefusal)

    public var isHire: Bool { if case .hired = self { true } else { false } }

    /// The tool's result, as the model reads it. A hire says the newcomer is
    /// sealed, so the hirer never promises it a capability; a hire into a team
    /// says so, and the lead's prompt already says how to brief a member.
    public var toolResultText: String {
        switch self {
        case .refused(let refusal):
            return refusal.toolResultText
        case .hired(let hire):
            let name = TeammateHireText.oneLine(hire.name)
            let purpose = TeammateHireText.sentence(hire.purpose)
            let sealed = "\(name) starts sealed: every switch off and no connectors; like every bot, they can read the team's shared folder and their own skills."
            let place = hire.joinedTeam
                ? " \(name) joined this team and has their own chat with the person too."
                : hire.couldNotJoinTeam
                ? " \(name) could not join this team, so no handoff in this conversation can reach them; they have their own chat with the person."
                : " \(name) has their own chat with the person."
            return "Hired @\(name): \(purpose) \(sealed)\(place)"
        }
    }
}

/// The hire calls of one reply. At most three are handled, refused ones
/// counted; a fourth is refused whatever it asks. One tool use is answered
/// once: a repeat gets the first answer and is not counted again, and a call
/// still being handled is not handled a second time.
public struct TeammateHireLedger: Equatable, Sendable {
    /// The old app's `HireGate.maxPerReply`: enough for any deliberate staffing
    /// move in one breath, and a bound on a confused reply.
    public static let maximumCallsPerReply = 3

    public enum Admission: Equatable, Sendable {
        case proceed
        case repeatOf(TeammateHireOutcome)
        case refuse(TeammateHireRefusal)
    }

    private var order: [String] = []
    private var answered: [String: TeammateHireOutcome] = [:]
    private var inHand: Set<String> = []

    public init() {}

    /// Every call this reply made, the refused ones included.
    public var callCount: Int { order.count }
    /// Each call's outcome, in call order, for the calls that have one.
    public var outcomes: [TeammateHireOutcome] { order.compactMap { answered[$0] } }

    public func admission(toolUseID: String) -> Admission {
        if let outcome = answered[toolUseID] { return .repeatOf(outcome) }
        if inHand.contains(toolUseID) { return .refuse(.alreadyInHand) }
        return order.count >= Self.maximumCallsPerReply ? .refuse(.tooManyCalls) : .proceed
    }

    /// Counts the call and marks it in hand until its outcome is recorded.
    public mutating func begin(toolUseID: String) {
        guard answered[toolUseID] == nil, inHand.insert(toolUseID).inserted else { return }
        order.append(toolUseID)
    }

    /// The call's outcome; a call never begun is counted here.
    public mutating func record(toolUseID: String, outcome: TeammateHireOutcome) {
        guard answered[toolUseID] == nil else { return }
        if !inHand.contains(toolUseID) { order.append(toolUseID) }
        inHand.remove(toolUseID)
        answered[toolUseID] = outcome
    }
}

/// The one line the hirer's conversation gets once the reply settles: who was
/// hired and for what, then any refusal with its reason.
public enum TeammateHireNote {
    public static func line(hirerName: String, outcomes: [TeammateHireOutcome]) -> String? {
        guard !outcomes.isEmpty else { return nil }
        let hirer = TeammateHireText.oneLine(hirerName)
        let hires = outcomes.compactMap { outcome -> TeammateHire? in
            if case .hired(let hire) = outcome { return hire }; return nil
        }
        let refusals = outcomes.compactMap { outcome -> TeammateHireRefusal? in
            if case .refused(let refusal) = outcome { return refusal }; return nil
        }
        var reasons: [String] = []
        for refusal in refusals where !reasons.contains(refusal.reason) { reasons.append(refusal.reason) }
        let why = reasons.joined(separator: "; ")
        guard !hires.isEmpty else {
            return refusals.count == 1
                ? "\(hirer)\(hireRefusedMarker)\(why)."
                : "\(hirer)'s \(refusals.count)\(hiresRefusedMarker)\(why)."
        }
        let named = hires.map { "@\(TeammateHireText.oneLine($0.name)) (\($0.quotedPurpose))" }
        let list = named.count == 1 ? named[0]
            : named.dropLast().joined(separator: ", ") + " and " + named[named.count - 1]
        var line = "\(hirer) hired \(list)."
        if refusals.count == 1 {
            line += " One more hire was refused: \(why)."
        } else if refusals.count > 1 {
            line += " \(refusals.count) more hires were refused: \(why)."
        }
        return line
    }

    /// True for a line `line(hirerName:outcomes:)` wrote. Only the app writes
    /// status lines and none of its other ones carries these phrases, so a
    /// saved note is recognised after a relaunch without a column of its own.
    public static func isNote(_ text: String) -> Bool {
        if let hired = text.range(of: " hired @"), hired.lowerBound > text.startIndex { return true }
        if let refused = text.range(of: hireRefusedMarker), refused.lowerBound > text.startIndex { return true }
        guard let refused = text.range(of: hiresRefusedMarker),
              let owner = text[..<refused.lowerBound].range(of: "'s ", options: .backwards),
              owner.lowerBound > text.startIndex else { return false }
        let count = text[owner.upperBound..<refused.lowerBound]
        return !count.isEmpty && count.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static let hireRefusedMarker = "'s hire was refused: "
    private static let hiresRefusedMarker = " hires were refused: "
}

/// The creature a new bot is born with: a deterministic spawn from its id, in
/// the grammar the New Bot sheet has always drawn. One function, so a bot a
/// hire made looks like a bot the person made.
public struct CreatureAllocation: Equatable, Sendable {
    public static let grammarVersion: UInt16 = 1
    static let silhouettes = ["soft-arch", "round-ears", "tall-tuft"]
    static let palettes = ["violet-coral", "teal-gold", "blue-lilac", "plum-mint"]
    static let eyes = ["round-alert", "soft-focused", "wide-curious"]
    static let cues = ["single brow notch", "paired cheek marks", "forehead spark"]

    public let seed: UInt64
    public let silhouette: String
    public let paletteToken: String
    public let eyeDialect: String
    public let nonColorIdentityCue: String
    /// Nil keeps the generated family; otherwise one of the bundled models.
    public let builtInAvatarID: String?

    public var accessibleIdentityDescription: String {
        "Creature with \(silhouette), \(eyeDialect) eyes, and \(nonColorIdentityCue)"
    }

    /// The generated creature for `seed`, without a bundled model: what a
    /// preview draws and what a saved appearance falls back to.
    public static func generated(seed: UInt64) -> Self {
        Self(seed: seed, builtInAvatarID: nil)
    }

    /// A new identity's creature for `seed`, with the bundled model its seed allocates.
    public static func newIdentity(seed: UInt64) -> Self {
        Self(seed: seed, builtInAvatarID: BuiltInAvatar.allocatedForNewIdentity(seed: seed)?.rawValue)
    }

    /// A new bot's creature, spawned from its id.
    public init(id: UUID) {
        self = Self.newIdentity(seed: Self.seed(for: id))
    }

    private init(seed: UInt64, builtInAvatarID: String?) {
        func value(_ values: [String]) -> String { values[Int(seed % UInt64(values.count))] }
        self.seed = seed
        silhouette = value(Self.silhouettes)
        paletteToken = value(Self.palettes)
        eyeDialect = value(Self.eyes)
        nonColorIdentityCue = value(Self.cues)
        self.builtInAvatarID = builtInAvatarID
    }

    /// FNV-1a over the id's uppercase string, byte for byte as the New Bot sheet has always spawned.
    public static func seed(for id: UUID) -> UInt64 {
        id.uuidString.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    public func appearance() throws -> AgentAppearance {
        try AgentAppearance(mode: .creature, grammarVersion: Self.grammarVersion, deterministicSeed: seed,
            silhouette: silhouette, paletteToken: paletteToken, eyeDialect: eyeDialect,
            nonColorIdentityCue: nonColorIdentityCue, accessibleIdentityDescription: accessibleIdentityDescription,
            builtInAvatarID: builtInAvatarID)
    }
}

/// One hire as the tool's arguments ask for it: a handle and a purpose, and
/// the hirer's instructions and seat for the newcomer when given. Every field
/// is text and bounded. A field of the wrong kind, a field the tool does not
/// take, or a handle that is not one plain word is refused; text that is only
/// too long is clipped to its bound, because a wordy hirer must not lose the
/// hire (the old app's rule for its seat fields).
public struct TeammateHireRequest: Equatable, Sendable {
    public static let maximumHandleLength = 32
    /// The profile's own bound for a role, which the purpose becomes.
    public static let maximumPurposeLength = 240
    /// The old app's cap for standing instructions (`AgentStore.maxInstructions`).
    public static let maximumInstructionsLength = 4_000
    /// Arguments larger than this are refused before anything is read out of
    /// them. It is a bound on the wire, not on the text: long text is clipped,
    /// never refused, and a character can be many bytes (👩‍💻 is eleven), so
    /// the clipped fields alone can pass 70 kilobytes. On a turn without a
    /// picture connector the arguments arrive out of one stream line of at most
    /// 524,288 bytes, which the stream encodes again; twice that is more than
    /// such a line can carry after re-encoding. A turn that also carries Control
    /// this Mac or the browser reads lines up to 12 MiB, so there a call whose
    /// arguments pass a mebibyte is refused as malformed rather than clipped:
    /// a bound no real hire comes near.
    public static let maximumArgumentsBytes = 1_048_576
    /// The fields the tool takes, in the order its schema lists them.
    public static let fieldNames = ["handle", "purpose", "instructions", "purview", "never", "interfaces", "escalate"]
    /// The transcript's own author labels (`ChatAuthorSnapshot`): no hire takes them.
    static let reservedHandles = ["OpenBots", "You"]

    /// The newcomer's name, as written, without a leading @.
    public let handle: String
    /// What the newcomer is for: their role.
    public let purpose: String
    public let instructions: String?
    public let seat: TeammateSeat?

    public static func parse(argumentsJSON: Data) -> Result<Self, TeammateHireRefusal> {
        guard argumentsJSON.count <= maximumArgumentsBytes,
              let object = try? JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any],
              object.keys.allSatisfy(fieldNames.contains) else { return .failure(.malformed) }
        var fields: [String: String] = [:]
        for (key, value) in object {
            guard let text = value as? String else { return .failure(.malformed) }
            fields[key] = text
        }
        var handle = (fields["handle"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if handle.hasPrefix("@") { handle.removeFirst() }
        guard isPlainHandle(handle) else { return .failure(.invalidHandle) }
        // The transcript names the app's own lines "OpenBots" and the person's
        // "You"; a bot with either name would speak as one of them.
        guard !reservedHandles.contains(where: { $0.caseInsensitiveCompare(handle) == .orderedSame }) else {
            return .failure(.reservedHandle)
        }
        let purpose = clipped(TeammateHireText.oneLine(fields["purpose"] ?? ""), to: maximumPurposeLength)
        guard !purpose.isEmpty else { return .failure(.missingPurpose) }
        let instructions = clipped(TeammateHireText.multiline(fields["instructions"] ?? ""), to: maximumInstructionsLength)
        func seatField(_ key: String) -> String? {
            let value = clipped(TeammateHireText.oneLine(fields[key] ?? ""), to: TeammateSeat.maximumFieldLength)
            return value.isEmpty ? nil : value
        }
        guard let seat = try? TeammateSeat(purview: seatField("purview"), never: seatField("never"),
                                           interfaces: seatField("interfaces"), escalate: seatField("escalate")) else {
            return .failure(.malformed)
        }
        return .success(Self(handle: handle, purpose: purpose, instructions: instructions.isEmpty ? nil : instructions,
                             seat: seat.isEmpty ? nil : seat))
    }

    /// The newcomer's profile: the handle as their name, the purpose as their
    /// role, the hirer's instructions and seat. No title; the person adds one.
    public func profile() throws -> TeammateProfile {
        try TeammateProfile(displayName: handle, role: purpose, detailedInstructions: instructions, seat: seat)
    }

    /// One word a mention can carry: an ASCII letter, then ASCII letters,
    /// digits, hyphens or underscores, at most 32 in all.
    static func isPlainHandle(_ handle: String) -> Bool {
        let scalars = Array(handle.unicodeScalars)
        guard let first = scalars.first, scalars.count <= maximumHandleLength,
              first.isASCII, first.properties.isAlphabetic else { return false }
        return scalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_")
        }
    }

    private static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Text a hire carries into a sentence or a line.
enum TeammateHireText {
    /// Characters that reorder what is read around them and are never part of
    /// the words: the bidi embeddings and overrides (U+202A to U+202E), the
    /// isolates (U+2066 to U+2069) and the three marks (U+200E, U+200F,
    /// U+061C). Not the rest of Cf: the zero-width joiner makes 👩‍💻 one emoji
    /// and the non-joiner is spelling in Persian. The connector card keeps the
    /// same judgement for its own words (`ClaudeTextConnectorApprovalPolicy.isHidden`).
    static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C: true
        default: false
        }
    }

    /// Line breaks, tabs and control characters folded into single spaces,
    /// bidi controls dropped, trimmed.
    static func oneLine(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if isBidiControl(scalar) { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar.properties.generalCategory == .control {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace { result.unicodeScalars.append(" "); pendingSpace = false }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    /// One line in quotation marks, its own quotation marks and backslashes
    /// escaped, so it can close neither its quote nor the sentence around it.
    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in oneLine(text).unicodeScalars {
            if scalar == "\"" || scalar == "\\" { result.unicodeScalars.append("\\") }
            result.unicodeScalars.append(scalar)
        }
        return result + "\""
    }

    /// Lines kept, every line break spelled as a newline, other control
    /// characters and bidi controls dropped except the tab, trimmed.
    static func multiline(_ text: String) -> String {
        var result = ""
        var previousWasReturn = false
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\r":
                result.unicodeScalars.append("\n")
                previousWasReturn = true
                continue
            case "\n":
                if !previousWasReturn { result.unicodeScalars.append("\n") }
            case "\u{0085}", "\u{2028}", "\u{2029}":
                result.unicodeScalars.append("\n")
            case "\t":
                result.unicodeScalars.append(scalar)
            default:
                if scalar.properties.generalCategory != .control, !isBidiControl(scalar) {
                    result.unicodeScalars.append(scalar)
                }
            }
            previousWasReturn = false
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line ending in a full stop, so it can open a longer sentence.
    static func sentence(_ text: String) -> String {
        let line = oneLine(text)
        guard let last = line.last else { return line }
        return ".!?".contains(last) ? line : line + "."
    }
}
