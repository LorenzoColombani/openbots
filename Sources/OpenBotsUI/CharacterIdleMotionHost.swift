import AppKit
import OpenBotsDomain
import QuartzCore
import SwiftUI

/// Cosmetic events only: no workspace, turn or Stop callback is reachable here.
@MainActor
enum CharacterWorkingReaction {
    static let notification = Notification.Name("OpenBotsNext.characterPlayfulReaction")
    static func request(for identity: UUID) {
        NotificationCenter.default.post(name: notification, object: nil,
            userInfo: ["identity": identity, "time": CACurrentMediaTime()])
    }
}

enum CharacterWorkingMotion {
    enum Part { case body, face, rasterBody }
    /// One shared media-clock origin keeps late-mounted sidebar and inline
    /// copies in phase. No publisher or application-side frame clock runs.
    static let epoch: CFTimeInterval = CACurrentMediaTime()
    static let sampleCount = 120
    static func duration(seed: UInt64) -> TimeInterval { 4.2 + Double(seed % 41) / 100 }
    static func phaseOffset(seed: UInt64) -> TimeInterval {
        Double((seed >> 9) % 997) / 997 * duration(seed: seed)
    }

    static func turnProgress(at phase: Double) -> Double {
        let t = min(1, max(0, (phase - 0.16) / 0.34))
        // Quintic easing has zero velocity and acceleration at both ends.
        return min(1, max(0, t * t * t * (t * (t * 6 - 15) + 10)))
    }

    static func keyframes(seed: UInt64, part: Part) -> CharacterIdleMotion.Keyframes {
        let times = (0...sampleCount).map { Double($0) / Double(sampleCount) }
        var opacities: [Double] = []
        let transforms = times.map { phase -> CharacterArtworkTransform in
            let turn = turnProgress(at: phase)
            let angle = turn >= 1 ? 0 : turn * 2 * .pi
            let sway = sin(phase * 2 * .pi)
            switch part {
            case .face:
                let cosine = cos(angle)
                opacities.append(min(1, max(0, cosine / 0.18)))
                return .init(scale: 1, rotation: sin(angle) * 2,
                    verticalOffsetFactor: -0.015 * sin(angle), horizontalOffsetFactor: 0.40 * sin(angle),
                    horizontalScale: max(0.025, abs(cosine)))
            case .body:
                return .init(scale: 1 + 0.012 * sway, rotation: 2 * sway,
                             verticalOffsetFactor: -0.012 * sway)
            case .rasterBody:
                // The painted face goes once around the head: it slides across
                // and narrows inside the head's own outline, which stays and
                // sways (`CharacterIdleMotionContainer.rasterHeadView`), and
                // the back of the head shows in its hair colour meanwhile. A
                // flat picture turned about its own centre reads as a card
                // flip: half a face on a brown disc, then a 2D coin.
                let cosine = cos(angle)
                opacities.append(min(1, max(0, cosine / 0.18)))
                return .init(scale: 1, rotation: 0, verticalOffsetFactor: 0,
                    horizontalOffsetFactor: 0.40 * sin(angle), horizontalScale: max(0.025, abs(cosine)))
            }
        }
        return .init(transforms: transforms, keyTimes: times, duration: duration(seed: seed),
                     phaseOffset: phaseOffset(seed: seed), opacities: opacities.isEmpty ? nil : opacities,
                     synchronized: true)
    }
}

private struct CharacterWorkingFaceSeedKey: EnvironmentKey {
    static let defaultValue: UInt64? = nil
}

extension EnvironmentValues {
    var characterWorkingFaceSeed: UInt64? {
        get { self[CharacterWorkingFaceSeedKey.self] }
        set { self[CharacterWorkingFaceSeedKey.self] = newValue }
    }
}

struct CharacterWorkingFaceLayer<Content: View>: View {
    @Environment(\.characterWorkingFaceSeed) private var seed
    @Environment(\.colorScheme) private var colorScheme
    let size: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let seed {
            CharacterIdleMotionHost(seed: seed, size: size, colorScheme: colorScheme,
                customKeyframes: CharacterWorkingMotion.keyframes(seed: seed, part: .face)) { content() }
        } else {
            content()
        }
    }
}

enum CharacterEyeMotion {
    struct Configuration: Equatable, Sendable {
        let seed: UInt64
        let isWorking: Bool
    }

    enum Part { case eyelids, pupils }

