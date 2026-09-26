import Foundation

// A new bot sets itself up. The person clicks plus, the
// bot asks what it is for, and from the answer it writes its own profile with
// the app's `set_up_self` tool: the hire tool's fields, read by the hire's own
// rules, plus the switches its job needs. Everything here is pure: the request
// as the tool's arguments carry it, the sentences the model reads, and the one
// line the conversation gets.

/// A switch a new bot may ask for when it sets itself up. A fixed list: never
/// Hire, Workers or Fetchers (for those the switch itself is the
/// authorisation, so a bot turning them on would approve itself), never a
/// connector's chosen chats or Control this Mac (the person's own choice), never an
/// app-wide master. The person approves the list on one card.
public enum BotSetupSwitch: String, CaseIterable, Codable, Sendable {
    case webSearch = "web_search"
    case webFetch = "web_fetch"
    case work

    /// How the person reads it, in a card or a line.
    public var label: String {
        switch self {
        case .webSearch: "web search"
        case .webFetch: "web fetch"
        case .work: "Work on this Mac"
        }
    }

    /// Labels joined as a sentence says them: "a", "a and b", "a, b and c".
    public static func sentenceList(_ switches: [BotSetupSwitch]) -> String {
        let labels = switches.map(\.label)
        guard labels.count > 1 else { return labels.first ?? "" }
        return labels.dropLast().joined(separator: ", ") + " and " + labels[labels.count - 1]
    }
}

/// Why one setup call was refused. The model reads it as the tool's result.
public enum BotSelfSetupRefusal: Error, Equatable, Sendable {
    /// This bot is not waiting to be set up: it already was, or the turn was
    /// not its direct chat.
    case notPending
    /// The call did not come from the bot's own reply.
    case notTheBot
    /// The arguments were not the tool's shape.
    case malformed
    /// `switches` named something outside the fixed list.
    case unknownSwitch
    /// A field broke one of the hire's own rules (handle, reserved name,
    /// purpose, a name another bot holds).
    case profile(TeammateHireRefusal)
    /// The new profile could not be saved.
    case notSaved

    public var toolResultText: String {
        switch self {
        case .notPending:
            "Setup refused: this bot is already set up. Its profile is the person's to change in Details."
        case .notTheBot:
            "Setup refused: only the bot itself can set itself up, from its own reply."
        case .malformed:
            "Setup refused: the tool takes handle and purpose, optionally instructions, purview, never, interfaces and escalate, all text, and switches, a list."
        case .unknownSwitch:
            "Setup refused: switches may name only web_search, web_fetch and work."
        case .profile(.invalidHandle):
            "Setup refused: a handle is one word of at most 32 letters, digits, hyphens or underscores, starting with a letter."
        case .profile(.reservedHandle):
            "Setup refused: OpenBots and You are the names the conversation shows for the app and the person. Pick another handle."
        case .profile(.missingPurpose):
            "Setup refused: say in purpose what you are for."
        case .profile(.nameTaken(let existingName)):
            "Setup refused: a bot named \(TeammateHireText.oneLine(existingName)) already exists. Pick another handle."
        case .profile(.nameArchived(let existingName)):
            "Setup refused: an archived bot is named \(TeammateHireText.oneLine(existingName)), and the person may bring it back. Pick another handle."
        case .profile:
            "Setup refused: the request was not in the tool's shape."
        case .notSaved:
            "Setup refused: OpenBots could not save your profile. Tell the person."
        }
    }
}

/// One `set_up_self` call's arguments: the hire's profile fields, read by the
/// hire's rules, and the switches asked for, each once, in the list's order.
public struct BotSelfSetupRequest: Equatable, Sendable {
    public static let switchesField = "switches"
    public static let fieldNames = TeammateHireRequest.fieldNames + [switchesField]

    public let profileFields: TeammateHireRequest
    public let switches: [BotSetupSwitch]

    public init(profileFields: TeammateHireRequest, switches: [BotSetupSwitch]) {
        self.profileFields = profileFields
        self.switches = BotSetupSwitch.allCases.filter(switches.contains)
    }

