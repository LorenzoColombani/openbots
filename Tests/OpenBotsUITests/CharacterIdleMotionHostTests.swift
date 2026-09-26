import AppKit
import Combine
import OpenBotsDomain
import QuartzCore
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class CharacterIdleMotionHostTests: XCTestCase {
    func testNativeWorkingFacePressUsesCosmeticReactionAndRevocationDisablesIt() {
        let id = UUID()
        let target = CharacterWorkingAccessibilityView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        target.identityID = id
        target.botName = "Ada"
        target.canReact = true
        target.onPress = { CharacterWorkingReaction.request(for: id) }
        var received: [UUID] = []
        let observer = NotificationCenter.default.publisher(for: CharacterWorkingReaction.notification).sink { note in
            if let id = note.userInfo?["identity"] as? UUID { received.append(id) }
        }
        defer { observer.cancel() }
        XCTAssertEqual(target.accessibilityRole(), .button)
        XCTAssertEqual(target.accessibilityLabel(), "Ada is working")
        XCTAssertEqual(target.accessibilityIdentifier(), "working-avatar-\(id.uuidString)")
        XCTAssertTrue(target.isAccessibilityEnabled())
        XCTAssertTrue(target.accessibilityPerformPress())
        XCTAssertEqual(received, [id])
        XCTAssertNil(target.hitTest(CGPoint(x: 16, y: 16)), "The semantic target must not consume normal pointer hover/tap")
        XCTAssertFalse(target.acceptsFirstResponder)
        target.canReact = false
        XCTAssertFalse(target.accessibilityPerformPress())
        XCTAssertEqual(received, [id])
        target.canReact = true
        CharacterWorkingAccessibilityTarget.dismantleNSView(target, coordinator: ())
        XCTAssertFalse(target.isAccessibilityEnabled())
        XCTAssertFalse(target.accessibilityPerformPress())
        XCTAssertEqual(received, [id])
        XCTAssertNil(target.window)
    }

    func testRealInlineWorkingViewContainsAnExactFaceSemanticTargetWithoutOpeningAWindow() async throws {
        let row = TeammateRowModel(snapshot: .init(id: UUID(), name: "Ada", role: "Researcher",
                                                   activity: .thinkingOrWorking, identitySeed: 5))
        let conversationID = UUID()
        let host = NSHostingController(rootView: WorkingBotIndicator(row: row, conversationID: conversationID))
        host.sizingOptions = []
        host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 64)
        for _ in 0..<4 {
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
        func targets(in view: NSView) -> [CharacterWorkingAccessibilityView] {
            (view as? CharacterWorkingAccessibilityView).map { [$0] } ?? view.subviews.flatMap(targets(in:))
        }
        let found = targets(in: host.view)
        XCTAssertEqual(found.count, 1)
        let face = try XCTUnwrap(found.first)
        XCTAssertEqual(face.bounds.width, 32, accuracy: 0.5)
        XCTAssertEqual(face.bounds.height, 32, accuracy: 0.5)
        XCTAssertEqual(face.accessibilityIdentifier(), "working-avatar-\(row.id.uuidString)-in-\(conversationID.uuidString)")
        XCTAssertEqual(face.accessibilityRole(), .button)
        XCTAssertFalse(face.isAccessibilityEnabled(), "The real offscreen view must retain its visibility gate")
        XCTAssertFalse(face.accessibilityPerformPress())
        XCTAssertNil(host.view.window)
    }

    func testWorkingCopiesShareAContinuousMediaClockAndDoNotRestartOnUnrelatedUpdates() throws {
        let frames = CharacterWorkingMotion.keyframes(seed: 815, part: .body)
        let first = CharacterIdleMotionContainer(frame: .zero)
        let second = CharacterIdleMotionContainer(frame: .zero)
        first.apply(content: AnyView(Color.blue), keyframes: frames, size: 42, workingEffectsSeed: 815)
        second.apply(content: AnyView(Color.blue), keyframes: frames, size: 28, workingEffectsSeed: 815)
        let firstAnimation = try XCTUnwrap(first.host?.layer?.animation(forKey: CharacterIdleMotionContainer.animationKey))
        let secondAnimation = try XCTUnwrap(second.host?.layer?.animation(forKey: CharacterIdleMotionContainer.animationKey))
        XCTAssertEqual(firstAnimation.beginTime, CharacterWorkingMotion.epoch)
        XCTAssertEqual(firstAnimation.beginTime, secondAnimation.beginTime)
        XCTAssertEqual(firstAnimation.timeOffset, secondAnimation.timeOffset)
        XCTAssertEqual(firstAnimation.duration, secondAnimation.duration)
        XCTAssertEqual(first.ribbonLayers.count, 6)
        let oldRibbons = first.ribbonLayers
        first.apply(content: AnyView(Color.green), keyframes: frames, size: 42, workingEffectsSeed: 815)
        XCTAssertTrue(firstAnimation === first.host?.layer?.animation(forKey: CharacterIdleMotionContainer.animationKey))
        XCTAssertEqual(oldRibbons.map(ObjectIdentifier.init), first.ribbonLayers.map(ObjectIdentifier.init))
        for ribbon in first.ribbonLayers {
            for key in ["strokeStart", "strokeEnd", "opacity"] {
                let animation = try XCTUnwrap(ribbon.animation(forKey: key) as? CAKeyframeAnimation)
                XCTAssertEqual(animation.beginTime, firstAnimation.beginTime)
                XCTAssertEqual(animation.timeOffset, firstAnimation.timeOffset)
                XCTAssertEqual(animation.duration, firstAnimation.duration)
                XCTAssertEqual(animation.calculationMode, .linear)
            }
        }
        first.stopMotion(); second.stopMotion()
    }

    func testWorkingFaceMakesACompleteOccludedTurnWhileBodyAndRasterStayBroad() throws {
        let face = CharacterWorkingMotion.keyframes(seed: 815, part: .face)
        let opacity = try XCTUnwrap(face.opacities)
        XCTAssertEqual(face.transforms.count, CharacterWorkingMotion.sampleCount + 1)
        XCTAssertEqual(face.transforms.first, .identity)
        XCTAssertEqual(face.transforms.last, .identity)
        XCTAssertEqual(opacity.first, 1); XCTAssertEqual(opacity.last, 1)
        XCTAssertTrue(opacity.contains(0), "The face passes behind the body during the complete turn")
        XCTAssertGreaterThan(face.transforms.map(\.horizontalOffsetFactor).max() ?? 0, 0.38)
        XCTAssertLessThan(face.transforms.map(\.horizontalOffsetFactor).min() ?? 0, -0.38)
        for (previous, next) in zip(face.transforms, face.transforms.dropFirst()) {
            XCTAssertLessThan(abs(next.horizontalOffsetFactor - previous.horizontalOffsetFactor), 0.13,
                              "Dense continuous interpolation must not jump between sampled poses")
        }
        let body = CharacterWorkingMotion.keyframes(seed: 815, part: .body)
        XCTAssertNil(body.opacities)
        XCTAssertTrue(body.transforms.allSatisfy { $0.horizontalScale == 1 && $0.yaw == 0 })
    }

    /// Seen on screen: the painted Canobi face turned a full circle about its
    /// own centre over a flat backing that stayed still, so mid-turn it showed
    /// half a face on a brown disc; turning the backing with it made a flat
    /// coin flip (the head looked 2D). A flat picture turned side-on is a line. The
    /// drawn faces look round because the head outline stays and the face slides
    /// across it and narrows; the painted face now does the same, inside its own
    /// outline, with the back of the head in its hair colour.
    func testRasterFaceSlidesAroundAStillHeadOutline() throws {
        let frames = CharacterWorkingMotion.keyframes(seed: 815, part: .rasterBody)
        XCTAssertTrue(frames.transforms.allSatisfy { $0.yaw == 0 }, "No flat card turn")
        XCTAssertTrue(frames.transforms.allSatisfy { $0.scale == 1 && $0.rotation == 0 && $0.verticalOffsetFactor == 0 },
                      "The sway belongs to the head outline, not the sliding face")
        let offsets = frames.transforms.map(\.horizontalOffsetFactor)
        XCTAssertEqual(offsets.map(abs).max() ?? 0, 0.40, accuracy: 0.01)
        XCTAssertTrue(frames.transforms.allSatisfy { $0.horizontalScale >= 0.025 && $0.horizontalScale <= 1 })
        let opacity = try XCTUnwrap(frames.opacities)
        XCTAssertEqual(opacity.first, 1); XCTAssertEqual(opacity.last, 1)
        XCTAssertTrue(opacity.contains(0), "The face is hidden while the back of the head faces the viewer")
        for avatar in [BuiltInAvatar.guide, .fin] {
            let container = CharacterIdleMotionContainer(frame: .zero)
            container.apply(content: AnyView(BuiltInAvatarArtwork(avatar: avatar, size: 42)),
                keyframes: frames, size: 42, workingEffectsSeed: 815, rasterBacking: avatar)
            let host = try XCTUnwrap(container.host)
            let head = try XCTUnwrap(container.rasterHeadView)
            XCTAssertTrue(host.superview === head, "The face moves inside the head outline")
            let headLayer = try XCTUnwrap(head.layer)
            XCTAssertNotNil(headLayer.mask?.contents, "The outline is the art's own alpha")
            XCTAssertEqual(headLayer.mask?.contentsGravity, .resizeAspect)
            let sway = try XCTUnwrap(headLayer.animation(forKey: CharacterIdleMotionContainer.animationKey) as? CAKeyframeAnimation)
            let body = CharacterWorkingMotion.keyframes(seed: 815, part: .body)
            XCTAssertEqual((sway.values as? [NSValue])?.map { $0.caTransform3DValue.m11 },
                           body.transforms.map { $0.layerTransform(size: 42).m11 })
            let backing = try XCTUnwrap(container.rasterBackingLayer)
            XCTAssertTrue(backing.superlayer === headLayer)
            XCTAssertTrue(headLayer.sublayers?.first === backing, "The back of the head is drawn under the face")
            XCTAssertNil(backing.animationKeys(), "The back of the head moves only with the head")
            let faceMotion = try XCTUnwrap(host.layer?.animation(forKey: CharacterIdleMotionContainer.animationKey))
            XCTAssertEqual(faceMotion.beginTime, sway.beginTime)
            XCTAssertEqual(faceMotion.timeOffset, sway.timeOffset)
            container.apply(content: AnyView(BuiltInAvatarArtwork(avatar: avatar, size: 42)),
                keyframes: frames, size: 42, workingEffectsSeed: 815, reactionTime: CACurrentMediaTime(), rasterBacking: avatar)
            XCTAssertTrue(backing === container.rasterBackingLayer, "A playful reaction must preserve the turning volume")
            container.stopMotion()
            XCTAssertNil(container.rasterBackingLayer)
            XCTAssertNil(backing.superlayer)
            XCTAssertTrue(host.superview === container, "Idle motion moves the face with the whole head again")
            XCTAssertNil(container.rasterHeadView)
        }
    }

    func testFaceOpacityRibbonAndOneShotSpecksAllStopWithTheOwningHost() throws {
        let container = CharacterIdleMotionContainer(frame: .zero)
        let frames = CharacterWorkingMotion.keyframes(seed: 815, part: .face)
        let stamp = CACurrentMediaTime()
        container.apply(content: AnyView(Color.blue), keyframes: frames, size: 42,
                        workingEffectsSeed: 815, reactionTime: stamp)
        let layer = try XCTUnwrap(container.host?.layer)
        XCTAssertNotNil(layer.animation(forKey: CharacterIdleMotionContainer.opacityAnimationKey))
        XCTAssertEqual(container.reactionLayers.count, 12)
        let specks = container.reactionLayers
        for speck in specks {
            let reaction = try XCTUnwrap(speck.animation(forKey: "reaction") as? CAAnimationGroup)
            XCTAssertEqual(reaction.repeatCount, 0)
            XCTAssertLessThanOrEqual(reaction.duration, 0.8)
            XCTAssertEqual(reaction.beginTime, stamp)
        }
        container.apply(content: AnyView(Color.blue), keyframes: frames, size: 42,
                        workingEffectsSeed: 815, reactionTime: stamp)
        XCTAssertEqual(specks.map(ObjectIdentifier.init), container.reactionLayers.map(ObjectIdentifier.init))
        container.stopMotion()
        XCTAssertNil(layer.animationKeys())
        XCTAssertTrue(container.ribbonLayers.isEmpty)
        XCTAssertTrue(container.reactionLayers.isEmpty)
        XCTAssertTrue(specks.allSatisfy { $0.superlayer == nil && $0.animationKeys() == nil })
    }

    func testPlayfulRequestBroadcastsOnlyTheChosenIdentityAndOneSharedTimestamp() {
        let id = UUID()
        var received: [(UUID, TimeInterval)] = []
        let observer = NotificationCenter.default.publisher(for: CharacterWorkingReaction.notification).sink { note in
            if let id = note.userInfo?["identity"] as? UUID, let time = note.userInfo?["time"] as? TimeInterval {
                received.append((id, time))
            }
        }
        defer { observer.cancel() }
        CharacterWorkingReaction.request(for: id)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, id)
        XCTAssertGreaterThan(received.first?.1 ?? 0, 0)
    }

    func testContainerInstallsOneRepeatingKeyframeAnimationOnTheHostedArtwork() throws {
        let container = CharacterIdleMotionContainer(frame: .zero)
        let keyframes = CharacterIdleMotion.keyframes(seed: 7)
        container.apply(content: AnyView(Color.red), keyframes: keyframes, size: 42)

        let host = try XCTUnwrap(container.host)
        XCTAssertEqual(host.frame, NSRect(x: 0, y: 0, width: 42, height: 42))
        XCTAssertEqual(container.intrinsicContentSize, NSSize(width: 42, height: 42))
        let animation = try XCTUnwrap(
            host.layer?.animation(forKey: CharacterIdleMotionContainer.animationKey) as? CAKeyframeAnimation
        )
        XCTAssertEqual(animation.keyPath, "transform")
        XCTAssertEqual(animation.values?.count, keyframes.transforms.count)
        XCTAssertEqual(animation.keyTimes?.map(\.doubleValue), keyframes.keyTimes)
        XCTAssertEqual(animation.timingFunctions?.count, keyframes.transforms.count - 1)
        XCTAssertEqual(animation.duration, CharacterIdleMotion.cycleDuration(seed: 7))
        XCTAssertEqual(animation.timeOffset, keyframes.phaseOffset)
        XCTAssertEqual(animation.repeatCount, .infinity)
        XCTAssertFalse(animation.isRemovedOnCompletion)
        XCTAssertEqual(host.layer?.animationKeys(), [CharacterIdleMotionContainer.animationKey])
    }

    func testReapplyingKeepsTheCycleAndANewSeedReplacesIt() throws {
        let container = CharacterIdleMotionContainer(frame: .zero)
        let first = CharacterIdleMotion.keyframes(seed: 7)
        container.apply(content: AnyView(Color.red), keyframes: first, size: 42)
        let before = try XCTUnwrap(container.host?.layer?.animation(forKey: CharacterIdleMotionContainer.animationKey))
        container.apply(content: AnyView(Color.blue), keyframes: first, size: 42)
        let after = try XCTUnwrap(container.host?.layer?.animation(forKey: CharacterIdleMotionContainer.animationKey))
        XCTAssertTrue(before === after, "an unchanged cycle must not restart on every SwiftUI update")
        XCTAssertEqual(container.subviews.count, 1)

        var otherSeed: UInt64 = 8
        while CharacterIdleMotion.keyframes(seed: otherSeed) == first { otherSeed += 1 }
        let second = CharacterIdleMotion.keyframes(seed: otherSeed)
        container.apply(content: AnyView(Color.blue), keyframes: second, size: 42)
        let replaced = try XCTUnwrap(
            container.host?.layer?.animation(forKey: CharacterIdleMotionContainer.animationKey) as? CAKeyframeAnimation
        )
        XCTAssertFalse(replaced === after)
        XCTAssertEqual(replaced.duration, second.duration)
        XCTAssertEqual(container.installedKeyframes, second)
    }

    func testContainerIsDecorativeOnly() {
        let container = CharacterIdleMotionContainer(frame: .zero)
        container.apply(content: AnyView(Color.red), keyframes: CharacterIdleMotion.keyframes(seed: 1), size: 36)
        XCTAssertTrue(container.isFlipped)
        XCTAssertFalse(container.acceptsFirstResponder)
        XCTAssertNil(container.hitTest(NSPoint(x: 10, y: 10)))
        XCTAssertFalse(container.isAccessibilityElement())
        XCTAssertEqual(container.host?.isAccessibilityElement(), false)
        XCTAssertNil(container.host?.accessibilityChildren())
        XCTAssertNil(container.host?.hitTest(NSPoint(x: 10, y: 10)))
        XCTAssertTrue(container.wantsLayer)
        XCTAssertEqual(container.host?.wantsLayer, true)
    }

    func testStoppingMotionRemovesTheLayerClockAndAnExplicitReentryReinstallsIt() {
        let container = CharacterIdleMotionContainer(frame: .zero)
        let frames = CharacterIdleMotion.keyframes(seed: 8, activity: .thinkingOrWorking)
        container.apply(content: AnyView(Color.red), keyframes: frames, size: 42)
        XCTAssertNotNil(container.host?.layer?.animation(forKey: CharacterIdleMotionContainer.animationKey))
        container.stopMotion()
        XCTAssertNil(container.host?.layer?.animation(forKey: CharacterIdleMotionContainer.animationKey))
        XCTAssertNil(container.installedKeyframes)
        container.apply(content: AnyView(Color.red), keyframes: frames, size: 42)
        XCTAssertNotNil(container.host?.layer?.animation(forKey: CharacterIdleMotionContainer.animationKey))
    }

    func testBothEyeLayersRemoveTheirClocksAndRetainTheUnchangedRestingGeometry() throws {
        let configuration = CharacterEyeMotion.Configuration(seed: 815, isWorking: false)
        for part in [CharacterEyeMotion.Part.eyelids, .pupils] {
            let container = CharacterIdleMotionContainer(frame: .zero)
            let frames = CharacterEyeMotion.keyframes(part: part, configuration: configuration)
            container.apply(content: AnyView(Color.white), keyframes: frames, size: 42)
            let layer = try XCTUnwrap(container.host?.layer)
            let animation = try XCTUnwrap(layer.animation(forKey: CharacterIdleMotionContainer.animationKey)
                as? CAKeyframeAnimation)
            XCTAssertEqual(animation.duration, frames.duration)
            XCTAssertEqual(animation.timeOffset, frames.phaseOffset)
            XCTAssertTrue(CATransform3DIsIdentity(layer.transform), "Motion never changes the model-layer eye pose")
            container.stopMotion()
            XCTAssertNil(layer.animationKeys())
            XCTAssertTrue(CATransform3DIsIdentity(layer.transform))
        }
    }

    func testLayerTransformMatchesTheSwiftUIPoseAboutTheArtworkCenter() {
        let size: CGFloat = 42
        let center = CGPoint(x: 21, y: 21)
        XCTAssertTrue(CATransform3DIsIdentity(CharacterArtworkTransform.identity.layerTransform(size: size)))

        let offset = CharacterArtworkTransform(scale: 1, rotation: 0, verticalOffsetFactor: 2.5 / 42,
                                               horizontalOffsetFactor: -1 / 42)
        let moved = Self.apply(offset.layerTransform(size: size), to: center)
        XCTAssertEqual(moved.x, 20, accuracy: 0.0001)
        XCTAssertEqual(moved.y, 23.5, accuracy: 0.0001)

        let scaled = CharacterArtworkTransform(scale: 1.02, rotation: 0, verticalOffsetFactor: 0)
        let stillCentered = Self.apply(scaled.layerTransform(size: size), to: center)
        XCTAssertEqual(stillCentered.x, center.x, accuracy: 0.0001)
        XCTAssertEqual(stillCentered.y, center.y, accuracy: 0.0001)
        let edge = Self.apply(scaled.layerTransform(size: size), to: CGPoint(x: 42, y: 21))
        XCTAssertEqual(edge.x, 21 + 21 * 1.02, accuracy: 0.0001)

        let blink = CharacterArtworkTransform(scale: 1, rotation: 0, verticalOffsetFactor: 0,
                                                verticalScale: 0.08)
        let eyelid = Self.apply(blink.layerTransform(size: size), to: CGPoint(x: 24, y: 25))
        XCTAssertEqual(eyelid.x, 24, accuracy: 0.0001)
        XCTAssertEqual(eyelid.y, 21 + 4 * 0.08, accuracy: 0.0001)

        // Flipped (top-left origin) geometry: a positive angle turns clockwise on screen,
        // matching SwiftUI's rotationEffect; the point right of center moves below it.
        let quarter = CharacterArtworkTransform(scale: 1, rotation: 90, verticalOffsetFactor: 0)
        let turned = Self.apply(quarter.layerTransform(size: size), to: CGPoint(x: 22, y: 21))
        XCTAssertEqual(turned.x, 21, accuracy: 0.0001)
        XCTAssertEqual(turned.y, 22, accuracy: 0.0001)
    }

    func testIdentityViewLoopsThroughCoreAnimationNotTheSwiftUIGraph() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenBotsUI/CharacterIdentityView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains(".phaseAnimator(CharacterIdleMotion"),
                       "the continuous idle loop must not re-render the SwiftUI graph every frame")
        XCTAssertTrue(source.contains("CharacterIdleMotionHost(seed: seed, size: size, colorScheme: colorScheme,"))
        XCTAssertTrue(source.contains(".phaseAnimator(CharacterTransitionPhase.allCases, trigger: activity)"),
                      "the finite state-change accent stays a SwiftUI phase animation")
        XCTAssertFalse(source.contains("TimelineView"))
        XCTAssertFalse(source.contains("Timer"))
    }

    private static func apply(_ transform: CATransform3D, to point: CGPoint) -> CGPoint {
        CGPoint(x: transform.m11 * point.x + transform.m21 * point.y + transform.m41,
                y: transform.m12 * point.x + transform.m22 * point.y + transform.m42)
    }
}
