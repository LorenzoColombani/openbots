import Foundation
import OpenBotsDomain
import OpenBotsPersistence
import Testing
@testable import OpenBotsServices

@Suite("Per-bot Markdown conversation export")
struct ConversationExportServiceTests {
    @Test("One export writes exactly a README, a transcript and metadata, with escaped and labelled content")
    func exportsOneConversation() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.provision(store, title: "Daily plan")
        try await fixture.append(store, sequence: 1, author: .user, delivery: .completed, parts: [
            .text("# not a heading\n- not a bullet\nplain closing line")
        ])
        try await fixture.append(store, sequence: 2, author: .teammate(fixture.bot), delivery: .completed, parts: [
            .text("First reply part."), .text("Second reply part.")
        ])
        try await fixture.append(store, sequence: 3, author: .system, delivery: .completed, parts: [
            .status("Waiting for Claude's reply.")
        ])
        try await fixture.append(store, sequence: 4, author: .user, delivery: .pending, parts: [
            .text("Still going out.")
        ])

        let receipt = try await fixture.service(store).export(fixture.request)

        #expect(receipt.conversationCount == 1)
        #expect(receipt.messageCount == 4)
        #expect(receipt.exportedAt == fixture.date)
        let transcriptName = "transcript-\(fixture.chat.persistedValue.prefix(8)).md"
        #expect(receipt.files == ["README.md", transcriptName, "metadata.json"])
        #expect(receipt.folderURL.lastPathComponent.hasPrefix("OpenBots Export - Ada Export - "))

        // Exactly one new folder, holding exactly the three named files.
        #expect(try fixture.entries(of: fixture.destination) == [receipt.folderURL.lastPathComponent])
        #expect(try fixture.entries(of: receipt.folderURL) == receipt.files.sorted())
        #expect(try fixture.permissions(of: receipt.folderURL) == 0o700)
        for file in receipt.files {
            #expect(try fixture.permissions(of: receipt.folderURL.appendingPathComponent(file)) == 0o600)
        }

        let transcript = try fixture.read(transcriptName, in: receipt.folderURL)
        let lines = transcript.components(separatedBy: "\n")
        #expect(lines.first == "# Ada Export - Daily plan")
        #expect(lines.contains("\\# not a heading"))
        #expect(lines.contains("\\- not a bullet"))
        #expect(!lines.contains("# not a heading"))
        #expect(!lines.contains("- not a bullet"))
        #expect(lines.contains("plain closing line"))
        #expect(lines.contains("First reply part.") && lines.contains("Second reply part."))
        #expect(lines.contains("> Status: Waiting for Claude's reply."))
        #expect(lines.filter { $0 == "> Delivery: pending" }.count == 1)
        #expect(lines.filter { $0.hasPrefix("> Delivery:") }.count == 1)
        #expect(lines.filter { $0.hasPrefix("### You · ") }.count == 2)
        #expect(lines.filter { $0.hasPrefix("### Ada Export · ") }.count == 1)
        #expect(lines.filter { $0.hasPrefix("### OpenBots · ") }.count == 1)

        let readme = try fixture.read("README.md", in: receipt.folderURL)
        #expect(readme.contains("Ada Export"))
        #expect(readme.contains(transcriptName))
        #expect(readme.contains("Attachments, secrets and memory documents are not included in this export."))

