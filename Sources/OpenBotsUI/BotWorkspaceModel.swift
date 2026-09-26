import AppKit
import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices

/// The selected bot's desk on the Mac, for Details: its own folder and the
/// folders the user added. Reading it creates the folder if it is missing;
/// adding one opens the native picker. Nothing here grants anything.
@MainActor
public final class BotWorkspaceModel: ObservableObject {
    @Published public private(set) var workspace: BotWorkspace?
    @Published public private(set) var notice: String?
    @Published public private(set) var isBusy = false
    /// The bot's skills, and the user's own Claude skills it could be given.
    @Published public private(set) var skills: [BotSkill] = []
    @Published public private(set) var availableSkills: [BotSkill] = []
    @Published public private(set) var skillNotice: String?
    /// Whether `~/.claude/skills` has been read for the selected bot. Until it
    /// has, the Add Skill menu claims nothing about what is there.
    @Published public private(set) var skillLibraryIsLoaded = false
    /// How many folders in `~/.claude/skills` could not be offered.
    @Published public private(set) var unusableSkillCount = 0
    public private(set) var teammateID: TeammateID?
    private let service: BotWorkspaceService
    private var generation: UInt64 = 0
    private var activation: AnyCancellable?

    public init(service: BotWorkspaceService) {
        self.service = service
        // A skill added or fixed in Finder shows the next time the user comes
        // back to the app, not only after they pick another bot.
        activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.refreshSkillLibrary() } }
    }

    /// The line the Add Skill menu shows in place of skills, or nil while it
    /// lists some (it must not say "No skills" before the folder is read, or
    /// when the folder holds skills it cannot offer).
    var skillMenuNote: String? {
        guard skillLibraryIsLoaded else { return BotSkillsCopy.readingSkills }
        guard availableSkills.isEmpty else { return nil }
        return unusableSkillCount > 0 ? BotSkillsCopy.noUsableSkills : BotSkillsCopy.noSkills
    }

    /// Reads `~/.claude/skills` again for the selected bot.
    public func refreshSkillLibrary() {
        guard teammateID != nil else { return }
        let expected = generation
        Task { [weak self] in
            guard let self else { return }
            let library = await self.service.skillLibrary()
            guard expected == self.generation else { return }
            self.apply(library)
        }
    }

    private func apply(_ library: BotSkillLibrary) {
        availableSkills = library.offered
        unusableSkillCount = library.unusableCount
        skillLibraryIsLoaded = true
    }

    public func select(_ id: TeammateID?) {
        guard teammateID != id else { return }
        teammateID = id; workspace = nil; notice = nil; skills = []; availableSkills = []; skillNotice = nil
        skillLibraryIsLoaded = false; unusableSkillCount = 0
        generation &+= 1
        guard let id else { return }
        let expected = generation
        Task { [weak self] in
            guard let self else { return }
            let loaded = try? await self.service.workspace(teammateID: id)
            let held = (try? await self.service.skills(teammateID: id)) ?? []
            let library = await self.service.skillLibrary()
            guard expected == self.generation else { return }
            self.workspace = loaded; self.skills = held
            self.apply(library)
        }
    }

    /// Copies one of the user's Claude skills into the bot's skills folder.
    public func addSkill(named name: String) {
        changeSkills { service, id in try await service.addSkill(named: name, teammateID: id) }
    }

    public func removeSkill(named name: String) {
        changeSkills { service, id in try await service.removeSkill(named: name, teammateID: id) }
    }

    private func changeSkills(_ change: @escaping @Sendable (BotWorkspaceService, TeammateID) async throws -> [BotSkill]) {
        guard let id = teammateID, !isBusy else { return }
        let expected = generation
        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                let updated = try await change(self.service, id)
                let library = await self.service.skillLibrary()
                guard expected == self.generation else { return }
                self.skills = updated; self.skillNotice = nil
                self.apply(library)
            } catch {
                guard expected == self.generation else { return }
                self.skillNotice = Self.skillExplanation(error)
            }
        }
    }

    private static func skillExplanation(_ error: any Error) -> String {
        switch error as? BotWorkspaceError {
        case .skillNotFound: "That skill is no longer in your Claude skills folder."
        case .skillAlreadyAdded: "This bot already has that skill."
        case .skillTooLarge: "That skill is too large to copy: more than 256 files or 8 MB."
        case .skillLimitReached: "This bot already has as many skills as it can have."
        default: "The skill could not be changed."
        }
    }

    public func revealHome() {
        guard let workspace else { return }
        NSWorkspace.shared.activateFileViewerSelecting([workspace.homeURL])
    }

    public func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The native folder picker. The choice is kept with a bookmark, so a
    /// rename in Finder does not lose it.
    public func addFolder() {
        guard let id = teammateID, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder this bot may work in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let expected = generation
        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                let updated = try await self.service.addFolder(url, teammateID: id)
                guard expected == self.generation else { return }
                self.workspace = updated; self.notice = nil
            } catch {
                guard expected == self.generation else { return }
                self.notice = Self.explanation(error)
            }
        }
    }

    public func removeFolder(id folderID: UUID) {
        guard let id = teammateID, !isBusy else { return }
        let expected = generation
        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                let updated = try await self.service.removeFolder(id: folderID, teammateID: id)
                guard expected == self.generation else { return }
                self.workspace = updated; self.notice = nil
            } catch {
                guard expected == self.generation else { return }
                self.notice = Self.explanation(error)
            }
        }
    }

    private static func explanation(_ error: any Error) -> String {
        switch error as? BotWorkspaceError {
        case .notAFolder: "That is not a folder."
        case .folderLimitReached: "This bot already has as many folders as it can have."
        case .protectedFolder: "That folder is private data or sits inside it (passwords, browser data, mail, messages, contacts, calendars, photos, iCloud Drive, the Library and .config folders), or it is your whole home folder, or the app's own files; bots never work there. A folder that only holds private data, like Pictures, can be added: what is private inside it stays out of reach."
        default: "The folder could not be added."
        }
    }
}
