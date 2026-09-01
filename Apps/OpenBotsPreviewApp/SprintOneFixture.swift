import Combine
import Foundation
import OpenBotsUI
import SwiftUI

/// Process-local Sprint 1 review data. It deliberately exercises the real
/// presentation seams without opening storage, Keychain, Claude, a runtime
/// process, or the network.
@MainActor
final class SprintOneFixture: ObservableObject {
    let sidebar: SidebarModel
    private(set) lazy var conversation: ConversationModel = makeConversationModel()

    @Published var creationModel: TeammateCreationModel?

    private var identities: [UUID: TeammateIdentitySnapshot]
    private var messagesByTeammate: [UUID: [ChatMessageSnapshot]]
    private var conversationIDs: [UUID: UUID]
    private var activeTeammateID: UUID?
    private var nextAppearanceSeed: UInt64 = 31
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let mika = TeammateIdentitySnapshot(
            id: UUID(uuidString: "81000000-0000-0000-0000-000000000001")!,
            name: "Mika",
            role: "Research and synthesis",
            appearance: CharacterAppearanceSnapshot(
                mode: .creature,
                grammarVersion: 1,
                deterministicSeed: 11,
                silhouette: "sprout",
                paletteToken: "violet",
                eyeDialect: "bright",
                nonColorIdentityCue: "leaf ears",
                accessibleIdentityDescription: "Violet sprout creature with leaf ears and bright eyes",
                profileAssetID: nil,
                revision: 1
            )
        )
        let rook = TeammateIdentitySnapshot(
            id: UUID(uuidString: "81000000-0000-0000-0000-000000000002")!,
            name: "Rook",
            role: "Builds and verifies",
            appearance: CharacterAppearanceSnapshot(
                mode: .creature,
                grammarVersion: 1,
                deterministicSeed: 22,
                silhouette: "drop",
                paletteToken: "mint",
                eyeDialect: "calm",
                nonColorIdentityCue: "two antennae",
                accessibleIdentityDescription: "Mint drop creature with two antennae and calm eyes",
                profileAssetID: nil,
                revision: 1
            )
        )

        let mikaConversationID = UUID(uuidString: "82000000-0000-0000-0000-000000000001")!
        let rookConversationID = UUID(uuidString: "82000000-0000-0000-0000-000000000002")!
        let fixtureDate = Date(timeIntervalSince1970: 1_788_000_000)

        identities = [mika.id: mika, rook.id: rook]
        conversationIDs = [mika.id: mikaConversationID, rook.id: rookConversationID]
        messagesByTeammate = [
            mika.id: [
                ChatMessageSnapshot(
                    id: UUID(uuidString: "83000000-0000-0000-0000-000000000001")!,
                    author: .teammate(mika),
                    body: "Local fixture greeting — tell me what you want to understand, and I’ll keep the sources and open questions visible. No Claude process has been started.",
                    delivery: .sent,
                    timestamp: fixtureDate
                )
            ],
            rook.id: [
                ChatMessageSnapshot(
                    id: UUID(uuidString: "83000000-0000-0000-0000-000000000002")!,
                    author: .teammate(rook),
                    body: "Local fixture greeting — I’m checking a build-shaped task. This status is simulated and no command is running.",
                    delivery: .sent,
                    timestamp: fixtureDate.addingTimeInterval(60)
                )
            ]
        ]
        activeTeammateID = mika.id
        sidebar = SidebarModel(
            rows: [
                TeammateRowSnapshot(identity: mika, activity: .idle),
                TeammateRowSnapshot(
                    identity: rook,
                    activity: .thinkingOrWorking,
                    unreadCount: 1
                )
            ],
            selection: mika.id
        )

