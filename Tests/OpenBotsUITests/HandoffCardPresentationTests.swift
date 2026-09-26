import Foundation
import OpenBotsDomain
@testable import OpenBotsUI
import Testing

@Suite("Handoff card presentation")
@MainActor
struct HandoffCardPresentationTests {
    let date = Date(timeIntervalSince1970: 7_000)

    func identity(_ name: String) -> TeammateIdentitySnapshot {
        TeammateIdentitySnapshot(
            id: UUID(), name: name, role: "Role",
            appearance: CharacterAppearanceSnapshot(
                mode: .creature, grammarVersion: 1, deterministicSeed: 1, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "crest",
                accessibleIdentityDescription: "Round", revision: 1
            )
        )
    }

    func record(state: HandoffState, sender: TeammateID, receiver: TeammateID) throws -> HandoffRecord {
        let provenance = try HandoffProvenance(
            handoffID: HandoffID(UUID()), legID: HandoffLegID(UUID()), originConversationID: ConversationID(UUID()),
            senderID: sender, receiverID: receiver, createdAt: date
        )
        let brief = try HandoffBrief(
            goal: "Write a haiku", constraints: [], inputReferences: [], requestedOutput: "The haiku", exclusions: [],
            stopOrApprovalBoundary: "Stop after one"
        )
        let recovery = state == .needsRecovery
            ? try HandoffRecovery(code: "declined", userMessage: "Not sent.", isRecoverable: false, occurredAt: date.addingTimeInterval(1))
            : nil
        let done = state == .succeeded || state == .returnedToOrigin
        return HandoffRecord(
            handoff: try Handoff(
                rehydrating: provenance, brief: brief, state: state, recovery: recovery,
                lastTransitionAt: date.addingTimeInterval(2), resultSummary: done ? "Silent hands" : nil,
                completedAt: done ? date.addingTimeInterval(2) : nil,
                returnedAt: state == .returnedToOrigin ? date.addingTimeInterval(3) : nil
            ),
            sourceMessageID: nil
        )
    }

    @Test("A staged record the workspace is sending carries no control; one it is not carries Send")
    func stagedCard() throws {
        let mira = identity("Mira"), ada = identity("Ada")
        let record = try record(state: .staged, sender: TeammateID(mira.id), receiver: TeammateID(ada.id))
        let card = ChatHandoffCardSnapshot(record: record, sender: mira, receiver: ada, dispatchesItself: true)
        #expect(card.id == record.id.rawValue && card.control == nil && card.receiverName == "Ada")
        // The same durable record, not staged by a turn this session watched:
        // nothing but a person will move it, so it says so.
        let waiting = ChatHandoffCardSnapshot(record: record, sender: mira, receiver: ada, dispatchesItself: false)
        #expect(waiting.control == .send && waiting.controlLabel == "Send to Ada")
        #expect(card.controlLabel == nil)
        #expect(!card.trail.isFixture && card.trail.state == .staged && card.trail.goal == "Write a haiku")
        #expect(card.trail.timeline.map(\.summary) == ["Brief staged by the lead"])
        #expect(card.trail.accessibilityDescription.hasPrefix("Handoff from Mira to Ada."))
        #expect(!card.trail.accessibilityDescription.contains("fixture"))
        #expect(ChatMessagePartContentSnapshot.handoffCard(card).accessibilityDescription == card.trail.accessibilityDescription)
    }

