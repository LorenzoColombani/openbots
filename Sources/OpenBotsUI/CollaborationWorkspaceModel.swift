import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices

/// Screen-scoped project/team presentation. Durable mutations cross only
/// `ProjectTeamDirectoryServing`; conversation context uses its injected
/// service. Development fixtures are available only when explicitly injected.
@MainActor
public final class CollaborationWorkspaceModel: ObservableObject {
    public static let directoryDisclosure =
        "Projects, teams, and their members are saved locally on this Mac."
    public static let activeContextDisclosure =
        "Current project and team selection are preview context and reset when OpenBots quits."
    public var contextDisclosure: String {
        contextModel == nil ? Self.activeContextDisclosure :
            "Project and team choices save for this conversation. Only current memberships can be selected; this grants no tool or account access."
    }
    public let contextModel: ConversationContextModel?
    public static let fixtureDisclosure = CollaborationReviewFixtureService.disclosure

    @Published public private(set) var projects: [CollaborationProjectSnapshot] = []
    @Published public private(set) var teams: [CollaborationTeamSnapshot] = []
    @Published public private(set) var availableTeammates: [TeammateIdentitySnapshot]
    @Published public private(set) var loadState: CollaborationWorkspaceLoadState = .idle
    @Published public private(set) var isInspectorPresented = false

    @Published public var selectedProjectID: UUID? {
        didSet { rememberCurrentSelectionUnlessSuppressed() }
    }
    @Published public var selectedTeamID: UUID? {
        didSet { rememberCurrentSelectionUnlessSuppressed() }
    }

    @Published public private(set) var creationKind: CollaborationCreationKind?
    @Published public var draftName = ""
    @Published public var draftSummary = ""
    @Published public private(set) var draftMemberIDs: Set<UUID> = []
    @Published public private(set) var draftLeadID: UUID?
    @Published public private(set) var isSubmittingCreation = false
    @Published public private(set) var creationFailure: String?
    @Published public private(set) var reviewVariant: CollaborationReviewFixtureVariant =
        .successfulFanIn
    @Published public private(set) var reviewPresentation: CollaborationReviewPresentation?
    @Published public private(set) var reviewFailure: String?

    private let directoryService: any ProjectTeamDirectoryServing
    private let reviewFixtureService: CollaborationReviewFixtureService?
    private var activeConversationID: UUID?
    private var activeTeammateID: UUID?
    private var projectSelectionByConversationID: [UUID: UUID] = [:]
    private var teamSelectionByConversationID: [UUID: UUID] = [:]
    private var projectSelectionInitializedConversationIDs: Set<UUID> = []
    private var teamSelectionInitializedConversationIDs: Set<UUID> = []
    private var reviewVariantByConversationID: [UUID: CollaborationReviewFixtureVariant] = [:]
    private var reviewPresentationByVariant: [String: CollaborationReviewPresentation] = [:]
    private struct ConversationFixtureIdentity {
        let messageID: UUID
        let disclosurePartID: UUID
        let handoffPartID: UUID
    }
    private var conversationFixtureIdentityByConversationID: [
        UUID: ConversationFixtureIdentity
    ] = [:]
    private var suppressSelectionMemory = false
    private var contextSubscriptions: Set<AnyCancellable> = []
    private var creationGeneration: UInt64 = 0

