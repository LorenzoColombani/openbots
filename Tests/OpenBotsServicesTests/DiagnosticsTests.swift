import Foundation
import Testing
@testable import OpenBotsServices

@Test("Diagnostics accept bounded codes and expose no arbitrary metadata field")
func boundedDiagnosticEvent() async throws {
    let event = try DiagnosticEvent(
        id: UUID(uuidString: "87000000-0000-0000-0000-000000000001")!,
        occurredAt: Date(timeIntervalSince1970: 870),
        severity: .warning,
        category: .storage,
        code: "storage.root.provider-uncertain"
    )
    let sink = InMemoryDiagnosticSink()

    await sink.record(event)

    #expect(await sink.recordedEvents() == [event])
    #expect(throws: DiagnosticValidationError.invalidCode) {
        try DiagnosticEvent(
            id: UUID(),
            occurredAt: Date(),
            severity: .error,
            category: .runtime,
            code: "secret=do-not-log"
        )
    }
}
