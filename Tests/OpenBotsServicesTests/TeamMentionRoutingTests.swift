import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

@Suite("Team mention routing")
struct TeamMentionRoutingTests {
    let date = Date(timeIntervalSince1970: 100)
    func bot(_ name: String, lifecycle: TeammateLifecycle = .active) throws -> Teammate {
        try Teammate(id: TeammateID(UUID()), profile: TeammateProfile(displayName: name, role: "Role"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 1, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "crest", accessibleIdentityDescription: "Round"),
            lifecycle: lifecycle, createdAt: date, updatedAt: date)
    }
    func team(lead: Teammate, members: [Teammate]) throws -> Team {
        try Team(id: TeamID(UUID()), name: "QA", leadID: lead.id, memberIDs: Set(members.map(\.id)), createdAt: date, updatedAt: date)
    }

    @Test("Unmentioned text goes to the lead")
    func leadByDefault() throws {
        let mira = try bot("Mira"), ada = try bot("Ada")
        let route = try #require(TeamMentionRouting.recipient(for: "Please summarise the plan.", team: team(lead: mira, members: [mira, ada]), members: [mira, ada]))
        #expect(route.teammateID == mira.id)
        #expect(route.isLead)
        #expect(route.mentionedName == nil)
    }

    @Test("An @mention names one member, case-insensitively, and reports the exact name")
    func mentionRoutesToThatMember() throws {
        let mira = try bot("Mira"), ada = try bot("Ada")
        let t = try team(lead: mira, members: [mira, ada])
        let route = try #require(TeamMentionRouting.recipient(for: "@ada can you check this?", team: t, members: [mira, ada]))
        #expect(route.teammateID == ada.id)
        #expect(!route.isLead)
        #expect(route.mentionedName == "Ada")
    }

    @Test("The longest matching name wins and a partial word is not a mention")
    func longestNameAndWordBoundary() throws {
        let mira = try bot("Mira"), ada = try bot("Ada"), lovelace = try bot("Ada Lovelace")
        let t = try team(lead: mira, members: [mira, ada, lovelace])
        let long = try #require(TeamMentionRouting.recipient(for: "@Ada Lovelace please", team: t, members: [mira, ada, lovelace]))
        #expect(long.teammateID == lovelace.id)
        let partial = try #require(TeamMentionRouting.recipient(for: "@Adam is not here", team: t, members: [mira, ada, lovelace]))
        #expect(partial.teammateID == mira.id)
        let email = try #require(TeamMentionRouting.recipient(for: "write to me@ada.example", team: t, members: [mira, ada, lovelace]))
        #expect(email.teammateID == mira.id)
    }

    @Test("The earliest mention wins when several members are named")
    func earliestMentionWins() throws {
        let mira = try bot("Mira"), ada = try bot("Ada"), bo = try bot("Bo")
        let t = try team(lead: mira, members: [mira, ada, bo])
        let route = try #require(TeamMentionRouting.recipient(for: "@Bo then @Ada", team: t, members: [mira, ada, bo]))
        #expect(route.teammateID == bo.id)
    }

    @Test("An archived or non-member name is not a recipient; an archived lead means no route")
    func inactiveNamesAreIgnored() throws {
        let mira = try bot("Mira"), ada = try bot("Ada", lifecycle: .archived), outsider = try bot("Zed")
        let t = try team(lead: mira, members: [mira, ada])
        let archived = try #require(TeamMentionRouting.recipient(for: "@Ada hello", team: t, members: [mira, ada]))
        #expect(archived.teammateID == mira.id)
        let stranger = try #require(TeamMentionRouting.recipient(for: "@Zed hello", team: t, members: [mira, ada, outsider]))
        #expect(stranger.teammateID == mira.id)
        let archivedLead = try bot("Lead", lifecycle: .archived)
        let broken = try team(lead: archivedLead, members: [archivedLead, outsider])
        #expect(TeamMentionRouting.recipient(for: "hello", team: broken, members: [archivedLead, outsider]) == nil)
    }
}
