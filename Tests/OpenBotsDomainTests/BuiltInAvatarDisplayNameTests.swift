import Foundation
import OpenBotsDomain
import Testing

struct BuiltInAvatarDisplayNameTests {
    @Test("Built-in avatar labels retain their established names")
    func establishedDisplayNames() {
        #expect(BuiltInAvatar.allCases.map(\.displayName) == ["Pillow", "Yogurt", "Kite", "Bean", "Canobi"])
    }

    @Test("Display labels do not rename persisted avatar identifiers")
    func savedIdentifiersRemainUnchanged() throws {
        let avatars: [BuiltInAvatar] = [.pillow, .fin, .kite, .bean, .guide]
        let identifiers = ["pillow", "fin", "kite", "bean", "guide"]
        #expect(avatars.map(\.rawValue) == identifiers)
        let encoded = try JSONEncoder().encode(avatars)
        let encodedIdentifiers = try JSONDecoder().decode([String].self, from: encoded)
        #expect(encodedIdentifiers == identifiers)
        let historicalData = try JSONEncoder().encode(identifiers)
        let restored = try JSONDecoder().decode([BuiltInAvatar].self, from: historicalData)
        #expect(restored == avatars)
        #expect(restored[1].displayName == "Yogurt")
        #expect(restored[4].displayName == "Canobi")
    }
}
