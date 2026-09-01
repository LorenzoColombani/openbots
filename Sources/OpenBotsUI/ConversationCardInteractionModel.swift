import Combine
import Foundation
import OpenBotsDomain

/// The UI freezes every identity needed to route one inline-card action. The
/// final UUID maps to the Domain card route; the other IDs keep presentation
/// actions from following a later sidebar selection or replacement row.
public struct ConversationCardInteractionRoute: Hashable, Sendable {
    public let conversationID: UUID
    public let messageID: UUID
    public let messagePartID: UUID
    public let cardID: UUID
    public let actionRouteID: UUID

    /// Source-compatible presentation shorthand. The canonical contract name
    /// matches Domain's `messagePartID`.
    public var partID: UUID { messagePartID }

    public init(
        conversationID: UUID,
        messageID: UUID,
        messagePartID: UUID,
        cardID: UUID,
        actionRouteID: UUID
    ) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.messagePartID = messagePartID
        self.cardID = cardID
        self.actionRouteID = actionRouteID
    }

    public init(_ route: ConversationCardRoute) {
        self.init(
            conversationID: route.conversationID.rawValue,
            messageID: route.messageID.rawValue,
            messagePartID: route.messagePartID.rawValue,
            cardID: route.cardID.rawValue,
            actionRouteID: route.id.rawValue
        )
    }

    public var domainRoute: ConversationCardRoute {
        ConversationCardRoute(
            id: ConversationCardRouteID(actionRouteID),
            conversationID: ConversationID(conversationID),
            messageID: MessageID(messageID),
            messagePartID: MessagePartID(messagePartID),
            cardID: ConversationCardID(cardID)
        )
    }
}

public enum ConversationCardActionOutcome: Equatable, Sendable {
    case succeeded(receiptID: UUID?)
    case failed(receiptID: UUID?)
}

/// Async adapters echo the exact route and attempt. Models reject a delayed or
/// misrouted completion before publishing any visible state.
public struct ConversationCardActionResult: Equatable, Sendable {
    public let route: ConversationCardInteractionRoute
    public let attemptID: UUID
    public let outcome: ConversationCardActionOutcome

    public init(
        route: ConversationCardInteractionRoute,
        attemptID: UUID,
        outcome: ConversationCardActionOutcome
    ) {
        self.route = route
        self.attemptID = attemptID
        self.outcome = outcome
    }
}

public enum QuestionCardAnswerRequest: Equatable, Sendable {
    case choice(UUID)
    case freeText(String)
    case decline
}

public enum QuestionCardInteractionState: Equatable, Sendable {
    case ready
    case submitting
    case answered
    case declined
    case failed

    public var isTerminal: Bool {
        switch self {
        case .answered, .declined: true
        case .ready, .submitting, .failed: false
        }
    }
}

@MainActor
public final class QuestionCardInteractionModel: ObservableObject, Identifiable {
    public typealias Submission = @Sendable (
        _ route: ConversationCardInteractionRoute,
        _ attemptID: UUID,
        _ answer: QuestionCardAnswerRequest
    ) async -> ConversationCardActionResult

    public nonisolated var id: UUID { route.partID }
    public nonisolated let route: ConversationCardInteractionRoute
    public let snapshot: ChatQuestionCardSnapshot

    @Published public var freeText = ""
    @Published public private(set) var state: QuestionCardInteractionState

    private let submit: Submission
    private var activeAttemptID: UUID?

    public init(
        route: ConversationCardInteractionRoute,
        snapshot: ChatQuestionCardSnapshot,
        submit: @escaping Submission
    ) {
        self.route = route
        self.snapshot = snapshot
        self.submit = submit
        switch snapshot.resolution {
        case .pending: state = .ready
        case .answered: state = .answered
        case .declined: state = .declined
        }
    }

    public var canInteract: Bool {
        route.cardID == snapshot.id
            && snapshot.hasValidChoiceContract
            && (state == .ready || state == .failed)
    }

    public var canSubmitFreeText: Bool {
        canInteract
            && snapshot.allowsFreeText
            && !freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    public func answer(choiceID: UUID) -> Bool {
        guard snapshot.choices.contains(where: { $0.id == choiceID }) else {
            return false
        }
        return begin(.choice(choiceID))
    }

    @discardableResult
    public func answerFreeText() -> Bool {
        guard snapshot.allowsFreeText else { return false }
        let answer = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return false }
        return begin(.freeText(answer))
    }

    @discardableResult
    public func decline() -> Bool {
        begin(.decline)
    }

    /// Invalidating an in-flight UI attempt never cancels or reroutes the
    /// service operation. It only makes a later completion stale to this view.
    public func invalidatePendingAction() {
        guard state == .submitting else { return }
        activeAttemptID = nil
        state = .ready
    }

