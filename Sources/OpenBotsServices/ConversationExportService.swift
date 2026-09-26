import Foundation
#if canImport(Darwin)
import Darwin
#endif
import OpenBotsDomain

/// Names one bot whose saved direct chats are copied out, and the user-chosen
/// folder that will receive exactly one new export folder.
public struct ConversationExportRequest: Sendable {
    public let teammateID: TeammateID
    public let destinationFolder: URL

    public init(teammateID: TeammateID, destinationFolder: URL) {
        self.teammateID = teammateID
        self.destinationFolder = destinationFolder
    }
}

/// Immutable proof of what one completed export wrote. `files` holds plain file
/// names, never paths, so a receipt can be shown or stored without disclosing
/// where the user's folders live.
public struct ConversationExportReceipt: Codable, Equatable, Sendable {
    public let folderURL: URL
    public let conversationCount: Int
    public let messageCount: Int
    public let files: [String]
    public let exportedAt: Date

    public init(
        folderURL: URL,
        conversationCount: Int,
        messageCount: Int,
        files: [String],
        exportedAt: Date
    ) {
        self.folderURL = folderURL
        self.conversationCount = conversationCount
        self.messageCount = messageCount
        self.files = files
        self.exportedAt = exportedAt
    }
}

public enum ConversationExportError: Error, Equatable, Sendable {
    /// The named bot is not in the roster. Nothing is created for it.
    case teammateNotFound
    /// The exact export folder already exists. An export never writes into,
    /// merges with, or overwrites an existing folder.
    case destinationExists
    case destinationNotWritable
    /// An unexpected `mkdir(2)` failure, kept exact instead of relabelled.
    case destinationUnusable(code: Int32)
    case fileWriteFailed(name: String)
}

/// Copies one bot's saved direct chats into a new folder of plain Markdown plus
/// one machine-readable index.
///
/// The export is deliberately a text copy of what the user already sees in the
/// chat. Attachment bytes, secrets and memory documents are out of scope: an
/// attachment or artifact part becomes a labelled placeholder line so a reader
/// can tell that something existed there without the export carrying it.
public struct ConversationExportService: Sendable {
    /// One page per query. A long chat is read in bounded pages, never in a
    /// single unbounded statement.
    static let messagePageLimit = 200

    /// How many folder names one export may try before refusing. A bound keeps
    /// a wedged destination from becoming an unbounded loop of `mkdir` calls.
    static let folderNameAttemptLimit = 32

    private let teammates: any TeammateRepository
    private let conversations: any ConversationRepository
    private let messages: any MessageRepository
    private let clock: @Sendable () -> Date

    public init(
        teammates: any TeammateRepository,
        conversations: any ConversationRepository,
        messages: any MessageRepository,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.teammates = teammates
        self.conversations = conversations
        self.messages = messages
        self.clock = clock
    }

    public func export(_ request: ConversationExportRequest) async throws -> ConversationExportReceipt {
        // The roster lookup precedes every filesystem effect so an unknown bot
        // leaves the user's chosen folder untouched.
        guard let teammate = try await teammates.teammate(id: request.teammateID) else {
            throw ConversationExportError.teammateNotFound
        }
        let exportedAt = clock()
        let planned = try await plannedConversations(for: request.teammateID)

        let folderURL = try Self.createExportFolder(
            in: request.destinationFolder,
            baseName: Self.folderName(displayName: teammate.profile.displayName, exportedAt: exportedAt)
        )

        var summaries: [ConversationExportSummary] = []
        var messageCount = 0
        for plan in planned {
            let history = try await loadMessages(conversationID: plan.conversation.id)
            messageCount += history.count
            try Self.write(
                Self.transcript(
                    teammate: teammate,
                    conversation: plan.conversation,
                    messages: history,
                    exportedAt: exportedAt
                ),
                named: plan.fileName,
                in: folderURL
            )
            summaries.append(ConversationExportSummary(
                conversation: plan.conversation,
                fileName: plan.fileName,
                messageCount: history.count
            ))
        }

        let files = [Self.readmeFileName] + planned.map(\.fileName) + [Self.metadataFileName]
        try Self.write(
            Self.readme(
                teammate: teammate,
                summaries: summaries,
                files: files,
                messageCount: messageCount,
                exportedAt: exportedAt
            ),
            named: Self.readmeFileName,
            in: folderURL
        )
        let metadataJSON = try Self.metadata(
            teammate: teammate,
            summaries: summaries,
            messageCount: messageCount,
            exportedAt: exportedAt
        )
        try Self.write(metadataJSON, named: Self.metadataFileName, in: folderURL)

        return ConversationExportReceipt(
            folderURL: folderURL,
            conversationCount: summaries.count,
            messageCount: messageCount,
            files: files,
            exportedAt: exportedAt
        )
    }