    /// Eye geometry stays unchanged. Only the existing eye layer compresses;
    /// the existing pupils make one rare, tiny glance within the open eyes.
    static func keyframes(part: Part, configuration: Configuration) -> CharacterIdleMotion.Keyframes {
        let seed = configuration.seed
        let duration = (configuration.isWorking ? 8.0 : 12.0) + Double(seed % 401) / 100
        let offset = Double((seed >> 7) % 997) / 997 * duration
        switch part {
        case .eyelids:
            let closed = CharacterArtworkTransform(scale: 1, rotation: 0, verticalOffsetFactor: 0,
                                                    verticalScale: 0.08)
            return .init(transforms: [.identity, .identity, closed, closed, .identity, .identity],
                         keyTimes: [0, 0.32, 0.328, 0.336, 0.344, 1], duration: duration, phaseOffset: offset)
        case .pupils:
            let glance = CharacterArtworkTransform(scale: 1, rotation: 0, verticalOffsetFactor: 0,
                horizontalOffsetFactor: seed.isMultiple(of: 2) ? -0.012 : 0.012)
            return .init(transforms: [.identity, .identity, glance, glance, .identity, .identity],
                         keyTimes: [0, 0.72, 0.735, 0.80, 0.815, 1], duration: duration, phaseOffset: offset)
        }
    }
}

private struct CharacterEyeMotionKey: EnvironmentKey {
    static let defaultValue: CharacterEyeMotion.Configuration? = nil
}

extension EnvironmentValues {
    var characterEyeMotion: CharacterEyeMotion.Configuration? {
        get { self[CharacterEyeMotionKey.self] }
        set { self[CharacterEyeMotionKey.self] = newValue }
    }
}

/// Optional eye motion is supplied only by a visible, active creature. Raster
/// artwork never uses this wrapper: its painted eyes are part of the base image.
struct CharacterEyeMotionLayer<Content: View>: View {
    @Environment(\.characterEyeMotion) private var configuration
    @Environment(\.colorScheme) private var colorScheme
    let part: CharacterEyeMotion.Part
    let size: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let configuration {
            CharacterIdleMotionHost(seed: configuration.seed, size: size, colorScheme: colorScheme,
                customKeyframes: CharacterEyeMotion.keyframes(part: part, configuration: configuration)) {
                content()
            }
        } else {
            content().frame(width: size, height: size)
        }
    }
}

extension CharacterIdleMotion {
    /// One full idle cycle as a repeating keyframe description. The poses are the
    /// existing seeded phases in seed order, closing back on the held pose, with
    /// one equal ease-in-out segment per phase step and the seeded cycle length.
    struct Keyframes: Equatable {
        let transforms: [CharacterArtworkTransform]
        let keyTimes: [Double]
        let duration: TimeInterval
        var phaseOffset: TimeInterval = 0
        var opacities: [Double]? = nil
        var synchronized = false
    }

    static func keyframes(seed: UInt64, activity: TeammateActivityState = .idle,
                          isSelected: Bool = false) -> Keyframes {
        let phases = phases(seed: seed)
        var transforms = phases.map {
            transform(activity: activity, mode: .creature, phase: $0, reduceMotion: false,
                      sceneIsActive: true, isVisible: true, isSelected: isSelected)
        }
        transforms.append(transforms[0])
        let steps = Double(phases.count)
        let duration = cycleDuration(seed: seed, activity: activity)
        return Keyframes(transforms: transforms,
                         keyTimes: (0...phases.count).map { Double($0) / steps },
                         duration: duration,
                         phaseOffset: Double((seed >> 9) % 997) / 997 * duration)
    }
}

extension CharacterArtworkTransform {
    /// The SwiftUI pose (`scaleEffect` then `rotationEffect` about the artwork
    /// center, then `offset`) as one layer transform for a flipped, top-left
    /// origin layer whose bounds are `size` square.
    func layerTransform(size: CGFloat) -> CATransform3D {
        let center = size / 2
        var transform = CATransform3DMakeTranslation(center + size * horizontalOffsetFactor,
                                                     center + size * verticalOffsetFactor, 0)
        transform = CATransform3DRotate(transform, CGFloat(rotation) * .pi / 180, 0, 0, 1)
        if yaw != 0 {
            var perspective = CATransform3DIdentity
            perspective.m34 = -1 / max(1, size * 5)
            transform = CATransform3DConcat(transform, perspective)
            transform = CATransform3DRotate(transform, CGFloat(yaw) * .pi / 180, 0, 1, 0)
        }
        transform = CATransform3DScale(transform, scale * horizontalScale, scale * verticalScale, 1)
        return CATransform3DTranslate(transform, -center, -center, 0)
    }
}

