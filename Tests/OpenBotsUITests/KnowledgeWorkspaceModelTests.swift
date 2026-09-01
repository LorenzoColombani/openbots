import Foundation
import Testing
@testable import OpenBotsUI

private enum KnowledgeUITestError: Error, Sendable {
    case failed
}

private actor KnowledgeActionRecorder {
    private(set) var loadedContexts: [KnowledgeWorkspaceContext] = []
    private(set) var reveals: [(UUID, UUID)] = []
    private(set) var choices: [UUID] = []
    private(set) var creations: [(UUID, KnowledgeSnapshotDestination)] = []
    private(set) var releases: [KnowledgeSnapshotDestination] = []

    func recordLoad(_ context: KnowledgeWorkspaceContext) { loadedContexts.append(context) }
    func recordReveal(snapshotID: UUID, documentID: UUID) {
        reveals.append((snapshotID, documentID))
    }
    func recordChoice(snapshotID: UUID) { choices.append(snapshotID) }
    func recordCreation(snapshotID: UUID, destination: KnowledgeSnapshotDestination) {
        creations.append((snapshotID, destination))
    }
    func recordRelease(_ destination: KnowledgeSnapshotDestination) {
        releases.append(destination)
    }

    func loadCount() -> Int { loadedContexts.count }
    func revealValues() -> [(UUID, UUID)] { reveals }
    func choiceValues() -> [UUID] { choices }
    func creationValues() -> [(UUID, KnowledgeSnapshotDestination)] { creations }
    func releaseValues() -> [KnowledgeSnapshotDestination] { releases }
}

private actor KnowledgeValueGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var queuedValue: Value?
    private var started = false

    func wait() async -> Value {
        started = true
        if let queuedValue {
            self.queuedValue = nil
            return queuedValue
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool { started }

    func release(_ value: Value) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: value)
        } else {
            queuedValue = value
        }
    }
}

private func knowledgeContext(
    suffix: UInt64,
    teammateName: String = "Mira",
    projectSuffix: UInt64? = 20
) -> KnowledgeWorkspaceContext {
    let projectID = projectSuffix.map(knowledgeUUID)
    return KnowledgeWorkspaceContext(
        conversationID: knowledgeUUID(suffix),
        teammateID: knowledgeUUID(suffix + 10),
        teammateName: teammateName,
        selectedProjectID: projectID,
        selectedProjectName: projectID == nil ? nil : "Atlas",
        activeProjectMembershipIDs: projectID.map { [$0] } ?? []
    )
}

private func knowledgeDocument(
    suffix: UInt64,
    scope: KnowledgeDocumentScopePresentation,
    title: String = "Working agreements",
    recovery: KnowledgeDocumentRecoveryPresentation = .current
) -> KnowledgeDocumentPresentation {
    KnowledgeDocumentPresentation(
        id: knowledgeUUID(suffix),
        title: title,
        scope: scope,
        author: .teammate(id: knowledgeUUID(700), name: "Mira"),
        revision: 3,
        updatedAt: Date(timeIntervalSince1970: 1_782_000_000),
        markdown: "# \(title)\n\nPrefer source-backed answers.",
        recovery: recovery
    )
}

private func knowledgeSnapshot(
    suffix: UInt64,
    context: KnowledgeWorkspaceContext,
    documents: [KnowledgeDocumentPresentation]
) -> KnowledgeWorkspaceSnapshot {
    KnowledgeWorkspaceSnapshot(
        id: knowledgeUUID(suffix),
        context: context,
        documents: documents,
        excludedDocumentCount: 2
    )
}

private func knowledgeUUID(_ suffix: UInt64) -> UUID {
    UUID(
        uuidString: String(
            format: "B3000000-0000-0000-0000-%012llx",
            suffix
        )
    )!
}

