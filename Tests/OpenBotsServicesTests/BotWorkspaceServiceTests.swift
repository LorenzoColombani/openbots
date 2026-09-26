import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsRuntime
@testable import OpenBotsPersistence
@testable import OpenBotsServices
import Testing

@Suite("Each bot gets a folder of its own, plus the folders the user adds")
struct BotWorkspaceServiceTests {
    private struct Fixture: Sendable {
        let root: URL
        let layout: PreviewStorageLayout
        let protection: ProtectionDecisionReceipt
        let now = Date(timeIntervalSince1970: 9_000)

        init() throws {
            root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextWorkspace-\(UUID()).noindex", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            layout = PreviewStorageLayout(homeDirectory: root.appending(path: "home"),
                systemTemporaryDirectory: root.appending(path: "tmp"))
            protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
            try FileManager.default.createDirectory(at: layout.homeDirectory, withIntermediateDirectories: true)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func store() throws -> SQLiteStore {
            try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: root.appending(path: "control.sqlite"),
                protection: .ordinarySQLite(decision: protection)))
        }
        func bot(named name: String, in store: SQLiteStore) async throws -> Teammate {
            let teammate = try Teammate(id: TeammateID(UUID()), profile: TeammateProfile(displayName: name, role: "Teammate"),
                appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 3, silhouette: "round",
                    paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "crest",
                    accessibleIdentityDescription: "Round creature"), createdAt: now, updatedAt: now)
            try await store.insert(teammate)
            return teammate
        }
    }

    @Test("The first use creates Bots/<name> under the content root and keeps it; a namesake gets a number")
    func homeFolder() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        let yogurt = try await f.bot(named: "Yogurt", in: store)
        let service = BotWorkspaceService(layout: f.layout, repository: store, teammates: store)
        let first = try await service.workspace(teammateID: yogurt.id)
        #expect(first.homeURL.path == f.layout.contentRoot.url.appending(path: "Bots/Yogurt").path)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: first.homeURL.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(try await service.workspace(teammateID: yogurt.id) == first)
        #expect(try await store.loadBotWorkspace(teammateID: yogurt.id)?.homePath == first.homeURL.path)
        // A namesake saved before two bots could no longer share a name: the
        // store refuses a second Yogurt now, so the old row is made by hand.
        let twin = try await f.bot(named: "Yogurt twin", in: store)
        _ = try await store.execute(sql: "UPDATE teammates SET display_name='Yogurt' WHERE id=?;",
                                    bindings: [.text(twin.id.persistedValue)])
        let second = try await service.workspace(teammateID: twin.id)
        #expect(second.homeURL.lastPathComponent == "Yogurt 2")
        let odd = try await f.bot(named: "a/b:c", in: store)
        #expect(try await service.workspace(teammateID: odd.id).homeURL.lastPathComponent == "a-b-c")
    }

    @Test("A bot that set itself up takes its unused folder along to its new name; a folder in use, or one named otherwise, stays")
    func folderFollowsSelfSetup() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        let service = BotWorkspaceService(layout: f.layout, repository: store, teammates: store)
        func rename(_ bot: Teammate, to name: String) async throws {
            var renamed = try #require(try await store.teammate(id: bot.id))
            renamed.profile = try renamed.profile.revised(displayName: name)
            try await store.update(renamed, expectedProfileRevision: bot.profile.revision)
        }
        let bots = f.layout.contentRoot.url.appending(path: "Bots")

        // Unused: only an empty Outbox, and a hidden file.
        let fresh = try await f.bot(named: "New Bot", in: store)
        let home = try await service.workspace(teammateID: fresh.id).homeURL
        FileManager.default.createFile(atPath: home.appending(path: ".DS_Store").path, contents: Data())
        try await rename(fresh, to: "PriceWatch")
        #expect(await service.followRename(teammateID: fresh.id, from: "New Bot"))
        #expect(try await service.workspace(teammateID: fresh.id).homeURL.path == bots.appending(path: "PriceWatch").path)
        #expect(!FileManager.default.fileExists(atPath: bots.appending(path: "New Bot").path))
        #expect(FileManager.default.fileExists(atPath: bots.appending(path: "PriceWatch/Outbox").path))

        // In use: a file in its Outbox keeps it where it is.
        let used = try await f.bot(named: "New Bot 2", in: store)
        let usedHome = try await service.workspace(teammateID: used.id).homeURL
        FileManager.default.createFile(atPath: usedHome.appending(path: "Outbox/report.txt").path, contents: Data("x".utf8))
        try await rename(used, to: "Tidy")
        #expect(!(await service.followRename(teammateID: used.id, from: "New Bot 2")))
        #expect(try await service.workspace(teammateID: used.id).homeURL.lastPathComponent == "New Bot 2")

        // A folder that never carried the old name stays; a bot with no folder has nothing to move.
        let other = try await f.bot(named: "Scout", in: store)
        _ = try await service.workspace(teammateID: other.id)
        try await rename(other, to: "Ranger")
        #expect(!(await service.followRename(teammateID: other.id, from: "New Bot 3")))
        let bare = try await f.bot(named: "New Bot 4", in: store)
        #expect(!(await service.followRename(teammateID: bare.id, from: "New Bot 4")))

        // The new name taken on disk: the next free number.
        try FileManager.default.createDirectory(at: bots.appending(path: "Ledger"), withIntermediateDirectories: true)
        let clash = try await f.bot(named: "New Bot 5", in: store)
        _ = try await service.workspace(teammateID: clash.id)
        try await rename(clash, to: "Ledger")
        #expect(await service.followRename(teammateID: clash.id, from: "New Bot 5"))
        #expect(try await service.workspace(teammateID: clash.id).homeURL.lastPathComponent == "Ledger 2")
    }

    @Test("Folders the user adds are kept, resolved and handed to a work turn; files and protected roots are refused")
    func addedFolders() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        let bot = try await f.bot(named: "Canobi", in: store)
        let documents = f.root.appending(path: "Documents/Invoices")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let file = f.root.appending(path: "Documents/note.txt")
        try Data("x".utf8).write(to: file)
        let ssh = f.layout.homeDirectory.appending(path: ".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        // A real /Applications may hold the old app, which is protected too; the fixture's is empty.
        let applications = f.root.appending(path: "Applications")
        #expect(BotWorkspaceService.protectedPaths(layout: f.layout, applicationsDirectory: applications) == [ssh.path])
        let service = BotWorkspaceService(layout: f.layout, repository: store, teammates: store,
                                          applicationsDirectory: applications)
        let added = try await service.addFolder(documents, teammateID: bot.id)
        #expect(added.folders.count == 1 && added.folders[0].url.path == documents.path && added.folders[0].exists)
        await #expect(throws: BotWorkspaceError.notAFolder) { try await service.addFolder(file, teammateID: bot.id) }
        await #expect(throws: BotWorkspaceError.protectedFolder) { try await service.addFolder(ssh, teammateID: bot.id) }
        await #expect(throws: BotWorkspaceError.protectedFolder) {
            try await service.addFolder(f.layout.homeDirectory, teammateID: bot.id)
        }
        // The same folder twice is one folder.
        #expect(try await service.addFolder(documents, teammateID: bot.id).folders.count == 1)
        let access = try #require(await service.workAccess(teammateID: bot.id))
        #expect(access.workingDirectoryURL.path == added.homeURL.path)
        #expect(access.additionalDirectoryURLs.map(\.path) == [documents.path])
        // Only roots that exist are fenced, and the bot's own desk is never one of them.
        #expect(access.protectedPaths == [ssh.path])
        let reopened = BotWorkspaceService(layout: f.layout, repository: try f.store(), teammates: store)
        #expect(try await reopened.workspace(teammateID: bot.id).folders.map(\.id) == added.folders.map(\.id))
        let removed = try await service.removeFolder(id: added.folders[0].id, teammateID: bot.id)
        #expect(removed.folders.isEmpty)
        #expect(try await store.loadBotWorkspace(teammateID: bot.id)?.folders.isEmpty == true)
    }

    // Where the old app is installed, its data, repository, bundle and
    // preferences all exist, and none used to be fenced.
    @Test("The old app's real places are protected wherever they exist: its data folder, its repository, its bundle and its preferences")
    func theOldAppsPlacesAreProtected() async throws {
        let f = try Fixture(); defer { f.remove() }
        let home = f.layout.homeDirectory
        let applications = f.root.appending(path: "Applications")
        let data = home.appending(path: "OpenBots"), repository = home.appending(path: "Developer/openbots")
        let bundle = applications.appending(path: "OpenBots.app")
        let preferences = home.appending(path: "Library/Preferences/com.lorenzocolombani.openbots.plist")
        for folder in [data.appending(path: "vault"), repository.appending(path: "Sources"), bundle.appending(path: "Contents"),
                       preferences.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("<plist/>".utf8).write(to: preferences)
        let protected = BotWorkspaceService.protectedPaths(layout: f.layout, applicationsDirectory: applications)
        for place in [data, repository, bundle, preferences] {
            #expect(protected.contains(place.path), "\(place.path)")
        }
        #expect(protected.count <= ClaudeTextWorkAccess.maximumProtectedPaths)
        _ = try ClaudeTextWorkAccess(workingDirectoryURL: f.layout.contentRoot.url.appending(path: "Bots/Yogurt"), protectedPaths: protected)
        // Next's own repository beside the old one is not the old one.
        #expect(!protected.contains(home.appending(path: "Developer/OpenBotsNext").path))
        let store = try f.store()
        let bot = try await f.bot(named: "Canobi", in: store)
        let service = BotWorkspaceService(layout: f.layout, repository: store, teammates: store,
                                          applicationsDirectory: applications)
        for folder in [data, data.appending(path: "vault"), repository.appending(path: "Sources"), bundle] {
            await #expect(throws: BotWorkspaceError.protectedFolder, "\(folder.path)") { try await service.addFolder(folder, teammateID: bot.id) }
        }
        // A folder that only holds one, like Developer, is added; the old repository stays fenced inside it.
        let developer = home.appending(path: "Developer")
        #expect(try await service.addFolder(developer, teammateID: bot.id).folders.map(\.url.path) == [developer.path])
        #expect(try #require(await service.workAccess(teammateID: bot.id)).protectedPaths.contains(repository.path))
    }

    /// The stores macOS keeps behind its privacy permissions, which a child of the app could read the
    /// moment the user grants the app Full Disk Access (for Messages), relative to the home folder.
    private static let privateStores = [
        "Library/Mobile Documents",
        "Library/Calendars", "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
        "Library/Application Support/CallHistoryTransactions", "Library/Application Support/com.apple.TCC",
        "Library/Accounts", "Pictures/Photos Library.photoslibrary", "Library/Application Support/MobileSync",
        "Library/Application Support/Knowledge", "Library/Suggestions", "Library/HomeKit", "Library/Biome",
        "Library/IdentityServices", "Library/Metadata/CoreSpotlight", "Library/Reminders",
        "Library/Containers/com.apple.Safari", "Library/Containers/com.apple.mail"
    ]

    @Test("The private stores macOS guards are protected roots wherever they exist, so Full Disk Access for the app never reaches a bot, iCloud Drive among them")
    func privateStoresAreProtected() throws {
        let f = try Fixture(); defer { f.remove() }
        for store in Self.privateStores {
            try FileManager.default.createDirectory(at: f.layout.homeDirectory.appending(path: store), withIntermediateDirectories: true)
        }
        let protected = BotWorkspaceService.protectedPaths(layout: f.layout)
        for store in Self.privateStores {
            #expect(protected.contains(f.layout.homeDirectory.appending(path: store).path), "\(store)")
        }
        // iCloud Drive joins them. A bot reaches a folder in it only when the
        // user adds that folder to the bot themselves.
        #expect(protected.contains(f.layout.homeDirectory.appending(path: "Library/Mobile Documents").path))
        #expect(protected.count <= ClaudeTextWorkAccess.maximumProtectedPaths)
        // The roots still build a work turn: none carries a character the rules would read as pattern.
        _ = try ClaudeTextWorkAccess(workingDirectoryURL: f.layout.contentRoot.url.appending(path: "Bots/Yogurt"), protectedPaths: protected)
    }

    @Test("A folder that is a private store or sits inside one cannot be added; one that only holds one, like Pictures, can; home and Library cannot")
    func privateStoresCannotBeAdded() async throws {
        let f = try Fixture(); defer { f.remove() }
        let pictures = f.layout.homeDirectory.appending(path: "Pictures")
        let library = pictures.appending(path: "Photos Library.photoslibrary")
        let trips = pictures.appending(path: "Trips")
        let contacts = f.layout.homeDirectory.appending(path: "Library/Application Support/AddressBook")
        for folder in [library.appending(path: "originals"), trips, contacts.appending(path: "Sources")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let store = try f.store()
        let bot = try await f.bot(named: "Canobi", in: store)
        let service = BotWorkspaceService(layout: f.layout, repository: store, teammates: store)
        let home = f.layout.homeDirectory
        let libraryFolder = home.appending(path: "Library")
        let supportFolder = libraryFolder.appending(path: "Application Support")
        // The command-line tools' Library, where sign-in tokens live.
        let config = home.appending(path: ".config"), gcloud = config.appending(path: "gcloud")
        try FileManager.default.createDirectory(at: gcloud, withIntermediateDirectories: true)
        for folder in [library, library.appending(path: "originals"), contacts, contacts.appending(path: "Sources"),
                       home, home.deletingLastPathComponent(), URL(fileURLWithPath: "/"), libraryFolder, supportFolder,
                       config, gcloud] {
            await #expect(throws: BotWorkspaceError.protectedFolder, "\(folder.path)") { try await service.addFolder(folder, teammateID: bot.id) }
        }
        #expect(try await service.addFolder(trips, teammateID: bot.id).folders.map(\.url.path) == [trips.path])
        // Pictures holds the Photos library and is added; the library stays a
        // protected root, fenced inside it on every turn.
        let added = try await service.addFolder(pictures, teammateID: bot.id)
        #expect(added.folders.map(\.url.path) == [trips.path, pictures.path])
        #expect(BotWorkspaceService.protectedPaths(layout: f.layout).contains(library.path))
    }

    /// The checks were once lexical, so a symlink to
    /// home, to the Library or to a protected root, or the firmlinked
    /// `/System/Volumes/Data` spelling of the home, went through.
    @Test("A symlink to home, the Library or a protected root, and the data volume's spelling of home, are refused too")
    func otherSpellingsAreRefused() async throws {
        let f = try Fixture(); defer { f.remove() }
        let home = f.layout.homeDirectory
        let photos = home.appending(path: "Pictures/Photos Library.photoslibrary")
        let trips = home.appending(path: "Pictures/Trips")
        for folder in [photos.appending(path: "originals"), home.appending(path: "Library/Caches"), trips] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let links = f.root.appending(path: "links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        var refused: [URL] = []
        for (name, target) in [("home", home), ("library", home.appending(path: "Library")),
                               ("caches", home.appending(path: "Library/Caches")), ("photos", photos),
                               ("originals", photos.appending(path: "originals"))] {
            let link = links.appending(path: name)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
            refused.append(link)
        }
        refused.append(URL(fileURLWithPath: "/System/Volumes/Data" + home.path))
        refused.append(URL(fileURLWithPath: "/System/Volumes/Data" + photos.path))
        // Above the data volume's spelling of home: both hold the whole home.
        refused.append(URL(fileURLWithPath: "/System/Volumes"))
        refused.append(URL(fileURLWithPath: "/System"))
        let store = try f.store()
        let bot = try await f.bot(named: "Canobi", in: store)
        let service = BotWorkspaceService(layout: f.layout, repository: store, teammates: store)
        for folder in refused {
            await #expect(throws: BotWorkspaceError.protectedFolder, "\(folder.path)") { try await service.addFolder(folder, teammateID: bot.id) }
        }
        // A symlink to a folder that is fine stays fine, saved as the user chose it.
        let tripsLink = links.appending(path: "trips")
        try FileManager.default.createSymbolicLink(atPath: tripsLink.path, withDestinationPath: trips.path)
        #expect(try await service.addFolder(tripsLink, teammateID: bot.id).folders.map(\.url.path) == [tripsLink.path])
        // A folder given by the data volume's spelling is saved by the plain
        // one, the spelling every fence of a turn is written in.
        let onDataVolume = URL(fileURLWithPath: "/System/Volumes/Data" + trips.path)
        #expect(try await service.addFolder(onDataVolume, teammateID: bot.id).folders.map(\.url.path) == [tripsLink.path, trips.path])
    }

    @Test("A folder added before it became a protected root is left out of the turn, and never costs the bot its Work")
    func folderThatBecameProtectedIsLeftOut() async throws {
        let f = try Fixture(); defer { f.remove() }
        let originals = f.layout.homeDirectory.appending(path: "Pictures/Photos Library.photoslibrary/originals")
        let documents = f.root.appending(path: "Documents")
        for folder in [originals, documents] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let store = try f.store()
        let bot = try await f.bot(named: "Canobi", in: store)
        let service = BotWorkspaceService(layout: f.layout, repository: store, teammates: store)
        let desk = try await service.workspace(teammateID: bot.id)
        // Saved as an older build saved it, before the Photos library was a
        // protected root, and home itself, too wide, as an older build let through.
        let home = f.layout.homeDirectory
        try await store.saveBotWorkspace(BotWorkspaceRecord(homePath: desk.homeURL.path, folders: [
            BotWorkspaceFolder(id: UUID(), path: originals.path, bookmark: nil),
            BotWorkspaceFolder(id: UUID(), path: documents.path, bookmark: nil),
            BotWorkspaceFolder(id: UUID(), path: home.path, bookmark: nil)]), teammateID: bot.id)
        let access = try #require(await service.workAccess(teammateID: bot.id), "a folder under a protected root took the bot's Work away")
        #expect(access.additionalDirectoryURLs.map(\.path) == [documents.path])
        // Details shows each folder the turn leaves out as out of reach, not
        // as one the bot works in.
        let shown = try await service.workspace(teammateID: bot.id).folders
        #expect(shown.map(\.url.path) == [originals.path, documents.path, home.path])
        #expect(shown.map(\.exists) == [true, true, true])
        #expect(shown.map(\.isOutOfReach) == [true, false, true])
    }

    @Test("Every work turn also reaches the team's shared folder, made on first use beside the bots' folders and never one of a bot's own sixteen")
    func sharedFolder() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        let bot = try await f.bot(named: "Canobi", in: store)
        let service = BotWorkspaceService(layout: f.layout, repository: store, teammates: store)
        let shared = f.layout.contentRoot.url.appending(path: "Shared")
        #expect(service.sharedFolderURL.path == shared.path)
        #expect(!FileManager.default.fileExists(atPath: shared.path))
        for index in 1...16 {
            let folder = f.root.appending(path: "Documents/F\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = try await service.addFolder(folder, teammateID: bot.id)
        }
        let access = try #require(await service.workAccess(teammateID: bot.id))
        #expect(access.additionalDirectoryURLs.count == 16)
        #expect(access.sharedDirectoryURL?.path == shared.path)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: shared.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        // Added by hand as well, it is still one folder on the turn.
        let other = try await f.bot(named: "Zed", in: store)
        _ = try await service.addFolder(shared, teammateID: other.id)
        let otherAccess = try #require(await service.workAccess(teammateID: other.id))
        #expect(otherAccess.additionalDirectoryURLs.isEmpty && otherAccess.sharedDirectoryURL?.path == shared.path)
    }

    @Test("A skill picked from the user's Claude skills is copied into the bot's skills folder, links inside it are left behind, and the turn is told what it holds")
    func skills() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        let bot = try await f.bot(named: "Yogurt", in: store)
        let service = BotWorkspaceService(layout: f.layout, repository: store, teammates: store)
        let library = f.layout.homeDirectory.appending(path: ".claude/skills")
        let pickup = library.appending(path: "pickup")
        try FileManager.default.createDirectory(at: pickup.appending(path: "scripts"), withIntermediateDirectories: true)
        try Data("---\nname: pickup\ndescription: \"Resume a paused project\"\n---\n\n# Resume\nRead the registry.\n".utf8)
            .write(to: pickup.appending(path: "SKILL.md"))
        try Data("echo hi\n".utf8).write(to: pickup.appending(path: "scripts/run.sh"))
        let outside = f.root.appending(path: "outside.txt")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: pickup.appending(path: "leak.txt"), withDestinationURL: outside)
        let elsewhere = f.root.appending(path: "Elsewhere/linked")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("---\nname: linked\ndescription: A linked skill\n---\nBody\n".utf8).write(to: elsewhere.appending(path: "SKILL.md"))
        try FileManager.default.createSymbolicLink(at: library.appending(path: "linked"), withDestinationURL: elsewhere)
        try FileManager.default.createDirectory(at: library.appending(path: "no-skill-file"), withIntermediateDirectories: true)

        let available = await service.availableSkills()
        #expect(available.map(\.name) == ["linked", "pickup"])
        #expect(available.first { $0.name == "pickup" }?.summary == "Resume a paused project")
        #expect(try await service.skills(teammateID: bot.id).isEmpty)
        #expect(await service.workAccess(teammateID: bot.id)?.skillsDirectoryURL == nil)

        let added = try await service.addSkill(named: "pickup", teammateID: bot.id)
        #expect(added == [BotSkill(name: "pickup", summary: "Resume a paused project")])
        let folder = f.layout.contentRoot.url.appending(path: "Skills/Yogurt/pickup")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "scripts/run.sh").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "leak.txt").path))
        _ = try await service.addSkill(named: "linked", teammateID: bot.id)
        await #expect(throws: BotWorkspaceError.self) { try await service.addSkill(named: "pickup", teammateID: bot.id) }
        for bad in ["../pickup", ".claude", "missing", "no-skill-file"] {
            await #expect(throws: BotWorkspaceError.self) { try await service.addSkill(named: bad, teammateID: bot.id) }
        }
        let access = try #require(await service.workAccess(teammateID: bot.id))
        #expect(access.skillsDirectoryURL?.path == f.layout.contentRoot.url.appending(path: "Skills/Yogurt").path)
        #expect(access.skills.map(\.name) == ["linked", "pickup"])
        let removed = try await service.removeSkill(named: "pickup", teammateID: bot.id)
        #expect(removed.map(\.name) == ["linked"] && !FileManager.default.fileExists(atPath: folder.path))
        _ = try await service.removeSkill(named: "linked", teammateID: bot.id)
        #expect(await service.workAccess(teammateID: bot.id)?.skillsDirectoryURL == nil)
    }

    @Test("A bot's own skills folder added by hand is still one folder on the turn, and never costs the bot its Work")
    func skillsFolderAddedByHand() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        let bot = try await f.bot(named: "Yogurt", in: store)
        let service = BotWorkspaceService(layout: f.layout, repository: store, teammates: store)
        let pickup = f.layout.homeDirectory.appending(path: ".claude/skills/pickup")
        try FileManager.default.createDirectory(at: pickup, withIntermediateDirectories: true)
        try Data("---\nname: pickup\ndescription: Resume a paused project\n---\nBody\n".utf8).write(to: pickup.appending(path: "SKILL.md"))
        _ = try await service.addSkill(named: "pickup", teammateID: bot.id)
        let skills = f.layout.contentRoot.url.appending(path: "Skills/Yogurt")
        let documents = f.root.appending(path: "Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        _ = try await service.addFolder(documents, teammateID: bot.id)
        _ = try await service.addFolder(skills, teammateID: bot.id)
        let access = try #require(await service.workAccess(teammateID: bot.id), "the hand-added skills folder took the bot's Work away")
        #expect(access.additionalDirectoryURLs.map(\.path) == [documents.path])
        #expect(access.skillsDirectoryURL?.path == skills.path && access.skills.map(\.name) == ["pickup"])
    }

    @Test("A bot whose name carries ( ) [ ] { } * or ? keeps its Work and its skills, and no rule or sandbox path of its turn carries those characters")
    func oddBotNameKeepsItsFence() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        let bot = try await f.bot(named: "Scout [EU] (draft) {v2} *?", in: store)
        let service = BotWorkspaceService(layout: f.layout, repository: store, teammates: store)
        let pickup = f.layout.homeDirectory.appending(path: ".claude/skills/pickup")
        try FileManager.default.createDirectory(at: pickup, withIntermediateDirectories: true)
        try Data("---\nname: pickup\ndescription: Resume a paused project\n---\nBody\n".utf8).write(to: pickup.appending(path: "SKILL.md"))
        _ = try await service.addSkill(named: "pickup", teammateID: bot.id)
        let access = try #require(await service.workAccess(teammateID: bot.id), "the bot's name cost it its Work")
        #expect(access.skillsDirectoryURL?.lastPathComponent == "Scout [EU] (draft) {v2} *?" && access.skills.map(\.name) == ["pickup"])
        let target = try ClaudeConnectionTarget(executableURL: URL(fileURLWithPath: "/private/tmp/not-created.noindex/claude"),
            expectedExecutableSHA256: String(repeating: "a", count: 64),
            profileURL: URL(fileURLWithPath: "/private/tmp/not-created.noindex/profile"),
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created.noindex/work"),
            temporaryDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created.noindex/temp"),
            homeDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created.noindex/home"))
        let request = try ClaudeTextOnlyRequest(target: target, runID: UUID(), sessionID: UUID(), messageID: UUID(),
            text: "Hello", systemPrompt: "Base.", workAccess: access)
        let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
        let settings = try #require(arguments.firstIndex(of: "--settings").map { arguments[$0 + 1] })
        let object = try #require(try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])
        let deny = try #require((object["permissions"] as? [String: Any])?["deny"] as? [String])
        let filesystem = try #require((object["sandbox"] as? [String: Any])?["filesystem"] as? [String: Any])
        let paths = deny.filter { $0.hasSuffix("/**)") }.compactMap { rule -> String? in
            rule.firstIndex(of: "(").map { String(rule[rule.index(after: $0)..<rule.index(rule.endIndex, offsetBy: -4)]) }
        } + (filesystem["denyRead"] as? [String] ?? []) + (filesystem["denyWrite"] as? [String] ?? [])
        #expect(paths.contains(f.layout.contentRoot.url.appending(path: "Skills").path))
        for path in paths { #expect(!path.contains(where: { "()[]{}*?".contains($0) }), "\(path)") }
    }

    @Test("Every work turn carries the whole skills root read-only, whether or not the bot holds a skill")
    func everyWorkTurnFencesTheSkillsRoot() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        let bot = try await f.bot(named: "Zed", in: store)
        let service = BotWorkspaceService(layout: f.layout, repository: store, teammates: store)
        let access = try #require(await service.workAccess(teammateID: bot.id))
        #expect(access.skills.isEmpty && access.skillsDirectoryURL == nil)
        #expect(access.skillsRootURL?.path == f.layout.contentRoot.url.appending(path: "Skills").path)
    }

    /// Details once said "No skills in
    /// ~/.claude/skills" whenever nothing could be offered, including when the
    /// folder held skills that fail the name or SKILL.md check. The library now
    /// says how many folders it could not offer.
    @Test("The skill library offers what can be added and counts the folders it cannot offer, never a hidden entry or a plain file")
    func theSkillLibraryCountsWhatItCannotOffer() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        let service = BotWorkspaceService(layout: f.layout, repository: store, teammates: store)
        #expect(await service.skillLibrary() == BotSkillLibrary(offered: [], unusableCount: 0), "no library folder at all")

        let library = f.layout.homeDirectory.appending(path: ".claude/skills")
        func folder(_ name: String, skill: Bool) throws {
            let url = library.appending(path: name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if skill { try Data("---\ndescription: \(name)\n---\n".utf8).write(to: url.appending(path: "SKILL.md")) }
        }
        try folder("no-skill-file", skill: false)
        try folder("has space", skill: true)
        try folder(".git", skill: true)
        try Data("notes".utf8).write(to: library.appending(path: "README.md"))
        let none = await service.skillLibrary()
        #expect(none.offered.isEmpty && none.unusableCount == 2)

        try folder("pickup", skill: true)
        let some = await service.skillLibrary()
        #expect(some.offered == [BotSkill(name: "pickup", summary: "pickup")] && some.unusableCount == 2)
        #expect(await service.availableSkills() == some.offered)
    }

    @Test("A bot without Work is handed the shared folder and, when it has skills, its skills folder to read, with the protected roots")
    func readAccessForEveryBot() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        let bot = try await f.bot(named: "Pillow", in: store)
        let service = BotWorkspaceService(layout: f.layout, repository: store, teammates: store)
        let ssh = f.layout.homeDirectory.appending(path: ".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let reopened = BotWorkspaceService(layout: f.layout, repository: store, teammates: store)
        let bare = try #require(await reopened.readAccess(teammateID: bot.id))
        #expect(bare.sharedDirectoryURL?.path == service.sharedFolderURL.path && bare.skillsDirectoryURL == nil && bare.skills.isEmpty)
        #expect(FileManager.default.fileExists(atPath: service.sharedFolderURL.path))
        #expect(bare.protectedPaths.contains(ssh.path))
        let pickup = f.layout.homeDirectory.appending(path: ".claude/skills/pickup")
        try FileManager.default.createDirectory(at: pickup, withIntermediateDirectories: true)
        try Data("---\nname: pickup\ndescription: Resume a paused project\n---\nBody\n".utf8).write(to: pickup.appending(path: "SKILL.md"))
        _ = try await reopened.addSkill(named: "pickup", teammateID: bot.id)
        let withSkills = try #require(await reopened.readAccess(teammateID: bot.id))
        #expect(withSkills.skillsDirectoryURL?.path == f.layout.contentRoot.url.appending(path: "Skills/Pillow").path)
        #expect(withSkills.skills.map(\.name) == ["pickup"])
    }

    @Test("A new bot never inherits skills a gone bot left behind: a name whose skills folder is still there is taken, and the newcomer gets the next number")
    func leftoverSkillsAreNotInherited() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        // A bot named Kite once held a skill; its desk was removed, its skills folder was not.
        let leftover = f.layout.contentRoot.url.appending(path: "Skills/Kite/pickup")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("---\nname: pickup\ndescription: The old Kite's skill\n---\nBody\n".utf8).write(to: leftover.appending(path: "SKILL.md"))
        let kite = try await f.bot(named: "Kite", in: store)
        let service = BotWorkspaceService(layout: f.layout, repository: store, teammates: store)
        let desk = try await service.workspace(teammateID: kite.id)
        #expect(desk.homeURL.lastPathComponent == "Kite 2")
        #expect(try await service.skills(teammateID: kite.id).isEmpty)
        let access = try #require(await service.workAccess(teammateID: kite.id))
        #expect(access.skills.isEmpty && access.skillsDirectoryURL == nil)
        // The leftover is left exactly where it was.
        #expect(FileManager.default.fileExists(atPath: leftover.appending(path: "SKILL.md").path))
    }

    @Test("A turn that only reads makes no desk: a bot that never had one still has none, and a desk removed by hand is not made again")
    func readingMakesNoDesk() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        let fresh = try await f.bot(named: "Pillow", in: store)
        let service = BotWorkspaceService(layout: f.layout, repository: store, teammates: store)
        let read = try #require(await service.readAccess(teammateID: fresh.id))
        #expect(read.sharedDirectoryURL?.path == service.sharedFolderURL.path && read.skillsDirectoryURL == nil)
        #expect(!FileManager.default.fileExists(atPath: service.botsRoot.appending(path: "Pillow").path))
        #expect(try await store.loadBotWorkspace(teammateID: fresh.id) == nil)
        // A bot with skills whose desk was removed by hand still reads its skills, and gets no desk back.
        let kept = try await f.bot(named: "Kite", in: store)
        let pickup = f.layout.homeDirectory.appending(path: ".claude/skills/pickup")
        try FileManager.default.createDirectory(at: pickup, withIntermediateDirectories: true)
        try Data("---\nname: pickup\ndescription: Resume a paused project\n---\nBody\n".utf8).write(to: pickup.appending(path: "SKILL.md"))
        _ = try await service.addSkill(named: "pickup", teammateID: kept.id)
        let desk = service.botsRoot.appending(path: "Kite")
        try FileManager.default.removeItem(at: desk)
        let withSkills = try #require(await service.readAccess(teammateID: kept.id))
        #expect(withSkills.skillsDirectoryURL?.path == f.layout.contentRoot.url.appending(path: "Skills/Kite").path)
        #expect(withSkills.skills.map(\.name) == ["pickup"])
        #expect(!FileManager.default.fileExists(atPath: desk.path))
    }

    @Test("A folder that disappears is shown as missing and left out of the turn, never a failure")
    func missingFolder() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        let bot = try await f.bot(named: "Zed", in: store)
        let gone = f.root.appending(path: "Gone")
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        let service = BotWorkspaceService(layout: f.layout, repository: store, teammates: store)
        _ = try await service.addFolder(gone, teammateID: bot.id)
        try FileManager.default.removeItem(at: gone)
        let workspace = try await service.workspace(teammateID: bot.id)
        #expect(workspace.folders.count == 1 && !workspace.folders[0].exists)
        let access = try #require(await service.workAccess(teammateID: bot.id))
        #expect(access.additionalDirectoryURLs.isEmpty)
    }
}
