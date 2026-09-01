import Foundation
import Testing
@testable import OpenBotsUI

private let messageMetadataLocale = Locale(identifier: "en_US_POSIX")
private let messageMetadataZone = TimeZone(secondsFromGMT: 0)!

@Test("Message group metadata preserves actual author and stored date without duplicating child content")
func messageAccessibilityMetadataPreservesStoredAuthorAndDate() {
    let identity = TeammateIdentitySnapshot(id: UUID(), name: "Mira", role: "Writer", appearance: .fixture(seed: 2))
    for author: ChatAuthorSnapshot in [.user, .teammate(identity), .system(label: "Local notice")] {
        let message = ChatMessageSnapshot(id: UUID(), author: author, parts: [
            ChatMessagePartSnapshot(id: UUID(), ordinal: 0, content: .text("Individually readable child text")),
            ChatMessagePartSnapshot(id: UUID(), ordinal: 1, content: .attachment(
                ChatAttachmentSnapshot(id: UUID(), displayName: "Independent file card.txt", detail: "Fixture only")
            ))
        ], delivery: .sent, timestamp: Date(timeIntervalSince1970: 1))
        let label = message.accessibilityGroupLabel(locale: messageMetadataLocale, timeZone: messageMetadataZone)
        #expect(label.hasPrefix(author.visibleName + ". "))
        #expect(label.contains("January 1, 1970"))
        #expect(label.contains("12:00"))
        #expect(!label.contains("Individually readable"))
        #expect(!label.contains("Independent file"))
        #expect(message.parts.count == 2)
        let western = message.accessibilityGroupLabel(locale: messageMetadataLocale,
                                                      timeZone: TimeZone(secondsFromGMT: -8 * 3600)!)
        #expect(western.contains("December 31, 1969"))
        #expect(western != label)
    }
}

@Test("Roster summary uses stored last activity and current activity without inventing history")
func rosterAccessibilityMetadataIncludesExistingActivityAndOptionalRecency() {
    let identity = TeammateIdentitySnapshot(id: UUID(), name: "Ada", role: "Researcher", appearance: .fixture(seed: 1))
    let dated = TeammateRowSnapshot(identity: identity, activity: .waitingForUser, unreadCount: 3,
                                   lastActivityAt: Date(timeIntervalSince1970: 1))
    let undated = TeammateRowSnapshot(identity: identity, activity: .idle)
    let label = dated.accessibilitySummary(locale: messageMetadataLocale, timeZone: messageMetadataZone)
    #expect(label.contains("Ada, Researcher, Waiting for you"))
    #expect(label.contains("Last activity"))
    #expect(label.contains("January 1, 1970"))
    #expect(dated.unreadCount == 3)
    let noHistory = undated.accessibilitySummary(locale: messageMetadataLocale, timeZone: messageMetadataZone)
    #expect(noHistory == "Ada, Researcher, Idle")
    #expect(!noHistory.contains("Last activity"))
}