        let metadata = try fixture.metadata(in: receipt.folderURL)
        #expect(metadata["formatVersion"] as? Int == 1)
        let counts = try #require(metadata["counts"] as? [String: Any])
        #expect(counts["conversations"] as? Int == 1 && counts["messages"] as? Int == 4)
        let teammate = try #require(metadata["teammate"] as? [String: Any])
        #expect(teammate["displayName"] as? String == "Ada Export")
        #expect(teammate["id"] as? String == fixture.bot.persistedValue)
        #expect(teammate["lifecycle"] as? String == "active")
        let conversations = try #require(metadata["conversations"] as? [[String: Any]])
        #expect(conversations.count == 1)
        #expect(conversations[0]["id"] as? String == fixture.chat.persistedValue)
        #expect(conversations[0]["kind"] as? String == "direct")
        #expect(conversations[0]["title"] as? String == "Daily plan")
        #expect(conversations[0]["messageCount"] as? Int == 4)
        #expect(conversations[0]["file"] as? String == transcriptName)
    }

    @Test("A second export in the same minute steps the folder name and leaves the first untouched")
    func secondExportStepsTheFolderName() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.provision(store, title: "Daily plan")
        try await fixture.append(store, sequence: 1, author: .user, delivery: .completed, parts: [
            .text("Only message.")
        ])
        let service = fixture.service(store)

        let first = try await service.export(fixture.request)
        let base = first.folderURL.lastPathComponent
        let before = try fixture.read("README.md", in: first.folderURL)

        let second = try await service.export(fixture.request)
        #expect(second.folderURL.lastPathComponent == "\(base) (2)")
        #expect(second.folderURL != first.folderURL)
        #expect(second.conversationCount == 1 && second.messageCount == 1)
        #expect(try fixture.permissions(of: second.folderURL) == 0o700)
        #expect(try fixture.entries(of: second.folderURL) == second.files.sorted())

        // The earlier export keeps its own folder, contents and permissions.
        #expect(try fixture.read("README.md", in: first.folderURL) == before)
        #expect(try fixture.entries(of: first.folderURL) == first.files.sorted())
        #expect(try fixture.entries(of: fixture.destination) == [base, "\(base) (2)"].sorted())

        let third = try await service.export(fixture.request)
        #expect(third.folderURL.lastPathComponent == "\(base) (3)")
        #expect(try fixture.entries(of: fixture.destination).count == 3)
    }

    @Test("Stepping gives up at its bound and refuses rather than looping")
    func steppingGivesUpAtItsBound() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.provision(store, title: "Daily plan")
        try await fixture.append(store, sequence: 1, author: .user, delivery: .completed, parts: [
            .text("Only message.")
        ])
        let service = fixture.service(store)

        let first = try await service.export(fixture.request)
        let base = first.folderURL.lastPathComponent
        let limit = ConversationExportService.folderNameAttemptLimit
        // Take every remaining name the stepper is willing to try.
        for attempt in 2...limit {
            try FileManager.default.createDirectory(
                at: fixture.destination.appendingPathComponent("\(base) (\(attempt))", isDirectory: true),
                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
        }

        await #expect(throws: ConversationExportError.destinationExists) {
            try await service.export(fixture.request)
        }
        #expect(try fixture.entries(of: fixture.destination).count == limit)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.destination.appendingPathComponent("\(base) (\(limit + 1))").path
        ))
    }

    @Test("An unknown bot is refused before anything is created")
    func unknownTeammateCreatesNothing() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.provision(store, title: "Daily plan")

        await #expect(throws: ConversationExportError.teammateNotFound) {
            try await fixture.service(store).export(ConversationExportRequest(
                teammateID: TeammateID(UUID()), destinationFolder: fixture.destination
            ))
        }
        #expect(try fixture.entries(of: fixture.destination).isEmpty)
    }

    @Test("A conversation longer than one page exports every message in order")
    func pagesLongConversationInOrder() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.provision(store, title: "Long thread")
        for sequence in 1...450 {
            try await fixture.append(
                store, sequence: Int64(sequence), author: sequence.isMultiple(of: 2) ? .teammate(fixture.bot) : .user,
                delivery: .completed, parts: [.text("Sequenced message \(sequence)")]
            )
        }

        let receipt = try await fixture.service(store).export(fixture.request)
        #expect(receipt.messageCount == 450)

        let transcript = try fixture.read(
            "transcript-\(fixture.chat.persistedValue.prefix(8)).md", in: receipt.folderURL
        )
        let prefix = "Sequenced message "
        let observed = transcript.components(separatedBy: "\n").compactMap { line -> Int? in
            guard line.hasPrefix(prefix) else { return nil }
            return Int(line.dropFirst(prefix.count))
        }
        #expect(observed == Array(1...450))

        let conversations = try #require(fixture.metadata(in: receipt.folderURL)["conversations"] as? [[String: Any]])
        #expect(conversations.first?["messageCount"] as? Int == 450)
    }
}

/// A disposable SQLite store plus a disposable destination folder. Both live
/// under one `.noindex` root that is removed when the test ends.
private struct ExportFixture: Sendable {
    let root: URL
    let destination: URL
    let protection: ProtectionDecisionReceipt
    let bot = TeammateID(UUID())
    let chat = ConversationID(UUID())
    let date = Date(timeIntervalSince1970: 1_760_000_000)

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextExport-\(UUID()).noindex", isDirectory: true)
        destination = root.appendingPathComponent("Destination", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(
            fileURL: root.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: protection)
        ))
    }

    var request: ConversationExportRequest {
        ConversationExportRequest(teammateID: bot, destinationFolder: destination)
    }

    func service(_ store: SQLiteStore) -> ConversationExportService {
        let stamp = date
        return ConversationExportService(
            teammates: store, conversations: store, messages: store, clock: { stamp }
        )
    }

    func provision(_ store: SQLiteStore, title: String?) async throws {
        let teammate = try Teammate(
            id: bot,
            profile: TeammateProfile(displayName: "Ada Export", role: "Research partner"),
            appearance: AgentAppearance(
                mode: .creature, grammarVersion: 1, deterministicSeed: 9, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest",
                accessibleIdentityDescription: "Round creature with a crest"
            ),
            createdAt: date, updatedAt: date
        )
        try await store.provisionDirectChat(
            teammate: teammate,
            conversation: Conversation(
                id: chat, kind: .direct(teammateID: bot), title: title, createdAt: date, updatedAt: date
            ),
            fixtureGreeting: nil,
            selectConversation: false
        )
    }

    func append(
        _ store: SQLiteStore,
        sequence: Int64,
        author: MessageAuthor,
        delivery: MessageDeliveryState,
        parts: [MessagePartContent]
    ) async throws {
        let stamped = date.addingTimeInterval(TimeInterval(sequence))
        try await store.append(
            Message(
                id: MessageID(UUID()), conversationID: chat, sequence: sequence, author: author,
                deliveryState: delivery,
                parts: try parts.enumerated().map { index, content in
                    try MessagePart(id: MessagePartID(UUID()), ordinal: index, content: content)
                },
                createdAt: stamped, updatedAt: stamped
            ),
            expectedPreviousSequence: sequence - 1
        )
    }

    func entries(of folderURL: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folderURL.path).sorted()
    }

    func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func read(_ name: String, in folderURL: URL) throws -> String {
        try String(contentsOf: folderURL.appendingPathComponent(name), encoding: .utf8)
    }

    func metadata(in folderURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: folderURL.appendingPathComponent("metadata.json"))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
