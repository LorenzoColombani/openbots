import Combine
import Foundation
import SwiftUI

/// An app-local presentation preference. It never changes a bot's capabilities.
public enum WorkspaceAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
public final class WorkspaceAppearanceModel: ObservableObject {
    static let preferenceKey = "openbotsnext.appearance"
    private let defaults: UserDefaults

    @Published public var selection: WorkspaceAppearance {
        didSet {
            guard selection != oldValue else { return }
            defaults.set(selection.rawValue, forKey: Self.preferenceKey)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Self.preferenceKey)
            .flatMap(WorkspaceAppearance.init(rawValue:)) ?? .system
    }
}
