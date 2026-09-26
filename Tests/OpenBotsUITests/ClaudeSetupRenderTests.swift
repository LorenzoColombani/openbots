import AppKit
import Foundation
import OpenBotsServices
import SwiftUI
import XCTest
@testable import OpenBotsUI

/// Offscreen images of injected local readiness and handoff outcomes.
/// No window, real inspector, provider operation or OCR is involved.
/// The images need a person's look; passing layout checks is not visual acceptance.
@MainActor
final class ClaudeSetupRenderTests: XCTestCase {
    func testPrimaryActionChecksExistingSubscriptionWithoutSignInOrAnExtraLocalStep() async throws {
        let evidence = try XCTUnwrap(ClaudeVerifiedSubscription(
            exitCode: 0, loggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty",
            subscriptionType: "max", checkedAt: Date(timeIntervalSince1970: 1_788_000_000)))
        let service = ClaudeSetupHandoffRenderService(statusOutcome: .verified(evidence))
        let model = ClaudeSetupModel(service: service)
        let view = ClaudeSetupView(model: model)
        XCTAssertEqual(view.checkButtonTitle, "Check Claude")
        XCTAssertFalse(view.offersSignIn)
        let initialChecks = await service.subscriptionCalls
        XCTAssertEqual(initialChecks, 0, "Rendering the new entry point stays inert")

        // macOS 26 SwiftUI controls are not NSButton descendants. Exercise the
        // exact view action and verify visible text separately through renders/OCR.
        view.checkClaude()
        let task = try XCTUnwrap(model.actionTask)
        await task.value
        XCTAssertEqual(model.state, .verified(evidence))
        XCTAssertEqual(view.checkButtonTitle, "Check again")
        XCTAssertFalse(view.offersSignIn)
        view.signInWithClaude()
        let localCalls = await service.localCalls
        let statusCalls = await service.subscriptionCalls
        let signInCalls = await service.signInCalls
        XCTAssertEqual(localCalls, 0, "The existing status service already owns the fresh installation preflight")
        XCTAssertEqual(statusCalls, 1)
        XCTAssertEqual(signInCalls, 0)
        try await render(model: model, width: 520, scheme: .light,
                         filename: "claude-setup-connected-light-520.png")
    }

    func testSignInActionIsOfferedOnlyAfterAnExplicitSignedOutResult() async throws {
        let outcomes: [ClaudeSetupOutcome] = [
            .needsSignIn, .readyToConnect, .handedOffNeedsVerification,
            .problem(.connectionCheckInconclusive), .problem(.installationRejected)
        ]
        for outcome in outcomes {
            let service = ClaudeSetupHandoffRenderService(statusOutcome: outcome)
            let model = ClaudeSetupModel(service: service)
            model.checkSubscription()
            await model.actionTask?.value
            let view = ClaudeSetupView(model: model)
            XCTAssertEqual(view.offersSignIn, outcome == .needsSignIn)
            XCTAssertEqual(view.checkButtonTitle, "Check Claude")
            let beforeSignIn = await service.signInCalls
            XCTAssertEqual(beforeSignIn, 0)
            if outcome == .needsSignIn {
                // macOS 27 delivers the rendered pane's onDisappear a beat after its host is
                // released, and that cancels whatever is pending. Keep the signed-out pane
                // alive while its button is pressed, as it is for a person.
                let signedOutPane = try await render(model: model, width: 460, scheme: .light,
                                                     filename: "claude-setup-signed-out-light-460.png")
                view.signInWithClaude()
                let task = try XCTUnwrap(model.actionTask)
                await task.value
                XCTAssertEqual(model.state, .handedOffNeedsVerification)
                XCTAssertFalse(view.offersSignIn)
                view.signInWithClaude()
                let checksAfterHandoff = await service.subscriptionCalls
                let handoffs = await service.signInCalls
                XCTAssertEqual(checksAfterHandoff, 1, "Terminal handoff never triggers an automatic account check")
                XCTAssertEqual(handoffs, 1)
                withExtendedLifetime(signedOutPane) {}
            } else {
                view.signInWithClaude()
                let handoffs = await service.signInCalls
                XCTAssertEqual(handoffs, 0, "A stale or inappropriate view action cannot start sign-in")
            }
        }
    }

    func testTerminalHandoffRendersWithoutACompletionClaimOrAutomaticCheck() async throws {
        for (width, scheme) in [(CGFloat(460), ColorScheme.light), (CGFloat(520), ColorScheme.dark)] {
            let service = ClaudeSetupHandoffRenderService()
            let model = ClaudeSetupModel(service: service)
            model.connectClaude()
            await model.actionTask?.value
            XCTAssertEqual(model.state, .readyToConnect)
            model.beginOfficialSignIn()
            await model.actionTask?.value
            XCTAssertEqual(model.state, .handedOffNeedsVerification)
            XCTAssertTrue(model.hasVerifiedLocalSetup)
            try await render(
                model: model, width: width, scheme: scheme,
                filename: "claude-setup-terminal-handoff-\(scheme == .dark ? "dark" : "light")-\(Int(width)).png"
            )
            let subscriptionCalls = await service.subscriptionCalls
            let signInCalls = await service.signInCalls
            XCTAssertEqual(subscriptionCalls, 0, "Displaying an accepted handoff must not check an account.")
            XCTAssertEqual(signInCalls, 1, "Displaying the handoff must not open it again.")
            XCTAssertEqual(model.state, .handedOffNeedsVerification)
        }
    }