    // MARK: - Reading

    /// Every direct chat this bot still participates in, archived included, in a
    /// stable oldest-first order with its transcript file name already claimed.
    private func plannedConversations(
        for teammateID: TeammateID
    ) async throws -> [PlannedConversation] {
        let all = try await conversations.conversations(for: teammateID, includingArchived: true)
        let direct = all
            .filter { conversation in
                if case let .direct(owner) = conversation.kind { return owner == teammateID }
                return false
            }
            .sorted { left, right in
                if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
                return left.id.persistedValue < right.id.persistedValue
            }

        var claimed: Set<String> = []
        return direct.map { conversation in
            let identifier = conversation.id.persistedValue
            let short = "transcript-\(identifier.prefix(8)).md"
            // A short identifier is a convenience, not an identity. A collision
            // falls back to the full one rather than overwriting a transcript.
            let name = claimed.contains(short) ? "transcript-\(identifier).md" : short
            claimed.insert(name)
            return PlannedConversation(conversation: conversation, fileName: name)
        }
    }

    /// Reads one chat in bounded pages. The repository only pages backwards, so
    /// the pages are gathered newest-first and then reversed into reading order.
    private func loadMessages(conversationID: ConversationID) async throws -> [Message] {
        var pages: [[Message]] = []
        var beforeSequence: Int64?
        while true {
            let page = try await messages.page(
                conversationID: conversationID,
                request: PageRequest(limit: Self.messagePageLimit, beforeSequence: beforeSequence)
            )
            pages.append(page.elements)
            guard page.hasMore, let oldest = page.elements.first?.sequence else { break }
            beforeSequence = oldest
        }
        return pages.reversed().flatMap { $0 }
    }

    // MARK: - Rendering

    static let readmeFileName = "README.md"
    static let metadataFileName = "metadata.json"