    @discardableResult
    private func begin(_ answer: QuestionCardAnswerRequest) -> Bool {
        guard canInteract else { return false }
        let attemptID = UUID()
        activeAttemptID = attemptID
        state = .submitting
        freeText = ""

        Task { [weak self, route, submit] in
            let result = await submit(route, attemptID, answer)
            self?.finish(result, expectedAttemptID: attemptID, answer: answer)
        }
        return true
    }

    private func finish(
        _ result: ConversationCardActionResult,
        expectedAttemptID: UUID,
        answer: QuestionCardAnswerRequest
    ) {
        guard activeAttemptID == expectedAttemptID else { return }
        guard result.route == route, result.attemptID == expectedAttemptID else {
            activeAttemptID = nil
            state = .failed
            return
        }
        activeAttemptID = nil
        switch result.outcome {
        case .succeeded:
            state = answer == .decline ? .declined : .answered
        case .failed:
            state = .failed
        }
    }
}

public enum ConnectorAuthenticationAttemptState: Equatable, Sendable {
    case ready
    case reopening
    case reopened(receiptID: UUID?)
    case failed(receiptID: UUID?)

    public var isTerminal: Bool {
        false
    }
}

@MainActor
public final class ConnectorSetupCardInteractionModel: ObservableObject, Identifiable {
    public typealias ReopenAuthentication = @Sendable (
        _ route: ConversationCardInteractionRoute,
        _ attemptID: UUID
    ) async -> ConversationCardActionResult

    public nonisolated var id: UUID { route.partID }
    public nonisolated let route: ConversationCardInteractionRoute
    public let snapshot: ChatConnectorSetupCardSnapshot

    @Published public private(set) var state: ConnectorAuthenticationAttemptState = .ready

    private let reopenAuthentication: ReopenAuthentication
    private var activeAttemptID: UUID?

    public init(
        route: ConversationCardInteractionRoute,
        snapshot: ChatConnectorSetupCardSnapshot,
        reopenAuthentication: @escaping ReopenAuthentication
    ) {
        self.route = route
        self.snapshot = snapshot
        self.reopenAuthentication = reopenAuthentication
    }

    public var canReopenAuthentication: Bool {
        guard route.cardID == snapshot.id else { return false }
        return switch state {
        case .ready, .failed, .reopened: true
        case .reopening: false
        }
    }

    @discardableResult
    public func reopen() -> Bool {
        guard canReopenAuthentication else { return false }
        let attemptID = UUID()
        activeAttemptID = attemptID
        state = .reopening

        Task { [weak self, route, reopenAuthentication] in
            let result = await reopenAuthentication(route, attemptID)
            self?.finish(result, expectedAttemptID: attemptID)
        }
        return true
    }

    public func invalidatePendingAction() {
        guard state == .reopening else { return }
        activeAttemptID = nil
        state = .ready
    }

    private func finish(
        _ result: ConversationCardActionResult,
        expectedAttemptID: UUID
    ) {
        guard activeAttemptID == expectedAttemptID else { return }
        guard result.route == route, result.attemptID == expectedAttemptID else {
            activeAttemptID = nil
            state = .failed(receiptID: nil)
            return
        }
        activeAttemptID = nil
        switch result.outcome {
        case .succeeded(let receiptID):
            state = .reopened(receiptID: receiptID)
        case .failed(let receiptID):
            state = .failed(receiptID: receiptID)
        }
    }
}

public enum SecretCardInteractionState: Equatable, Sendable {
    case awaitingInput
    case submitting
    case present(receiptID: UUID?)
    case failed(receiptID: UUID?)

    public var isTerminal: Bool {
        if case .present = self { return true }
        return false
    }
}

