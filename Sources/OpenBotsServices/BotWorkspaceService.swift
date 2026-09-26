import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsRuntime

/// Where a bot works on the Mac, resolved for the screen: its own folder and
/// the folders the user added, with whether each still exists and whether a
/// turn can reach it.
public struct BotWorkspace: Equatable, Sendable {
    public struct Folder: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let url: URL
        public let exists: Bool
        /// Saved by an older build, but too wide or inside a protected root,
        /// so a work turn leaves it out.
        public let isOutOfReach: Bool
        public init(id: UUID, url: URL, exists: Bool, isOutOfReach: Bool = false) {
            self.id = id; self.url = url; self.exists = exists; self.isOutOfReach = isOutOfReach
        }
    }
    public let homeURL: URL
    public let folders: [Folder]
    public init(homeURL: URL, folders: [Folder]) { self.homeURL = homeURL; self.folders = folders }
}

public enum BotWorkspaceError: Error, Equatable, Sendable {
    case unknownBot, notAFolder, folderLimitReached, protectedFolder, unavailable
    case skillNotFound, skillAlreadyAdded, skillTooLarge, skillLimitReached
}

/// A skill as Details shows it: its folder name and the one-line summary from
/// its SKILL.md.
public struct BotSkill: Equatable, Sendable, Identifiable {
    public let name: String
    public let summary: String
    public var id: String { name }
    public init(name: String, summary: String) { self.name = name; self.summary = summary }
}

/// What the user's skills folder holds for Details: the skills a bot can be
/// given, and how many folders there could not be offered.
public struct BotSkillLibrary: Equatable, Sendable {
    public let offered: [BotSkill]
    public let unusableCount: Int
    public init(offered: [BotSkill], unusableCount: Int) { self.offered = offered; self.unusableCount = unusableCount }
}

