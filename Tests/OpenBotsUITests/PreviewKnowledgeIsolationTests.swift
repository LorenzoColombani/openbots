import Foundation
import Testing

private func previewAppSource() throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Apps/OpenBotsPreviewApp/OpenBotsPreviewApp.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func previewSourceSegment(
    _ source: String,
    from start: String,
    through end: String
) throws -> Substring {
    let startIndex = try #require(source.range(of: start)?.lowerBound)
    let endIndex = try #require(
        source.range(of: end, range: startIndex..<source.endIndex)?.upperBound
    )
    return source[startIndex..<endIndex]
}

@Test("Chat startup keeps Knowledge composition dormant")
func previewChatStartupKeepsKnowledgeCompositionDormant() throws {
    let source = try previewAppSource()
    let startup = try previewSourceSegment(
        source,
        from: "func start() async {",
        through: "func beginTeammateCreation()"
    )

    #expect(startup.contains("let markdownAuthority: VerifiedAuthoritativeMarkdownRoot?") == false)
    #expect(startup.contains("knowledgeModel =") == false)
    #expect(startup.contains("observeKnowledgeAvailability(") == false)
    #expect(startup.contains("knowledgeModel: knowledgeModel") == false)
    #expect(startup.contains("let workspace = DurableWorkspaceModel("))
    #expect(startup.contains("self.workspace = workspace"))
    #expect(startup.contains("launchReadiness.setPreviewReviewState(.ready)"))

    let workspaceConstruction = try #require(
        startup.range(of: "let workspace = DurableWorkspaceModel(")
    )
    let workspacePublication = try #require(startup.range(of: "self.workspace = workspace"))
    let readyPublication = try #require(
        startup.range(of: "launchReadiness.setPreviewReviewState(.ready)")
    )
    #expect(workspaceConstruction.lowerBound < workspacePublication.lowerBound)
    #expect(workspacePublication.lowerBound < readyPublication.lowerBound)
}

@Test("Database and bootstrap failures still use the app-wide recovery path")
func previewDatabaseFailuresRemainFatal() throws {
    let source = try previewAppSource()
    let startup = try previewSourceSegment(
        source,
        from: "func start() async {",
        through: "func beginTeammateCreation()"
    )

    let databaseOpen = try #require(
        startup.range(of: "let context = try await openOrBootstrapPreviewInstallation()")
    )
    let appWideFailure = try #require(
        startup.range(of: "startupDiagnosticCode = Self.diagnosticCode(for: error)")
    )
    let recovery = try #require(
        startup.range(of: "launchReadiness.setPreviewReviewState(.recovery(Self.recoveryIssue(for: error)))")
    )

    #expect(databaseOpen.lowerBound < appWideFailure.lowerBound)
    #expect(appWideFailure.lowerBound < recovery.lowerBound)
    #expect(startup.contains("workspace = nil"))
    #expect(startup.contains("showsWorkspace = false"))
    #expect(startup.contains("try? await openOrBootstrapPreviewInstallation()") == false)
}

@Test("Dormant unavailable Knowledge factory is inert and unwired")
func previewDormantUnavailableKnowledgeFactoryIsInertAndUnwired() throws {
    let source = try previewAppSource()
    let unavailableFactory = try previewSourceSegment(
        source,
        from: "private static func unavailableKnowledgeModel()",
        through: "nonisolated private static func knowledgePresentation("
    )
    let startup = try previewSourceSegment(
        source,
        from: "func start() async {",
        through: "func beginTeammateCreation()"
    )

    #expect(unavailableFactory.contains("loader: { _ in throw PreviewKnowledgeUnavailableError.authorityVerificationFailed }"))
    #expect(unavailableFactory.contains("revealer: { _, _ in"))
    #expect(unavailableFactory.contains("chooseSnapshotDestination: { _ in nil }"))
    #expect(unavailableFactory.contains("createSnapshot: { _, _ in"))
    #expect(unavailableFactory.contains("NSWorkspace") == false)
    #expect(unavailableFactory.contains("snapshotBroker") == false)

    #expect(source.contains("knowledgeModel: knowledgeModel") == false)
    #expect(startup.contains("Self.unavailableKnowledgeModel()") == false)
    #expect(startup.contains("observeKnowledgeAvailability(") == false)
}
