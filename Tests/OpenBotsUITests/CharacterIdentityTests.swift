import Foundation
import OpenBotsDomain
import SwiftUI
import Testing
@testable import OpenBotsUI

@Test("Explicit appearance tokens select every color-independent identity feature")
func explicitAppearanceTokensDriveIdentityDescriptor() {
    let appearance = CharacterAppearanceSnapshot(
        mode: .creature,
        grammarVersion: 3,
        deterministicSeed: 41,
        silhouette: "round-ears",
        paletteToken: "violet-coral",
        eyeDialect: "wide-curious",
        nonColorIdentityCue: "forehead spark",
        accessibleIdentityDescription: "Round-eared creature with a forehead spark",
        revision: 7
    )

    let descriptor = CharacterIdentityDescriptor(appearance: appearance)

    #expect(descriptor.mode == .creature)
    #expect(descriptor.grammarVersion == 3)
    #expect(descriptor.deterministicSeed == 41)
    #expect(descriptor.silhouette == .roundEars)
    #expect(descriptor.palette == .violetCoral)
    #expect(descriptor.eyes == .wideCurious)
    #expect(descriptor.mark == .foreheadSpark)
    #expect(descriptor.accessibleDescription == "Round-eared creature with a forehead spark")
    #expect(descriptor.revision == 7)
}

@Test("Legacy appearance vocabulary remains a first-class rendering contract")
func legacyAppearanceVocabularyIsNotCollapsedToSeedOnly() {
    let appearance = CharacterAppearanceSnapshot(
        mode: .creature,
        grammarVersion: 1,
        deterministicSeed: 999,
        silhouette: "cloud",
        paletteToken: "mint",
        eyeDialect: "calm",
        nonColorIdentityCue: "two antennae",
        accessibleIdentityDescription: "Cloud creature with calm eyes and two antennae",
        revision: 1
    )

    let descriptor = CharacterIdentityDescriptor(appearance: appearance)

    #expect(descriptor.silhouette == .cloud)
    #expect(descriptor.palette == .mint)
    #expect(descriptor.eyes == .calm)
    #expect(descriptor.mark == .twoAntennae)
}

@Test("Silhouette and mark distinguish identities independently of palette")
func colorIndependentIdentityCuesRemainDistinct() {
    let first = CharacterIdentityDescriptor(
        appearance: CharacterAppearanceSnapshot(
            mode: .creature,
            grammarVersion: 1,
            deterministicSeed: 77,
            silhouette: "soft-arch",
            paletteToken: "teal-gold",
            eyeDialect: "round-alert",
            nonColorIdentityCue: "single brow notch",
            accessibleIdentityDescription: "Soft-arch creature with one brow notch",
            revision: 1
        )
    )
    let second = CharacterIdentityDescriptor(
        appearance: CharacterAppearanceSnapshot(
            mode: .creature,
            grammarVersion: 1,
            deterministicSeed: 77,
            silhouette: "tall-tuft",
            paletteToken: "teal-gold",
            eyeDialect: "round-alert",
            nonColorIdentityCue: "paired cheek marks",
            accessibleIdentityDescription: "Tall-tuft creature with paired cheek marks",
            revision: 1
        )
    )

    #expect(first.palette == second.palette)
    #expect(first.silhouette != second.silhouette)
    #expect(first.mark != second.mark)
}

@Test("Unknown future grammar tokens degrade deterministically")
func unknownAppearanceTokensHaveDeterministicFallbacks() {
    let appearance = CharacterAppearanceSnapshot(
        mode: .creature,
        grammarVersion: 99,
        deterministicSeed: 8_811,
        silhouette: "future silhouette",
        paletteToken: "future palette",
        eyeDialect: "future eyes",
        nonColorIdentityCue: "future mark",
        accessibleIdentityDescription: "Future creature",
        revision: 2
    )

    let first = CharacterIdentityDescriptor(appearance: appearance)
    let second = CharacterIdentityDescriptor(appearance: appearance)

    #expect(first == second)
    #expect(CharacterSilhouetteDescriptor.allCases.contains(first.silhouette))
    #expect(CharacterPaletteDescriptor.allCases.contains(first.palette))
    #expect(CharacterEyeDescriptor.allCases.contains(first.eyes))
    #expect(CharacterMarkDescriptor.allCases.contains(first.mark))
}

@Test("Every activity owns a unique written, symbol, and static-pose vocabulary")
func stateVocabularyWorksWithoutColorOrMotion() {
    let descriptors = TeammateActivityState.allCases.map(CharacterActivityDescriptor.init(activity:))

    #expect(Set(descriptors.map(\.visibleLabel)).count == TeammateActivityState.allCases.count)
    #expect(Set(descriptors.map(\.symbolName)).count == TeammateActivityState.allCases.count)
    #expect(Set(descriptors.map(\.pose)).count == TeammateActivityState.allCases.count)
    #expect(descriptors.allSatisfy { !$0.visibleLabel.isEmpty && !$0.symbolName.isEmpty })
}

