import Combine
import OpenBotsDomain
import OpenBotsServices
import SwiftUI

/// Owns the reversible hidden-bot list. Hide never deletes content.
@MainActor
public final class BotHiddenModel: ObservableObject {
    @Published public var isPresented = false
    @Published public private(set) var hiddenBots: [Teammate] = []
    @Published public private(set) var isBusy = false
    @Published public var errorMessage: String?
    private let service: any TeammateNavigating

    public init(service: any TeammateNavigating) { self.service = service }

    public func load() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { hiddenBots = try await service.hiddenTeammates() }
        catch { errorMessage = "Couldn’t load hidden bots. Your saved bots are unchanged." }
    }

    func setHidden(_ teammate: Teammate, hidden: Bool) async -> Teammate? {
        guard !isBusy else { return nil }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let saved = try await service.setHidden(
                id: teammate.id,
                hidden: hidden,
                expectedProfileRevision: teammate.profile.revision
            )
            if saved.isHidden {
                hiddenBots.removeAll { $0.id == saved.id }
                hiddenBots.append(saved)
            } else {
                hiddenBots.removeAll { $0.id == saved.id }
            }
            return saved
        } catch {
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? TeammateNavigationError {
        case .staleRevision:
            return "This bot changed in another operation. Refresh and try again."
        case .notFound, .notActive:
            return "This bot is no longer in the expected state. Refresh the bot list before trying again."
        default:
            return "Couldn’t change this bot’s visibility. Your saved data is preserved."
        }
    }
}

struct HiddenBotsView: View {
    @ObservedObject var model: BotHiddenModel
    let unhide: @MainActor (Teammate) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Hidden Bots").font(.title2).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { model.isPresented = false }.keyboardShortcut(.cancelAction)
            }
            Text("Hidden bots keep their messages, drafts, files and settings. Unhide brings the same bot back to the sidebar.")
                .foregroundStyle(.secondary)
            List(model.hiddenBots) { bot in
                HStack(spacing: 12) {
                    CharacterIdentityView(identity: TeammateIdentitySnapshot(bot), activity: .idle, size: 36)
                    VStack(alignment: .leading) {
                        Text(bot.profile.displayName).font(.headline)
                        Text(bot.profile.role).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Unhide") { Task { await unhide(bot) } }
                        .accessibilityLabel("Unhide \(bot.profile.displayName)")
                }
                .padding(.vertical, 4)
                .contextMenu {
                    Button("Unhide Bot") { [bot] in Task { await unhide(bot) } }
                        .disabled(model.isBusy)
                }
            }
            .overlay {
                if model.hiddenBots.isEmpty, !model.isBusy {
                    Text("No hidden bots").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Refresh") { Task { await model.load() } }
                if model.isBusy {
                    ProgressView().controlSize(.small).accessibilityLabel("Updating hidden bots")
                }
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 360, idealHeight: 420)
        .disabled(model.isBusy)
        .task { await model.load() }
        .alert("Hide or Unhide", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) { Button("OK", role: .cancel) { model.errorMessage = nil } }
        message: { Text(model.errorMessage ?? "") }
    }
}
