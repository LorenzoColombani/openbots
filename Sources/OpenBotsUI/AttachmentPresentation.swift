import Combine
import Foundation
import OpenBotsDomain
import SwiftUI

/// Path-free, exact-message operations. The app validates that the part still
/// references this attachment before resolving metadata or revealing its copy.
public struct AttachmentPresentation: Sendable {
    public typealias Resolver = @MainActor @Sendable (UUID, UUID, UUID) async throws -> AttachmentAsset?
    public typealias Revealer = @MainActor @Sendable (UUID, UUID, UUID) async throws -> Void
    public typealias Previewer = @MainActor @Sendable (UUID, UUID, UUID, Int) async throws -> AttachmentPreview
    public let resolve: Resolver
    public let reveal: Revealer
    public let preview: Previewer?

    public init(resolve: @escaping Resolver, reveal: @escaping Revealer, preview: Previewer? = nil) {
        self.resolve = resolve
        self.reveal = reveal
        self.preview = preview
    }
}

private struct AttachmentPresentationKey: EnvironmentKey {
    static let defaultValue: AttachmentPresentation? = nil
}

public extension EnvironmentValues {
    var attachmentPresentation: AttachmentPresentation? {
        get { self[AttachmentPresentationKey.self] }
        set { self[AttachmentPresentationKey.self] = newValue }
    }
}

struct AttachmentPresentationRoute: Equatable, Hashable, Sendable {
    let messageID: UUID
    let partID: UUID
    let attachmentID: UUID
}

@MainActor
final class AttachmentPartPresentationModel: ObservableObject {
    @Published private(set) var asset: AttachmentAsset?
    @Published private(set) var isLoading = false
    @Published private(set) var isRevealing = false
    @Published private(set) var errorMessage: String?
    private var route: AttachmentPresentationRoute?
    private var presentation: AttachmentPresentation?
    private var generation: UInt64 = 0
    private var hasLoaded = false

    var canReveal: Bool { asset != nil && !isLoading && !isRevealing }

    func load(route: AttachmentPresentationRoute, presentation: AttachmentPresentation?, force: Bool = false) async {
        guard force || self.route != route || !hasLoaded else { return }
        generation &+= 1
        let request = generation
        self.route = route
        self.presentation = presentation
        asset = nil
        errorMessage = nil
        isRevealing = false
        hasLoaded = true
        guard let presentation else { isLoading = false; return }
        isLoading = true
        do {
            let result = try await presentation.resolve(route.messageID, route.partID, route.attachmentID)
            guard generation == request, !Task.isCancelled else {
                if generation == request { isLoading = false; hasLoaded = false }
                return
            }
            guard let result, result.id.rawValue == route.attachmentID else {
                isLoading = false
                errorMessage = "This saved attachment is unavailable. Try Reload."
                return
            }
            asset = result
            isLoading = false
        } catch {
            guard generation == request else { return }
            isLoading = false
            if Task.isCancelled || error is CancellationError { hasLoaded = false; return }
            errorMessage = "OpenBots couldn’t load this saved attachment. Try Reload."
        }
    }

    func reveal() async {
        guard canReveal, let route, let presentation else { return }
        let request = generation
        isRevealing = true
        errorMessage = nil
        do {
            // Metadata is not authority: this callback must validate the exact
            // route and owned bytes again, immediately before Finder reveal.
            try await presentation.reveal(route.messageID, route.partID, route.attachmentID)
            guard generation == request else { return }
            isRevealing = false
        } catch {
            guard generation == request else { return }
            isRevealing = false
            if Task.isCancelled || error is CancellationError { return }
            errorMessage = "OpenBots couldn’t reveal this saved attachment. Your files were not changed."
        }
    }
}
