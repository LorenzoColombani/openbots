import Foundation

/// The conversations one bot may read through the app's Messages connector.
///
/// The ported connector read across every conversation, so a bot holding it
/// read the user's whole history and whoever texted them wrote into that
/// bot's input. Now a bot reads only the chats the user names for it, chosen in the
/// app and enforced in the server on every read. An empty list reads nothing.
///
/// A chat is named by Messages' own `chat.guid` and nothing else: the one value
/// the app reads when it lists the user's conversations and the one the server
/// compares when it reads, byte for byte. A handle, a display name or a
/// last-nine-digits match would each be a second matching rule, and the card
/// and the server drifting apart on a second rule is this repo's most repeated
/// defect (it happened on the mail card).
public struct AppleMessagesChatScope: Codable, Equatable, Hashable, Sendable {
    /// The variable the server reads the list from.
    public static let environmentKey = "OPENBOTS_MESSAGES_CHATS"
    /// The most chats one bot may read. Bounded so the list always fits the
    /// launch's environment, whose values are capped at 4,096 bytes: 32 guids of
    /// at most 80 bytes each, JSON-quoted, come to at most 2,658 bytes before
    /// base64 and 3,544 after.
    public static let maximumChats = 32
    /// The longest guid that can be chosen. Real guids are well under
    /// this.
    public static let maximumGUIDBytes = 80

    /// Sorted and without repeats, so two lists naming the same chats are one.
    public let guids: [String]

    public init(guids: [String]) {
        self.guids = Array(Set(guids)).sorted()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(guids: try container.decode([String].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(guids)
    }

    public var isEmpty: Bool { guids.isEmpty }

    /// Whether a conversation can be named at all: not empty, short enough to
    /// fit, and free of the control characters no guid Messages writes has.
    public static func isChoosable(_ guid: String) -> Bool {
        !guid.isEmpty && guid.utf8.count <= maximumGUIDBytes
            && guid.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0x80...0x9F).contains($0.value) }
    }

    public var isValid: Bool {
        guids.count <= Self.maximumChats && guids.allSatisfy(Self.isChoosable)
    }

    /// The list as the server receives it: the guids as a JSON array, in
    /// base64. Base64 because a launch's environment refuses a value carrying
    /// `${` or a backtick, and a guid is Messages' text, not the app's; any
    /// guid at all travels whole this way, and the server refuses anything
    /// that is not this exact shape.
    public var environmentValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // An array of strings always encodes.
        let json = (try? encoder.encode(guids)) ?? Data("[]".utf8)
        return json.base64EncodedString()
    }
}

/// One conversation in the user's Messages history, as the app lists it for
/// them to choose from. Nothing in it is a message: the list names conversations, and
/// only a bot's server, on a read the user allowed, opens what was said.
public struct MessagesConversation: Equatable, Identifiable, Sendable {
    public var id: String { guid }
    /// Messages' own `chat.guid`, exactly as stored: what a bot's list names.
    public let guid: String
    /// The address or sender a one-to-one conversation is filed under, or the
    /// `chat<digits>` id of a group.
    public let identifier: String
    /// The name a group was given, when it has one.
    public let displayName: String?
    public let isGroup: Bool
    /// When the newest message this Mac keeps in it was sent or received; nil
    /// when it keeps none (true of most conversations).
    public let lastMessageAt: Date?
    /// The addresses of the people in it, sorted.
    public let memberAddresses: [String]

    public init(guid: String, identifier: String, displayName: String?, isGroup: Bool,
                lastMessageAt: Date?, memberAddresses: [String]) {
        self.guid = guid; self.identifier = identifier; self.displayName = displayName
        self.isGroup = isGroup; self.lastMessageAt = lastMessageAt; self.memberAddresses = memberAddresses
    }
}