@Test("Photo references retain a deterministic creature for unavailable-image fallback")
func photoModeRetainsItsCreatureFallback() {
    let assetID = UUID(uuidString: "7A000000-0000-0000-0000-000000000001")!
    let appearance = CharacterAppearanceSnapshot(
        mode: .photo,
        grammarVersion: 1,
        deterministicSeed: 12,
        silhouette: "round",
        paletteToken: "sky",
        eyeDialect: "round",
        nonColorIdentityCue: "single crest",
        accessibleIdentityDescription: "Profile photo",
        profileAssetID: assetID,
        revision: 1
    )

    let descriptor = CharacterIdentityDescriptor(appearance: appearance)

    #expect(descriptor.mode == .photo)
    #expect(descriptor.hasPhotoAssetReference)
    #expect(descriptor.silhouette == .round)
    #expect(descriptor.palette == .sky)
    #expect(descriptor.eyes == .round)
    #expect(descriptor.mark == .singleCrest)
}

@Test("Creature transition accents are brief, bounded, and settle to the existing state pose")
func creatureTransitionHasBoundedMotionAndUnchangedEndpoints() {
    let durations = CharacterTransitionPhase.allCases.map(CharacterTransitionMotion.duration(for:))
    #expect(durations.allSatisfy { $0 >= 0 && $0.isFinite })
    #expect(durations.reduce(0, +) > 0)
    #expect(durations.reduce(0, +) <= 0.4)

    for activity in TeammateActivityState.allCases {
        let descriptor = CharacterActivityDescriptor(activity: activity)
        let held = CharacterArtworkTransform(scale: descriptor.scale, rotation: descriptor.rotation,
                                             verticalOffsetFactor: descriptor.verticalOffsetFactor)
        for phase in CharacterTransitionPhase.allCases {
            let transform = CharacterTransitionMotion.transform(
                activity: activity, mode: .creature, phase: phase,
                reduceMotion: false, sceneIsActive: true
            )
            if phase == .accent && activity != .idle {
                #expect(transform != held)
                #expect(abs(transform.scale / held.scale - 1) <= 0.031)
                #expect(abs(transform.rotation - held.rotation) <= 2)
                // Up to 0.1: the hop is meant to be seen.
                #expect(abs(transform.verticalOffsetFactor - held.verticalOffsetFactor) <= 0.1)
            } else {
                #expect(transform == held)
            }
        }
    }
}

@Test("Reduce Motion and inactive scenes keep every transition phase at its static pose")
func creatureTransitionIsStaticWhenMotionIsUnavailable() {
    for activity in TeammateActivityState.allCases {
        let descriptor = CharacterActivityDescriptor(activity: activity)
        let held = CharacterArtworkTransform(scale: descriptor.scale, rotation: descriptor.rotation,
                                             verticalOffsetFactor: descriptor.verticalOffsetFactor)
        for phase in CharacterTransitionPhase.allCases {
            for (reduceMotion, sceneIsActive) in [(true, true), (false, false), (true, false)] {
                #expect(!CharacterTransitionMotion.isEnabled(mode: .creature, reduceMotion: reduceMotion,
                                                            sceneIsActive: sceneIsActive))
                #expect(CharacterTransitionMotion.transform(
                    activity: activity, mode: .creature, phase: phase,
                    reduceMotion: reduceMotion, sceneIsActive: sceneIsActive
                ) == held)
            }
        }
    }
}