    func testInitialAndReadySettingsRenderWithoutCredentials() async throws {
        let configurations: [(CGFloat, ColorScheme)] = [
            (520, .light), (520, .dark), (460, .light)
        ]
        for (width, scheme) in configurations {
            let service = ClaudeSetupHandoffRenderService()
            let model = ClaudeSetupModel(service: service)
            let appearance = scheme == .dark ? "dark" : "light"
            XCTAssertEqual(model.state, .notChecked)
            XCTAssertNil(model.localFindings)
            try await render(
                model: model, width: width, scheme: scheme,
                filename: "claude-setup-initial-\(appearance)-\(Int(width)).png"
            )
            let initialChecks = await service.localCalls
            XCTAssertEqual(initialChecks, 0, "Opening the pane must not inspect even the injected metadata.")
            XCTAssertEqual(model.state, .notChecked)

            model.connectClaude()
            XCTAssertEqual(model.state, .checking)
            await model.actionTask?.value
            XCTAssertEqual(model.state, .readyToConnect)
            XCTAssertEqual(model.localFindings?.installation, .verified)
            XCTAssertEqual(model.localFindings?.profile, .metadataVerified)
            XCTAssertFalse(model.isBusy)
            try await render(
                model: model, width: width, scheme: scheme,
                filename: "claude-setup-ready-to-connect-\(appearance)-\(Int(width)).png"
            )
            let finalChecks = await service.localCalls
            let signInCalls = await service.signInCalls
            let subscriptionCalls = await service.subscriptionCalls
            XCTAssertEqual(finalChecks, 1, "Rendering a result must not retry or inspect again.")
            XCTAssertEqual(signInCalls, 0, "Local readiness must not start sign-in.")
            XCTAssertEqual(subscriptionCalls, 0, "Local readiness must not check an account.")
            XCTAssertEqual(model.state, .readyToConnect)
        }
    }

    @discardableResult
    private func render(
        model: ClaudeSetupModel, width: CGFloat, scheme: ColorScheme, filename: String
    ) async throws -> NSViewController {
        let height: CGFloat = 820
        let controller = NSHostingController(rootView: ClaudeSetupView(model: model)
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!))
        controller.view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        for _ in 0..<4 {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
        let fit = controller.sizeThatFits(in: CGSize(width: width, height: height))
        XCTAssertTrue(fit.width.isFinite && fit.height.isFinite)
        XCTAssertGreaterThan(fit.width, 0)
        XCTAssertGreaterThan(fit.height, 0)
        XCTAssertLessThanOrEqual(fit.width, width + 1)
        XCTAssertLessThanOrEqual(fit.height, height + 1)
        XCTAssertNil(controller.view.window)
        let descendants = allSubviews(of: controller.view)
        XCTAssertFalse(descendants.contains { $0 is NSSecureTextField })
        XCTAssertFalse(descendants.compactMap { $0 as? NSTextField }.contains(where: \.isEditable))
        XCTAssertFalse(descendants.compactMap { $0 as? NSTextView }.contains(where: \.isEditable))
        for view in descendants where !view.isHiddenOrHasHiddenAncestor {
            let bounds = view.convert(view.bounds, to: controller.view)
            XCTAssertTrue(bounds.minX.isFinite && bounds.minY.isFinite && bounds.width.isFinite && bounds.height.isFinite)
            XCTAssertGreaterThanOrEqual(bounds.width, 0)
            XCTAssertGreaterThanOrEqual(bounds.height, 0)
        }

        let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1_000)
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build.noindex/claude-setup-evidence-20260830/rendered", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let destination = directory.appendingPathComponent(filename)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        print("Claude setup offscreen image: \(destination.path)")
        return controller
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allSubviews(of: $0) }
    }
}

private actor ClaudeSetupHandoffRenderService: ClaudeSetupServicing {
    private(set) var localCalls = 0
    private(set) var subscriptionCalls = 0
    private(set) var signInCalls = 0
    private let statusOutcome: ClaudeSetupOutcome

    init(statusOutcome: ClaudeSetupOutcome = .problem(.connectionCheckInconclusive)) {
        self.statusOutcome = statusOutcome
    }

    func checkThisMac() async -> ClaudeSetupReport {
        localCalls += 1
        return .init(
            local: .init(
                installation: .verified, profile: .metadataVerified,
                details: [
                    .init(label: "Evidence", value: "Injected render metadata; no installation was inspected"),
                    .init(label: "Signature", value: "Verified fixture result")
                ]
            ),
            outcome: .readyToConnect
        )
    }

    func checkSubscription() async -> ClaudeSetupReport {
        subscriptionCalls += 1
        return .init(outcome: statusOutcome)
    }

    func beginOfficialSignIn() async -> ClaudeSetupReport {
        signInCalls += 1
        return .init(outcome: .handedOffNeedsVerification)
    }
}
