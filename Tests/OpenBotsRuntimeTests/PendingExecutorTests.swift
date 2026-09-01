import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsRuntime

@Test("Pending executor fails explicitly instead of behaving like a chat-only runtime")
func pendingExecutorRejectsExecution() async throws {
    let executor = PendingArchitectureExecutor()
    let messageID = MessageID(UUID())
    let request = try WorkRequest(
        runID: RunID(UUID()),
        teammateID: TeammateID(UUID()),
        conversationID: ConversationID(UUID()),
        initiatingMessageID: messageID,
        selectedProjectID: nil,
        profileRevision: 1,
        initialInput: WorkInput(messageID: messageID, sequence: 1, text: "Do the work"),
        submittedAt: Date(timeIntervalSince1970: 1)
    )

    await #expect(throws: ExecutorUnavailableError.self) {
        try await executor.start(request)
    }
}

@Test("Pending executor cannot falsely acknowledge live steering")
func pendingExecutorRejectsSteering() async throws {
    let executor = PendingArchitectureExecutor()
    let input = try SteeringInput(
        messageID: MessageID(UUID()),
        sequence: 2,
        text: "Change direction",
        submittedAt: Date(timeIntervalSince1970: 2)
    )

    await #expect(throws: ExecutorUnavailableError.self) {
        _ = try await executor.steer(input, into: RunID(UUID()))
    }
}

@Test("Pending executor event stream terminates with an explicit error")
func pendingExecutorEventStreamFails() async {
    let executor = PendingArchitectureExecutor()
    let events = await executor.events(for: RunID(UUID()))

    await #expect(throws: ExecutorUnavailableError.self) {
        for try await _ in events {}
    }
}
