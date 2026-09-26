import Foundation
import SwiftUI
import Testing
@testable import OpenBotsUI

// One suite name per test, never a fresh one per run: macOS keeps an empty file
// in ~/Library/Preferences for every suite even after its domain is removed.
@MainActor
@Suite struct WorkspaceAppearanceTests {
@Test func appearanceDefaultsToSystemWithoutWritingAValue() throws {
    let suite = "OpenBotsNext.AppearanceTests.default"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = WorkspaceAppearanceModel(defaults: defaults)
    #expect(model.selection == .system)
    #expect(model.selection.colorScheme == nil)
    #expect(defaults.object(forKey: WorkspaceAppearanceModel.preferenceKey) == nil)
}

@Test func appearanceChoiceSurvivesModelRecreationAndCanReturnToSystem() throws {
    let suite = "OpenBotsNext.AppearanceTests.survives"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = WorkspaceAppearanceModel(defaults: defaults)
    model.selection = .light
    let reopened = WorkspaceAppearanceModel(defaults: defaults)
    #expect(reopened.selection == .light)
    #expect(reopened.selection.colorScheme == .light)
    reopened.selection = .dark
    #expect(WorkspaceAppearanceModel(defaults: defaults).selection.colorScheme == .dark)
    reopened.selection = .system
    #expect(WorkspaceAppearanceModel(defaults: defaults).selection.colorScheme == nil)
}

@Test func unknownAppearanceValueUsesSystemWithoutChangingOtherPreferences() throws {
    let suite = "OpenBotsNext.AppearanceTests.unknown"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("future-appearance", forKey: WorkspaceAppearanceModel.preferenceKey)
    defaults.set("preserved", forKey: "another.preference")
    let model = WorkspaceAppearanceModel(defaults: defaults)
    #expect(model.selection == .system)
    model.selection = .dark
    #expect(defaults.string(forKey: "another.preference") == "preserved")
}
}
