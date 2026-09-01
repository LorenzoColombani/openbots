import SwiftUI
import OpenBotsDomain

enum CharacterRenderMode: String, Equatable, Sendable {
    case creature
    case photo
}

enum CharacterSilhouetteDescriptor: String, CaseIterable, Equatable, Sendable {
    case round
    case sprout
    case drop
    case cloud
    case softArch
    case roundEars
    case tallTuft
}

enum CharacterPaletteDescriptor: String, CaseIterable, Equatable, Sendable {
    case sky
    case mint
    case violet
    case amber
    case coral
    case blue
    case violetCoral
    case tealGold
    case blueLilac
    case plumMint
}

enum CharacterEyeDescriptor: String, CaseIterable, Equatable, Sendable {
    case round
    case bright
    case calm
    case wide
    case roundAlert
    case softFocused
    case wideCurious
}

enum CharacterMarkDescriptor: String, CaseIterable, Equatable, Sendable {
    case singleCrest
    case twoAntennae
    case leafEars
    case softCrown
    case singleBrowNotch
    case pairedCheekMarks
    case foreheadSpark
}

/// Pure, color-independent rendering decisions derived from the complete
/// persisted appearance contract. Unknown future grammar tokens degrade to a
/// deterministic member of the current grammar rather than collapsing every
/// teammate to the same generic avatar.
struct CharacterIdentityDescriptor: Equatable, Sendable {
    let mode: CharacterRenderMode
    let grammarVersion: UInt16
    let deterministicSeed: UInt64
    let silhouette: CharacterSilhouetteDescriptor
    let palette: CharacterPaletteDescriptor
    let eyes: CharacterEyeDescriptor
    let mark: CharacterMarkDescriptor
    let accessibleDescription: String
    let hasPhotoAssetReference: Bool
    let builtInAvatar: BuiltInAvatar?
    let revision: UInt64

    init(appearance: CharacterAppearanceSnapshot) {
        mode = appearance.mode == .photo ? .photo : .creature
        grammarVersion = appearance.grammarVersion
        deterministicSeed = appearance.deterministicSeed
        silhouette = Self.silhouette(
            for: appearance.silhouette,
            seed: appearance.deterministicSeed
        )
        palette = Self.palette(
            for: appearance.paletteToken,
            seed: appearance.deterministicSeed
        )
        eyes = Self.eyes(
            for: appearance.eyeDialect,
            seed: appearance.deterministicSeed
        )
        mark = Self.mark(
            for: appearance.nonColorIdentityCue,
            seed: appearance.deterministicSeed
        )
        accessibleDescription = appearance.accessibleIdentityDescription
        hasPhotoAssetReference = appearance.profileAssetID != nil
        builtInAvatar = appearance.mode == .creature
            ? appearance.builtInAvatarID.flatMap(BuiltInAvatar.init(rawValue:)) : nil
        revision = appearance.revision
    }

    private static func silhouette(
        for source: String,
        seed: UInt64
    ) -> CharacterSilhouetteDescriptor {
        switch normalized(source) {
        case "round": .round
        case "sprout": .sprout
        case "drop": .drop
        case "cloud": .cloud
        case "soft-arch": .softArch
        case "round-ears": .roundEars
        case "tall-tuft": .tallTuft
        default: deterministicFallback(source, seed: seed)
        }
    }

    private static func palette(
        for source: String,
        seed: UInt64
    ) -> CharacterPaletteDescriptor {
        switch normalized(source) {
        case "sky": .sky
        case "mint": .mint
        case "violet": .violet
        case "amber": .amber
        case "coral": .coral
        case "blue": .blue
        case "violet-coral": .violetCoral
        case "teal-gold": .tealGold
        case "blue-lilac": .blueLilac
        case "plum-mint": .plumMint
        default: deterministicFallback(source, seed: seed)
        }
    }

    private static func eyes(
        for source: String,
        seed: UInt64
    ) -> CharacterEyeDescriptor {
        switch normalized(source) {
        case "round": .round
        case "bright": .bright
        case "calm": .calm
        case "wide": .wide
        case "round-alert": .roundAlert
        case "soft-focused": .softFocused
        case "wide-curious": .wideCurious
        default: deterministicFallback(source, seed: seed)
        }
    }

