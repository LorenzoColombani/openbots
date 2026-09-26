import Foundation
import OpenBotsContent
import OpenBotsDomain
@testable import OpenBotsPersistence
import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

@Suite("What a bot makes becomes a chip on its reply")
struct ProducedFileDeliveryTests {
    @Test("Only visible items changed since the turn began, in the Outbox, bounded in size, oldest first")
    func outboxScan() throws {
        let home = URL(fileURLWithPath: "/private/tmp/OpenBotsNextOutbox-\(UUID()).noindex/Zed")
        let outbox = home.appending(path: "Outbox")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        let old = outbox.appending(path: "old.txt")
        try Data("old".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: old.path)
        let start = Date()
        try Data("report".utf8).write(to: outbox.appending(path: "report.md"))
        try Data("hidden".utf8).write(to: outbox.appending(path: ".hidden"))
        try FileManager.default.createDirectory(at: outbox.appending(path: "Slides"), withIntermediateDirectories: false)
        try Data("later".utf8).write(to: outbox.appending(path: "notes.txt"))
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(30)], ofItemAtPath: outbox.appending(path: "notes.txt").path)
        try Data("stray".utf8).write(to: home.appending(path: "stray.txt"))
        let items = BotWorkspaceService.producedItems(in: home, since: start).map(\.lastPathComponent)
        #expect(items.contains("report.md") && items.contains("Slides") && items.last == "notes.txt")
        #expect(!items.contains("old.txt") && !items.contains(".hidden") && !items.contains("stray.txt"))
        #expect(BotWorkspaceService.producedItems(in: home.appending(path: "missing"), since: start).isEmpty)
    }

    @Test("A file the reply names by absolute path under the bot's folders is handed over too, once")
    func namedFiles() throws {
        let root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextNamed-\(UUID()).noindex")
        let home = root.appending(path: "Zed"), extra = root.appending(path: "Invoices")
        try FileManager.default.createDirectory(at: home.appending(path: "Outbox"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("summary".utf8).write(to: extra.appending(path: "summary 2026.md"))
        try Data("out".utf8).write(to: home.appending(path: "Outbox/out.md"))
        let access = try ClaudeTextWorkAccess(workingDirectoryURL: home, additionalDirectoryURLs: [extra], protectedPaths: [])
        let text = "Done. I wrote \(extra.path)/summary 2026.md and \(home.path)/Outbox/out.md, see \(extra.path)/summary 2026.md again. \(extra.path)/missing.md is not there."
        let items = OfficialClaudeTextReplyService.producedItems(access: access, text: text, since: Date(timeIntervalSinceNow: -60))
        #expect(items.map(\.lastPathComponent) == ["out.md", "summary 2026.md"])
    }

    // The bot wrote its script in its folder's root and ran it on a card;
    // nothing offered Save.
    @Test("A script a run used is handed over wherever it is under the bot's folders, once, and never from a protected root")
    func ranScriptsAreHandedOver() throws {
        let root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextRan-\(UUID()).noindex")
        let home = root.appending(path: "Zed"), secret = root.appending(path: "Zed/keys")
        try FileManager.default.createDirectory(at: home.appending(path: "Outbox"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = home.appending(path: "list_files_by_date.py"), outboxed = home.appending(path: "Outbox/chart.py")
        try Data("print(1)".utf8).write(to: script)
        try Data("print(2)".utf8).write(to: outboxed)
        try Data("x".utf8).write(to: secret.appending(path: "k.py"))
        let elsewhere = URL(fileURLWithPath: "/private/tmp/OpenBotsNextElsewhere-\(UUID()).py")
        try Data("x".utf8).write(to: elsewhere)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let access = try ClaudeTextWorkAccess(workingDirectoryURL: home, protectedPaths: [secret.path])
        let items = OfficialClaudeTextReplyService.producedItems(access: access, text: "Ran it.",
            since: Date(timeIntervalSinceNow: -60),
            ranScripts: [script.path, script.path, outboxed.path, secret.appending(path: "k.py").path, elsewhere.path,
                         home.appending(path: "missing.py").path])
        #expect(items.map(\.lastPathComponent) == ["chart.py", "list_files_by_date.py"], "\(items.map(\.path))")
    }

    /// A folder that holds a protected root, as
    /// Pictures holds the Photos library, can be granted. The app reads what a
    /// reply names with its own Full Disk Access, so a path into the root,
    /// spelled directly, through a symlink or by another spelling of the
    /// same place, is never handed over.
    @Test("A file the reply names inside a protected root under a granted folder is never handed over")
    func namedFilesSkipProtectedRoots() throws {
        let name = "OpenBotsNextProtected-\(UUID()).noindex"
        let root = URL(fileURLWithPath: "/private/tmp/\(name)")
        let home = root.appending(path: "Zed"), pictures = root.appending(path: "Pictures")
        let library = pictures.appending(path: "Photos Library.photoslibrary")
        try FileManager.default.createDirectory(at: home.appending(path: "Outbox"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library.appending(path: "database"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("db".utf8).write(to: library.appending(path: "database/Photos.sqlite"))
        try Data("fine".utf8).write(to: pictures.appending(path: "holiday.txt"))
        try FileManager.default.createSymbolicLink(atPath: pictures.appending(path: "shortcut").path,
                                                   withDestinationPath: library.path)
        // The root is written the way /tmp spells it, the granted folder the
        // way it resolves: only a comparison of every spelling sees them meet.
        let access = try ClaudeTextWorkAccess(workingDirectoryURL: home, additionalDirectoryURLs: [pictures],
                                              protectedPaths: ["/tmp/\(name)/Pictures/Photos Library.photoslibrary"])
        let text = "See \(library.path)/database/Photos.sqlite, \(pictures.path)/shortcut/database/Photos.sqlite "
            + "and \(pictures.path)/holiday.txt."
        let items = OfficialClaudeTextReplyService.producedItems(access: access, text: text, since: Date(timeIntervalSinceNow: -60))
        #expect(items.map(\.lastPathComponent) == ["holiday.txt"], "\(items.map(\.path))")
        // The deny rule of the file tools reads the same spellings.
        #expect(ClaudeTextWorkApprovalPolicy.isDenied("/System/Volumes/Data\(library.path)/database/Photos.sqlite", access: access))
        #expect(!ClaudeTextWorkApprovalPolicy.isDenied("/System/Volumes/Data\(pictures.path)/holiday.txt", access: access))
    }

    @Test("A produced asset links to the bot's saved reply after its text, off the draft, and the turn still reads back")
    func linkToReply() async throws {
        let f = try TextRecoveryFixture(); defer { f.remove() }
        let store = try f.open()
        let begun = try await f.seedPending(store, hasSession: true, partial: nil)
        let submitted = try await store.checkpointTextTurn(id: begun.run.id, expectedRevision: begun.run.revision,
            token: f.token, text: "", inputEvidence: .submitted, now: f.at(1))
        let acknowledged = try await store.checkpointTextTurn(id: begun.run.id, expectedRevision: submitted.run.revision,
            token: f.token, text: "Here it is.\n\nThe report is in the Outbox.", inputEvidence: .acknowledged, now: f.at(1))
        let finished = try await store.finishTextTurn(id: begun.run.id, expectedRevision: acknowledged.run.revision,
            token: f.token, text: "Here it is.\n\nThe report is in the Outbox.", outcome: .succeeded, diagnosticCode: nil, now: f.at(2))
        #expect(finished.run.state == .succeeded)
        let replyID = try #require(finished.run.request.textTurnIdentity?.replyMessageID)
        let asset = try AttachmentAsset(id: AttachmentID(UUID()), conversationID: f.chat, displayName: "report.md",
            typeIdentifier: "net.daringfireball.markdown", byteCount: 6, sha256: String(repeating: "a", count: 64), createdAt: f.at(3))
        try await store.attachProducedAssets([asset], toReply: replyID, conversationID: f.chat)
        let reply = try #require(try await store.message(id: replyID))
        #expect(reply.parts.count == 2)
        #expect(reply.parts[1].content == .attachment(asset.id) && reply.parts[1].ordinal == 1)
        #expect(try await store.draft(conversationID: f.chat).attachments.isEmpty)
        #expect(try await store.attachment(id: asset.id, conversationID: f.chat) == asset)
        // The turn's own reader still sees its text and nothing else.
        let again = try #require(try await store.run(id: begun.run.id))
        #expect(again.state == .succeeded)
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).isEmpty)
        let provenance = try await store.textTurnProvenance(conversationID: f.chat, messageIDs: [replyID])
        #expect(provenance.count == 1)
        // A second link of the same asset onto the same reply is refused, and so
        // is a different record under a known id; a user message never takes a chip this way.
        await #expect(throws: AttachmentRepositoryError.invalidExchange) {
            try await store.attachProducedAssets([asset], toReply: replyID, conversationID: f.chat)
        }
        let renamed = try AttachmentAsset(id: asset.id, conversationID: f.chat, displayName: "other.md",
            typeIdentifier: asset.typeIdentifier, byteCount: asset.byteCount, sha256: asset.sha256, createdAt: asset.createdAt)
        await #expect(throws: AttachmentRepositoryError.assetCollision) {
            try await store.attachProducedAssets([renamed], toReply: replyID, conversationID: f.chat)
        }
        let userID = finished.run.request.initiatingMessageID
        let other = try AttachmentAsset(id: AttachmentID(UUID()), conversationID: f.chat, displayName: "x.txt",
            typeIdentifier: "public.plain-text", byteCount: 1, sha256: String(repeating: "b", count: 64), createdAt: f.at(4))
        await #expect(throws: AttachmentRepositoryError.invalidExchange) {
            try await store.attachProducedAssets([other], toReply: userID, conversationID: f.chat)
        }
        #expect(try await store.attachment(id: other.id, conversationID: f.chat) == nil)
    }
}