@MainActor
private func inertKnowledgeModel(
    loader: @escaping KnowledgeWorkspaceModel.Loader
) -> KnowledgeWorkspaceModel {
    KnowledgeWorkspaceModel(
        loader: loader,
        revealer: { _, _ in },
        chooseSnapshotDestination: { _ in nil },
        createSnapshot: { _, destination in
            KnowledgeSnapshotReceipt(
                exactDisplayPath: destination.exactDisplayPath,
                documentCount: 0,
                createdAt: Date(timeIntervalSince1970: 0)
            )
        },
        releaseSnapshotDestination: { _ in }
    )
}

@Test("Knowledge loads reject stale results after a conversation switch")
@MainActor
func knowledgeModelRejectsStaleContextLoad() async {
    let firstContext = knowledgeContext(suffix: 1, teammateName: "Mira")
    let secondContext = knowledgeContext(suffix: 2, teammateName: "Ada", projectSuffix: nil)
    let firstGate = KnowledgeValueGate<KnowledgeWorkspaceSnapshot>()
    let secondGate = KnowledgeValueGate<KnowledgeWorkspaceSnapshot>()
    let firstSnapshot = knowledgeSnapshot(
        suffix: 101,
        context: firstContext,
        documents: [knowledgeDocument(suffix: 201, scope: .teammate(id: firstContext.teammateID, name: "Mira"))]
    )
    let secondSnapshot = knowledgeSnapshot(
        suffix: 102,
        context: secondContext,
        documents: [knowledgeDocument(suffix: 202, scope: .teammate(id: secondContext.teammateID, name: "Ada"))]
    )
    let model = inertKnowledgeModel { context in
        if context == firstContext { return await firstGate.wait() }
        return await secondGate.wait()
    }

    model.activateContext(firstContext)
    let firstLoad = Task { await model.load() }
    for _ in 0..<100 where await !firstGate.hasStarted() { await Task.yield() }

    model.activateContext(secondContext)
    let secondLoad = Task { await model.load() }
    for _ in 0..<100 where await !secondGate.hasStarted() { await Task.yield() }
    await secondGate.release(secondSnapshot)
    await secondLoad.value
    await firstGate.release(firstSnapshot)
    await firstLoad.value

    #expect(model.context == secondContext)
    #expect(model.snapshot == secondSnapshot)
    #expect(model.snapshot?.documents.map(\.id) == [knowledgeUUID(202)])
}

@Test("Knowledge UI rejects any content outside its exact teammate and project scope")
@MainActor
func knowledgeModelFailsClosedOnScopeMismatch() async {
    let context = knowledgeContext(suffix: 3)
    let leaked = knowledgeDocument(
        suffix: 203,
        scope: .teammate(id: knowledgeUUID(999), name: "Another teammate"),
        title: "Out of scope"
    )
    let model = inertKnowledgeModel { requested in
        knowledgeSnapshot(suffix: 103, context: requested, documents: [leaked])
    }

    model.activateContext(context)
    await model.load()

    #expect(model.loadState == .failed(reason: KnowledgeWorkspaceModel.loadFailureMessage))
    #expect(model.snapshot == nil)
}

@Test("Reveal identifies the exact assembled snapshot and selected document")
@MainActor
func knowledgeRevealUsesExactSelectedDocument() async {
    let context = knowledgeContext(suffix: 4)
    let first = knowledgeDocument(suffix: 204, scope: .user, title: "User preferences")
    let second = knowledgeDocument(
        suffix: 205,
        scope: .teammate(id: context.teammateID, name: context.teammateName),
        title: "Research practice"
    )
    let snapshot = knowledgeSnapshot(suffix: 104, context: context, documents: [first, second])
    let recorder = KnowledgeActionRecorder()
    let model = KnowledgeWorkspaceModel(
        loader: { _ in snapshot },
        revealer: { snapshotID, documentID in
            await recorder.recordReveal(snapshotID: snapshotID, documentID: documentID)
        },
        chooseSnapshotDestination: { _ in nil },
        createSnapshot: { _, _ in throw KnowledgeUITestError.failed },
        releaseSnapshotDestination: { _ in }
    )
    model.activateContext(context)
    await model.load()

    await model.revealInFinder(documentID: second.id)

    let reveals = await recorder.revealValues()
    #expect(reveals.count == 1)
    #expect(reveals.first?.0 == snapshot.id)
    #expect(reveals.first?.1 == second.id)
    #expect(model.revealFailure == nil)
}