    private static func mark(
        for source: String,
        seed: UInt64
    ) -> CharacterMarkDescriptor {
        switch normalized(source) {
        case "single-crest": .singleCrest
        case "two-antennae": .twoAntennae
        case "leaf-ears": .leafEars
        case "soft-crown": .softCrown
        case "single-brow-notch": .singleBrowNotch
        case "paired-cheek-marks": .pairedCheekMarks
        case "forehead-spark": .foreheadSpark
        default: deterministicFallback(source, seed: seed)
        }
    }

    private static func normalized(_ source: String) -> String {
        source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    private static func deterministicFallback<Value: CaseIterable>(
        _ source: String,
        seed: UInt64
    ) -> Value where Value.AllCases: RandomAccessCollection, Value.AllCases.Index == Int {
        let hash = source.utf8.reduce(seed ^ 14_695_981_039_346_656_037) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let values = Value.allCases
        return values[Int(hash % UInt64(values.count))]
    }
}

enum CharacterActivityPose: String, CaseIterable, Equatable, Sendable {
    case speaking
    case working
    case waiting
    case idle
    case attention
}

/// The pose, symbol, and written label are a three-part state vocabulary.
/// Pose and symbol keep states distinguishable without color or motion.
struct CharacterActivityDescriptor: Equatable, Sendable {
    let pose: CharacterActivityPose
    let visibleLabel: String
    let symbolName: String

    init(activity: TeammateActivityState) {
        visibleLabel = activity.visibleLabel
        symbolName = activity.symbolName
        switch activity {
        case .speaking:
            pose = .speaking
        case .thinkingOrWorking:
            pose = .working
        case .waitingForUser:
            pose = .waiting
        case .idle:
            pose = .idle
        case .errorOrAttention:
            pose = .attention
        }
    }

    var scale: CGFloat {
        switch pose {
        case .speaking: 1.04
        case .working: 1
        case .waiting: 1.02
        case .idle: 0.96
        case .attention: 1.03
        }
    }

    var rotation: Double {
        switch pose {
        case .working: -2
        case .attention: 2
        default: 0
        }
    }

    var verticalOffsetFactor: CGFloat {
        pose == .waiting ? -0.025 : 0
    }

    var eyeOffsetFactor: CGFloat {
        switch pose {
        case .working: -0.025
        case .waiting: -0.04
        case .idle: 0.02
        default: 0
        }
    }

    var eyeCompression: CGFloat {
        pose == .idle ? 0.64 : 1
    }

    var pupilHorizontalOffsetFactor: CGFloat {
        switch pose {
        case .working: -0.06
        case .waiting: 0.05
        case .attention: 0.03
        default: 0
        }
    }
}

enum CharacterTransitionPhase: CaseIterable, Equatable {
    case held, accent, settled
}

struct CharacterArtworkTransform: Equatable {
    let scale: CGFloat
    let rotation: Double
    let verticalOffsetFactor: CGFloat
    let horizontalOffsetFactor: CGFloat

    init(scale: CGFloat, rotation: Double, verticalOffsetFactor: CGFloat, horizontalOffsetFactor: CGFloat = 0) {
        self.scale = scale
        self.rotation = rotation
        self.verticalOffsetFactor = verticalOffsetFactor
        self.horizontalOffsetFactor = horizontalOffsetFactor
    }

    static let identity = Self(scale: 1, rotation: 0, verticalOffsetFactor: 0)
}

/// A finite accent, never a clock or an interpretation of provider text. Both
/// endpoints are the existing held pose; photos have no motion or pose transform.
enum CharacterTransitionMotion {
    static func isEnabled(mode: CharacterRenderMode, reduceMotion: Bool, sceneIsActive: Bool,
                          isAllowed: Bool = true) -> Bool {
        mode == .creature && !reduceMotion && sceneIsActive && isAllowed
    }

    static func duration(for phase: CharacterTransitionPhase) -> TimeInterval {
        switch phase {
        case .held: 0
        case .accent: 0.12
        case .settled: 0.18
        }
    }