/// Hosts the idle creature artwork in a native layer whose repeating pose cycle is
/// owned by Core Animation on the render server. Per frame, nothing runs in the
/// app: no SwiftUI graph update, no hosting-view layout pass, no timer. The
/// SwiftUI `phaseAnimator` that preceded it re-rendered every visible creature on
/// every display refresh and re-laid out its list row, which cost about a third
/// of a core with an idle roster on screen.
struct CharacterIdleMotionHost<Content: View>: NSViewRepresentable {
    let seed: UInt64
    let size: CGFloat
    let colorScheme: ColorScheme
    var activity: TeammateActivityState = .idle
    var isSelected = false
    var customKeyframes: CharacterIdleMotion.Keyframes?
    var workingEffectsSeed: UInt64?
    var reactionTime: TimeInterval?
    var rasterBacking: BuiltInAvatar?
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> CharacterIdleMotionContainer {
        let container = CharacterIdleMotionContainer(frame: NSRect(x: 0, y: 0, width: size, height: size))
        container.apply(content: hostedContent, keyframes: keyframes, size: size,
                        workingEffectsSeed: workingEffectsSeed, reactionTime: reactionTime, rasterBacking: rasterBacking)
        return container
    }

    func updateNSView(_ nsView: CharacterIdleMotionContainer, context: Context) {
        LayoutStormCounters.hit("idleMotion.update")
        nsView.apply(content: hostedContent, keyframes: keyframes, size: size,
                     workingEffectsSeed: workingEffectsSeed, reactionTime: reactionTime, rasterBacking: rasterBacking)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CharacterIdleMotionContainer,
                      context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    private var hostedContent: AnyView {
        AnyView(content().frame(width: size, height: size).environment(\.colorScheme, colorScheme)
            .accessibilityHidden(true))
    }

    private var keyframes: CharacterIdleMotion.Keyframes {
        customKeyframes ?? CharacterIdleMotion.keyframes(seed: seed, activity: activity, isSelected: isSelected)
    }

    static func dismantleNSView(_ nsView: CharacterIdleMotionContainer, coordinator: ()) {
        nsView.stopMotion()
    }
}

/// Decorative only: never hit-testable, never an accessibility element. The
/// artwork's meaning stays with the outer identity view's label and value.
@MainActor
final class CharacterIdleMotionContainer: NSView {
    static let animationKey = "openbots.character.idle"
    static let opacityAnimationKey = "openbots.character.face.visibility"