    public init(
        directoryService: any ProjectTeamDirectoryServing,
        reviewFixtureService: CollaborationReviewFixtureService? = nil,
        availableTeammates: [TeammateIdentitySnapshot] = [],
        contextService: (any ConversationContextServing)? = nil
    ) {
        self.directoryService = directoryService
        self.reviewFixtureService = reviewFixtureService
        self.availableTeammates = Self.sortedTeammates(availableTeammates)
        contextModel = contextService.map { ConversationContextModel(service: $0) }
        selectedProjectID = nil
        selectedTeamID = nil
        refreshReviewPresentations()
        contextModel?.$selection.sink { [weak self] selection in
            guard let self else { return }
            self.selectedProjectID = selection?.projectID?.rawValue
            self.selectedTeamID = selection?.teamID?.rawValue
        }.store(in: &contextSubscriptions)
        contextModel?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &contextSubscriptions)
    }

    public var isReviewFixtureEnabled: Bool { reviewFixtureService != nil }

    public var selectableProjects: [CollaborationProjectSnapshot] {
        guard contextModel != nil else { return projects }
        return projects.filter { $0.members.contains { $0.id == activeTeammateID } }
    }

    public var selectableTeams: [CollaborationTeamSnapshot] {
        guard contextModel != nil else { return teams }
        return teams.filter { $0.members.contains { $0.id == activeTeammateID } }
    }

    public var selectedProject: CollaborationProjectSnapshot? {
        guard let selectedProjectID else { return nil }
        return projects.first(where: { $0.id == selectedProjectID })
    }

    public var selectedTeam: CollaborationTeamSnapshot? {
        guard let selectedTeamID else { return nil }
        return teams.first(where: { $0.id == selectedTeamID })
    }

    public var canSubmitCreation: Bool {
        guard creationKind != nil,
              !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draftMemberIDs.isEmpty,
              !isSubmittingCreation else { return false }
        if creationKind == .team {
            guard let draftLeadID, draftMemberIDs.contains(draftLeadID) else { return false }
        }
        return true
    }

    public var contextAccessibilityValue: String {
        let project = selectedProject?.name ?? "No project selected"
        let team = selectedTeam?.name ?? "No team selected"
        return "Project: \(project). Team: \(team)."
    }

    public func load() async {
        loadState = .loading
        do {
            async let projectSnapshots = directoryService.activeProjects()
            async let teamSnapshots = directoryService.activeTeams()
            let (loadedProjects, loadedTeams) = try await (projectSnapshots, teamSnapshots)
            projects = Self.sortedProjects(
                loadedProjects.map(CollaborationProjectSnapshot.init)
            )
            teams = Self.sortedTeams(
                loadedTeams.map(CollaborationTeamSnapshot.init)
            )
            restoreSelection(for: activeConversationID)
            loadState = .ready
        } catch {
            loadState = .failed(
                reason: "OpenBots could not load your saved projects and teams."
            )
        }
    }

    /// Moves only process-local work-context selection between conversations.
    /// Durable project/team membership remains unchanged.
    public func activateConversation(
        _ conversationID: UUID?,
        selectedTeammateID: UUID?
    ) {
        rememberCurrentSelectionUnlessSuppressed()
        activeConversationID = conversationID
        activeTeammateID = selectedTeammateID
        restoreSelection(for: conversationID)
        contextModel?.activate(conversationID: conversationID, teammateID: selectedTeammateID)
        let restoredVariant = conversationID.flatMap { reviewVariantByConversationID[$0] }
            ?? .successfulFanIn
        reviewVariant = restoredVariant
        reviewPresentation = reviewPresentationByVariant[restoredVariant.rawValue]
        if creationKind != nil {
            cancelCreation()
        }
    }

    public func replaceAvailableTeammates(
        _ teammates: [TeammateIdentitySnapshot]
    ) {
        availableTeammates = Self.sortedTeammates(teammates)
        let availableIDs = Set(availableTeammates.map(\.id))
        draftMemberIDs.formIntersection(availableIDs)
        if let draftLeadID, !availableIDs.contains(draftLeadID) {
            self.draftLeadID = draftMemberIDs.sorted(by: Self.uuidLessThan).first
        }
    }

    public func toggleInspector() {
        isInspectorPresented.toggle()
    }

    public func showInspector() {
        guard !isInspectorPresented else { return }
        isInspectorPresented = true
    }

    public func hideInspector() {
        guard isInspectorPresented else { return }
        isInspectorPresented = false
    }

    public func selectProject(_ projectID: UUID?) {
        guard projectID == nil || selectableProjects.contains(where: { $0.id == projectID }) else { return }
        if let contextModel {
            contextModel.select(projectID: projectID, teamID: selectedTeamID)
            return
        }
        selectedProjectID = projectID
    }

    public func selectTeam(_ teamID: UUID?) {
        guard teamID == nil || selectableTeams.contains(where: { $0.id == teamID }) else { return }
        if let contextModel {
            contextModel.select(projectID: selectedProjectID, teamID: teamID)
            return
        }
        selectedTeamID = teamID
    }

    public func selectReviewVariant(_ variant: CollaborationReviewFixtureVariant) {
        guard isReviewFixtureEnabled else { return }
        reviewVariant = variant
        if let activeConversationID {
            reviewVariantByConversationID[activeConversationID] = variant
        }
        reviewPresentation = reviewPresentationByVariant[variant.rawValue]
    }

    /// Produces one stable, process-local transcript row for the exact
    /// conversation. No repository receives this message and changing the
    /// review variant reuses the same row and part identities.
    public func conversationFixtureMessage(
        for conversationID: UUID
    ) -> ChatMessageSnapshot? {
        guard isReviewFixtureEnabled else { return nil }
        let variant = reviewVariantByConversationID[conversationID] ?? .successfulFanIn
        guard let presentation = reviewPresentationByVariant[variant.rawValue] else { return nil }
        let identity: ConversationFixtureIdentity
        if let existing = conversationFixtureIdentityByConversationID[conversationID] {
            identity = existing
        } else {
            identity = ConversationFixtureIdentity(
                messageID: UUID(),
                disclosurePartID: UUID(),
                handoffPartID: UUID()
            )
            conversationFixtureIdentityByConversationID[conversationID] = identity
        }
        return ChatMessageSnapshot(
            id: identity.messageID,
            author: .teammate(presentation.handoff.receiver),
            parts: [
                ChatMessagePartSnapshot(
                    id: identity.disclosurePartID,
                    ordinal: 0,
                    content: .status(Self.fixtureDisclosure)
                ),
                ChatMessagePartSnapshot(
                    id: identity.handoffPartID,
                    ordinal: 1,
                    content: .handoff(presentation.handoff)
                )
            ],
            delivery: .sent,
            timestamp: presentation.handoff.timeline.first?.timestamp ?? Date(timeIntervalSince1970: 0)
        )
    }

    public func beginCreation(_ kind: CollaborationCreationKind) {
        creationGeneration &+= 1
        creationKind = kind
        draftName = ""
        draftSummary = ""
        creationFailure = nil
        let preferred = activeTeammateID.flatMap { activeID in
            availableTeammates.first(where: { $0.id == activeID })?.id
        } ?? availableTeammates.first?.id
        draftMemberIDs = preferred.map { [$0] } ?? []
        draftLeadID = kind == .team ? preferred : nil
        isInspectorPresented = true
    }

    public func cancelCreation() {
        creationGeneration &+= 1
        creationKind = nil
        draftName = ""
        draftSummary = ""
        draftMemberIDs = []
        draftLeadID = nil
        creationFailure = nil
        isSubmittingCreation = false
    }

    public func toggleDraftMember(_ teammateID: UUID) {
        guard availableTeammates.contains(where: { $0.id == teammateID }) else { return }
        if draftMemberIDs.contains(teammateID) {
            draftMemberIDs.remove(teammateID)
            if draftLeadID == teammateID {
                draftLeadID = draftMemberIDs.sorted(by: Self.uuidLessThan).first
            }
        } else {
            draftMemberIDs.insert(teammateID)
            if creationKind == .team, draftLeadID == nil {
                draftLeadID = teammateID
            }
        }
        creationFailure = nil
    }

    public func selectDraftLead(_ teammateID: UUID) {
        guard creationKind == .team, draftMemberIDs.contains(teammateID) else { return }
        draftLeadID = teammateID
        creationFailure = nil
    }

    public func submitCreation() async {
        guard canSubmitCreation, let creationKind else { return }
        let ticket = creationGeneration
        let originConversation = activeConversationID
        let originTeammate = activeTeammateID
        isSubmittingCreation = true
        creationFailure = nil
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = draftSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let memberIDs = Set(draftMemberIDs.map(TeammateID.init))

        do {
            switch creationKind {
            case .project:
                let created = try await directoryService.createProject(
                    ProjectDirectoryDraft(
                        name: name,
                        summary: summary.isEmpty ? nil : summary,
                        memberIDs: memberIDs
                    )
                )
                let presentation = CollaborationProjectSnapshot(created)
                projects = Self.sortedProjects(
                    projects.filter { $0.id != presentation.id } + [presentation]
                )
                if ticket == creationGeneration, originConversation == activeConversationID,
                   originTeammate == activeTeammateID {
                    selectProject(presentation.id)
                }
            case .team:
                guard let draftLeadID else { return }
                let created = try await directoryService.createTeam(
                    TeamDirectoryDraft(
                        name: name,
                        summary: summary.isEmpty ? nil : summary,
                        leadID: TeammateID(draftLeadID),
                        memberIDs: memberIDs
                    )
                )
                let presentation = CollaborationTeamSnapshot(created)
                teams = Self.sortedTeams(
                    teams.filter { $0.id != presentation.id } + [presentation]
                )
                if ticket == creationGeneration, originConversation == activeConversationID,
                   originTeammate == activeTeammateID {
                    selectTeam(presentation.id)
                }
            }
            guard ticket == creationGeneration else { return }
            isSubmittingCreation = false
            cancelCreation()
        } catch {
            guard ticket == creationGeneration else { return }
            isSubmittingCreation = false
            creationFailure = "OpenBots could not save this \(creationKind.visibleName.lowercased())."
        }
    }

    private func restoreSelection(for conversationID: UUID?) {
        guard contextModel == nil else {
            let selection = contextModel?.selection
            selectedProjectID = selection?.conversationID.rawValue == conversationID ? selection?.projectID?.rawValue : nil
            selectedTeamID = selection?.conversationID.rawValue == conversationID ? selection?.teamID?.rawValue : nil
            return
        }
        suppressSelectionMemory = true
        defer { suppressSelectionMemory = false }

        let rememberedProject = conversationID.flatMap { projectSelectionByConversationID[$0] }
        if let conversationID,
           projectSelectionInitializedConversationIDs.contains(conversationID) {
            selectedProjectID = rememberedProject.flatMap { remembered in
                projects.contains(where: { $0.id == remembered }) ? remembered : nil
            }
        } else {
            selectedProjectID = projects.first?.id
        }

        let rememberedTeam = conversationID.flatMap { teamSelectionByConversationID[$0] }
        if let conversationID,
           teamSelectionInitializedConversationIDs.contains(conversationID) {
            selectedTeamID = rememberedTeam.flatMap { remembered in
                teams.contains(where: { $0.id == remembered }) ? remembered : nil
            }
        } else {
            selectedTeamID = teams.first?.id
        }
    }

    private func refreshReviewPresentations() {
        guard let reviewFixtureService else {
            reviewPresentationByVariant = [:]
            reviewPresentation = nil
            reviewFailure = nil
            return
        }
        do {
            reviewPresentationByVariant = try Dictionary(
                uniqueKeysWithValues: CollaborationReviewFixtureVariant.allCases.map { variant in
                    let snapshot = try reviewFixtureService.snapshot(variant: variant)
                    return (variant.rawValue, try CollaborationReviewPresentation(snapshot))
                }
            )
            reviewPresentation = reviewPresentationByVariant[reviewVariant.rawValue]
            reviewFailure = nil
        } catch {
            reviewPresentationByVariant = [:]
            reviewPresentation = nil
            reviewFailure = "The process-local collaboration review fixture is unavailable."
        }
    }

    private func rememberCurrentSelectionUnlessSuppressed() {
        guard contextModel == nil, !suppressSelectionMemory, let activeConversationID else { return }
        projectSelectionInitializedConversationIDs.insert(activeConversationID)
        teamSelectionInitializedConversationIDs.insert(activeConversationID)
        if let selectedProjectID {
            projectSelectionByConversationID[activeConversationID] = selectedProjectID
        } else {
            projectSelectionByConversationID.removeValue(forKey: activeConversationID)
        }
        if let selectedTeamID {
            teamSelectionByConversationID[activeConversationID] = selectedTeamID
        } else {
            teamSelectionByConversationID.removeValue(forKey: activeConversationID)
        }
    }

    private static func sortedProjects(
        _ projects: [CollaborationProjectSnapshot]
    ) -> [CollaborationProjectSnapshot] {
        projects.sorted { left, right in
            let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
            return comparison == .orderedSame
                ? uuidLessThan(left.id, right.id)
                : comparison == .orderedAscending
        }
    }

    private static func sortedTeams(
        _ teams: [CollaborationTeamSnapshot]
    ) -> [CollaborationTeamSnapshot] {
        teams.sorted { left, right in
            let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
            return comparison == .orderedSame
                ? uuidLessThan(left.id, right.id)
                : comparison == .orderedAscending
        }
    }

    private static func sortedTeammates(
        _ teammates: [TeammateIdentitySnapshot]
    ) -> [TeammateIdentitySnapshot] {
        teammates.sorted { left, right in
            let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
            return comparison == .orderedSame
                ? uuidLessThan(left.id, right.id)
                : comparison == .orderedAscending
        }
    }

    private static func uuidLessThan(_ left: UUID, _ right: UUID) -> Bool {
        left.uuidString < right.uuidString
    }
}
