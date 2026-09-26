import Foundation
import Testing

/// The repository root, three folders up from this file.
private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite("What the app's signature asks macOS for")
struct AppSignatureEntitlementsTests {
    static let entitlementsPath = "Apps/OpenBotsPreviewApp/OpenBotsPreviewApp.entitlements"

    @Test("The app is signed with the Contacts entitlement, so a fresh Mac is asked about Contacts")
    func theContactsEntitlementIsSigned() throws {
        // Under the hardened runtime tccd refuses to prompt without it:
        // "kTCCServiceAddressBook requires entitlement
        // com.apple.security.personal-information.addressbook but it is missing",
        // so Show Names from Contacts raised nothing on a Mac that had not decided
        // yet.
        let data = try Data(contentsOf: repositoryRoot.appending(path: Self.entitlementsPath))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["com.apple.security.personal-information.addressbook"] as? Bool == true)
    }

    @Test("The app is signed with the Calendars entitlement, so the calendar connector can ask")
    func theCalendarsEntitlementIsSigned() throws {
        // Without it the Apple Calendar connector failed with "Calendar refused",
        // and tccd logged "kTCCServiceCalendar requires entitlement
        // com.apple.security.personal-information.calendars but it is missing" for
        // the app, the responsible process of the embedded reader. No prompt could
        // ever appear, so no switch or System Settings click could make the
        // connector work.
        let data = try Data(contentsOf: repositoryRoot.appending(path: Self.entitlementsPath))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["com.apple.security.personal-information.calendars"] as? Bool == true)
        let spec = try String(contentsOf: repositoryRoot.appending(path: "project.yml"), encoding: .utf8)
        #expect(spec.contains("com.apple.security.personal-information.calendars: true"))
    }

    @Test("The build signs the app with that file, not a file nothing points at")
    func theBuildUsesTheFile() throws {
        // xcodegen writes the file and the setting from project.yml; the
        // generated project is what xcodebuild reads, so both must say it.
        let project = try String(contentsOf: repositoryRoot.appending(path: "OpenBotsNext.xcodeproj/project.pbxproj"),
                                 encoding: .utf8)
        #expect(project.contains("CODE_SIGN_ENTITLEMENTS = \(Self.entitlementsPath);"))
        let spec = try String(contentsOf: repositoryRoot.appending(path: "project.yml"), encoding: .utf8)
        #expect(spec.contains("path: \(Self.entitlementsPath)"))
        #expect(spec.contains("com.apple.security.personal-information.addressbook: true"))
    }

    @Test("The Contacts prompt has its sentence in the app's Info.plist")
    func theContactsPromptHasItsSentence() throws {
        let data = try Data(contentsOf: repositoryRoot.appending(path: "Apps/OpenBotsPreviewApp/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let sentence = try #require(plist["NSContactsUsageDescription"] as? String)
        #expect(!sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