    private(set) var host: CharacterIdleArtworkHostingView?
    private(set) var installedKeyframes: CharacterIdleMotion.Keyframes?
    private(set) var installedSize: CGFloat = 0
    private(set) var ribbonLayers: [CAShapeLayer] = []
    private(set) var reactionLayers: [CAShapeLayer] = []
    private(set) var rasterBackingLayer: CALayer?
    /// While a painted face turns: the head outline (the art's alpha), which
    /// sways, holds the back of the head and clips the sliding face inside it.
    private(set) var rasterHeadView: NSView?
    private var rasterBackingAvatar: BuiltInAvatar?
    private var rasterBackingSize: CGFloat = 0
    private var rasterBackingSeed: UInt64?
    private var ribbonSeed: UInt64?
    private var ribbonSize: CGFloat = 0
    private var lastReactionTime: TimeInterval?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: installedSize, height: installedSize) }

    func apply(content: AnyView, keyframes: CharacterIdleMotion.Keyframes, size: CGFloat,
               workingEffectsSeed: UInt64? = nil, reactionTime: TimeInterval? = nil,
               rasterBacking: BuiltInAvatar? = nil) {
        let host: CharacterIdleArtworkHostingView
        if let existing = self.host {
            host = existing
            host.rootView = content
        } else {
            host = CharacterIdleArtworkHostingView(rootView: content)
            host.sizingOptions = []
            host.wantsLayer = true
            addSubview(host)
            self.host = host
        }
        host.frame = NSRect(x: 0, y: 0, width: size, height: size)
        updateRasterBacking(avatar: rasterBacking, size: size, seed: workingEffectsSeed)
        updateRibbon(seed: workingEffectsSeed, size: size)
        if workingEffectsSeed != nil, let reactionTime, reactionTime != lastReactionTime {
            lastReactionTime = reactionTime
            playReaction(at: reactionTime, size: size, seed: workingEffectsSeed ?? 0)
        }
        guard keyframes != installedKeyframes || size != installedSize
                || host.layer?.animation(forKey: Self.animationKey) == nil else { return }
        installedKeyframes = keyframes
        installedSize = size
        invalidateIntrinsicContentSize()
        host.layer?.removeAnimation(forKey: Self.animationKey)
        host.layer?.removeAnimation(forKey: Self.opacityAnimationKey)
        host.layer?.add(Self.animation(for: keyframes, size: size), forKey: Self.animationKey)
        if let opacities = keyframes.opacities {
            host.layer?.add(Self.scalarAnimation(keyPath: "opacity", values: opacities,
                times: keyframes.keyTimes, duration: keyframes.duration, phaseOffset: keyframes.phaseOffset,
                synchronized: keyframes.synchronized), forKey: Self.opacityAnimationKey)
        }
    }

    func stopMotion() {
        host?.layer?.removeAnimation(forKey: Self.animationKey)
        host?.layer?.removeAnimation(forKey: Self.opacityAnimationKey)
        ribbonLayers.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        reactionLayers.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        ribbonLayers = []; reactionLayers = []; ribbonSeed = nil
        removeRasterHead()
        rasterBackingAvatar = nil; rasterBackingSeed = nil
        installedKeyframes = nil
    }

    static func animation(for keyframes: CharacterIdleMotion.Keyframes, size: CGFloat) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = keyframes.transforms.map { NSValue(caTransform3D: $0.layerTransform(size: size)) }
        animation.keyTimes = keyframes.keyTimes.map { NSNumber(value: $0) }
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: keyframes.synchronized ? .linear : .easeInEaseOut),
                                          count: max(0, keyframes.transforms.count - 1))
        animation.duration = keyframes.duration
        animation.timeOffset = keyframes.phaseOffset
        if keyframes.synchronized { animation.beginTime = CharacterWorkingMotion.epoch }
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    static func scalarAnimation(keyPath: String, values: [Double], times: [Double], duration: TimeInterval,
                                phaseOffset: TimeInterval, synchronized: Bool = true) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times.map(NSNumber.init(value:))
        animation.duration = duration
        animation.timeOffset = phaseOffset
        animation.beginTime = synchronized ? CharacterWorkingMotion.epoch : 0
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.calculationMode = .linear
        return animation
    }

    private func updateRibbon(seed: UInt64?, size: CGFloat) {
        guard seed != ribbonSeed || size != ribbonSize else { return }
        ribbonLayers.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        ribbonLayers = []; ribbonSeed = seed; ribbonSize = size
        guard let seed, let layer else { return }
        let frames = CharacterWorkingMotion.keyframes(seed: seed, part: .body)
        let progress = frames.keyTimes.map(CharacterWorkingMotion.turnProgress(at:))
        let starts = progress.map { max(0, $0 - 0.20) }
        let opacity = progress.map { $0 <= 0 || $0 >= 1 ? 0 : min(1, min($0 / 0.10, (1 - $0) / 0.16)) }
        let frontOpacity = zip(progress, opacity).map { turn, opacity in
            opacity * min(1, max(0, cos(turn * 2 * .pi) / 0.12))
        }
        let colors: [NSColor] = [
            .init(srgbRed: 0.94, green: 0.80, blue: 0.35, alpha: 1),
            .init(srgbRed: 0.90, green: 0.40, blue: 0.67, alpha: 1),
            .init(srgbRed: 0.44, green: 0.65, blue: 0.98, alpha: 1)
        ]
        for front in [false, true] {
            for (index, color) in colors.enumerated() {
                let ribbon = CAShapeLayer()
                ribbon.frame = CGRect(x: 0, y: 0, width: size, height: size)
                ribbon.zPosition = front ? 1 : -1
                ribbon.fillColor = nil; ribbon.strokeColor = color.cgColor
                ribbon.lineWidth = max(0.8, size * 0.035)
                ribbon.lineCap = .round; ribbon.lineJoin = .round
                ribbon.opacity = 0
                let path = CGMutablePath()
                for step in 0...100 {
                    let angle = Double(step) / 100 * 2 * .pi
                    let point = CGPoint(x: size * (0.5 + 0.56 * sin(angle)),
                        y: size * (0.31 - 0.12 * cos(angle) + Double(index - 1) * 0.031))
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                ribbon.path = path
                for (keyPath, values) in [("strokeStart", starts), ("strokeEnd", progress),
                                           ("opacity", front ? frontOpacity : opacity)] {
                    ribbon.add(Self.scalarAnimation(keyPath: keyPath, values: values, times: frames.keyTimes,
                        duration: frames.duration, phaseOffset: frames.phaseOffset), forKey: keyPath)
                }
                layer.addSublayer(ribbon); ribbonLayers.append(ribbon)
            }
        }
    }

    private func updateRasterBacking(avatar: BuiltInAvatar?, size: CGFloat, seed: UInt64?) {
        guard avatar != rasterBackingAvatar || size != rasterBackingSize || seed != rasterBackingSeed else { return }
        removeRasterHead()
        rasterBackingAvatar = avatar; rasterBackingSize = size; rasterBackingSeed = seed
        guard let avatar, let seed, let host,
              let image = BuiltInAvatarResources.image(for: avatar)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        let head = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        head.wantsLayer = true
        addSubview(head, positioned: .below, relativeTo: host)
        host.removeFromSuperview()
        head.addSubview(host)
        guard let headLayer = head.layer else { return }
        let mask = CALayer()
        let scale: CGFloat = avatar == .fin ? 1.4 : 1
        mask.frame = CGRect(x: size * (1 - scale) / 2, y: size * (1 - scale) / 2,
                            width: size * scale, height: size * scale)
        mask.contents = image
        mask.contentsGravity = .resizeAspect
        headLayer.mask = mask
        let backing = CAGradientLayer()
        backing.frame = CGRect(x: 0, y: 0, width: size, height: size)
        let color = Self.backingColor(from: image)
        backing.colors = [color.blended(withFraction: 0.10, of: .white)?.cgColor ?? color.cgColor,
                          color.blended(withFraction: 0.30, of: .black)?.cgColor ?? color.cgColor]
        headLayer.insertSublayer(backing, at: 0)
        headLayer.add(Self.animation(for: CharacterWorkingMotion.keyframes(seed: seed, part: .body), size: size),
                      forKey: Self.animationKey)
        rasterHeadView = head
        rasterBackingLayer = backing
    }

    private func removeRasterHead() {
        rasterBackingLayer?.removeAllAnimations()
        rasterBackingLayer?.removeFromSuperlayer()
        rasterBackingLayer = nil
        guard let head = rasterHeadView else { return }
        head.layer?.removeAllAnimations()
        if let host, host.superview === head {
            host.removeFromSuperview()
            addSubview(host, positioned: .below, relativeTo: head)
        }
        head.removeFromSuperview()
        rasterHeadView = nil
    }

    /// Sample only the existing bundled art; never sample the screen or user
    /// photos. The back of the head takes the colour of the art's top quarter,
    /// its hair, not the face's average.
    private static func backingColor(from image: CGImage) -> NSColor {
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 16, height: 16,
                bitsPerComponent: 8, bytesPerRow: 16 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
        // CGContext rows run bottom to top: the top quarter is the last four rows.
        for index in stride(from: 12 * 16 * 4, to: pixels.count, by: 4) where pixels[index + 3] > 240 {
            let alpha = Double(pixels[index + 3])
            red += Double(pixels[index]) / alpha
            green += Double(pixels[index + 1]) / alpha
            blue += Double(pixels[index + 2]) / alpha
            count += 1
        }
        guard count > 0 else { return .gray }
        return NSColor(srgbRed: red / count, green: green / count, blue: blue / count, alpha: 1)
    }

    private func playReaction(at time: TimeInterval, size: CGFloat, seed: UInt64) {
        reactionLayers.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        reactionLayers = []
        guard CACurrentMediaTime() - time < 0.8, let layer else { return }
        for index in 0..<12 {
            let angle = Double(index) / 12 * 2 * .pi + Double(seed % 17) / 17
            let speck = CAShapeLayer()
            let radius = max(0.7, size * 0.018)
            speck.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
            speck.fillColor = NSColor(hue: CGFloat(index) / 12, saturation: 0.6, brightness: 0.95, alpha: 1).cgColor
            speck.zPosition = 2; speck.opacity = 0
            let motion = CAKeyframeAnimation(keyPath: "position")
            // Typed step by step: as one expression Swift 6.1 could not type-check it in time.
            let radii: [CGFloat] = [0.38, 0.59, 0.68]
            let direction = CGPoint(x: CGFloat(cos(angle)), y: CGFloat(sin(angle)))
            motion.values = radii.map { (radius: CGFloat) -> NSValue in
                let x: CGFloat = size * (0.5 + radius * direction.x)
                let y: CGFloat = size * (0.5 + radius * direction.y)
                return NSValue(point: CGPoint(x: x, y: y))
            }
            motion.keyTimes = [0, 0.45, 1]
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.9, 0]; fade.keyTimes = [0, 0.15, 1]
            let group = CAAnimationGroup()
            group.animations = [motion, fade]; group.duration = 0.8; group.beginTime = time
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.addSublayer(speck); speck.add(group, forKey: "reaction")
            reactionLayers.append(speck)
        }
    }
}

/// The hosted artwork is decorative; its native hosting view exposes nothing to
/// accessibility (the outer identity view carries the label and value).
@MainActor
final class CharacterIdleArtworkHostingView: NSHostingView<AnyView> {
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
