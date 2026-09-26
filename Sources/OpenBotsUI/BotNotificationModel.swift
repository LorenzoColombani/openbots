import AppKit
import Combine
import OpenBotsDomain
import SwiftUI
@preconcurrency import UserNotifications

public enum BotNotificationKind: String, Sendable {
    case reply, attention

    var body: String {
        switch self {
        case .reply: "A bot’s reply is ready."
        case .attention: "A bot needs your attention."
        }
    }
}

public struct BotNotificationEvent: Equatable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let kind: BotNotificationKind
    public init(id: UUID, conversationID: UUID, kind: BotNotificationKind) {
        self.id = id; self.conversationID = conversationID; self.kind = kind
    }
}

@MainActor
protocol BotNotificationClient: AnyObject {
    func requestAuthorization() async throws -> Bool
    func isAuthorized() async -> Bool
    func deliver(_ event: BotNotificationEvent) async throws
    func removePending()
}

/// App-wide permission AND the bot's override/default. Foreground suppression
/// is conversation-specific: working in another conversation may still notify.
enum BotNotificationPolicy {
    static func allows(appEnabled: Bool, enabledByDefault: Bool,
                       preference: NotificationPreference, isFrontmost: Bool) -> Bool {
        appEnabled && !isFrontmost && (preference == .enabled || (preference == .inherit && enabledByDefault))
    }
}

@MainActor
public final class BotNotificationModel: ObservableObject {
    @Published public private(set) var appEnabled: Bool
    @Published public private(set) var enabledByDefault: Bool
    @Published public private(set) var isRequesting = false
    @Published public private(set) var notice: String?
    public var isConversationFrontmost: (UUID) -> Bool = { _ in false }
    public var openConversation: (UUID) -> Void = { _ in }
    private let defaults: UserDefaults
    private let client: any BotNotificationClient
    private var deliveryGeneration: UInt64 = 0
    private var authorizationGeneration: UInt64 = 0
    private var isClosed = false
    private var delivered = Set<UUID>()
    private var deliveredOrder: [UUID] = []
    private var pending = Set<UUID>()
    private static let enabledKey = "openbots.notifications.enabled"
    private static let defaultKey = "openbots.notifications.default"

    public convenience init() {
        let client = NativeBotNotificationClient()
        self.init(defaults: .standard, client: client)
        client.shouldPresent = { [weak self] id in
            guard let self else { return false }
            return self.appEnabled && !self.isClosed && !self.isConversationFrontmost(id)
        }
        client.onOpen = { [weak self] id in self?.openConversation(id) }
    }

    init(defaults: UserDefaults, client: any BotNotificationClient) {
        self.defaults = defaults; self.client = client
        appEnabled = defaults.bool(forKey: Self.enabledKey)
        enabledByDefault = defaults.object(forKey: Self.defaultKey) as? Bool ?? true
    }

    /// Called once by the installed app; constructing a model in an offline
    /// test never accesses the system notification center or asks permission.
    public func start() {
        guard !isClosed else { return }
        (client as? NativeBotNotificationClient)?.start()
    }

    public func setAppEnabled(_ enabled: Bool) async {
        guard !isClosed else { return }
        deliveryGeneration &+= 1
        authorizationGeneration &+= 1
        let current = authorizationGeneration
        notice = nil
        if !enabled {
            appEnabled = false; isRequesting = false
            defaults.set(false, forKey: Self.enabledKey)
            client.removePending()
            return
        }
        isRequesting = true
        defer {
            if current == authorizationGeneration { isRequesting = false }
        }
        do {
            let allowed = try await client.requestAuthorization()
            guard current == authorizationGeneration, !isClosed else { return }
            appEnabled = allowed
            defaults.set(allowed, forKey: Self.enabledKey)
            if !allowed { notice = "Notifications are off in macOS. You can allow them in System Settings → Notifications → OpenBots Next." }
        } catch {
            guard current == authorizationGeneration, !isClosed else { return }
            appEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            notice = "macOS could not enable notifications. Try again from this setting."
        }
    }

