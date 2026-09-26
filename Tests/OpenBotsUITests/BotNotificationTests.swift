import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsUI

@Suite("Bot notifications")
@MainActor
struct BotNotificationTests {
    @Test("Delivery needs the master, the bot preference and a conversation outside the foreground")
    func switchPolicy() {
        for master in [false, true] {
            for defaultOn in [false, true] {
                for foreground in [false, true] {
                    #expect(BotNotificationPolicy.allows(appEnabled: master, enabledByDefault: defaultOn,
                        preference: .enabled, isFrontmost: foreground) == (master && !foreground))
                    #expect(!BotNotificationPolicy.allows(appEnabled: master, enabledByDefault: defaultOn,
                        preference: .disabled, isFrontmost: foreground))
                    #expect(BotNotificationPolicy.allows(appEnabled: master, enabledByDefault: defaultOn,
                        preference: .inherit, isFrontmost: foreground) == (master && defaultOn && !foreground))
                }
            }
        }
    }

    @Test("Construction is inert; enabling requests permission, and disabled or foreground events are never queued")
    func inertAndSuppressed() async throws {
        let fixture = NotificationFixture()
        defer { fixture.close() }
        let model = fixture.model, client = fixture.client
        let event = BotNotificationEvent(id: UUID(), conversationID: UUID(), kind: .reply)
        #expect(client.authorizationRequests == 0)
        await model.post(event, preference: .enabled)
        #expect(client.events.isEmpty)
        await model.setAppEnabled(true)
        #expect(client.authorizationRequests == 1)
        model.isConversationFrontmost = { $0 == event.conversationID }
        await model.post(event, preference: .enabled)
        #expect(client.events.isEmpty)
        model.isConversationFrontmost = { _ in false }
        await model.post(event, preference: .disabled)
        #expect(client.events.isEmpty)
        await model.post(event, preference: .enabled)
        await model.post(event, preference: .enabled)
        #expect(client.events == [event])
        #expect(event.kind.body == "A bot’s reply is ready.")
    }

    @Test("A late authorization response cannot re-enable after Off or shutdown")
    func permissionRace() async {
        for close in [false, true] {
            let fixture = NotificationFixture()
            defer { fixture.close() }
            fixture.client.holdAuthorization = true
            let enable = Task { await fixture.model.setAppEnabled(true) }
            await fixture.client.waitForAuthorization()
            if close { fixture.model.stop() }
            else { await fixture.model.setAppEnabled(false) }
            fixture.client.releaseAuthorization(true)
            await enable.value
            #expect(!fixture.model.appEnabled)
            #expect(!fixture.model.isRequesting)
            #expect(fixture.client.events.isEmpty)
        }
    }

    @Test("Changing bot preferences while system authorization waits cannot strand the master toggle")
    func preferencesDuringAuthorization() async {
        for allowed in [false, true] {
            let fixture = NotificationFixture()
            defer { fixture.close() }
            fixture.client.holdAuthorization = true
            let enable = Task { await fixture.model.setAppEnabled(true) }
            await fixture.client.waitForAuthorization()
            #expect(fixture.model.isRequesting)
            fixture.model.preferencesChanged()
            fixture.model.setEnabledByDefault(false)
            fixture.client.releaseAuthorization(allowed)
            await enable.value
            #expect(!fixture.model.isRequesting)
            #expect(fixture.model.appEnabled == allowed)
            #expect(!fixture.model.enabledByDefault)
            let reopened = BotNotificationModel(defaults: fixture.defaults, client: fixture.client)
            #expect(reopened.appEnabled == allowed)
            #expect(!reopened.enabledByDefault)
            fixture.client.holdAuthorization = false
            await fixture.model.setAppEnabled(false)
            await fixture.model.setAppEnabled(true)
            #expect(fixture.model.appEnabled && !fixture.model.isRequesting)
        }
    }

    @Test("Off during delivery admission fences the event and preferences persist independently")
    func deliveryRaceAndPersistence() async {
        let fixture = NotificationFixture()
        defer { fixture.close() }
        await fixture.model.setAppEnabled(true)
        fixture.model.setEnabledByDefault(false)
        let restored = BotNotificationModel(defaults: fixture.defaults, client: fixture.client)
        #expect(restored.appEnabled)
        #expect(!restored.enabledByDefault)
        fixture.client.holdStatus = true
        let priorRemovals = fixture.client.removals
        let send = Task { await fixture.model.post(.init(id: UUID(), conversationID: UUID(), kind: .attention), preference: .enabled) }
        await fixture.client.waitForStatus()
        await fixture.model.setAppEnabled(false)
        fixture.client.releaseStatus(true)
        await send.value
        #expect(fixture.client.events.isEmpty)
        #expect(fixture.client.removals == priorRemovals + 1)
    }

    @Test("Declined macOS permission leaves the application switch off")
    func deniedPermission() async {
        let fixture = NotificationFixture()
        defer { fixture.close() }
        fixture.client.allowed = false
        await fixture.model.setAppEnabled(true)
        #expect(!fixture.model.appEnabled)
        #expect(fixture.model.notice?.contains("System Settings") == true)
    }
}

@MainActor
private final class NotificationFixture {
    /// One suite name per test, never a fresh one per run: macOS keeps an empty
    /// file in ~/Library/Preferences for every suite even after its domain is
    /// removed, and thousands can pile up there.
    let suite: String
    let client = FakeNotificationClient()
    let defaults: UserDefaults
    let model: BotNotificationModel
    init(test: String = #function) {
        suite = "OpenBotsNotificationTests." + test.filter { $0.isLetter || $0.isNumber }
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        model = BotNotificationModel(defaults: defaults, client: client)
    }
    func close() { defaults.removePersistentDomain(forName: suite) }
}

@MainActor
private final class FakeNotificationClient: BotNotificationClient {
    var allowed = true
    var authorizationRequests = 0
    var events: [BotNotificationEvent] = []
    var removals = 0
    var holdAuthorization = false
    var holdStatus = false
    private var authorization: CheckedContinuation<Bool, Never>?
    private var status: CheckedContinuation<Bool, Never>?
    private var authorizationWaiter: CheckedContinuation<Void, Never>?
    private var statusWaiter: CheckedContinuation<Void, Never>?

    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        guard holdAuthorization else { return allowed }
        return await withCheckedContinuation { continuation in
            authorization = continuation
            authorizationWaiter?.resume(); authorizationWaiter = nil
        }
    }
    func isAuthorized() async -> Bool {
        guard holdStatus else { return allowed }
        return await withCheckedContinuation { continuation in
            status = continuation
            statusWaiter?.resume(); statusWaiter = nil
        }
    }
    func deliver(_ event: BotNotificationEvent) async throws { events.append(event) }
    func removePending() { removals += 1 }
    func waitForAuthorization() async {
        if authorization != nil { return }
        await withCheckedContinuation { authorizationWaiter = $0 }
    }
    func waitForStatus() async {
        if status != nil { return }
        await withCheckedContinuation { statusWaiter = $0 }
    }
    func releaseAuthorization(_ value: Bool) { authorization?.resume(returning: value); authorization = nil }
    func releaseStatus(_ value: Bool) { status?.resume(returning: value); status = nil }
}