    static func transform(activity: TeammateActivityState, mode: CharacterRenderMode,
                          phase: CharacterTransitionPhase, reduceMotion: Bool,
                          sceneIsActive: Bool, isAllowed: Bool = true) -> CharacterArtworkTransform {
        guard mode == .creature else { return .identity }
        let state = CharacterActivityDescriptor(activity: activity)
        guard phase == .accent, isEnabled(mode: mode, reduceMotion: reduceMotion,
                                         sceneIsActive: sceneIsActive, isAllowed: isAllowed) else {
            return .init(scale: state.scale, rotation: state.rotation, verticalOffsetFactor: state.verticalOffsetFactor)
        }
        switch activity {
        case .speaking:
            return .init(scale: state.scale * 1.03, rotation: state.rotation,
                         verticalOffsetFactor: state.verticalOffsetFactor - 0.025)
        case .thinkingOrWorking:
            return .init(scale: state.scale * 1.015, rotation: state.rotation - 2,
                         verticalOffsetFactor: state.verticalOffsetFactor)
        case .waitingForUser:
            return .init(scale: state.scale * 1.02, rotation: state.rotation,
                         verticalOffsetFactor: state.verticalOffsetFactor - 0.02)
        case .errorOrAttention:
            return .init(scale: state.scale * 1.025, rotation: state.rotation + 2,
                         verticalOffsetFactor: state.verticalOffsetFactor)
        case .idle:
            return .init(scale: state.scale, rotation: state.rotation,
                         verticalOffsetFactor: state.verticalOffsetFactor)
        }
    }
}

enum CharacterIdlePhase: CaseIterable, Hashable {
    case held, upperLeft, lowerRight
}

/// Idle liveness is decorative, not evidence of work. SwiftUI owns the loop;
/// only this artwork leaf participates, and only while its native view is visible.
enum CharacterIdleMotion {
    static func isEnabled(activity: TeammateActivityState, mode: CharacterRenderMode,
                          reduceMotion: Bool, sceneIsActive: Bool, isVisible: Bool,
                          isAllowed: Bool = true) -> Bool {
        activity == .idle && isVisible
            && CharacterTransitionMotion.isEnabled(mode: mode, reduceMotion: reduceMotion,
                                                   sceneIsActive: sceneIsActive, isAllowed: isAllowed)
    }

    static func seed(identityID: UUID, appearanceSeed: UInt64) -> UInt64 {
        identityID.uuidString.utf8.reduce(appearanceSeed ^ 14_695_981_039_346_656_037) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
    }

    static func phases(seed: UInt64) -> [CharacterIdlePhase] {
        seed.isMultiple(of: 2) ? [.held, .upperLeft, .lowerRight] : [.held, .lowerRight, .upperLeft]
    }

    static func cycleDuration(seed: UInt64) -> TimeInterval {
        3.6 + Double((seed >> 1) % 101) / 100
    }

    static func transform(activity: TeammateActivityState, mode: CharacterRenderMode,
                          phase: CharacterIdlePhase, reduceMotion: Bool,
                          sceneIsActive: Bool, isVisible: Bool,
                          isAllowed: Bool = true) -> CharacterArtworkTransform {
        guard isEnabled(activity: activity, mode: mode, reduceMotion: reduceMotion,
                        sceneIsActive: sceneIsActive, isVisible: isVisible, isAllowed: isAllowed) else { return .identity }
        switch phase {
        case .held: return .identity
        case .upperLeft:
            return .init(scale: 1.02, rotation: -3, verticalOffsetFactor: -2.5 / 42,
                         horizontalOffsetFactor: -1 / 42)
        case .lowerRight:
            return .init(scale: 0.98, rotation: 3, verticalOffsetFactor: 2.5 / 42,
                         horizontalOffsetFactor: 1 / 42)
        }
    }
}

private struct CharacterArtworkPose: ViewModifier {
    let transform: CharacterArtworkTransform
    let size: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(transform.scale)
            .rotationEffect(.degrees(transform.rotation))
            .offset(x: size * transform.horizontalOffsetFactor,
                    y: size * transform.verticalOffsetFactor)
    }
}