@MainActor
public final class SecretCardInteractionModel:
    ObservableObject,
    Identifiable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public typealias Submission = @Sendable (
        _ route: ConversationCardInteractionRoute,
        _ attemptID: UUID,
        _ secret: String
    ) async -> ConversationCardActionResult

    public nonisolated var id: UUID { route.partID }
    public nonisolated let route: ConversationCardInteractionRoute
    public let snapshot: ChatSecretCardSnapshot

    /// This is the sole transient UI binding. It is emptied synchronously
    /// before the async adapter starts and is never copied into card state.
    @Published public var transientInput = ""
    @Published public private(set) var state: SecretCardInteractionState

    private let submit: Submission
    private var activeAttemptID: UUID?

    public nonisolated var description: String {
        "SecretCardInteractionModel(value: redacted)"
    }

    public nonisolated var debugDescription: String { description }

    public init(
        route: ConversationCardInteractionRoute,
        snapshot: ChatSecretCardSnapshot,
        submit: @escaping Submission
    ) {
        self.route = route
        self.snapshot = snapshot
        self.submit = submit
        switch snapshot.presence {
        case .absent:
            state = .awaitingInput
        case .present(let receiptID):
            state = .present(receiptID: receiptID)
        case .failed(let receiptID):
            state = .failed(receiptID: receiptID)
        }
    }

    public var canSubmit: Bool {
        guard route.cardID == snapshot.id else { return false }
        return switch state {
        case .awaitingInput, .failed:
            !transientInput.isEmpty
        case .submitting, .present:
            false
        }
    }

    @discardableResult
    public func submitSecret() -> Bool {
        guard canSubmit else { return false }
        let secret = transientInput
        let attemptID = UUID()
        transientInput.removeAll(keepingCapacity: false)
        activeAttemptID = attemptID
        state = .submitting

        Task { [weak self, route, submit] in
            let result = await submit(route, attemptID, secret)
            self?.finish(result, expectedAttemptID: attemptID)
        }
        return true
    }

    public func invalidatePendingAction() {
        guard state == .submitting else { return }
        activeAttemptID = nil
        state = .awaitingInput
    }

    private func finish(
        _ result: ConversationCardActionResult,
        expectedAttemptID: UUID
    ) {
        guard activeAttemptID == expectedAttemptID else { return }
        guard result.route == route, result.attemptID == expectedAttemptID else {
            activeAttemptID = nil
            state = .failed(receiptID: nil)
            return
        }
        activeAttemptID = nil
        switch result.outcome {
        case .succeeded(let receiptID):
            state = .present(receiptID: receiptID)
        case .failed(let receiptID):
            state = .failed(receiptID: receiptID)
        }
    }
}

/// A selected conversation owns its card interactions. Lookups require the
/// message, part, and card IDs again, so merely passing the wrong conversation
/// model cannot redirect an action to a visually similar card.
@MainActor
public final class ConversationCardInteractionModel: ObservableObject {
    public nonisolated let conversationID: UUID

    private var questions: [UUID: QuestionCardInteractionModel] = [:]
    private var connectors: [UUID: ConnectorSetupCardInteractionModel] = [:]
    private var secrets: [UUID: SecretCardInteractionModel] = [:]

    public init(conversationID: UUID) {
        self.conversationID = conversationID
    }

    @discardableResult
    public func register(_ model: QuestionCardInteractionModel) -> Bool {
        guard canRegister(route: model.route, modelID: model.id) else { return false }
        questions[model.route.partID] = model
        objectWillChange.send()
        return true
    }

    @discardableResult
    public func register(_ model: ConnectorSetupCardInteractionModel) -> Bool {
        guard canRegister(route: model.route, modelID: model.id) else { return false }
        connectors[model.route.partID] = model
        objectWillChange.send()
        return true
    }

    @discardableResult
    public func register(_ model: SecretCardInteractionModel) -> Bool {
        guard canRegister(route: model.route, modelID: model.id) else { return false }
        secrets[model.route.partID] = model
        objectWillChange.send()
        return true
    }

    public func question(
        messageID: UUID,
        partID: UUID,
        cardID: UUID
    ) -> QuestionCardInteractionModel? {
        matching(questions[partID], messageID: messageID, partID: partID, cardID: cardID)
    }

    public func connector(
        messageID: UUID,
        partID: UUID,
        cardID: UUID
    ) -> ConnectorSetupCardInteractionModel? {
        matching(connectors[partID], messageID: messageID, partID: partID, cardID: cardID)
    }

    public func secret(
        messageID: UUID,
        partID: UUID,
        cardID: UUID
    ) -> SecretCardInteractionModel? {
        matching(secrets[partID], messageID: messageID, partID: partID, cardID: cardID)
    }

    private func canRegister(
        route: ConversationCardInteractionRoute,
        modelID: UUID
    ) -> Bool {
        guard route.conversationID == conversationID,
              route.partID == modelID,
              questions[route.partID] == nil,
              connectors[route.partID] == nil,
              secrets[route.partID] == nil else { return false }
        return true
    }

    private func matching<Model>(
        _ model: Model?,
        messageID: UUID,
        partID: UUID,
        cardID: UUID
    ) -> Model? {
        let route: ConversationCardInteractionRoute
        switch model {
        case let question as QuestionCardInteractionModel:
            route = question.route
        case let connector as ConnectorSetupCardInteractionModel:
            route = connector.route
        case let secret as SecretCardInteractionModel:
            route = secret.route
        default:
            return nil
        }
        guard route.conversationID == conversationID,
              route.messageID == messageID,
              route.partID == partID,
              route.cardID == cardID else { return nil }
        return model
    }
}
