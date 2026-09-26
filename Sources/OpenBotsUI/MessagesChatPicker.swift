import Foundation
import OpenBotsDomain
import OpenBotsServices
import SwiftUI

/// The chats one bot may read in Messages, ticked in a list of the user's
/// conversations. Nothing is saved until the user presses Save; the list is
/// the user's conversations by the names they know, never their messages.
@MainActor
public final class MessagesChatPickerModel: ObservableObject, Identifiable {
    public let id = UUID()
    public let botName: String
    @Published public var search = ""
    @Published public private(set) var selected: Set<String>
    /// Every conversation, the chats the user already chose first: those
    /// Messages still keeps in the list's own order, then any it no longer
    /// keeps, so the user can untick them.
    public let choices: [MessagesChatChoice]

    public init(botName: String, choices: [MessagesChatChoice], chosen: AppleMessagesChatScope) {
        self.botName = botName
        let wanted = Set(chosen.guids)
        let listed = Set(choices.map(\.guid))
        let gone = chosen.guids.filter { !listed.contains($0) }.map {
            MessagesChatChoice(guid: $0, title: BotAccessCopy.chatGone, detail: nil, lastMessageAt: nil,
                               isChoosable: true)
        }
        self.choices = choices.filter { wanted.contains($0.guid) } + gone + choices.filter { !wanted.contains($0.guid) }
        selected = wanted
    }

    /// What the list shows for what the user typed: every word found in the title
    /// or the line beneath, ignoring case and accents.
    public var visible: [MessagesChatChoice] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return choices }
        return choices.filter { choice in
            let text = choice.title + " " + (choice.detail ?? "")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    public func isChosen(_ guid: String) -> Bool { selected.contains(guid) }

    public var limitReached: Bool { selected.count >= AppleMessagesChatScope.maximumChats }

    /// A chosen chat can always be unticked; another can be ticked while there
    /// is room and its id can be named.
    public func canToggle(_ guid: String) -> Bool {
        if selected.contains(guid) { return true }
        guard let choice = choices.first(where: { $0.guid == guid }) else { return false }
        return choice.isChoosable && !limitReached
    }

    public func toggle(_ guid: String) {
        guard canToggle(guid) else { return }
        if selected.contains(guid) { selected.remove(guid) } else { selected.insert(guid) }
    }

    public var countLine: String { BotAccessCopy.pickerCount(selected.count) }
}

struct MessagesChatPickerSheet: View {
    @ObservedObject var picker: MessagesChatPickerModel
    let contactNames: MessagesContactNames
    let onAskForNames: @MainActor () -> Void
    let onCancel: @MainActor () -> Void
    let onSave: @MainActor (Set<String>) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(BotAccessCopy.pickerTitle(picker.botName))
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(BotAccessCopy.pickerCaption(picker.botName))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Search chats", text: $picker.search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("messages-chats.search")
                    .padding(.top, 6)
            }
            .padding(20)
            Divider()
            List(picker.visible) { choice in
                Toggle(isOn: Binding(get: { picker.isChosen(choice.guid) }, set: { _ in picker.toggle(choice.guid) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.title)
                        if let detail = choice.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                        if let last = choice.lastMessageAt {
                            Text(last, format: .relative(presentation: .named))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!picker.canToggle(choice.guid))
                .accessibilityIdentifier("messages-chats.chat")
            }
            .accessibilityIdentifier("messages-chats.list")
            Divider()
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(picker.countLine).font(.callout)
                        .accessibilityIdentifier("messages-chats.count")
                    if picker.limitReached {
                        Text(BotAccessCopy.pickerLimit).font(.caption).foregroundStyle(.secondary)
                    }
                    if contactNames == .refused {
                        Text(BotAccessCopy.contactNamesOff).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if contactNames == .notAsked {
                    Button(BotAccessCopy.showContactNames, action: onAskForNames)
                        .accessibilityIdentifier("messages-chats.names")
                }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("messages-chats.cancel")
                Button("Save") { onSave(picker.selected) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("messages-chats.save")
            }
            .padding(20)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 440, idealHeight: 600)
        .background(OpenBotsVisualStyle.surface(for: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BotAccessCopy.pickerTitle(picker.botName))
        .accessibilityIdentifier("messages-chats")
    }
}