public struct CharacterIdentityView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.characterMotionAllowed) private var motionAllowed
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.profilePhotoPresentation) private var photoPresentation
    @StateObject private var photoModel = ProfilePhotoViewModel()
    @State private var artworkIsVisible = false

    private let identity: TeammateIdentitySnapshot
    private let activity: TeammateActivityState
    private let size: CGFloat

    public init(
        identity: TeammateIdentitySnapshot,
        activity: TeammateActivityState,
        size: CGFloat = 36
    ) {
        self.identity = identity
        self.activity = activity
        self.size = max(20, size)
    }

    public init(teammate: TeammateRowSnapshot, size: CGFloat = 36) {
        self.init(identity: teammate.identity, activity: teammate.activity, size: size)
    }

    public var body: some View {
        let character = CharacterIdentityDescriptor(appearance: identity.appearance)
        let state = CharacterActivityDescriptor(activity: activity)

        ZStack(alignment: .bottomTrailing) {
            Group {
                switch character.mode {
                case .creature:
                    transitioningCreature(character, state: state)
                case .photo:
                    Group {
                        if let photo = photoModel.image(for: photoAssetID, presentation: photoPresentation) {
                            Image(decorative: photo.cgImage, scale: 1)
                                .resizable()
                                .scaledToFill()
                                .frame(width: size, height: size)
                                .clipShape(Circle())
                                .overlay {
                                    Circle().stroke(.primary, lineWidth: contrast == .increased ? 2 : 0.85)
                                }
                        } else {
                            creature(character, state: CharacterActivityDescriptor(activity: .idle))
                        }
                    }
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
            }
            .frame(width: size, height: size)

            statusBadge(state)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(identity.name)
        .accessibilityValue(accessibilityValue(character: character, state: state))
        .task(id: photoRequest) {
            await photoModel.load(assetID: photoAssetID, presentation: photoPresentation)
        }
    }

    @ViewBuilder
    private func transitioningCreature(_ character: CharacterIdentityDescriptor,
                                       state: CharacterActivityDescriptor) -> some View {
        Group {
            if artworkIsVisible && CharacterTransitionMotion.isEnabled(
                mode: character.mode, reduceMotion: reduceMotion, sceneIsActive: scenePhase == .active,
                isAllowed: motionAllowed
            ) {
                idleCapableCreatureArtwork(character, state: state)
                    .phaseAnimator(CharacterTransitionPhase.allCases, trigger: activity) { content, phase in
                        content.modifier(CharacterArtworkPose(transform: CharacterTransitionMotion.transform(
                            activity: activity, mode: character.mode, phase: phase,
                            reduceMotion: false, sceneIsActive: true), size: size))
                    } animation: { phase in
                        .easeOut(duration: CharacterTransitionMotion.duration(for: phase))
                    }
            } else {
                creatureArtwork(character, state: state)
                    .modifier(CharacterArtworkPose(transform: CharacterTransitionMotion.transform(
                        activity: activity, mode: character.mode, phase: .held,
                        reduceMotion: reduceMotion, sceneIsActive: scenePhase == .active), size: size))
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
            }
        }
        .background {
            CharacterMotionVisibilityObserver(isVisible: $artworkIsVisible)
                .frame(width: size, height: size)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // Reused identities get a fresh visibility observation. SwiftUI owns
        // the idle loop; no app timer, clock or frame publisher is installed.
        .id(identity.id)
        .onChange(of: identity.id) { _, _ in artworkIsVisible = false }
        .onDisappear { artworkIsVisible = false }
    }

    @ViewBuilder
    private func idleCapableCreatureArtwork(_ character: CharacterIdentityDescriptor,
                                           state: CharacterActivityDescriptor) -> some View {
        if CharacterIdleMotion.isEnabled(activity: activity, mode: character.mode,
                                         reduceMotion: reduceMotion, sceneIsActive: scenePhase == .active,
                                         isVisible: artworkIsVisible, isAllowed: motionAllowed) {
            let seed = CharacterIdleMotion.seed(identityID: identity.id, appearanceSeed: character.deterministicSeed)
            creatureArtwork(character, state: state)
                .phaseAnimator(CharacterIdleMotion.phases(seed: seed)) { content, phase in
                    content.modifier(CharacterArtworkPose(transform: CharacterIdleMotion.transform(
                        activity: activity, mode: character.mode, phase: phase,
                        reduceMotion: false, sceneIsActive: true, isVisible: true), size: size))
                } animation: { _ in
                    .easeInOut(duration: CharacterIdleMotion.cycleDuration(seed: seed) / 3)
                }
        } else {
            creatureArtwork(character, state: state)
        }
    }

    @ViewBuilder
    private func creatureArtwork(_ character: CharacterIdentityDescriptor,
                                 state: CharacterActivityDescriptor) -> some View {
        if let avatar = character.builtInAvatar, BuiltInAvatarResources.isAvailable(avatar) {
            BuiltInAvatarArtwork(avatar: avatar, size: size)
        } else {
            creature(character, state: state)
        }
    }

    private var photoAssetID: UUID? {
        identity.appearance.mode == .photo ? identity.appearance.profileAssetID : nil
    }

    private var photoRequest: ProfilePhotoRequest? {
        guard let photoAssetID, let photoPresentation else { return nil }
        return ProfilePhotoRequest(assetID: photoAssetID, presentationID: photoPresentation.id)
    }

    private func creature(
        _ character: CharacterIdentityDescriptor,
        state: CharacterActivityDescriptor
    ) -> some View {
        let colors = character.palette.colors(for: colorScheme)
        let lineWidth: CGFloat = contrast == .increased ? 2 : 0.85
        return CharacterBodyShape(silhouette: character.silhouette)
            .fill(
                LinearGradient(
                    colors: [colors.primary, colors.secondary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                CharacterBodyShape(silhouette: character.silhouette)
                    .stroke(.primary.opacity(contrast == .increased ? 1 : 0.72), lineWidth: lineWidth)
            }
            .overlay {
                CharacterEyesView(
                    dialect: character.eyes,
                    state: state,
                    size: size,
                    increasedContrast: contrast == .increased
                )
            }
            .overlay {
                CharacterIdentityMarkShape(mark: character.mark)
                    .fill(.white.opacity(0.96))
                    .overlay {
                        CharacterIdentityMarkShape(mark: character.mark)
                            .stroke(.black.opacity(0.82), lineWidth: lineWidth)
                    }
            }
    }

    private func statusBadge(_ state: CharacterActivityDescriptor) -> some View {
        let badgeSize = max(13, size * 0.34)
        return Image(systemName: state.symbolName)
            .font(.system(size: max(8, badgeSize * 0.52), weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: badgeSize, height: badgeSize)
            .background(OpenBotsVisualStyle.surface(for: colorScheme), in: Circle())
            .overlay {
                Circle()
                    .stroke(
                        .primary.opacity(contrast == .increased ? 1 : 0.55),
                        lineWidth: contrast == .increased ? 1.5 : 0.75
                    )
            }
            .accessibilityHidden(true)
    }

    private func accessibilityValue(
        character: CharacterIdentityDescriptor,
        state: CharacterActivityDescriptor
    ) -> String {
        let appearance: String
        if character.mode == .photo {
            appearance = photoModel.image(for: photoAssetID, presentation: photoPresentation) != nil
                ? character.accessibleDescription
                : "Photo unavailable; showing this teammate’s creature identity with \(character.mark.rawValue)"
        } else if let avatar = character.builtInAvatar, BuiltInAvatarResources.isAvailable(avatar) {
            appearance = "\(avatar.displayName) avatar. \(character.accessibleDescription)"
        } else {
            appearance = character.accessibleDescription
        }
        return "\(identity.role). \(appearance). Status: \(state.visibleLabel)."
    }
}

private struct CharacterBodyShape: Shape {
    let silhouette: CharacterSilhouetteDescriptor

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch silhouette {
        case .round:
            path.addEllipse(in: rect.insetBy(dx: rect.width * 0.035, dy: rect.height * 0.035))

        case .sprout:
            path.move(to: point(0.50, 0.04, in: rect))
            path.addCurve(to: point(0.94, 0.46, in: rect), control1: point(0.78, 0.08, in: rect), control2: point(0.96, 0.23, in: rect))
            path.addCurve(to: point(0.50, 0.97, in: rect), control1: point(0.95, 0.79, in: rect), control2: point(0.76, 0.97, in: rect))
            path.addCurve(to: point(0.06, 0.46, in: rect), control1: point(0.24, 0.97, in: rect), control2: point(0.05, 0.79, in: rect))
            path.addCurve(to: point(0.50, 0.04, in: rect), control1: point(0.04, 0.23, in: rect), control2: point(0.22, 0.08, in: rect))
            path.closeSubpath()

        case .drop:
            path.move(to: point(0.50, 0.02, in: rect))
            path.addCurve(to: point(0.96, 0.65, in: rect), control1: point(0.66, 0.22, in: rect), control2: point(0.96, 0.42, in: rect))
            path.addCurve(to: point(0.50, 0.98, in: rect), control1: point(0.96, 0.88, in: rect), control2: point(0.76, 0.98, in: rect))
            path.addCurve(to: point(0.04, 0.65, in: rect), control1: point(0.24, 0.98, in: rect), control2: point(0.04, 0.88, in: rect))
            path.addCurve(to: point(0.50, 0.02, in: rect), control1: point(0.04, 0.42, in: rect), control2: point(0.34, 0.22, in: rect))
            path.closeSubpath()

        case .cloud:
            path.move(to: point(0.14, 0.82, in: rect))
            path.addCurve(to: point(0.13, 0.43, in: rect), control1: point(0.01, 0.70, in: rect), control2: point(0.01, 0.50, in: rect))
            path.addCurve(to: point(0.38, 0.23, in: rect), control1: point(0.18, 0.26, in: rect), control2: point(0.30, 0.21, in: rect))
            path.addCurve(to: point(0.72, 0.26, in: rect), control1: point(0.49, 0.02, in: rect), control2: point(0.70, 0.08, in: rect))
            path.addCurve(to: point(0.94, 0.59, in: rect), control1: point(0.93, 0.23, in: rect), control2: point(1.00, 0.44, in: rect))
            path.addCurve(to: point(0.76, 0.91, in: rect), control1: point(0.96, 0.80, in: rect), control2: point(0.88, 0.91, in: rect))
            path.addCurve(to: point(0.14, 0.82, in: rect), control1: point(0.54, 1.00, in: rect), control2: point(0.29, 0.97, in: rect))
            path.closeSubpath()

        case .softArch:
            path.move(to: point(0.08, 0.94, in: rect))
            path.addLine(to: point(0.08, 0.49, in: rect))
            path.addCurve(to: point(0.92, 0.49, in: rect), control1: point(0.08, 0.02, in: rect), control2: point(0.92, 0.02, in: rect))
            path.addLine(to: point(0.92, 0.94, in: rect))
            path.addCurve(to: point(0.08, 0.94, in: rect), control1: point(0.72, 1.00, in: rect), control2: point(0.28, 1.00, in: rect))
            path.closeSubpath()

        case .roundEars:
            path.move(to: point(0.11, 0.92, in: rect))
            path.addCurve(to: point(0.06, 0.32, in: rect), control1: point(0.02, 0.73, in: rect), control2: point(0.03, 0.48, in: rect))
            path.addCurve(to: point(0.31, 0.20, in: rect), control1: point(0.05, 0.06, in: rect), control2: point(0.25, 0.04, in: rect))
            path.addCurve(to: point(0.69, 0.20, in: rect), control1: point(0.42, 0.10, in: rect), control2: point(0.58, 0.10, in: rect))
            path.addCurve(to: point(0.94, 0.32, in: rect), control1: point(0.75, 0.04, in: rect), control2: point(0.95, 0.06, in: rect))
            path.addCurve(to: point(0.89, 0.92, in: rect), control1: point(0.97, 0.48, in: rect), control2: point(0.98, 0.73, in: rect))
            path.addCurve(to: point(0.11, 0.92, in: rect), control1: point(0.70, 1.00, in: rect), control2: point(0.30, 1.00, in: rect))
            path.closeSubpath()

        case .tallTuft:
            path.move(to: point(0.10, 0.95, in: rect))
            path.addCurve(to: point(0.28, 0.22, in: rect), control1: point(0.01, 0.66, in: rect), control2: point(0.08, 0.33, in: rect))
            path.addCurve(to: point(0.50, 0.03, in: rect), control1: point(0.37, 0.19, in: rect), control2: point(0.46, 0.08, in: rect))
            path.addCurve(to: point(0.72, 0.22, in: rect), control1: point(0.54, 0.08, in: rect), control2: point(0.63, 0.19, in: rect))
            path.addCurve(to: point(0.90, 0.95, in: rect), control1: point(0.92, 0.33, in: rect), control2: point(0.99, 0.66, in: rect))
            path.addCurve(to: point(0.10, 0.95, in: rect), control1: point(0.70, 1.00, in: rect), control2: point(0.30, 1.00, in: rect))
            path.closeSubpath()
        }
        return path
    }

    private func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }
}

private struct CharacterIdentityMarkShape: Shape {
    let mark: CharacterMarkDescriptor

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch mark {
        case .singleCrest:
            polygon([point(0.50, 0.08, in: rect), point(0.61, 0.27, in: rect), point(0.39, 0.27, in: rect)], into: &path)
        case .twoAntennae:
            path.addRect(CGRect(x: rect.minX + rect.width * 0.33, y: rect.minY + rect.height * 0.12, width: rect.width * 0.035, height: rect.height * 0.16))
            path.addRect(CGRect(x: rect.minX + rect.width * 0.64, y: rect.minY + rect.height * 0.12, width: rect.width * 0.035, height: rect.height * 0.16))
            path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.285, y: rect.minY + rect.height * 0.06, width: rect.width * 0.12, height: rect.height * 0.12))
            path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.595, y: rect.minY + rect.height * 0.06, width: rect.width * 0.12, height: rect.height * 0.12))
        case .leafEars:
            polygon([point(0.14, 0.21, in: rect), point(0.34, 0.27, in: rect), point(0.22, 0.39, in: rect)], into: &path)
            polygon([point(0.86, 0.21, in: rect), point(0.66, 0.27, in: rect), point(0.78, 0.39, in: rect)], into: &path)
        case .softCrown:
            polygon([point(0.30, 0.29, in: rect), point(0.29, 0.11, in: rect), point(0.43, 0.22, in: rect), point(0.50, 0.07, in: rect), point(0.57, 0.22, in: rect), point(0.71, 0.11, in: rect), point(0.70, 0.29, in: rect)], into: &path)
        case .singleBrowNotch:
            polygon([point(0.41, 0.34, in: rect), point(0.52, 0.27, in: rect), point(0.59, 0.34, in: rect), point(0.50, 0.31, in: rect)], into: &path)
        case .pairedCheekMarks:
            path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.61, width: rect.width * 0.15, height: rect.height * 0.08))
            path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.69, y: rect.minY + rect.height * 0.61, width: rect.width * 0.15, height: rect.height * 0.08))
        case .foreheadSpark:
            polygon([point(0.50, 0.09, in: rect), point(0.57, 0.23, in: rect), point(0.50, 0.31, in: rect), point(0.43, 0.23, in: rect)], into: &path)
        }
        return path
    }

    private func polygon(_ points: [CGPoint], into path: inout Path) {
        guard let first = points.first else { return }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
    }

    private func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }
}