@Test("Choosing a destination freezes a target but performs no write until confirmation")
@MainActor
func knowledgeSnapshotChoiceRequiresExplicitConfirmation() async {
    let context = knowledgeContext(suffix: 5)
    let snapshot = knowledgeSnapshot(
        suffix: 105,
        context: context,
        documents: [knowledgeDocument(suffix: 206, scope: .user)]
    )
    let destination = KnowledgeSnapshotDestination(
        id: knowledgeUUID(301),
        exactDisplayPath: "/Users/lorenzo/Obsidian/OpenBots snapshot.md"
    )
    let recorder = KnowledgeActionRecorder()
    let model = KnowledgeWorkspaceModel(
        loader: { _ in snapshot },
        revealer: { _, _ in },
        chooseSnapshotDestination: { snapshotID in
            await recorder.recordChoice(snapshotID: snapshotID)
            return destination
        },
        createSnapshot: { snapshotID, selectedDestination in
            await recorder.recordCreation(
                snapshotID: snapshotID,
                destination: selectedDestination
            )
            return KnowledgeSnapshotReceipt(
                exactDisplayPath: selectedDestination.exactDisplayPath,
                documentCount: snapshot.documents.count,
                createdAt: Date(timeIntervalSince1970: 1_782_000_100)
            )
        },
        releaseSnapshotDestination: { selectedDestination in
            await recorder.recordRelease(selectedDestination)
        }
    )
    model.activateContext(context)
    await model.load()

    await model.selectSnapshotDestination()

    #expect(await recorder.choiceValues() == [snapshot.id])
    #expect(await recorder.creationValues().isEmpty)
    #expect(model.pendingSnapshot?.destination == destination)
    #expect(model.snapshotReceipt == nil)

    await model.confirmSnapshotCreation()

    let creations = await recorder.creationValues()
    #expect(creations.count == 1)
    #expect(creations.first?.0 == snapshot.id)
    #expect(creations.first?.1 == destination)
    #expect(await recorder.releaseValues() == [destination])
    #expect(model.pendingSnapshot == nil)
    #expect(model.snapshotReceipt?.exactDisplayPath == destination.exactDisplayPath)
    #expect(model.snapshotReceipt?.disclosure.contains("non-authoritative") == true)
    #expect(model.snapshotReceipt?.disclosure.contains("do not flow back") == true)
}

@Test("Cancel and double submission cannot create or reuse a destination")
@MainActor
func knowledgeSnapshotCancelAndDoubleSubmitAreOneShot() async {
    let context = knowledgeContext(suffix: 6)
    let snapshot = knowledgeSnapshot(
        suffix: 106,
        context: context,
        documents: [knowledgeDocument(suffix: 207, scope: .user)]
    )
    let firstDestination = KnowledgeSnapshotDestination(
        id: knowledgeUUID(302),
        exactDisplayPath: "/private/tmp/cancelled.md"
    )
    let secondDestination = KnowledgeSnapshotDestination(
        id: knowledgeUUID(303),
        exactDisplayPath: "/private/tmp/created.md"
    )
    let createGate = KnowledgeValueGate<KnowledgeSnapshotReceipt>()
    let recorder = KnowledgeActionRecorder()
    actor DestinationQueue {
        var values: [KnowledgeSnapshotDestination]
        init(_ values: [KnowledgeSnapshotDestination]) { self.values = values }
        func next() -> KnowledgeSnapshotDestination? {
            values.isEmpty ? nil : values.removeFirst()
        }
    }
    let destinations = DestinationQueue([firstDestination, secondDestination])
    let model = KnowledgeWorkspaceModel(
        loader: { _ in snapshot },
        revealer: { _, _ in },
        chooseSnapshotDestination: { _ in await destinations.next() },
        createSnapshot: { snapshotID, selectedDestination in
            await recorder.recordCreation(
                snapshotID: snapshotID,
                destination: selectedDestination
            )
            return await createGate.wait()
        },
        releaseSnapshotDestination: { selectedDestination in
            await recorder.recordRelease(selectedDestination)
        }
    )
    model.activateContext(context)
    await model.load()

    await model.selectSnapshotDestination()
    await model.cancelPendingSnapshot()
    await model.cancelPendingSnapshot()
    #expect(await recorder.creationValues().isEmpty)
    #expect(await recorder.releaseValues() == [firstDestination])

    await model.selectSnapshotDestination()
    let firstConfirmation = Task { await model.confirmSnapshotCreation() }
    for _ in 0..<100 where await !createGate.hasStarted() { await Task.yield() }
    await model.confirmSnapshotCreation()
    #expect(await recorder.creationValues().count == 1)
    await createGate.release(
        KnowledgeSnapshotReceipt(
            exactDisplayPath: secondDestination.exactDisplayPath,
            documentCount: 1,
            createdAt: Date(timeIntervalSince1970: 1_782_000_200)
        )
    )
    await firstConfirmation.value

    #expect(await recorder.creationValues().count == 1)
    #expect(await recorder.releaseValues() == [firstDestination, secondDestination])
    #expect(model.snapshotReceipt?.exactDisplayPath == secondDestination.exactDisplayPath)
}