    private static func transcript(
        teammate: Teammate,
        conversation: Conversation,
        messages: [Message],
        exportedAt: Date
    ) -> String {
        let botName = singleLine(teammate.profile.displayName)
        let title = conversation.title.map(singleLine) ?? "Untitled conversation"
        var lines = [
            "# \(botName) - \(title)",
            "",
            "Exported \(iso8601(exportedAt)). Attachments, secrets and memory documents are not included.",
            ""
        ]
        for message in messages {
            lines.append("### \(author(of: message, teammate: teammate)) · \(iso8601(message.createdAt))")
            lines.append("")
            // A partial or unknown outcome is labelled rather than dropped, so a
            // reader never mistakes an unsent message for a delivered one.
            if message.deliveryState != .completed {
                lines.append("> Delivery: \(message.deliveryState.rawValue)")
                lines.append("")
            }
            for part in message.parts {
                switch part.content {
                case let .text(text):
                    lines.append(contentsOf: text.components(separatedBy: .newlines).map(escaped))
                case let .status(text):
                    lines.append(contentsOf: blockquote("Status: \(text)"))
                case let .attachment(id):
                    lines.append("> Attachment (not exported): \(id.persistedValue)")
                case let .artifact(id):
                    lines.append("> Artifact (not exported): \(id.persistedValue)")
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func readme(
        teammate: Teammate,
        summaries: [ConversationExportSummary],
        files: [String],
        messageCount: Int,
        exportedAt: Date
    ) -> String {
        var lines = [
            "# OpenBots export",
            "",
            "A plain-text copy of the saved conversations with \(singleLine(teammate.profile.displayName)).",
            "It is a readable snapshot, not a backup you can load back into the app.",
            "",
            "- Bot: \(singleLine(teammate.profile.displayName))",
            "- Role: \(singleLine(teammate.profile.role))",
            "- Exported: \(iso8601(exportedAt))",
            "- Conversations: \(summaries.count)",
            "- Messages: \(messageCount)",
            "",
            "## Files",
            ""
        ]
        for file in files {
            switch file {
            case readmeFileName:
                lines.append("- \(file) - this note.")
            case metadataFileName:
                lines.append("- \(file) - the same conversation list in machine-readable form.")
            default:
                let title = summaries.first { $0.fileName == file }?.title ?? "Untitled conversation"
                lines.append("- \(file) - \(title).")
            }
        }
        lines.append(contentsOf: [
            "",
            "Attachments, secrets and memory documents are not included in this export.",
            ""
        ])
        return lines.joined(separator: "\n")
    }

    private static func metadata(
        teammate: Teammate,
        summaries: [ConversationExportSummary],
        messageCount: Int,
        exportedAt: Date
    ) throws -> String {
        let document = ExportMetadataDocument(
            formatVersion: 1,
            exportedAt: iso8601(exportedAt),
            teammate: ExportMetadataTeammate(
                id: teammate.id.persistedValue,
                displayName: teammate.profile.displayName,
                role: teammate.profile.role,
                lifecycle: teammate.lifecycle.rawValue,
                createdAt: iso8601(teammate.createdAt)
            ),
            conversations: summaries.map { summary in
                ExportMetadataConversation(
                    id: summary.conversation.id.persistedValue,
                    title: summary.conversation.title,
                    kind: kindName(summary.conversation.kind),
                    createdAt: iso8601(summary.conversation.createdAt),
                    updatedAt: iso8601(summary.conversation.updatedAt),
                    messageCount: summary.messageCount,
                    file: summary.fileName
                )
            },
            counts: ExportMetadataCounts(conversations: summaries.count, messages: messageCount)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let json = String(data: try encoder.encode(document), encoding: .utf8) else {
            throw ConversationExportError.fileWriteFailed(name: metadataFileName)
        }
        return json + "\n"
    }

    private static func author(of message: Message, teammate: Teammate) -> String {
        switch message.author {
        case .user:
            "You"
        case let .teammate(id):
            id == teammate.id ? singleLine(teammate.profile.displayName) : "Teammate \(id.persistedValue)"
        case .system:
            "OpenBots"
        }
    }

    private static func kindName(_ kind: ConversationKind) -> String {
        switch kind {
        case .direct: "direct"
        case .project: "project"
        case .team: "team"
        }
    }

    /// Keeps a multi-line status readable as one quoted block instead of letting
    /// its later lines escape the annotation.
    private static func blockquote(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { "> \($0)" }
    }

    /// Escapes only what would turn one line of the user's own words into
    /// transcript structure: a heading, a list item, a quoted annotation, or a
    /// fence that would swallow everything after it.
    private static func escaped(_ line: String) -> String {
        let bodyStart = line.firstIndex { $0 != " " && $0 != "\t" } ?? line.endIndex
        let indent = String(line[line.startIndex..<bodyStart])
        let body = String(line[bodyStart...])
        guard let first = body.first else { return line }

        if first == "#" || first == ">" { return indent + "\\" + body }
        if first == "`" || first == "~" {
            return body.prefix(3).allSatisfy { $0 == first } ? indent + "\\" + body : line
        }
        if first == "-" || first == "*" || first == "+" {
            return startsListItem(body.dropFirst()) ? indent + "\\" + body : line
        }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let marker = body.dropFirst(digits.count)
            if let punctuation = marker.first, punctuation == "." || punctuation == ")",
               startsListItem(marker.dropFirst()) {
                return indent + digits + "\\" + marker
            }
        }
        return line
    }

    private static func startsListItem(_ remainder: Substring) -> Bool {
        guard let next = remainder.first else { return true }
        return next == " " || next == "\t"
    }

    /// A stored name or title is trusted text, but it is still one line of it.
    private static func singleLine(_ value: String) -> String {
        value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func folderName(displayName: String, exportedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "OpenBots Export - \(sanitised(displayName)) - \(formatter.string(from: exportedAt))"
    }

    /// Letters, digits, space, dash and underscore only. Everything else is
    /// dropped so a display name can never introduce a path component, a hidden
    /// file, or a shell-significant character.
    private static func sanitised(_ displayName: String) -> String {
        let kept = displayName.map { character -> Character in
            let allowed = character.isLetter || character.isNumber
                || character == " " || character == "-" || character == "_"
            return allowed ? character : " "
        }
        let collapsed = String(kept)
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        return trimmed.isEmpty ? "Bot" : trimmed
    }

    // MARK: - Writing

    /// Claims a new folder for this export, stepping the name when one is taken.
    ///
    /// The stamp only resolves to the minute, and two bots can share a display
    /// name, so a second export a few seconds later would otherwise collide.
    /// Stepping keeps both exports rather than refusing the newer one. Every
    /// attempt is an exclusive create, so a taken name is skipped, never
    /// entered, merged with or overwritten.
    private static func createExportFolder(in destination: URL, baseName: String) throws -> URL {
        for attempt in 1...folderNameAttemptLimit {
            let name = attempt == 1 ? baseName : "\(baseName) (\(attempt))"
            let candidate = destination.appendingPathComponent(name, isDirectory: true)
            if try createFolderIfAbsent(at: candidate) { return candidate }
        }
        throw ConversationExportError.destinationExists
    }

    /// Returns false when the folder already exists, so the caller can step the
    /// name. `mkdir(2)` is used directly because checking for absence and then
    /// creating is two steps, and only the kernel can make them one.
    private static func createFolderIfAbsent(at folderURL: URL) throws -> Bool {
        let outcome: Int32 = folderURL.withUnsafeFileSystemRepresentation { representation in
            guard let representation else { return EINVAL }
            return mkdir(representation, 0o700) == 0 ? 0 : errno
        }
        switch outcome {
        case 0:
            break
        case EEXIST:
            return false
        case EACCES, EPERM, EROFS, ENOENT, ENOTDIR, ENAMETOOLONG:
            throw ConversationExportError.destinationNotWritable
        default:
            throw ConversationExportError.destinationUnusable(code: outcome)
        }
        // `mkdir` applies the process umask, so the mode is set explicitly.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: folderURL.path
        )
        return true
    }

    private static func write(_ contents: String, named name: String, in folderURL: URL) throws {
        let fileURL = folderURL.appendingPathComponent(name, isDirectory: false)
        do {
            // Exclusive create, so a name collision fails loudly instead of
            // replacing a transcript this same export already wrote.
            try Data(contents.utf8).write(to: fileURL, options: [.withoutOverwriting])
        } catch {
            throw ConversationExportError.fileWriteFailed(name: name)
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

private struct PlannedConversation: Sendable {
    let conversation: Conversation
    let fileName: String
}

private struct ConversationExportSummary: Sendable {
    let conversation: Conversation
    let fileName: String
    let messageCount: Int

    var title: String { conversation.title ?? "Untitled conversation" }
}

private struct ExportMetadataDocument: Codable {
    let formatVersion: Int
    let exportedAt: String
    let teammate: ExportMetadataTeammate
    let conversations: [ExportMetadataConversation]
    let counts: ExportMetadataCounts
}

private struct ExportMetadataTeammate: Codable {
    let id: String
    let displayName: String
    let role: String
    let lifecycle: String
    let createdAt: String
}

private struct ExportMetadataConversation: Codable {
    let id: String
    let title: String?
    let kind: String
    let createdAt: String
    let updatedAt: String
    let messageCount: Int
    let file: String
}

private struct ExportMetadataCounts: Codable {
    let conversations: Int
    let messages: Int
}