@Test("Idle motion is calm, bounded and varies deterministically between bot identities")
func creatureIdleMotionHasBoundedDistinctCycles() {
    var durations: Set<TimeInterval> = []
    var firstMovingPhases: Set<CharacterIdlePhase> = []
    for index in 1...32 {
        let id = UUID(uuidString: String(format: "EA000000-0000-0000-0000-%012x", index))!
        let seed = CharacterIdleMotion.seed(identityID: id, appearanceSeed: 42)
        #expect(seed == CharacterIdleMotion.seed(identityID: id, appearanceSeed: 42))
        let duration = CharacterIdleMotion.cycleDuration(seed: seed)
        #expect(duration >= 3.6 && duration <= 4.6)
        durations.insert(duration)
        let phases = CharacterIdleMotion.phases(seed: seed)
        #expect(phases.first == .held)
        #expect(phases.count == CharacterIdlePhase.allCases.count)
        #expect(CharacterIdlePhase.allCases.allSatisfy(phases.contains))
        firstMovingPhases.insert(phases[1])
        for phase in phases {
            let pose = CharacterIdleMotion.transform(activity: .idle, mode: .creature, phase: phase,
                                                     reduceMotion: false, sceneIsActive: true, isVisible: true)
            #expect(abs(pose.scale - 1) <= 0.020_001)
            #expect(abs(pose.rotation) <= 3)
            #expect(abs(pose.verticalOffsetFactor * 42) <= 2.500_001)
            #expect(abs(pose.horizontalOffsetFactor * 42) <= 1.000_001)
            if phase == .held { #expect(pose == .identity) }
            else { #expect(pose != .identity) }
        }
    }
    #expect(durations.count > 1)
    #expect(firstMovingPhases.count == 2)
}

@Test("Body loops include a speaking bot still at work and never animate photos or attention")
func creatureIdleMotionRequiresEveryEligibilityGate() {
    for activity in TeammateActivityState.allCases {
        for mode in [CharacterRenderMode.creature, .photo] {
            for reduceMotion in [false, true] {
                for sceneIsActive in [false, true] {
                    for isVisible in [false, true] {
                        let eligible = (activity == .idle || activity == .thinkingOrWorking || activity == .speaking) && mode == .creature
                            && !reduceMotion && sceneIsActive && isVisible
                        #expect(CharacterIdleMotion.isEnabled(
                            activity: activity, mode: mode, reduceMotion: reduceMotion,
                            sceneIsActive: sceneIsActive, isVisible: isVisible
                        ) == eligible)
                        for phase in CharacterIdlePhase.allCases where !eligible {
                            #expect(CharacterIdleMotion.transform(
                                activity: activity, mode: mode, phase: phase, reduceMotion: reduceMotion,
                                sceneIsActive: sceneIsActive, isVisible: isVisible
                            ) == .identity)
                        }
                    }
                }
            }
        }
    }
}

@Test("Working motion is faster, selected motion is quieter, and every loop starts at a seeded offset")
func creatureWorkingAndSelectedMotionPreserveCalmBounds() {
    var offsets: Set<TimeInterval> = []
    for seed in [UInt64(41), 815, 9_039, 724_212] {
        let idle = CharacterIdleMotion.keyframes(seed: seed)
        let working = CharacterIdleMotion.keyframes(seed: seed, activity: .thinkingOrWorking)
        #expect(working.duration < idle.duration)
        #expect(working.duration >= 1.6 && working.duration <= 2)
        #expect(idle.phaseOffset >= 0 && idle.phaseOffset < idle.duration)
        #expect(idle.phaseOffset == CharacterIdleMotion.keyframes(seed: seed).phaseOffset)
        offsets.insert(idle.phaseOffset)
        for activity in [TeammateActivityState.idle, .thinkingOrWorking] {
            let normal = CharacterIdleMotion.keyframes(seed: seed, activity: activity)
            let selected = CharacterIdleMotion.keyframes(seed: seed, activity: activity, isSelected: true)
            for (full, quiet) in zip(normal.transforms.dropFirst().dropLast(), selected.transforms.dropFirst().dropLast()) {
                #expect(abs(quiet.scale - 1) < abs(full.scale - 1))
                #expect(abs(quiet.rotation) < abs(full.rotation))
                #expect(abs(quiet.verticalOffsetFactor) < abs(full.verticalOffsetFactor))
                #expect(abs(full.scale - 1) <= 0.012_001)
                #expect(abs(full.rotation) <= 1.2)
            }
        }
    }
    #expect(offsets.count == 4)
}

@Test("Vector eyes blink briefly and glance rarely; both end in their unchanged open pose")
func creatureEyeMotionUsesBoundedIndependentLayers() {
    for isWorking in [false, true] {
        let configuration = CharacterEyeMotion.Configuration(seed: 815, isWorking: isWorking)
        let blink = CharacterEyeMotion.keyframes(part: .eyelids, configuration: configuration)
        let glance = CharacterEyeMotion.keyframes(part: .pupils, configuration: configuration)
        for keyframes in [blink, glance] {
            #expect(keyframes.transforms.first == .identity)
            #expect(keyframes.transforms.last == .identity)
            #expect(keyframes.keyTimes == keyframes.keyTimes.sorted())
            #expect(keyframes.phaseOffset >= 0 && keyframes.phaseOffset < keyframes.duration)
        }
        #expect(blink.transforms.map(\.verticalScale).min() == 0.08)
        #expect(blink.transforms.allSatisfy { $0.horizontalOffsetFactor == 0 && $0.scale == 1 })
        #expect((blink.keyTimes[4] - blink.keyTimes[1]) * blink.duration < 0.4)
        #expect(glance.transforms.allSatisfy { abs($0.horizontalOffsetFactor) <= 0.012 && $0.verticalScale == 1 })
        #expect(blink.phaseOffset == glance.phaseOffset)
        #expect(blink.duration == glance.duration)
    }
    var environment = EnvironmentValues()
    #expect(environment.characterEyeMotion == nil)
    environment.characterEyeMotion = .init(seed: 1, isWorking: false)
    #expect(environment.characterEyeMotion != nil)
    environment.characterEyeMotion = nil
    #expect(environment.characterEyeMotion == nil)
}