@Test("Changing context invalidates and releases an unconfirmed exact target")
@MainActor
func knowledgeContextChangeInvalidatesPendingTarget() async {
    let firstContext = knowledgeContext(suffix: 7)
    let secondContext = knowledgeContext(suffix: 8, teammateName: "Ada", projectSuffix: nil)
    let snapshot = knowledgeSnapshot(
        suffix: 107,
        context: firstContext,
        documents: [knowledgeDocument(suffix: 208, scope: .user)]
    )
    let destination = KnowledgeSnapshotDestination(
        id: knowledgeUUID(304),
        exactDisplayPath: "/private/tmp/abandoned.md"
    )
    let recorder = KnowledgeActionRecorder()
    let model = KnowledgeWorkspaceModel(
        loader: { _ in snapshot },
        revealer: { _, _ in },
        chooseSnapshotDestination: { _ in destination },
        createSnapshot: { _, _ in throw KnowledgeUITestError.failed },
        releaseSnapshotDestination: { selectedDestination in
            await recorder.recordRelease(selectedDestination)
        }
    )
    model.activateContext(firstContext)
    await model.load()
    await model.selectSnapshotDestination()
    #expect(model.pendingSnapshot != nil)

    model.activateContext(secondContext)
    for _ in 0..<100 where await recorder.releaseValues().isEmpty { await Task.yield() }

    #expect(model.context == secondContext)
    #expect(model.loadState == .idle)
    #expect(model.pendingSnapshot == nil)
    #expect(model.snapshotReceipt == nil)
    #expect(await recorder.releaseValues() == [destination])
}

@Test("Knowledge presentation names authority, provenance, recovery, and no-writeback semantics")
func knowledgeAccessibilityAndAuthorityWordingIsHonest() {
    let document = knowledgeDocument(
        suffix: 209,
        scope: .project(id: knowledgeUUID(20), name: "Atlas"),
        title: "Source standards",
        recovery: .lastKnownGood(
            unavailableRevision: 4,
            explanation: "The newer file failed integrity validation."
        )
    )

    #expect(document.accessibilityDescription.contains("Source standards"))
    #expect(document.accessibilityDescription.contains("Atlas project memory"))
    #expect(document.accessibilityDescription.contains("Written by Mira"))
    #expect(document.accessibilityDescription.contains("Authoritative OpenBots Markdown"))
    #expect(document.accessibilityDescription.contains("last known good"))
    #expect(KnowledgeWorkspaceSnapshot.defaultAuthorityDisclosure.contains("non-authoritative"))
    #expect(KnowledgeWorkspaceSnapshot.defaultAuthorityDisclosure.contains("read-only") == false)
    #expect(KnowledgeSnapshotReceipt.nonAuthoritativeDisclosure.contains("do not flow back"))
}