private struct CharacterEyesView: View {
    let dialect: CharacterEyeDescriptor
    let state: CharacterActivityDescriptor
    let size: CGFloat
    let increasedContrast: Bool

    var body: some View {
        HStack(spacing: size * eyeSpacingFactor) {
            eye
            eye
        }
        .offset(y: -size * 0.01 + size * state.eyeOffsetFactor)
    }

    private var eye: some View {
        Capsule(style: .continuous)
            .fill(.white)
            .frame(width: size * eyeWidthFactor, height: size * eyeHeightFactor * state.eyeCompression)
            .overlay {
                Capsule(style: .continuous)
                    .stroke(.black.opacity(0.8), lineWidth: increasedContrast ? 1.5 : 0.65)
            }
            .overlay(alignment: .center) {
                Circle()
                    .fill(.black)
                    .frame(width: size * pupilFactor, height: size * pupilFactor)
                    .offset(x: size * state.pupilHorizontalOffsetFactor, y: size * 0.025)
            }
    }

    private var eyeWidthFactor: CGFloat {
        switch dialect {
        case .round, .roundAlert: 0.17
        case .bright: 0.15
        case .calm, .softFocused: 0.19
        case .wide, .wideCurious: 0.18
        }
    }

    private var eyeHeightFactor: CGFloat {
        switch dialect {
        case .round: 0.24
        case .bright: 0.29
        case .calm: 0.16
        case .wide: 0.32
        case .roundAlert: 0.28
        case .softFocused: 0.18
        case .wideCurious: 0.34
        }
    }