@Test("Covered semantic content disables idle and finite artwork animation")
func creatureMotionStopsWhenItsRetainedContentIsCovered() {
    #expect(!CharacterTransitionMotion.isEnabled(mode: .creature, reduceMotion: false,
                                                 sceneIsActive: true, isAllowed: false))
    for activity in TeammateActivityState.allCases {
        let held = CharacterActivityDescriptor(activity: activity)
        for phase in CharacterTransitionPhase.allCases {
            #expect(CharacterTransitionMotion.transform(
                activity: activity, mode: .creature, phase: phase, reduceMotion: false,
                sceneIsActive: true, isAllowed: false
            ) == CharacterArtworkTransform(scale: held.scale, rotation: held.rotation,
                                            verticalOffsetFactor: held.verticalOffsetFactor))
        }
        #expect(!CharacterIdleMotion.isEnabled(activity: activity, mode: .creature,
                                               reduceMotion: false, sceneIsActive: true,
                                               isVisible: true, isAllowed: false))
        for phase in CharacterIdlePhase.allCases {
            #expect(CharacterIdleMotion.transform(
                activity: activity, mode: .creature, phase: phase, reduceMotion: false,
                sceneIsActive: true, isVisible: true, isAllowed: false
            ) == .identity)
        }
    }
}

@Test("Idle keyframes replay the seeded phases once per cycle and close on the held pose")
func creatureIdleKeyframesFollowTheSeededCycle() {
    for index in 1...32 {
        let id = UUID(uuidString: String(format: "EB000000-0000-0000-0000-%012x", index))!
        let seed = CharacterIdleMotion.seed(identityID: id, appearanceSeed: 42)
        let keyframes = CharacterIdleMotion.keyframes(seed: seed)
        let phases = CharacterIdleMotion.phases(seed: seed)
        let expectedCount = phases.count + 1
        let identity = CharacterArtworkTransform.identity
        #expect(keyframes.transforms.count == expectedCount)
        #expect(keyframes.transforms.first == identity)
        #expect(keyframes.transforms.last == identity)
        for (offset, phase) in phases.enumerated() {
            let expected = CharacterIdleMotion.transform(
                activity: .idle, mode: .creature, phase: phase,
                reduceMotion: false, sceneIsActive: true, isVisible: true)
            let actual = keyframes.transforms[offset]
            #expect(actual == expected)
        }
        let thirds: [Double] = [0, 1.0 / 3, 2.0 / 3, 1]
        let expectedDuration = CharacterIdleMotion.cycleDuration(seed: seed)
        #expect(keyframes.keyTimes == thirds)
        #expect(keyframes.duration == expectedDuration)
        let moving = Array(keyframes.transforms.dropFirst().dropLast())
        #expect(moving.allSatisfy { $0 != identity })
    }
}

/// Watching Scriptsmith on the installed app, nothing seemed to move, though
/// the head should float and move a bit. The idle loop moved 0.17 points and tilted 0.15
/// degrees, and the attention hop rose 1 point for a tenth of a second. The
/// idle float and the hop must now be big enough to see at sidebar size.
@Test("The idle float and the attention hop are big enough to see")
func creatureMotionIsVisible() {
    let size: CGFloat = 42
    for phase in [CharacterIdlePhase.upperLeft, .lowerRight] {
        let pose = CharacterIdleMotion.transform(activity: .idle, mode: .creature, phase: phase,
                                                 reduceMotion: false, sceneIsActive: true, isVisible: true)
        #expect(abs(pose.verticalOffsetFactor * size) >= 1.5, "float \(pose.verticalOffsetFactor * size) pt")
        #expect(abs(pose.rotation) >= 1)
    }
    for activity in [TeammateActivityState.waitingForUser, .errorOrAttention] {
        let held = CharacterTransitionMotion.transform(activity: activity, mode: .creature, phase: .held,
                                                      reduceMotion: false, sceneIsActive: true)
        let hop = CharacterTransitionMotion.transform(activity: activity, mode: .creature, phase: .accent,
                                                     reduceMotion: false, sceneIsActive: true)
        #expect((held.verticalOffsetFactor - hop.verticalOffsetFactor) * size >= 3, "hop \((held.verticalOffsetFactor - hop.verticalOffsetFactor) * size) pt")
    }
}
