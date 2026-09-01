import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing

struct DefaultBotNameTests {
    @Test("Omitted names use the exact new-bot defaults for the two stable avatar IDs")
    func omittedNameUsesAvatarDefault() throws {
        for (avatar, expectedName) in [("fin", "Yogurt"), ("guide", "Canobi")] {
            let id = TeammateID(UUID())
            let appearance = try appearance(avatar: avatar)
            let draft = DurableTeammateDraft(teammateID: id, role: "Not configured", appearance: appearance)
            #expect(draft.displayName == expectedName)
            #expect(draft.teammateID == id)
            #expect(draft.appearance == appearance)
            #expect(draft.role == "Not configured")
        }
    }

    @Test("Every explicit name wins, including the old default and unvalidated empty text", arguments: ["User name", "Fin", "Guide", "New Bot", "", "  Custom name  "])
    func explicitNameIsNeverReplaced(name: String) throws {
        for avatar in ["fin", "guide"] {
            let draft = DurableTeammateDraft(teammateID: TeammateID(UUID()), displayName: name,
                role: "Research", appearance: try appearance(avatar: avatar))
            #expect(draft.displayName == name)
            if name.isEmpty {
                #expect(throws: DomainValidationError.self) {
                    _ = try TeammateProfile(displayName: draft.displayName, role: draft.role)
                }
            }
        }
    }

    @Test("Other and unknown avatar IDs retain New Bot without changing identity")
    func unrelatedAvatarDefaultsAreUnchanged() throws {
        for avatar in [nil, "pillow", "kite", "bean", "future-avatar", "Fin", "Guide"] as [String?] {
            let appearance = try appearance(avatar: avatar)
            let draft = DurableTeammateDraft(teammateID: TeammateID(UUID()), role: "Research", appearance: appearance)
            #expect(draft.displayName == "New Bot")
            #expect(draft.appearance == appearance)
        }
    }

    @Test("Photo mode never adopts a creature default from a retained built-in ID")
    func photoModeKeepsOrdinaryDefault() throws {
        for avatar in ["fin", "guide"] {
            let appearance = try appearance(avatar: avatar, mode: .photo)
            let draft = DurableTeammateDraft(teammateID: TeammateID(UUID()), role: "Research", appearance: appearance)
            #expect(draft.displayName == "New Bot")
            #expect(draft.appearance == appearance)
        }
    }

    private func appearance(avatar: String?, mode: AppearanceMode = .creature) throws -> AgentAppearance {
        try AgentAppearance(mode: mode, grammarVersion: 1, deterministicSeed: 123,
            silhouette: "round", paletteToken: "mint", eyeDialect: "calm",
            nonColorIdentityCue: "leaf ears", accessibleIdentityDescription: "Saved character",
            profileAssetID: mode == .photo ? ProfileAssetID(UUID()) : nil, builtInAvatarID: avatar)
    }
}