    private var eyeSpacingFactor: CGFloat {
        switch dialect {
        case .calm, .softFocused: 0.11
        case .wide, .wideCurious: 0.15
        default: 0.13
        }
    }

    private var pupilFactor: CGFloat {
        switch dialect {
        case .bright, .roundAlert: 0.075
        case .calm, .softFocused: 0.055
        default: 0.065
        }
    }
}

private extension CharacterPaletteDescriptor {
    func colors(for colorScheme: ColorScheme) -> (primary: Color, secondary: Color) {
        switch (self, colorScheme) {
        case (.sky, .dark): (rgb(0x6F, 0xA8, 0xFF), rgb(0x80, 0xD5, 0xF4))
        case (.sky, _): (rgb(0x3A, 0x7D, 0xD8), rgb(0x53, 0xB6, 0xDA))
        case (.mint, .dark): (rgb(0x54, 0xCF, 0xA1), rgb(0x9A, 0xDF, 0x8D))
        case (.mint, _): (rgb(0x28, 0x8C, 0x6C), rgb(0x6A, 0xB8, 0x67))
        case (.violet, .dark): (rgb(0xA7, 0x97, 0xFF), rgb(0xD0, 0x8F, 0xE6))
        case (.violet, _): (rgb(0x70, 0x55, 0xCC), rgb(0xA5, 0x5D, 0xB8))
        case (.amber, .dark): (rgb(0xE7, 0xA8, 0x4B), rgb(0xF2, 0xCB, 0x68))
        case (.amber, _): (rgb(0xB9, 0x6A, 0x16), rgb(0xD2, 0xA2, 0x2D))
        case (.coral, .dark): (rgb(0xFF, 0x8C, 0x91), rgb(0xFF, 0xB0, 0x83))
        case (.coral, _): (rgb(0xC8, 0x53, 0x5B), rgb(0xDB, 0x7B, 0x55))
        case (.blue, .dark): (rgb(0x74, 0x9E, 0xFF), rgb(0x9C, 0x87, 0xF1))
        case (.blue, _): (rgb(0x3D, 0x69, 0xC8), rgb(0x70, 0x58, 0xC7))
        case (.violetCoral, .dark): (rgb(0xA4, 0x96, 0xFF), rgb(0xFF, 0x92, 0x9A))
        case (.violetCoral, _): (rgb(0x62, 0x55, 0xD8), rgb(0xD9, 0x63, 0x72))
        case (.tealGold, .dark): (rgb(0x55, 0xCB, 0xBD), rgb(0xF0, 0xBE, 0x5D))
        case (.tealGold, _): (rgb(0x20, 0x83, 0x7D), rgb(0xC4, 0x86, 0x24))
        case (.blueLilac, .dark): (rgb(0x6F, 0xA8, 0xFF), rgb(0xC3, 0x9D, 0xF5))
        case (.blueLilac, _): (rgb(0x3A, 0x72, 0xCF), rgb(0x8D, 0x63, 0xC7))
        case (.plumMint, .dark): (rgb(0xD0, 0x85, 0xD5), rgb(0x68, 0xD5, 0xAF))
        case (.plumMint, _): (rgb(0x8A, 0x48, 0x8F), rgb(0x2F, 0x9B, 0x76))
        }
    }

    private func rgb(_ red: Int, _ green: Int, _ blue: Int) -> Color {
        Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}