    @Test("The collapsed line names both seats and one line of goal, and hides the rest of the brief")
    func collapsedLine() throws {
        let mira = identity("Mira"), ada = identity("Ada")
        let card = ChatHandoffCardSnapshot(
            record: try record(state: .staged, sender: TeammateID(mira.id), receiver: TeammateID(ada.id)),
            sender: mira, receiver: ada, dispatchesItself: true
        )
        #expect(card.summaryLine == "Mira asked Ada — Write a haiku")
        #expect(card.collapsedAccessibilityLabel == "Mira asked Ada for: Write a haiku. Staged.")
        // The requested output and the boundary belong to the brief the reader
        // opens, and never to the line the transcript shows.
        #expect(!card.summaryLine.contains("The haiku") && !card.summaryLine.contains("Stop after one"))
        #expect(card.trail.requestedOutput == "The haiku" && card.trail.stopOrApprovalBoundary == "Stop after one")

        // A goal that runs long or over several lines still renders one line.
        let long = String(repeating: "verify ", count: 40).trimmingCharacters(in: .whitespaces)
        let wrapped = ChatHandoffCardSnapshot(
            id: card.id,
            trail: ChatHandoffTrailSnapshot(
                id: card.id, sender: mira, receiver: ada, goal: "Read\n  the   sources\nclosely",
                requestedOutput: "A list", stopOrApprovalBoundary: "Stop after one", state: .working,
                timeline: [], recoveryMessage: nil, resultSummary: nil, fixtureDisclosure: ""
            ),
            receiverName: "Ada", control: nil
        )
        #expect(wrapped.summaryLine == "Mira asked Ada — Read the sources closely")
        #expect(wrapped.collapsedAccessibilityLabel == "Mira asked Ada for: Read the sources closely. Working.")

        let cut = ChatHandoffCardSnapshot.oneLine(long)
        #expect(cut.count == ChatHandoffCardSnapshot.summaryGoalLimit + 1)
        #expect(cut.hasSuffix("…") && !cut.hasSuffix(" …"))
        #expect(ChatHandoffCardSnapshot.oneLine("Write a haiku") == "Write a haiku")
    }

    @Test("Returned and declined records show their timeline and cannot be sent")
    func terminalCards() throws {
        let mira = identity("Mira"), ada = identity("Ada")
        let returned = ChatHandoffCardSnapshot(
            record: try record(state: .returnedToOrigin, sender: TeammateID(mira.id), receiver: TeammateID(ada.id)),
            sender: mira, receiver: ada, dispatchesItself: false
        )
        #expect(returned.control == nil && returned.trail.resultSummary == "Silent hands")
        #expect(returned.trail.timeline.map(\.summary) == ["Brief staged by the lead", "Returned to sender", "Result returned to the lead"])
        #expect(returned.trail.timeline.map(\.actor.name) == ["Mira", "Ada", "Mira"])
        // "Not now" is the user's own answer: no recovery box, no warning
        // state, and nothing about it needs attention.
        let declined = ChatHandoffCardSnapshot(
            record: try record(state: .needsRecovery, sender: TeammateID(mira.id), receiver: TeammateID(ada.id)),
            sender: mira, receiver: ada, dispatchesItself: false
        )
        #expect(declined.control == nil && declined.trail.recoveryMessage == nil)
        #expect(declined.trail.state == .declined && declined.trail.state.visibleLabel == "Not sent")
        #expect(declined.trail.state.symbolName == "xmark.circle")
        #expect(declined.trail.timeline.map(\.summary) == ["Brief staged by the lead", "Not sent"])
        #expect(declined.trail.timeline.last?.state == .declined)
        #expect(!declined.trail.accessibilityDescription.contains("Recovery"))
        #expect(ChatHandoffStateSnapshot.working.visibleLabel == "Working")
    }