        sidebar.$selection
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] selection in
                self?.showConversation(for: selection)
            }
            .store(in: &cancellables)
    }

    func beginTeammateCreation() {
        guard creationModel == nil else { return }
        let seed = nextAppearanceSeed
        nextAppearanceSeed &+= 13
        creationModel = TeammateCreationModel(
            identityID: UUID(),
            appearance: .fixture(seed: seed),
            submit: { [weak self] identity in
                self?.insert(identity)
            }
        )
    }

    func setSelectedActivity(_ activity: TeammateActivityState) {
        guard
            let selectedID = sidebar.selection,
            let current = sidebar.rows.first(where: { $0.id == selectedID })
        else { return }
        sidebar.update(
            TeammateRowSnapshot(
                identity: current.identity,
                activity: activity,
                unreadCount: current.unreadCount
            )
        )
    }

    private func insert(_ identity: TeammateIdentitySnapshot) {
        identities[identity.id] = identity
        conversationIDs[identity.id] = UUID()
        messagesByTeammate[identity.id] = [
            ChatMessageSnapshot(
                id: UUID(),
                author: .teammate(identity),
                body: "Local fixture greeting — I’m \(identity.name). My profile exists only for this review session; it has not been saved and Claude is not running.",
                delivery: .sent,
                timestamp: Date()
            )
        ]
        sidebar.update(
            TeammateRowSnapshot(identity: identity, activity: .idle)
        )
        sidebar.selection = identity.id
    }

    private func makeConversationModel() -> ConversationModel {
        let identity = activeIdentity
        return ConversationModel(
            conversationID: activeTeammateID.flatMap { conversationIDs[$0] },
            title: identity?.name ?? "Conversation",
            messages: activeTeammateID.flatMap { messagesByTeammate[$0] } ?? [],
            readyDeliveryDescription:
                "Messages appear immediately; replies are a local fixture. Claude and tools are not running.",
            inputAvailability: .ready,
            submit: { [weak self] messageID, _, text in
                await self?.acceptFixtureMessage(messageID: messageID, text: text)
            }
        )
    }

    private func showConversation(for teammateID: UUID?) {
        if let activeTeammateID {
            messagesByTeammate[activeTeammateID] = conversation.messages
        }
        activeTeammateID = teammateID
        conversation.composerText = ""
        conversation.show(
            conversationID: teammateID.flatMap { conversationIDs[$0] },
            title: teammateID.flatMap { identities[$0]?.name } ?? "Conversation",
            messages: teammateID.flatMap { messagesByTeammate[$0] } ?? []
        )
    }

    private func acceptFixtureMessage(messageID: UUID, text: String) async {
        guard
            let targetID = activeTeammateID,
            let identity = identities[targetID]
        else { return }

        if let pending = conversation.messages.first(where: { $0.id == messageID }) {
            conversation.replaceMessage(
                ChatMessageSnapshot(
                    id: pending.id,
                    author: pending.author,
                    body: pending.body,
                    delivery: .sent,
                    timestamp: pending.timestamp
                )
            )
        }
        setActivity(.thinkingOrWorking, teammateID: targetID)

        try? await Task.sleep(for: .milliseconds(450))

        let response = ChatMessageSnapshot(
            id: UUID(),
            author: .teammate(identity),
            body: "Local fixture response — I received “\(text)”. This proves the immediate chat and identity path only; no Claude runtime or tool executed it.",
            delivery: .sent,
            timestamp: Date()
        )
        if activeTeammateID == targetID {
            conversation.replaceMessage(response)
            messagesByTeammate[targetID] = conversation.messages
        } else {
            var messages = messagesByTeammate[targetID] ?? []
            if let index = messages.firstIndex(where: { $0.id == messageID }) {
                let pending = messages[index]
                messages[index] = ChatMessageSnapshot(
                    id: pending.id,
                    author: pending.author,
                    body: pending.body,
                    delivery: .sent,
                    timestamp: pending.timestamp
                )
            }
            messages.append(response)
            messagesByTeammate[targetID] = messages
        }
        setActivity(.waitingForUser, teammateID: targetID)
    }

    private func setActivity(_ activity: TeammateActivityState, teammateID: UUID) {
        guard let current = sidebar.rows.first(where: { $0.id == teammateID }) else { return }
        sidebar.update(
            TeammateRowSnapshot(
                identity: current.identity,
                activity: activity,
                unreadCount: current.unreadCount
            )
        )
    }

    private var activeIdentity: TeammateIdentitySnapshot? {
        activeTeammateID.flatMap { identities[$0] }
    }
}

struct SprintOneWorkspaceView: View {
    @ObservedObject var fixture: SprintOneFixture
    let openSettings: @MainActor () -> Void

    var body: some View {
        OpenBotsRootView(
            sidebar: fixture.sidebar,
            conversation: fixture.conversation,
            createTeammate: fixture.beginTeammateCreation,
            openSettings: openSettings
        )
        .sheet(item: $fixture.creationModel) { model in
            TeammateCreationView(model: model)
        }
    }
}