/// Each bot's desk on the Mac: a folder of its own under the content
/// root, created the first time it is needed and named after the bot, plus any
/// folder the user adds with the native picker. The record is kept whole per
/// bot; a folder is kept as a bookmark with its path as the fallback, so a
/// rename in Finder does not lose it. Nothing here grants anything: the two
/// work switches decide whether a turn gets these folders at all.
public actor BotWorkspaceService: BotWorkspaceResolving {
    public static let maximumFolders = ClaudeTextWorkAccess.maximumAdditionalDirectories
    private let layout: PreviewStorageLayout
    private let repository: any BotWorkspaceRepository
    private let teammates: any TeammateRepository
    private let fileManager: FileManager
    /// The roots no bot may read or write, whatever it is told: credential
    /// stores, browser profiles, the app's own data, the legacy app's data.
    private let protectedPaths: [String]
    /// Told after every save that changed a bot's folders. The switch store
    /// listens, so a work turn launched with a folder ends when it is removed,
    /// the way it ends when a work switch is turned off.
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(layout: PreviewStorageLayout, repository: any BotWorkspaceRepository,
                teammates: any TeammateRepository, fileManager: FileManager = .default,
                applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)) {
        self.layout = layout; self.repository = repository; self.teammates = teammates
        self.fileManager = fileManager
        protectedPaths = Self.protectedPaths(layout: layout, fileManager: fileManager,
                                             applicationsDirectory: applicationsDirectory)
    }

    /// The bots' folders live beside the other visible content.
    public nonisolated var botsRoot: URL {
        layout.contentRoot.url.appending(path: "Bots", directoryHint: .isDirectory)
    }

    /// The team's shared folder beside the bots' folders: the user drops documents there and every work turn
    /// reaches it. Made on first use, like a bot's own folder.
    public nonisolated var sharedFolderURL: URL {
        layout.contentRoot.url.appending(path: "Shared", directoryHint: .isDirectory)
    }

    /// The user's own Claude skills, offered to a bot by name (the old app
    /// listed the same folder in its profile sheet).
    public nonisolated var userSkillsLibraryURL: URL {
        layout.homeDirectory.appending(path: ".claude/skills", directoryHint: .isDirectory)
    }

    /// A copied skill stays small: its files, not a whole project behind a link.
    public static let maximumSkillFiles = 256
    public static let maximumSkillBytes = 8 * 1_048_576

    /// The folder inside a bot's own where what it makes for the user lands;
    /// each item there becomes a chip on the reply.
    public static let outboxName = "Outbox"

    /// The files and folders a turn left in the Outbox: new or changed since the
    /// turn began, visible, bounded in number and size, oldest first.
    public static func producedItems(in home: URL, since start: Date, fileManager: FileManager = .default,
                                     limit: Int = 12) -> [URL] {
        let outbox = home.appending(path: outboxName, directoryHint: .isDirectory)
        guard let names = try? fileManager.contentsOfDirectory(atPath: outbox.path) else { return [] }
        var found: [(URL, Date)] = []
        for name in names where !name.hasPrefix(".") {
            let url = outbox.appending(path: name)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date,
                  modified >= start.addingTimeInterval(-2) else { continue }
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory else { continue }
            if type == .typeRegular, let size = attributes[.size] as? Int64, size > AttachmentAsset.provisionalMaximumByteCount { continue }
            found.append((url, modified))
        }
        return found.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }

    /// The candidate roots, kept only when they exist, so the CLI's sandbox is
    /// never asked to fence a path that is not there. Read when the service is
    /// made, at launch: macOS relaunches an app it grants Full Disk Access.
    public static func protectedPaths(layout: PreviewStorageLayout, fileManager: FileManager = .default,
                                      applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)) -> [String] {
        let home = layout.homeDirectory
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        let support = library.appending(path: "Application Support", directoryHint: .isDirectory)
        var candidates: [URL] = [
            library.appending(path: "Keychains"), library.appending(path: "Cookies"),
            home.appending(path: ".ssh"), home.appending(path: ".aws"), home.appending(path: ".gnupg"),
            home.appending(path: ".netrc"), home.appending(path: ".npmrc"), home.appending(path: ".docker"),
            home.appending(path: ".config/gh"), home.appending(path: ".claude"), home.appending(path: ".claude.json"),
            support.appending(path: "Claude"), support.appending(path: "Google/Chrome"),
            support.appending(path: "Firefox"), support.appending(path: "Arc"), support.appending(path: "BraveSoftware"),
            support.appending(path: "Microsoft Edge"), support.appending(path: "Chromium"), support.appending(path: "Vivaldi"),
            library.appending(path: "Safari"), library.appending(path: "Messages"), library.appending(path: "Mail"),
            library.appending(path: "Group Containers"),
            // What macOS keeps behind its privacy permissions. Children inherit
            // the app's Full Disk Access, which Messages needs, so without these
            // a Work turn's shell could read them the day the user grants it: calendars,
            // contacts, call history, the permissions database, accounts, the
            // Photos library, iPhone backups, usage and Siri history, Home, the
            // Spotlight index, old reminders, and Safari's and Mail's containers.
            // iCloud Drive joins them: a bot reaches a folder in it only when the
            // user adds that folder to the bot.
            library.appending(path: "Mobile Documents"),
            library.appending(path: "Calendars"), support.appending(path: "AddressBook"),
            support.appending(path: "CallHistoryDB"), support.appending(path: "CallHistoryTransactions"),
            support.appending(path: "com.apple.TCC"), library.appending(path: "Accounts"),
            home.appending(path: "Pictures/Photos Library.photoslibrary"), support.appending(path: "MobileSync"),
            support.appending(path: "Knowledge"), library.appending(path: "Suggestions"), library.appending(path: "HomeKit"),
            library.appending(path: "Biome"), library.appending(path: "IdentityServices"),
            library.appending(path: "Metadata/CoreSpotlight"), library.appending(path: "Reminders"),
            library.appending(path: "Containers/com.apple.Safari"), library.appending(path: "Containers/com.apple.mail"),
            layout.applicationSupportRoot.url, layout.cacheRoot.url,
            support.appending(path: "com.lorenzocolombani.openbots"),
            library.appending(path: "Containers/com.lorenzocolombani.openbots"),
            library.appending(path: "Caches/com.lorenzocolombani.openbots"),
            // Where the old app keeps its things: its data folder, its repository, its bundle and its
            // preferences. The two apps are not supposed to know each other.
            home.appending(path: "OpenBots"), home.appending(path: "Developer/openbots"),
            applicationsDirectory.appending(path: "OpenBots.app"),
            library.appending(path: "Preferences/com.lorenzocolombani.openbots.plist")
        ]
        candidates = candidates.map { URL(fileURLWithPath: $0.path) }
        var seen = Set<String>()
        return candidates.compactMap { url in
            let path = url.path
            guard fileManager.fileExists(atPath: path), seen.insert(path).inserted else { return nil }
            return path
        }
    }

    /// The bot's desk, created on first use. Never fails a turn that only reads.
    public func workspace(teammateID: TeammateID) async throws -> BotWorkspace {
        let record = try await ensuredRecord(teammateID: teammateID)
        return resolve(record)
    }

    public func addFolder(_ url: URL, teammateID: TeammateID) async throws -> BotWorkspace {
        var isDirectory: ObjCBool = false
        // Lexical only: Foundation's standardizing and symlink resolution both
        // strip the `/private` prefix macOS puts on temporary paths, and a
        // fence compared by prefix must see the spelling the roots use.
        // The data volume's spelling of a place is saved by its plain one,
        // the spelling every fence of a turn is written in.
        let path = Self.plainSpelling(Self.lexicalPath(url.path))
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BotWorkspaceError.notAFolder
        }
        // A protected root, or a folder inside one, is refused. A folder that
        // only holds one, as Pictures holds the Photos library, may be added:
        // the root inside stays denied by rule and by the sandbox, which a
        // probe proved for the shell and for the file tools alike. The home
        // folder and everything above it, and the Library and everything in
        // it, stay refused: the roots are a list of what is known to be
        // private, and those folders hold every other app's data too.
        // Compared by every spelling, not only as written:
        // a symlink to the home folder, to the Library or to a protected root,
        // or the firmlinked `/System/Volumes/Data` spelling of the home, names
        // the same place. The folder is still saved as the user chose it.
        guard !ClaudeTextWorkApprovalPolicy.isAtOrUnder(path, anyOf: protectedPaths),
              !Self.isTooWide(path, home: Self.lexicalPath(layout.homeDirectory.path)) else {
            throw BotWorkspaceError.protectedFolder
        }
        let record = try await ensuredRecord(teammateID: teammateID)
        guard record.homePath != path, !record.folders.contains(where: { $0.path == path }) else { return resolve(record) }
        guard record.folders.count < Self.maximumFolders else { throw BotWorkspaceError.folderLimitReached }
        let bookmark = try? URL(fileURLWithPath: path).bookmarkData(options: [.minimalBookmark])
        let next = BotWorkspaceRecord(homePath: record.homePath,
            folders: record.folders + [BotWorkspaceFolder(id: UUID(), path: path, bookmark: bookmark)])
        try await repository.saveBotWorkspace(next, teammateID: teammateID)
        notify()
        return resolve(next)
    }

    /// The home folder or a folder above it, or the Library or a folder in it,
    /// by any spelling of either (`ClaudeTextWorkApprovalPolicy.spellings`).
    /// Home's data-volume spelling counts too, so `/System/Volumes` and
    /// `/System`, which hold the whole home through the firmlink, are above it.
    static func isTooWide(_ path: String, home: String) -> Bool {
        let volume = ClaudeTextWorkApprovalPolicy.dataVolume
        let plain = ClaudeTextWorkApprovalPolicy.spellings(home)
        let homes = plain.union(plain.filter { !$0.hasPrefix(volume + "/") }.map { volume + $0 })
        return ClaudeTextWorkApprovalPolicy.spellings(path).contains { path in
            homes.contains { home in
                let library = home + "/Library"
                // ~/.config is the command-line tools' Library: gcloud, rclone
                // and others keep their sign-in tokens there.
                let config = home + "/.config"
                return path == "/" || path == home || home.hasPrefix(path + "/") || path == library
                    || path.hasPrefix(library + "/") || path == config || path.hasPrefix(config + "/")
            }
        }
    }

    public func removeFolder(id: UUID, teammateID: TeammateID) async throws -> BotWorkspace {
        let record = try await ensuredRecord(teammateID: teammateID)
        let next = BotWorkspaceRecord(homePath: record.homePath, folders: record.folders.filter { $0.id != id })
        if next != record {
            // Saved before anyone is told, so a watcher that re-reads the
            // folders on the news reads the record without this one.
            try await repository.saveBotWorkspace(next, teammateID: teammateID)
            notify()
        }
        return resolve(next)
    }

    /// Yields after every save that changed a bot's folders; the newest element
    /// is enough, a listener re-reads the folders rather than the change.
    public func workspaceChanges() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        }
    }

    private func notify() { for observer in observers.values { observer.yield(()) } }
    private func remove(_ id: UUID) { observers[id] = nil }

    /// The user's skills folder as Details offers it: each skill a bot can be
    /// given (a folder, or a link to one, with a plain name and a SKILL.md),
    /// and how many other folders are there, so an empty menu never says there
    /// are no skills when there are ones it cannot offer. A hidden entry or a plain file is not a skill and is
    /// not counted.
    public func skillLibrary() -> BotSkillLibrary {
        let library = userSkillsLibraryURL
        let names = (try? fileManager.contentsOfDirectory(atPath: library.path)) ?? []
        var offered: [BotSkill] = []
        var unusable = 0
        for name in names.sorted() where !name.hasPrefix(".") {
            let folder = library.appending(path: name).resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if ClaudeTextWorkSkill.isPlainName(name), let summary = Self.skillSummary(in: folder, fileManager: fileManager) {
                offered.append(BotSkill(name: name, summary: summary))
            } else {
                unusable += 1
            }
        }
        return BotSkillLibrary(offered: offered, unusableCount: unusable)
    }

    /// Each skill in the user's library: a folder, or a link to one, holding a SKILL.md.
    public func availableSkills() -> [BotSkill] {
        skillLibrary().offered
    }

    /// The skills this bot holds, read from its skills folder.
    public func skills(teammateID: TeammateID) async throws -> [BotSkill] {
        installedSkills(in: try await skillsFolder(teammateID: teammateID))
    }

    /// Copies one skill from the user's library into the bot's skills folder.
    /// A link at the top is followed, since the user picked it by name; links
    /// inside the skill are left behind. The copy lands whole or not at all.
    public func addSkill(named name: String, teammateID: TeammateID) async throws -> [BotSkill] {
        guard ClaudeTextWorkSkill.isPlainName(name) else { throw BotWorkspaceError.skillNotFound }
        let source = userSkillsLibraryURL.appending(path: name).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue,
              Self.skillSummary(in: source, fileManager: fileManager) != nil else { throw BotWorkspaceError.skillNotFound }
        let folder = try await skillsFolder(teammateID: teammateID)
        let existing = installedSkills(in: folder)
        let destination = folder.appending(path: name, directoryHint: .isDirectory)
        guard !existing.contains(where: { $0.name == name }), !fileManager.fileExists(atPath: destination.path) else {
            throw BotWorkspaceError.skillAlreadyAdded
        }
        guard existing.count < ClaudeTextWorkAccess.maximumSkills else { throw BotWorkspaceError.skillLimitReached }
        guard let walker = fileManager.enumerator(atPath: source.path) else { throw BotWorkspaceError.skillNotFound }
        var directories: [String] = []
        var files: [(relative: String, executable: Bool)] = []
        var bytes = 0
        while let relative = walker.nextObject() as? String {
            let attributes = walker.fileAttributes ?? [:]
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory?: directories.append(relative)
            case .typeRegular?:
                bytes += (attributes[.size] as? NSNumber)?.intValue ?? 0
                let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                files.append((relative, mode & 0o111 != 0))
            case .typeSymbolicLink?: walker.skipDescendants()
            default: continue
            }
            guard files.count <= Self.maximumSkillFiles, bytes <= Self.maximumSkillBytes else {
                throw BotWorkspaceError.skillTooLarge
            }
        }
        try ensureDirectory(folder)
        let staging = folder.appending(path: ".adding-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for relative in directories {
                try fileManager.createDirectory(at: staging.appending(path: relative), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
            }
            for file in files {
                let target = staging.appending(path: file.relative)
                try fileManager.copyItem(at: source.appending(path: file.relative), to: target)
                try fileManager.setAttributes([.posixPermissions: file.executable ? 0o700 : 0o600], ofItemAtPath: target.path)
            }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw BotWorkspaceError.unavailable
        }
        notify()
        return installedSkills(in: folder)
    }

    public func removeSkill(named name: String, teammateID: TeammateID) async throws -> [BotSkill] {
        guard ClaudeTextWorkSkill.isPlainName(name) else { throw BotWorkspaceError.skillNotFound }
        let folder = try await skillsFolder(teammateID: teammateID)
        let target = folder.appending(path: name, directoryHint: .isDirectory)
        guard let attributes = try? fileManager.attributesOfItem(atPath: target.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else { throw BotWorkspaceError.skillNotFound }
        try fileManager.removeItem(at: target)
        notify()
        return installedSkills(in: folder)
    }

    /// `Skills/<the bot's folder name>` in the visible content root, beside `Bots` and `Shared`.
    private func skillsFolder(teammateID: TeammateID) async throws -> URL {
        let workspace = try await workspace(teammateID: teammateID)
        return skillsFolder(home: workspace.homeURL)
    }

    private nonisolated func skillsFolder(home: URL) -> URL {
        URL(fileURLWithPath: layout.skillsRoot.appending(path: home.lastPathComponent, directoryHint: .isDirectory).path)
    }

    private func installedSkills(in folder: URL) -> [BotSkill] {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().compactMap { name in
            guard ClaudeTextWorkSkill.isPlainName(name) else { return nil }
            let skill = folder.appending(path: name)
            guard let attributes = try? fileManager.attributesOfItem(atPath: skill.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  let summary = Self.skillSummary(in: skill, fileManager: fileManager) else { return nil }
            return BotSkill(name: name, summary: summary)
        }
    }

    /// The description line of a SKILL.md's front matter, as one plain bounded
    /// line; empty when it has none; nil when the folder holds no SKILL.md file.
    static func skillSummary(in folder: URL, fileManager: FileManager) -> String? {
        let file = folder.appending(path: "SKILL.md")
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 16_384)) ?? Data(), as: UTF8.self)
        var lines = head.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return "" }
        lines.removeFirst()
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard line.hasPrefix("description:") else { continue }
            var value = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            let plain = String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }))
            return String(plain.prefix(ClaudeTextWorkSkill.maximumSummaryCharacters))
        }
        return ""
    }

    /// What a turn without Work may read: the
    /// shared folder, made on first use, and the bot's skills folder when it
    /// holds a skill, with the protected roots. Nil when neither can be had.
    /// It makes no desk: the skills folder is named by the desk a bot already
    /// has, and a bot without one has never been given a skill.
    public func readAccess(teammateID: TeammateID) async -> ClaudeTextReadAccess? {
        let shared = URL(fileURLWithPath: sharedFolderURL.path)
        let reachable = (try? ensureDirectory(shared)) != nil
        var skillsFolder: URL?
        var skills: [ClaudeTextWorkSkill] = []
        if let record = try? await repository.loadBotWorkspace(teammateID: teammateID) {
            let folder = self.skillsFolder(home: URL(fileURLWithPath: record.homePath))
            skills = installedSkills(in: folder).prefix(ClaudeTextWorkAccess.maximumSkills)
                .map { ClaudeTextWorkSkill(name: $0.name, summary: $0.summary) }
            if !skills.isEmpty { skillsFolder = folder }
        }
        guard reachable || skillsFolder != nil else { return nil }
        return try? ClaudeTextReadAccess(sharedDirectoryURL: reachable ? shared : nil, skillsDirectoryURL: skillsFolder,
                                         skills: skills, protectedPaths: protectedPaths)
    }

    /// What a work turn may reach, or nil when the bot's desk cannot be made.
    /// A folder that no longer exists is left out rather than failing the turn.
    public func workAccess(teammateID: TeammateID) async -> ClaudeTextWorkAccess? {
        guard let workspace = try? await workspace(teammateID: teammateID) else { return nil }
        // The shared folder and the bot's skills folder are reached on their own;
        // added by hand as well, neither is doubled, which the access would
        // refuse, costing the bot its Work.
        let shared = URL(fileURLWithPath: sharedFolderURL.path)
        let skillsFolder = skillsFolder(home: workspace.homeURL)
        // A folder added before its place became a protected root is left out
        // like a missing one; the access would refuse it, and the whole turn with it.
        // So is one an older build let through by another spelling.
        let extra = workspace.folders.filter { $0.exists && !$0.isOutOfReach }.map(\.url)
            .filter { $0.path != shared.path && $0.path != skillsFolder.path }
        // A shared folder that cannot be made leaves the turn its own folders, never no Work at all.
        let reachable = (try? ensureDirectory(shared)) != nil
        let skills = installedSkills(in: skillsFolder).prefix(ClaudeTextWorkAccess.maximumSkills)
            .map { ClaudeTextWorkSkill(name: $0.name, summary: $0.summary) }
        // Every bot's skills stay read-only, whichever folder reaches them.
        return try? ClaudeTextWorkAccess(workingDirectoryURL: workspace.homeURL,
            additionalDirectoryURLs: extra, sharedDirectoryURL: reachable ? shared : nil,
            skillsDirectoryURL: skills.isEmpty ? nil : skillsFolder, skills: skills,
            skillsRootURL: URL(fileURLWithPath: layout.skillsRoot.path), protectedPaths: protectedPaths)
    }

    private func ensuredRecord(teammateID: TeammateID) async throws -> BotWorkspaceRecord {
        if let record = try await repository.loadBotWorkspace(teammateID: teammateID) {
            try ensureDirectory(URL(fileURLWithPath: record.homePath))
            try ensureDirectory(URL(fileURLWithPath: record.homePath).appending(path: Self.outboxName, directoryHint: .isDirectory))
            return record
        }
        guard let teammate = try await teammates.teammate(id: teammateID) else { throw BotWorkspaceError.unknownBot }
        let home = try createHome(named: teammate.profile.displayName)
        let record = BotWorkspaceRecord(homePath: home.path, folders: [])
        try await repository.saveBotWorkspace(record, teammateID: teammateID)
        return record
    }

    /// A bot that set itself up under a new name: its folder follows
    /// the name while nothing is in it yet, so a bot called PriceWatch does not
    /// work in `Bots/New Bot`. Only when the folder still carries the old name,
    /// holds nothing but an empty Outbox, and no skills folder goes by that
    /// name; otherwise it stays where it is. True when it moved.
    @discardableResult
    public func followRename(teammateID: TeammateID, from oldName: String) async -> Bool {
        guard let record = try? await repository.loadBotWorkspace(teammateID: teammateID),
              let teammate = try? await teammates.teammate(id: teammateID) else { return false }
        let home = URL(fileURLWithPath: record.homePath)
        guard home.lastPathComponent == Self.folderName(for: oldName),
              Self.folderName(for: teammate.profile.displayName) != home.lastPathComponent,
              isUnused(home), !fileManager.fileExists(atPath: skillsFolder(home: home).path) else { return false }
        for attempt in 1...99 {
            let base = Self.folderName(for: teammate.profile.displayName)
            let candidate = botsRoot.appending(path: attempt == 1 ? base : "\(base) \(attempt)", directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: candidate.path)
                || fileManager.fileExists(atPath: skillsFolder(home: candidate).path) { continue }
            do { try fileManager.moveItem(at: home, to: candidate) } catch {
                AgenticDiagnosticsLog.error("workspace", "folder not renamed after setup: \(String(describing: error).prefix(160))")
                return false
            }
            do {
                try await repository.saveBotWorkspace(BotWorkspaceRecord(homePath: URL(fileURLWithPath: candidate.path).path,
                                                                         folders: record.folders), teammateID: teammateID)
            } catch {
                // The record still names the old folder, so the folder goes back to it.
                try? fileManager.moveItem(at: candidate, to: home)
                AgenticDiagnosticsLog.error("workspace", "folder rename not saved after setup: \(String(describing: error).prefix(160))")
                return false
            }
            notify()
            return true
        }
        return false
    }

    /// Nothing in the folder but an empty Outbox and hidden files.
    private func isUnused(_ home: URL) -> Bool {
        guard let names = try? fileManager.contentsOfDirectory(atPath: home.path) else { return false }
        for name in names where !name.hasPrefix(".") {
            guard name == Self.outboxName,
                  let inside = try? fileManager.contentsOfDirectory(atPath: home.appending(path: name).path),
                  inside.allSatisfy({ $0.hasPrefix(".") }) else { return false }
        }
        return true
    }

    /// `Bots/<name>`, or `Bots/<name> 2`, `3`… when another bot already has that
    /// name, with its Outbox inside. A name whose skills folder is still there
    /// is taken too, though its desk is gone: the skills folder is found by the
    /// desk's name, and a newcomer never inherits another bot's skills. The
    /// leftover stays where it is.
    private func createHome(named name: String) throws -> URL {
        try ensureDirectory(botsRoot)
        let base = Self.folderName(for: name)
        for attempt in 1...99 {
            let candidate = botsRoot.appending(path: attempt == 1 ? base : "\(base) \(attempt)", directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: candidate.path)
                || fileManager.fileExists(atPath: skillsFolder(home: candidate).path) { continue }
            try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
            try ensureDirectory(candidate.appending(path: Self.outboxName, directoryHint: .isDirectory))
            return URL(fileURLWithPath: candidate.path)
        }
        throw BotWorkspaceError.unavailable
    }

    private func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw BotWorkspaceError.notAFolder }
            return
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func resolve(_ record: BotWorkspaceRecord) -> BotWorkspace {
        let home = Self.lexicalPath(layout.homeDirectory.path)
        let folders = record.folders.map { folder -> BotWorkspace.Folder in
            var url = URL(fileURLWithPath: folder.path)
            if let bookmark = folder.bookmark {
                var stale = false
                if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale) {
                    url = URL(fileURLWithPath: resolved.path)
                }
            }
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            let outOfReach = ClaudeTextWorkApprovalPolicy.isAtOrUnder(url.path, anyOf: protectedPaths)
                || Self.isTooWide(url.path, home: home)
            return BotWorkspace.Folder(id: folder.id, url: url, exists: exists, isOutOfReach: outOfReach)
        }
        return BotWorkspace(homeURL: URL(fileURLWithPath: record.homePath), folders: folders)
    }

    /// A path written on the data volume (`/System/Volumes/Data/Users/x`) as
    /// its plain spelling (`/Users/x`) when that names the same folder;
    /// anything else as given.
    static func plainSpelling(_ path: String) -> String {
        let volume = ClaudeTextWorkApprovalPolicy.dataVolume
        guard path.hasPrefix(volume + "/") else { return path }
        let plain = String(path.dropFirst(volume.count))
        var onVolume = stat(), atPlain = stat()
        guard stat(path, &onVolume) == 0, stat(plain, &atPlain) == 0,
              onVolume.st_dev == atPlain.st_dev, onVolume.st_ino == atPlain.st_ino else { return path }
        return plain
    }

    /// `.` and `..` removed without touching the filesystem or the spelling.
    static func lexicalPath(_ path: String) -> String {
        var parts: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { _ = parts.popLast(); continue }
            parts.append(String(component))
        }
        return "/" + parts.joined(separator: "/")
    }

    /// A Finder-safe folder name from the bot's display name.
    static func folderName(for name: String) -> String {
        let cleaned = name.map { character -> Character in
            if character == "/" || character == ":" { return "-" }
            if character.isNewline || character == "\0" { return " " }
            return character
        }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let bounded = String(trimmed.prefix(60))
        return bounded.isEmpty ? "Bot" : bounded
    }
}