    public static func parse(argumentsJSON: Data) -> Result<Self, BotSelfSetupRefusal> {
        guard argumentsJSON.count <= TeammateHireRequest.maximumArgumentsBytes,
              var object = try? JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any],
              object.keys.allSatisfy(fieldNames.contains) else { return .failure(.malformed) }
        var switches: [BotSetupSwitch] = []
        if let value = object.removeValue(forKey: switchesField) {
            guard let names = value as? [Any] else { return .failure(.malformed) }
            for name in names {
                guard let text = name as? String else { return .failure(.malformed) }
                guard let chosen = BotSetupSwitch(rawValue: text) else { return .failure(.unknownSwitch) }
                switches.append(chosen)
            }
        }
        guard let rest = try? JSONSerialization.data(withJSONObject: object) else { return .failure(.malformed) }
        switch TeammateHireRequest.parse(argumentsJSON: rest) {
        case .success(let fields): return .success(Self(profileFields: fields, switches: switches))
        case .failure(.malformed): return .failure(.malformed)
        case .failure(let refusal): return .failure(.profile(refusal))
        }
    }

    /// The switch card's title and words: what the bot wants to
    /// become, what it asks for, and what each button does. The name and the
    /// purpose are the model's words, so the purpose is quoted.
    public var cardTitle: String { "Switches for \(TeammateHireText.oneLine(profileFields.handle))" }

    public func cardDetail(botName: String) -> String {
        let bot = String(TeammateHireText.oneLine(botName).prefix(60))
        let list = BotSetupSwitch.sentenceList(switches)
        return String(("\(bot) wants to become \(TeammateHireText.oneLine(profileFields.handle)): "
            + "\(TeammateHireText.quoted(profileFields.purpose)). For that job it asks for \(list), for this bot only. "
            + "Approve turns \(switches.count == 1 ? "it" : "them") on. Deny sets it up with every switch off; "
            + "you can turn them on later in its Access.").prefix(900))
    }

    /// The same arguments with `switches` replaced: what the call runs as when
    /// the person approved fewer switches than were asked for.
    public static func arguments(_ argumentsJSON: Data, keepingSwitches kept: [BotSetupSwitch]) -> Data? {
        guard var object = try? JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any] else { return nil }
        object[switchesField] = BotSetupSwitch.allCases.filter(kept.contains).map(\.rawValue)
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// What one setup did.
public struct BotSelfSetup: Equatable, Sendable {
    /// The role a new bot carries until it sets itself up. A profile still at
    /// its placeholder name, this role and nothing else written is one the
    /// person has not touched, so the setup may write it.
    public static let placeholderRole = "New bot, waiting to hear what it is for"
    /// The new bot's first message, written by the app when the bot is born:
    /// the question the setup prompt says it already asked.
    public static let firstQuestion = "Hi! I'm new here. What am I for? Tell me in a sentence or two and I'll set myself up."

    /// True while the person has written nothing of the profile: the name is
    /// the placeholder, the role is the placeholder's, and there is no title,
    /// no instructions and no seat. A model or notification choice is not a word.
    public static func isUntouched(_ profile: TeammateProfile, placeholderName: String) -> Bool {
        profile.displayName == placeholderName && profile.role == placeholderRole
            && profile.title == nil && profile.detailedInstructions == nil && profile.seat == nil
    }

    /// The name the bot had before: the placeholder.
    public let previousName: String
    public let name: String
    public let purpose: String
    /// False when the person had already changed the profile: their words stay.
    public let wroteProfile: Bool
    /// The switches turned on for this bot, in the list's order.
    public let turnedOn: [BotSetupSwitch]
    /// Of those, the ones still off for the whole app.
    public let offForTheApp: [BotSetupSwitch]

    public init(previousName: String, name: String, purpose: String, wroteProfile: Bool,
                turnedOn: [BotSetupSwitch], offForTheApp: [BotSetupSwitch]) {
        self.previousName = previousName; self.name = name; self.purpose = purpose
        self.wroteProfile = wroteProfile
        self.turnedOn = BotSetupSwitch.allCases.filter(turnedOn.contains)
        self.offForTheApp = BotSetupSwitch.allCases.filter { offForTheApp.contains($0) && turnedOn.contains($0) }
    }

    /// The tool's result, as the model reads it.
    public var toolResultText: String {
        let name = TeammateHireText.oneLine(name)
        let profile = wroteProfile
            ? "You are set up as \(name): \(TeammateHireText.sentence(purpose))"
            : "The person had already written your profile, so it stays as they wrote it; you are \(name)."
        let switches = turnedOn.isEmpty
            ? " No switch was turned on."
            : " Turned on for you: \(BotSetupSwitch.sentenceList(turnedOn)). They take effect from your next reply."
        let app = offForTheApp.isEmpty ? ""
            : " \(BotSetupSwitch.sentenceList(offForTheApp).capitalizedFirst) \(offForTheApp.count == 1 ? "is" : "are") still off for the whole app, in Settings; say so."
        return profile + switches + app
    }

    /// The one line the conversation gets, written by the app.
    public var noteLine: String {
        let before = TeammateHireText.oneLine(previousName)
        let after = TeammateHireText.oneLine(name)
        var line = wroteProfile
            ? "\(before) set itself up as \(after) (\(TeammateHireText.quoted(purpose)))."
            : "\(after) kept the profile you wrote."
        line += turnedOn.isEmpty ? " No switches turned on."
            : " Turned on for it: \(BotSetupSwitch.sentenceList(turnedOn))."
        if !offForTheApp.isEmpty {
            line += " \(BotSetupSwitch.sentenceList(offForTheApp).capitalizedFirst) \(offForTheApp.count == 1 ? "is" : "are") off for the whole app: turn \(offForTheApp.count == 1 ? "it" : "them") on in Settings."
        }
        return line
    }
}

/// The line the person's own edit of a bot's words leaves in its chat: a later
/// change to a profile is said in the chat. Nil when no word changed:
/// a model, an effort or a notification choice is not a word.
public enum BotProfileChangeNote {
    public static func line(before: TeammateProfile, after: TeammateProfile) -> String? {
        let old = TeammateHireText.oneLine(before.displayName), new = TeammateHireText.oneLine(after.displayName)
        var changed: [String] = []
        if before.title != after.title { changed.append("title") }
        if before.role != after.role { changed.append("role") }
        if before.detailedInstructions != after.detailedInstructions { changed.append("instructions") }
        let list = changed.count > 1 ? changed.dropLast().joined(separator: ", ") + " and " + changed[changed.count - 1]
            : changed.first
        switch (old != new, list) {
        case (false, nil): return nil
        case (true, nil): return "You renamed \(old) to \(new)."
        case (false, let list?): return "You changed \(new)'s \(list)."
        case (true, let list?): return "You renamed \(old) to \(new) and changed its \(list)."
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