    @Test("A leg that failed for any other reason keeps its recovery box; only a stalled accepted brief can be sent again, and only while the conversation is free")
    func failedAndAcceptedCards() throws {
        let mira = identity("Mira"), ada = identity("Ada")
        var stopped = try record(state: .staged, sender: TeammateID(mira.id), receiver: TeammateID(ada.id))
        try stopped.apply(.requireRecovery(HandoffRecovery(code: "leg-stopped",
            userMessage: "Stopped before the member answered.", isRecoverable: false, occurredAt: date.addingTimeInterval(4))))
        let failed = ChatHandoffCardSnapshot(record: stopped, sender: mira, receiver: ada, dispatchesItself: true)
        // A record in recovery is finished as far as this screen is concerned:
        // the reply service admits only a staged or accepted one, so promising
        // a re-send here would promise a refusal.
        #expect(failed.control == nil && failed.trail.state == .needsRecovery)
        #expect(failed.trail.recoveryMessage == "Stopped before the member answered.")
        // Accepted and no durable turn begun: the automatic dispatch takes only
        // a staged record, so a person is the one thing left that can move it,
        // whichever way the brief got here.
        var accepted = try record(state: .staged, sender: TeammateID(mira.id), receiver: TeammateID(ada.id))
        try accepted.apply(.accept(at: date.addingTimeInterval(5)))
        for dispatched in [true, false] {
            let stalled = ChatHandoffCardSnapshot(record: accepted, sender: mira, receiver: ada,
                                                  dispatchesItself: dispatched)
            #expect(stalled.control == .sendAgain && stalled.controlLabel == "Send again")
            #expect(stalled.trail.state == .accepted)
        }
        // While a turn or leg holds the conversation a press could only be
        // refused, so a busy conversation draws neither control.
        #expect(ChatHandoffCardSnapshot(record: accepted, sender: mira, receiver: ada, dispatchesItself: false,
                                        conversationIsBusy: true).control == nil)
        let waiting = try record(state: .staged, sender: TeammateID(mira.id), receiver: TeammateID(ada.id))
        #expect(ChatHandoffCardSnapshot(record: waiting, sender: mira, receiver: ada, dispatchesItself: false,
                                        conversationIsBusy: true).control == nil)
        #expect(ChatHandoffCardSnapshot(record: waiting, sender: mira, receiver: ada, dispatchesItself: false).control == .send)
        // Working and succeeded are the workspace's business, not a person's.
        var working = accepted
        try working.apply(.beginWork(at: date.addingTimeInterval(6)))
        #expect(ChatHandoffCardSnapshot(record: working, sender: mira, receiver: ada,
                                        dispatchesItself: false).control == nil)
    }

    @Test("The interaction model sends a stalled brief once, ignores stray results, and re-enables after a failure")
    func interaction() async throws {
        let mira = identity("Mira"), ada = identity("Ada")
        var record = try record(state: .staged, sender: TeammateID(mira.id), receiver: TeammateID(ada.id))
        try record.apply(.accept(at: date.addingTimeInterval(5)))
        let card = ChatHandoffCardSnapshot(record: record, sender: mira, receiver: ada, dispatchesItself: false)
        let route = ConversationCardInteractionRoute(
            conversationID: UUID(), messageID: record.id.rawValue, messagePartID: record.legID.rawValue,
            cardID: record.id.rawValue, actionRouteID: UUID()
        )
        let sends = Counter(), declines = Counter()
        let model = HandoffCardInteractionModel(
            route: route, snapshot: card,
            send: { r, attempt in
                await sends.increment()
                return ConversationCardActionResult(route: r, attemptID: attempt, outcome: .succeeded(receiptID: nil))
            },
            decline: { r, attempt in
                await declines.increment()
                return ConversationCardActionResult(route: r, attemptID: attempt, outcome: .failed(receiptID: nil))
            }
        )
        #expect(model.state == .ready)
        model.decline()
        #expect(model.state == .declining)
        model.decline() // ignored while busy
        try await waitUntil { model.state == .failed("Could not decline. Try again.") }
        #expect(await declines.value == 1)
        model.send()
        try await waitUntil { model.state == .sent }
        model.send() // terminal: ignored
        #expect(await sends.value == 1)
        let registry = ConversationCardInteractionModel(conversationID: route.conversationID)
        #expect(registry.register(model))
        #expect(registry.handoff(messageID: route.messageID, partID: route.partID, cardID: route.cardID) === model)
        #expect(registry.handoff(messageID: UUID(), partID: route.partID, cardID: route.cardID) == nil)
        #expect(!registry.register(model), "a part registers once")
    }

    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}
