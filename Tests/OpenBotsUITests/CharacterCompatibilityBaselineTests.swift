import OpenBotsDomain
import Testing
@testable import OpenBotsUI

/// Literal saved-appearance vectors: adding vocabulary must not silently
/// change the fallback identities of tokens the renderer does not recognize.
@Suite("CharacterCompatibilityBaselineTests")
struct CharacterCompatibilityBaselineTests {
    @Test("Unknown saved tokens retain their literal fallback identities at boundary seeds")
    func unknownSavedTokenMappingsRemainCompatible() {
        let cases: [(seed: UInt64, silhouette: CharacterSilhouetteDescriptor,
                     palette: CharacterPaletteDescriptor, eyes: CharacterEyeDescriptor,
                     mark: CharacterMarkDescriptor)] = [
            (8_811, .tallTuft, .violetCoral, .roundAlert, .foreheadSpark),
            (0, .softArch, .amber, .calm, .pairedCheekMarks),
            (UInt64.max, .cloud, .violet, .calm, .softCrown)
        ]
        for expected in cases {
            let descriptor = CharacterIdentityDescriptor(appearance: compatibilitySnapshot(seed: expected.seed))
            #expect(descriptor.grammarVersion == 99)
            #expect(descriptor.deterministicSeed == expected.seed)
            #expect(descriptor.silhouette == expected.silhouette)
            #expect(descriptor.palette == expected.palette)
            #expect(descriptor.eyes == expected.eyes)
            #expect(descriptor.mark == expected.mark)
        }
    }

    @Test("Unknown-token fallback retains original bytes instead of normalizing them")
    func unknownUnderscoreTokensKeepTheirDistinctSavedIdentity() {
        let descriptor = CharacterIdentityDescriptor(appearance: compatibilitySnapshot(
            seed: 8_811,
            tokens: ("future_silhouette", "future_palette", "future_eyes", "future_mark")
        ))
        #expect(descriptor.grammarVersion == 99)
        #expect(descriptor.deterministicSeed == 8_811)
        #expect(descriptor.silhouette == .sprout)
        #expect(descriptor.palette == .mint)
        #expect(descriptor.eyes == .softFocused)
        #expect(descriptor.mark == .softCrown)
    }
}

private func compatibilitySnapshot(
    seed: UInt64,
    tokens: (String, String, String, String) = ("future silhouette", "future palette", "future eyes", "future mark")
) -> CharacterAppearanceSnapshot {
    CharacterAppearanceSnapshot(
        mode: .creature, grammarVersion: 99, deterministicSeed: seed,
        silhouette: tokens.0, paletteToken: tokens.1, eyeDialect: tokens.2,
        nonColorIdentityCue: tokens.3, accessibleIdentityDescription: "Saved unknown creature", revision: 2
    )
}
