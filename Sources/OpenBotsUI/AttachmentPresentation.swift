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
    /// Opens the saved copy with its default app.
    public let open: Revealer?
    /// Copies the saved copy to a place the user picks; the create-new delivery.
    public let save: Revealer?

    public init(resolve: @escaping Resolver, reveal: @escaping Revealer, preview: Previewer? = nil,
                open: Revealer? = nil, save: Revealer? = nil) {
        self.resolve = resolve
        self.reveal = reveal
        self.preview = preview
        self.open = open
        self.save = save
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

/// A picture shown inside the bubble: the same bounded,
/// decoded-off-main preview the Preview sheet uses, fetched once per chip and
/// only for an attachment whose type is an image.
@MainActor
final class InlineAttachmentImageModel: ObservableObject {
    @Published private(set) var image: AttachmentPreviewImage?
    private var loadedRoute: AttachmentPresentationRoute?
    private var generation: UInt64 = 0
    private let decoder = AttachmentPreviewDecoder()

    func load(route: AttachmentPresentationRoute, previewer: AttachmentPresentation.Previewer?) async {
        guard let previewer, loadedRoute != route else { return }
        generation &+= 1
        let request = generation
        loadedRoute = route
        image = nil
        do {
            let receipt = try await previewer(route.messageID, route.partID, route.attachmentID, 1)
            try Task.checkCancellation()
            let prepared = try await decoder.prepare(receipt, requestedPage: 1)
            guard generation == request else { return }
            if case .image(let decoded) = prepared { image = decoded }
        } catch {
            guard generation == request else { return }
            if error is CancellationError || Task.isCancelled { loadedRoute = nil }
        }
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
        guard let presentation else { return }
        await perform(presentation.reveal, failure: "OpenBots couldn’t reveal this saved attachment. Your files were not changed.")
    }

    func open() async {
        guard let action = presentation?.open else { return }
        await perform(action, failure: "OpenBots couldn’t open this saved attachment. Your files were not changed.")
    }

    func save() async {
        guard let action = presentation?.save else { return }
        await perform(action, failure: "OpenBots couldn’t save a copy of this attachment.")
    }

    private func perform(_ action: AttachmentPresentation.Revealer, failure: String) async {
        guard canReveal, let route else { return }
        let request = generation
        isRevealing = true
        errorMessage = nil
        do {
            // Metadata is not authority: this callback must validate the exact
            // route and owned bytes again, immediately before it acts.
            try await action(route.messageID, route.partID, route.attachmentID)
            guard generation == request else { return }
            isRevealing = false
        } catch {
            guard generation == request else { return }
            isRevealing = false
            if Task.isCancelled || error is CancellationError { return }
            errorMessage = failure
        }
    }
}