    public func setEnabledByDefault(_ enabled: Bool) {
        guard !isClosed else { return }
        enabledByDefault = enabled
        defaults.set(enabled, forKey: Self.defaultKey)
        preferencesChanged()
    }

    public func preferencesChanged() {
        guard !isClosed else { return }
        deliveryGeneration &+= 1
        client.removePending()
    }

    public func post(_ event: BotNotificationEvent, preference: NotificationPreference) async {
        guard !isClosed, !delivered.contains(event.id), !pending.contains(event.id),
              canPost(preference, conversationID: event.conversationID) else { return }
        pending.insert(event.id)
        defer { pending.remove(event.id) }
        let current = deliveryGeneration
        guard await client.isAuthorized(), current == deliveryGeneration, !isClosed,
              canPost(preference, conversationID: event.conversationID) else { return }
        do {
            try await client.deliver(event)
            guard current == deliveryGeneration, !isClosed else { client.removePending(); return }
            delivered.insert(event.id); deliveredOrder.append(event.id)
            if deliveredOrder.count > 256 { delivered.remove(deliveredOrder.removeFirst()) }
        } catch {
            guard current == deliveryGeneration, !isClosed else { return }
            notice = "A notification could not be delivered. The conversation is saved in OpenBots Next."
        }
    }

    private func canPost(_ preference: NotificationPreference, conversationID: UUID) -> Bool {
        BotNotificationPolicy.allows(appEnabled: appEnabled, enabledByDefault: enabledByDefault,
                                     preference: preference, isFrontmost: isConversationFrontmost(conversationID))
    }

    public func stop() {
        isClosed = true
        deliveryGeneration &+= 1; authorizationGeneration &+= 1
        isRequesting = false
        client.removePending()
    }
}

@MainActor
private final class NativeBotNotificationClient: NSObject, BotNotificationClient, UNUserNotificationCenterDelegate {
    var shouldPresent: (UUID) -> Bool = { _ in false }
    var onOpen: (UUID) -> Void = { _ in }
    private var center: UNUserNotificationCenter?

    func start() {
        guard center == nil else { return }
        let value = UNUserNotificationCenter.current()
        value.delegate = self
        center = value
    }
    func requestAuthorization() async throws -> Bool {
        start()
        return try await center?.requestAuthorization(options: [.alert, .sound]) ?? false
    }
    func isAuthorized() async -> Bool {
        guard let center else { return false }
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }
    func deliver(_ event: BotNotificationEvent) async throws {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "OpenBots Next"
        content.body = event.kind.body
        content.sound = .default
        content.userInfo = ["conversationID": event.conversationID.uuidString]
        content.threadIdentifier = event.conversationID.uuidString
        try await center.add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil))
    }
    func removePending() { center?.removeAllPendingNotificationRequests() }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard let value = notification.request.content.userInfo["conversationID"] as? String,
              let id = UUID(uuidString: value) else { return [] }
        return await MainActor.run { shouldPresent(id) ? [.banner, .sound] : [] }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let value = response.notification.request.content.userInfo["conversationID"] as? String,
              let id = UUID(uuidString: value) else { return }
        await MainActor.run { onOpen(id) }
    }
}

public struct BotNotificationSettingsView: View {
    @ObservedObject private var model: BotNotificationModel
    public init(model: BotNotificationModel) { self.model = model }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Allow notifications", isOn: Binding(get: { model.appEnabled }, set: { enabled in
                Task { await model.setAppEnabled(enabled) }
            }))
            .disabled(model.isRequesting)
            .accessibilityIdentifier("notifications.enabled")
            Toggle("Notify for bots by default", isOn: Binding(get: { model.enabledByDefault }, set: { model.setEnabledByDefault($0) }))
                .disabled(!model.appEnabled)
                .accessibilityIdentifier("notifications.default")
            Text("Each bot can use this default or override it in its settings. Notifications stay quiet for the conversation you are viewing, and never show message contents.")
                .font(.callout).foregroundStyle(.secondary)
            if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
