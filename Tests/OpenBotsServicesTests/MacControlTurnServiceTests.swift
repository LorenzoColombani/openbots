import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
@testable import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

/// Control this Mac on the chat path, where the approval cards of every bot are
/// on one screen that Peekaboo can see and press.
@Suite("Control this Mac on the chat path: nothing on the screen moves while a card waits for the user")
struct MacControlTurnServiceTests {
    @Test("A Control this Mac call is refused while another bot's card is waiting, and asks again once it is answered")
    func macControlWaitsWhileAnyCardIsOpen() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = MacControlRunner()
        let service = f.service(store, runner: runner)
        // Yogurt, a bot with Work, puts a card on the screen and it waits.
        let yogurtProgress = MacControlProgressLog()
        let yogurt = Task { await service.sendText(f.submission(for: f.yogurt)) { await yogurtProgress.append($0) } }
        let card = try await yogurtProgress.waitForApproval()
        #expect(card.title == "Move or rename files with a command")
        // Zed holds Control this Mac and tries to click while that card waits.
        let zedProgress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await zedProgress.append($0) } }
        for _ in 0..<800 {
            let answered = await runner.answer(to: "req-mac-1") != nil
            let carded = await !zedProgress.approvals.isEmpty
            if answered || carded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if let shown = await zedProgress.approvals.first {
            Issue.record("the click was put on a card (\(shown.title)) while Yogurt's card waited")
            #expect(await service.decideApproval(id: shown.id, allow: false))
        }
        let first = try await runner.waitForAnswer(to: "req-mac-1")
        #expect(first.contains("\"behavior\":\"deny\"") && first.contains("card is waiting"), "\(first)")
        #expect(await zedProgress.approvals.isEmpty, "no card of its own goes up in front of the user's")
        #expect(await zedProgress.activities.contains("Blocked Control this Mac while a card was waiting"))
        // The user answers Yogurt's card; Zed's next click is asked about normally.
        #expect(await service.decideApproval(id: card.id, allow: false))
        #expect(await yogurt.value.outcome == .completed)
        await runner.releaseSecondClick()
        let second = try await zedProgress.waitForApproval()
        #expect(second.title == "Let Zed control your Mac")
        #expect(await service.decideApproval(id: second.id, allow: false))
        #expect(await zed.value.outcome == .completed)
    }

    @Test("A question card another bot is waiting on holds Control this Mac back too")
    func macControlWaitsWhileAQuestionIsOpen() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = MacControlRunner(workAsksAQuestion: true)
        let service = f.service(store, runner: runner)
        let yogurtProgress = MacControlProgressLog()
        let yogurt = Task { await service.sendText(f.submission(for: f.yogurt)) { await yogurtProgress.append($0) } }
        let question = try await yogurtProgress.waitForQuestion()
        let zedProgress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await zedProgress.append($0) } }
        for _ in 0..<800 {
            let answered = await runner.answer(to: "req-mac-1") != nil
            let carded = await !zedProgress.approvals.isEmpty
            if answered || carded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if let shown = await zedProgress.approvals.first {
            Issue.record("the click was put on a card (\(shown.title)) while Yogurt's question waited")
            #expect(await service.decideApproval(id: shown.id, allow: false))
        }
        let first = try await runner.waitForAnswer(to: "req-mac-1")
        #expect(first.contains("\"behavior\":\"deny\"") && first.contains("card is waiting"), "\(first)")
        #expect(await service.answerUserQuestion(id: question.id, answer: ClaudeTextQuestionAnswer(chosen: ["Red"])))
        #expect(await yogurt.value.outcome == .completed)
        await runner.releaseSecondClick()
        let second = try await zedProgress.waitForApproval()
        #expect(await service.decideApproval(id: second.id, allow: false))
        #expect(await zed.value.outcome == .completed)
    }

    // A card that says "wait 1 second" must not be where the user gives the bot
    // their screen and keyboard for the rest of the reply.
    @Test("Allow for this turn is offered only on a card that sees or changes the user's Mac, and then covers the rest")
    func theTurnIsAllowedOnlyFromARealControlCall() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = MacControlRunner(macCalls: [MacCall("sleep", ["duration": 1000]), MacCall("press", ["keys": ["return"], "app": "Mail"]),
                                                 MacCall("sleep", ["duration": 1000])], holdBefore: nil)
        let service = f.service(store, runner: runner)
        let progress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await progress.append($0) } }
        let wait = try await progress.waitForApproval()
        #expect(wait.target == "wait 1 second" && wait.turnScopeFolder == nil, "\(wait.target) \(String(describing: wait.turnScopeFolder))")
        #expect(!(await service.allowApprovalForTurn(id: wait.id)), "a wait cannot allow the turn")
        #expect(await service.decideApproval(id: wait.id, allow: true))
        let click = try await progress.waitForApproval(count: 2)
        #expect(click.target == "press return in Mail" && click.turnScopeFolder != nil)
        #expect(await service.allowApprovalForTurn(id: click.id))
        // The second wait rides the allowance: no third card.
        let last = try await runner.waitForAnswer(to: "req-mac-3")
        #expect(last.contains("\"behavior\":\"allow\""), "\(last)")
        #expect(await zed.value.outcome == .completed)
        #expect(await progress.approvals.count == 2)
    }

    // A look keeps its Allow for
    // this turn, and no bot acts inside OpenBots; an element of a look at the
    // whole screen can be one of OpenBots' own buttons.
    @Test("After a whole-screen look, a click on one of its elements is refused even under the turn's allowance")
    func anElementOfAWholeScreenLookIsRefused() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = MacControlRunner(macCalls: [MacCall("see", ["app_target": "screen"]), MacCall("click", ["on": "B7"]),
                                                 MacCall("see", ["app_target": "TextEdit"]), MacCall("click", ["on": "B2"])],
                                      holdBefore: nil)
        let service = f.service(store, runner: runner)
        let progress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await progress.append($0) } }
        let look = try await progress.waitForApproval()
        #expect(look.turnScopeFolder != nil, "a look still offers the turn")
        #expect(await service.allowApprovalForTurn(id: look.id))
        let refused = try await runner.waitForAnswer(to: "req-mac-2")
        #expect(refused.contains("\"behavior\":\"deny\"") && refused.contains("app_target"), "\(refused)")
        // Looked again at a named app: its element rides the allowance.
        let clicked = try await runner.waitForAnswer(to: "req-mac-4")
        #expect(clicked.contains("\"behavior\":\"allow\""), "\(clicked)")
        #expect(await zed.value.outcome == .completed)
        #expect(await progress.approvals.count == 1)
    }

    // Results can come back in a batch after the next call
    // is asked about, so a whole-screen look counts from the moment it is let
    // through, by a card, by Allow for this turn, or by an allowance given earlier.
    @Test("A whole-screen look counts once it is allowed, before its result is back",
          arguments: ["approve", "allowForTurn", "earlierThisTurn"])
    func aWholeScreenLookCountsOnceAllowed(_ how: String) async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let look = MacCall("see", ["app_target": "screen"]), element = MacCall("action", ["on": "B7", "action": "AXPress"])
        let calls = how == "earlierThisTurn" ? [MacCall("press", ["keys": ["return"], "app": "Mail"]), look, element] : [look, element]
        let runner = MacControlRunner(macCalls: calls, holdBefore: nil, finishesAtEnd: true)
        let service = f.service(store, runner: runner)
        let progress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await progress.append($0) } }
        let card = try await progress.waitForApproval()
        if how == "approve" { #expect(await service.decideApproval(id: card.id, allow: true)) }
        else { #expect(await service.allowApprovalForTurn(id: card.id)) }
        let refused = try await runner.waitForAnswer(to: "req-mac-\(calls.count)")
        #expect(refused.contains("\"behavior\":\"deny\"") && refused.contains("app_target"), "\(refused)")
        #expect(await zed.value.outcome == .completed)
        #expect(await progress.approvals.count == 1)
    }

    // No card goes up for a call the allowance covers, so its line is the only
    // place the record says what was typed where.
    @Test("A call allowed earlier this turn goes on the record in its card's words, not as the bare tool name")
    func aCallAllowedForTheTurnIsRecordedInItsCardsWords() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = MacControlRunner(macCalls: [MacCall("press", ["keys": ["return"], "app": "Mail"]),
                                                 MacCall("type", ["text": "Lunch at one?", "app": "Mail"])], holdBefore: nil)
        let service = f.service(store, runner: runner)
        let progress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await progress.append($0) } }
        let click = try await progress.waitForApproval()
        #expect(await service.allowApprovalForTurn(id: click.id))
        #expect(await zed.value.outcome == .completed)
        let lines = await progress.activities
        #expect(lines.contains("Used Control this Mac to type 13 characters in Mail · Allowed earlier this turn"), "\(lines)")
        #expect(!lines.contains { $0.hasPrefix("Used type") }, "\(lines)")
        #expect(await progress.approvals.count == 1)
    }

    // MARK: Typing is checked, or the reply says it was not

    // Peekaboo once answered "[ok] Typed", TextEdit stayed empty, and the
    // reply told the user it was done.
    @Test("Typing that no look at its app followed ends the reply with a line saying it was never checked",
          arguments: [
            [MacCall("type", ["text": "Hello", "app": "TextEdit"])],
            [MacCall("type", ["text": "Hello", "app": "TextEdit"]), MacCall("see", ["app_target": "Notes"])],
            [MacCall("see", ["app_target": "TextEdit"]), MacCall("type", ["text": "Hello", "app": "TextEdit"])],
          ])
    fileprivate func uncheckedTypingIsSaid(_ calls: [MacCall]) async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = MacControlRunner(macCalls: calls, holdBefore: nil)
        let service = f.service(store, runner: runner)
        let progress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await progress.append($0) } }
        let first = try await progress.waitForApproval()
        #expect(await service.allowApprovalForTurn(id: first.id))
        // Typing after a look asks every time: approve it.
        let approver = Task {
            var seen = 1
            while !Task.isCancelled {
                let all = await progress.approvals
                if all.count > seen { _ = await service.decideApproval(id: all[seen].id, allow: true); seen += 1 }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let result = await zed.value
        approver.cancel()
        #expect(result.outcome == .completed)
        #expect(result.savedReplyMessage?.parts.map(\.content)
            == [.text("Done.\n\n" + OfficialClaudeTextReplyService.uncheckedTypingLine(["TextEdit"]))],
            "\(String(describing: result.savedReplyMessage?.parts))")
    }

    @Test("Typing followed by a look at the same app leaves the reply as the bot wrote it",
          arguments: [
            [MacCall("type", ["text": "Hello", "app": "TextEdit"]), MacCall("inspect_ui", ["app_target": "textedit"])],
            [MacCall("set_value", ["on": "T1", "value": "Hi"]), MacCall("see", ["app_target": "Mail"])],
            [MacCall("press", ["keys": ["return"], "app": "Mail"])],
          ])
    fileprivate func checkedTypingIsLeftAlone(_ calls: [MacCall]) async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        // set_value names an element, so the turn looks at an app first.
        let runner = MacControlRunner(macCalls: (calls.first?.tool == "set_value" ? [MacCall("see", ["app_target": "Mail"])] : [])
            + calls, holdBefore: nil)
        let service = f.service(store, runner: runner)
        let progress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await progress.append($0) } }
        let first = try await progress.waitForApproval()
        #expect(await service.allowApprovalForTurn(id: first.id))
        // After the look, set_value asks every time: approve it,
        // so the case checks what its name says rather than a call that timed out.
        let approver = Task {
            var seen = 1
            while !Task.isCancelled {
                let all = await progress.approvals
                if all.count > seen { _ = await service.decideApproval(id: all[seen].id, allow: true); seen += 1 }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let result = await zed.value
        approver.cancel()
        for index in 1...calls.count + (calls.first?.tool == "set_value" ? 1 : 0) {
            #expect(await runner.answer(to: "req-mac-\(index)")?.contains("\"behavior\":\"allow\"") == true, "req-mac-\(index)")
        }
        #expect(result.savedReplyMessage?.parts.map(\.content) == [.text("Done.")],
                "\(String(describing: result.savedReplyMessage?.parts))")
    }

    @Test("Typing that failed or was denied adds no line: nothing was sent")
    func deniedTypingAddsNoLine() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = MacControlRunner(macCalls: [MacCall("type", ["text": "Hello", "app": "TextEdit"])], holdBefore: nil)
        let service = f.service(store, runner: runner)
        let progress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await progress.append($0) } }
        let card = try await progress.waitForApproval()
        #expect(await service.decideApproval(id: card.id, allow: false))
        let result = await zed.value
        #expect(result.savedReplyMessage?.parts.map(\.content) == [.text("Done.")])
    }

    @Test("The typing card the user reads shows the words; the approvals record keeps only the count")
    func theCardHeReadsShowsTheWords() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = MacControlRunner(macCalls: [MacCall("type", ["text": "Lunch at one?", "app": "Mail"])], holdBefore: nil)
        let service = f.service(store, runner: runner)
        let progress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await progress.append($0) } }
        let card = try await progress.waitForApproval()
        #expect(card.detail.hasSuffix(" The words: \"Lunch at one?\""), "\(card.detail)")
        #expect(await service.decideApproval(id: card.id, allow: false))
        _ = await zed.value
        let rows = try await store.approvals(conversationID: f.zedChat, limit: 10)
        #expect(!rows.isEmpty && rows.allSatisfy { !$0.exactTargetSummary.contains("Lunch") && !$0.consequenceSummary.contains("Lunch") },
                "\(rows.map(\.exactTargetSummary))")
    }

    // The runtime lets a Control this Mac reply make more calls than any other
    // turn; every one of them that runs is on the record, the last included.
    @Test("Every call of a long Control this Mac reply goes on the record, past the sixty-fourth too")
    func everyCallOfALongReplyIsRecorded() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        // As many calls as the runtime lets a Control this Mac reply make.
        let calls = ClaudeTextOnlyStream.maximumGrantedToolUses + ClaudeTextOnlyStream.maximumMacControlCalls
        let runner = MacControlRunner(macCalls: [MacCall("press", ["keys": ["return"], "app": "Mail"])]
            + (2...calls).map { MacCall("press", ["keys": ["tab"], "app": "Mail", "count": $0]) }, holdBefore: nil)
        let service = f.service(store, runner: runner)
        let progress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await progress.append($0) } }
        let click = try await progress.waitForApproval()
        #expect(await service.allowApprovalForTurn(id: click.id))
        #expect(await zed.value.outcome == .completed)
        let lines = await progress.activities
        #expect(lines.filter { $0.hasSuffix("· Allowed earlier this turn") }.count == calls - 1, "\(lines.suffix(3))")
        #expect(lines.contains("Used Control this Mac to press tab \(calls) times in Mail · Allowed earlier this turn"),
                "\(lines.suffix(3))")
    }

    // The calls a turn keeps for its lines are capped,
    // and a look past the cap was never counted, so a click on an element of
    // a named look was refused as if no look had been taken.
    @Test("A look at a named app counts past the cap on the calls a turn keeps for its lines")
    func aLookPastTheRecordedCallsCapCounts() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let presses = OfficialClaudeTextReplyService.maximumRecordedToolUses
        let runner = MacControlRunner(macCalls: (1...presses).map { MacCall("press", ["keys": ["tab"], "app": "Mail", "count": $0]) }
            + [MacCall("see", ["app_target": "TextEdit"]), MacCall("click", ["query": "Send"])], holdBefore: nil)
        let service = f.service(store, runner: runner)
        let progress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await progress.append($0) } }
        let first = try await progress.waitForApproval()
        #expect(await service.allowApprovalForTurn(id: first.id))
        let clicked = try await runner.waitForAnswer(to: "req-mac-\(presses + 2)")
        #expect(clicked.contains("\"behavior\":\"allow\""), "\(clicked)")
        #expect(await zed.value.outcome == .completed)
    }

    // MARK: Renewing the rounds

    @Test("When a Control this Mac reply runs out of rounds a card asks the user; Approve gives sixty-four more and the reply finishes")
    func approvingTheRenewalCardGivesMoreRounds() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = MacControlRunner(runsOutOfRounds: true)
        let service = f.service(store, runner: runner)
        let progress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await progress.append($0) } }
        let card = try await progress.waitForApproval()
        #expect(card.title == "Let Zed keep going")
        #expect(card.detail.contains("used its 64 rounds on your Mac") && card.detail.contains("Deny ends the reply here"))
        #expect(card.target == "64 more rounds on this Mac")
        #expect(card.turnScopeFolder == nil && !card.handsOverScreen)
        #expect(!(await service.allowApprovalForTurn(id: card.id)), "the renewal card offers no allowance")
        #expect(await service.decideApproval(id: card.id, allow: true))
        #expect(!(await service.decideApproval(id: card.id, allow: true)), "a card is answered once")
        let result = await zed.value
        #expect(result.outcome == .completed)
        #expect(result.savedReplyMessage.map { "\($0.parts)" }?.contains("And the second.") == true)
        #expect(await runner.renewalDecisions == [.renew])
        #expect(await progress.activities.contains("Asked to keep going"))
        let lines = try await store.runActivity(conversationID: f.zedChat, limit: 50).map(\.line)
        #expect(lines.contains("Asked to keep going") && lines.contains("Given 64 more rounds on this Mac"), "\(lines)")
        #expect(try await store.approval(id: ApprovalID(card.id))?.state == .approved)
        // The turn launched with sixty-four rounds.
        let request = try #require(await runner.requests.first)
        let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
        #expect(arguments.firstIndex(of: "--max-turns").map { arguments[$0 + 1] } == "64")
        #expect(request.renewsRoundsByCard)
    }

    @Test("Deny on the renewal card ends the reply at its rounds, keeps what it wrote, and says rounds on the user's Mac rather than web tool calls")
    func denyingTheRenewalCardEndsTheReply() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = MacControlRunner(runsOutOfRounds: true)
        let service = f.service(store, runner: runner)
        let progress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await progress.append($0) } }
        let card = try await progress.waitForApproval()
        #expect(await service.decideApproval(id: card.id, allow: false))
        let result = await zed.value
        #expect(result.outcome == .failed(.macControlRoundsUsedUp))
        let reply = try #require(result.savedReplyMessage)
        #expect(reply.deliveryState == .failed)
        #expect(reply.parts.first?.content == .text("Clicked through the first page."))
        // The saved status still names the cap, as on every other turn.
        #expect(reply.parts.last?.content == .status("OpenBots diagnostic: turnLimitReached"))
        #expect(await runner.renewalDecisions == [.end])
        let lines = try await store.runActivity(conversationID: f.zedChat, limit: 50).map(\.line)
        #expect(lines.contains("Denied: let zed keep going"), "\(lines)")
        #expect(try await store.approval(id: ApprovalID(card.id))?.state == .denied)
    }

    @Test("A renewal card nobody answers in time is a Deny")
    func anUnansweredRenewalCardEndsTheReply() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = MacControlRunner(runsOutOfRounds: true)
        let service = f.service(store, runner: runner)
        let progress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await progress.append($0) } }
        let card = try await progress.waitForApproval()
        // What the card's own timer does after `approvalLifetime`.
        await service.expireApproval(id: card.id)
        let result = await zed.value
        #expect(result.outcome == .failed(.macControlRoundsUsedUp))
        #expect(await runner.renewalDecisions == [.end])
        #expect(await progress.resolved.contains(card.id))
        let lines = try await store.runActivity(conversationID: f.zedChat, limit: 50).map(\.line)
        #expect(lines.contains("Card closed unanswered: let zed keep going"), "\(lines)")
        #expect(try await store.approval(id: ApprovalID(card.id))?.state == .expired)
        #expect(!(await service.decideApproval(id: card.id, allow: true)))
    }

    @Test("Stop while the renewal card waits ends the reply at once and takes the card down")
    func stopWhileTheRenewalCardWaits() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = MacControlRunner(runsOutOfRounds: true)
        let service = f.service(store, runner: runner)
        let progress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await progress.append($0) } }
        let card = try await progress.waitForApproval()
        zed.cancel()
        #expect(await zed.value.outcome == .stopped)
        #expect(await runner.renewalDecisions.isEmpty, "nothing was renewed")
        #expect(await progress.resolved.contains(card.id))
        #expect(try await store.approval(id: ApprovalID(card.id))?.state == .expired)
        #expect(!(await service.decideApproval(id: card.id, allow: true)), "a card does not outlive its turn")
    }

    @Test("While a renewal card waits, another bot's Control this Mac call is refused: its Approve is on the user's screen")
    func theRenewalCardHoldsControlThisMacBack() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = MacControlRunner(scripts: ["Kite": [MacCall("press", ["keys": ["return"], "app": "Mail"])]], runsOutOfRounds: true)
        let service = f.service(store, runner: runner)
        let zedProgress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await zedProgress.append($0) } }
        let card = try await zedProgress.waitForApproval()
        let kite = Task { await service.sendText(f.submission(for: f.kite)) { _ in } }
        let refused = try await runner.waitForAnswer(to: "req-Kite-1")
        #expect(refused.contains("\"behavior\":\"deny\"") && refused.contains("card is waiting"), "\(refused)")
        #expect(await kite.value.outcome == .completed)
        #expect(await service.decideApproval(id: card.id, allow: false))
        #expect(await zed.value.outcome == .failed(.macControlRoundsUsedUp))
    }

    // MARK: The login handoff

    @Test("While a bot has handed the user the screen every Control this Mac call of every bot is refused, looks included, and after the user hands back the next action asks again")
    func theHandoffHoldsTheScreenAndTakesTheAllowance() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let reason = "Sign in to your Apple Account in the Safari window."
        let runner = MacControlRunner(scripts: [
            "Zed": [MacCall("press", ["keys": ["return"], "app": "Mail"]), MacCall(MacCall.handoff, ["reason": reason]),
                    MacCall("see", ["app_target": "Safari"])],
            "Kite": [MacCall("see", [:]), MacCall("permissions", [:]), MacCall("app", ["action": "list"])],
        ])
        let service = f.service(store, runner: runner)
        let zedProgress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await zedProgress.append($0) } }
        let click = try await zedProgress.waitForApproval()
        #expect(await service.allowApprovalForTurn(id: click.id))
        let handoff = try await zedProgress.waitForApproval(count: 2)
        #expect(handoff.handsOverScreen)
        #expect(handoff.title == "Your turn on the screen")
        #expect(handoff.target == reason)
        #expect(handoff.detail.contains(reason) && handoff.detail.contains("Hand back"), "\(handoff.detail)")
        #expect(handoff.turnScopeFolder == nil, "a handoff is never answered for the rest of the turn")
        #expect(!(await service.allowApprovalForTurn(id: handoff.id)))
        #expect(await zedProgress.activities.contains("Handed you the screen: \(reason)"))
        // Another bot on the user's Mac, while the user has the screen: every call refused, a look too.
        let kiteProgress = MacControlProgressLog()
        let kite = Task { await service.sendText(f.submission(for: f.kite)) { await kiteProgress.append($0) } }
        #expect(await kite.value.outcome == .completed)
        for call in 1...3 {
            let answer = try await runner.waitForAnswer(to: "req-Kite-\(call)")
            #expect(answer.contains("\"behavior\":\"deny\"") && answer.contains("He has the screen"), "\(answer)")
        }
        #expect(await kiteProgress.approvals.isEmpty, "no card goes up in front of the user's screen")
        #expect(await kiteProgress.activities.filter { $0 == "Blocked Control this Mac while he had the screen" }.count == 3)
        // The user hands back: the call runs, and the allowance given before is gone.
        #expect(await service.decideApproval(id: handoff.id, allow: true))
        let handedBack = try await runner.waitForAnswer(to: "req-Zed-2")
        #expect(handedBack.contains("\"behavior\":\"allow\""), "\(handedBack)")
        let look = try await zedProgress.waitForApproval(count: 3)
        #expect(look.title == "Let Zed control your Mac", "a fresh card, though the turn was allowed before")
        #expect(await service.decideApproval(id: look.id, allow: false))
        #expect(await zed.value.outcome == .completed)
        #expect(try await store.runActivity(conversationID: f.zedChat, limit: 50).map(\.line).contains("He handed the screen back"))
    }

    @Test("A Control this Mac card already waiting is taken down when another bot hands the user the screen, and I couldn't do it tells the bot so")
    func aHandoffWithdrawsAWaitingControlCard() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = MacControlRunner(scripts: [
            "Kite": [MacCall("press", ["keys": ["return"], "app": "Mail"])],
            "Zed": [MacCall(MacCall.handoff, ["reason": "Type the code from your phone."])],
        ])
        let service = f.service(store, runner: runner)
        let kiteProgress = MacControlProgressLog()
        let kite = Task { await service.sendText(f.submission(for: f.kite)) { await kiteProgress.append($0) } }
        let waiting = try await kiteProgress.waitForApproval()
        let zedProgress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await zedProgress.append($0) } }
        let handoff = try await zedProgress.waitForApproval()
        #expect(handoff.handsOverScreen)
        let withdrawn = try await runner.waitForAnswer(to: "req-Kite-1")
        #expect(withdrawn.contains("\"behavior\":\"deny\"") && withdrawn.contains("He has the screen"), "\(withdrawn)")
        #expect(await kiteProgress.resolved.contains(waiting.id), "the waiting card is taken off the screen")
        #expect(!(await service.decideApproval(id: waiting.id, allow: true)), "a withdrawn card cannot be approved")
        #expect(await kite.value.outcome == .completed)
        #expect(await service.decideApproval(id: handoff.id, allow: false))
        let couldNot = try await runner.waitForAnswer(to: "req-Zed-1")
        #expect(couldNot.contains("\"behavior\":\"deny\"") && couldNot.contains("He could not finish that on the screen"), "\(couldNot)")
        #expect(await zed.value.outcome == .completed)
        #expect(try await store.runActivity(conversationID: f.zedChat, limit: 50).map(\.line).contains("He could not finish on the screen"))
    }

    // Two turns interleave at every await. A
    // Control this Mac card still being written when another bot hands over
    // must never go up, since approving it would act while the user types.
    @Test("A Control this Mac card still being written when another bot hands over the screen never goes up, and its call is refused")
    func aCardBeingWrittenWhenTheScreenIsHandedOverNeverShows() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let held = HeldApprovals(store)
        let runner = MacControlRunner(scripts: [
            "Kite": [MacCall("press", ["keys": ["return"], "app": "Mail"])],
            "Zed": [MacCall(MacCall.handoff, ["reason": "Sign in to the shop."])],
        ])
        let service = f.service(store, runner: runner, approvals: held)
        await held.holdNextInsert()
        let kiteProgress = MacControlProgressLog()
        let kite = Task { await service.sendText(f.submission(for: f.kite)) { await kiteProgress.append($0) } }
        try await held.waitUntilHolding()
        let zedProgress = MacControlProgressLog()
        let zed = Task { await service.sendText(f.submission(for: f.zed)) { await zedProgress.append($0) } }
        let handoff = try await zedProgress.waitForApproval()
        #expect(handoff.handsOverScreen)
        await held.release()
        let refused = try await runner.waitForAnswer(to: "req-Kite-1")
        #expect(refused.contains("\"behavior\":\"deny\"") && refused.contains("He has the screen"), "\(refused)")
        #expect(await kite.value.outcome == .completed)
        #expect(await kiteProgress.approvals.isEmpty, "the click's card never went up")
        #expect(await service.decideApproval(id: handoff.id, allow: false))
        #expect(await zed.value.outcome == .completed)
    }

    @Test("A bot without Control this Mac cannot hand over the screen, and a handoff with anything but a short reason is refused")
    func onlyAControlBotHandsOverAndOnlyWithAReason() async throws {
        let f = try MacControlTurnFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = MacControlRunner(scripts: [
            "Yogurt": [MacCall(MacCall.handoff, ["reason": "Sign in."])],
            "Zed": [MacCall(MacCall.handoff, ["reason": "Sign in.", "app": "Safari"]), MacCall(MacCall.handoff, ["reason": "  "]),
                    MacCall(MacCall.handoff, ["reason": String(repeating: "a", count: 301)])],
        ])
        let service = f.service(store, runner: runner)
        let yogurtProgress = MacControlProgressLog()
        #expect(await service.sendText(f.submission(for: f.yogurt)) { await yogurtProgress.append($0) }.outcome == .completed)
        let yogurt = try await runner.waitForAnswer(to: "req-Yogurt-1")
        #expect(yogurt.contains("\"behavior\":\"deny\"") && yogurt.contains("Only a bot with Control this Mac"), "\(yogurt)")
        let zedProgress = MacControlProgressLog()
        #expect(await service.sendText(f.submission(for: f.zed)) { await zedProgress.append($0) }.outcome == .completed)
        for call in 1...3 {
            let answer = try await runner.waitForAnswer(to: "req-Zed-\(call)")
            #expect(answer.contains("\"behavior\":\"deny\"") && answer.contains("Pass only reason"), "\(answer)")
        }
        #expect(await yogurtProgress.approvals.isEmpty)
        #expect(await zedProgress.approvals.isEmpty)
    }
}

/// One Control this Mac call the child makes: a Peekaboo tool and its input.
/// The cards here press Return in Mail rather than click by query: a click on
/// an element before any look is refused.
private struct MacCall: Sendable {
    /// Stands for the app's own handoff tool rather than a Peekaboo one.
    static let handoff = "@hand_over_screen"
    let tool: String
    let input: Data

    init(_ tool: String, _ input: [String: Any]) {
        self.tool = tool
        self.input = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
    }
}

/// A child that asks one command (or a question) on a work turn, and its
/// scripted calls in order on a Control this Mac turn, holding back the call
/// at `holdBefore` until the test releases it.
private actor MacControlRunner: ClaudeTextOnlyRunning {
    private var answers: [String: String] = [:]
    private var released = false
    /// The work turn asks the user a question instead of running a command.
    private let workAsksAQuestion: Bool
    private let macCalls: [MacCall]
    private let holdBefore: Int?
    /// Calls for one bot by name, in place of the rest: request ids
    /// "req-<name>-<n>", and `MacCall.handoff` is the app's handoff tool.
    private let scripts: [String: [MacCall]]
    /// The Control this Mac turn's rounds run out, as the transport reports
    /// it: it offers the renewal, waits for the host's
    /// decision, and finishes on more rounds or ends at the cap on none.
    private let runsOutOfRounds: Bool
    /// Every call's result comes back only after the last call was asked
    /// about, as when the CLI runs a batch of calls together.
    private let finishesAtEnd: Bool
    private var heldFinishes: [ClaudeTextOnlyEvent] = []
    private(set) var renewalDecisions: [ClaudeTextRoundsRenewalDecision] = []
    private(set) var requests: [ClaudeTextOnlyRequest] = []

    init(workAsksAQuestion: Bool = false,
         macCalls: [MacCall] = [MacCall("press", ["keys": ["return"], "app": "Mail"]), MacCall("press", ["keys": ["return"], "app": "Mail"])],
         holdBefore: Int? = 1, scripts: [String: [MacCall]] = [:], runsOutOfRounds: Bool = false,
         finishesAtEnd: Bool = false) {
        self.finishesAtEnd = finishesAtEnd
        self.workAsksAQuestion = workAsksAQuestion
        self.macCalls = macCalls
        self.holdBefore = holdBefore
        self.scripts = scripts
        self.runsOutOfRounds = runsOutOfRounds
    }

    func releaseSecondClick() { released = true }

    func answer(to requestID: String) -> String? { answers[requestID] }

    func waitForAnswer(to requestID: String) async throws -> String {
        for _ in 0..<800 {
            if let answer = answers[requestID] { return answer }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MacControlTestError.timedOut
    }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await run(request: request, control: nil, onEvent: onEvent)
    }

    func run(request: ClaudeTextOnlyRequest, control: ClaudeTextTurnControl?,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        requests.append(request)
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel))
        await onEvent(.inputSubmitted(messageID: request.messageID))
        await onEvent(.inputAcknowledged(messageID: request.messageID))
        let scripted = scripts.keys.contains { request.systemPrompt.contains("You are \($0),") }
        if runsOutOfRounds, !scripted, let control, request.renewsRoundsByCard {
            await onEvent(.textSnapshot("Clicked through the first page."))
            control.offerRoundsRenewal()
            await onEvent(.roundsRanOut)
            var decision: ClaudeTextRoundsRenewalDecision?
            for _ in 0..<800 {
                if Task.isCancelled { return .cancelled }
                decision = control.takeRoundsRenewalDecision()
                if decision != nil { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard let decision else { return .cancelled }
            renewalDecisions.append(decision)
            guard decision == .renew else {
                // What the transport publishes as it ends the turn at the cap.
                await onEvent(.diagnostic(.turnLimitReached))
                return .failed(.turnLimitReached)
            }
            let text = "Clicked through the first page.\n\nAnd the second."
            await onEvent(.textSnapshot(text))
            return .success(ClaudeTextOnlyReply(sessionID: request.sessionID, actualModel: request.expectedResolvedModel,
                text: text, confirmedActualModel: request.expectedResolvedModel))
        }
        if let control, let (name, script) = scripts.first(where: { request.systemPrompt.contains("You are \($0.key),") }) {
            let namespace = request.connectorAccess?.servers.first(where: { $0.role == .macControl })?.toolNamespace ?? "mcp__none__"
            for (index, call) in script.enumerated() {
                await ask(control, onEvent, requestID: "req-\(name)-\(index + 1)", toolUseID: "toolu_\(name)_\(index + 1)",
                          toolName: call.tool == MacCall.handoff ? ClaudeTextScreenHandoffPolicy.qualifiedToolName
                              : namespace + call.tool, inputJSON: call.input)
            }
        } else if let control {
            if request.grantsWork, workAsksAQuestion {
                await ask(control, onEvent, requestID: "req-colour", toolUseID: "toolu_colour",
                          toolName: ClaudeTextOnlyRequest.questionToolName,
                          input: ["questions": [["question": "Which colour do you prefer?", "header": "Colour",
                                                 "options": [["label": "Red", "description": "You prefer red."],
                                                             ["label": "Blue", "description": "You prefer blue."]],
                                                 "multiSelect": false]]])
            } else if request.grantsWork {
                await ask(control, onEvent, requestID: "req-mv", toolUseID: "toolu_mv", toolName: "Bash",
                          input: ["command": "mv a.txt b.txt"])
            } else if let server = request.connectorAccess?.servers.first(where: { $0.role == .macControl }) {
                for (index, call) in macCalls.enumerated() {
                    if index == holdBefore {
                        for _ in 0..<800 where !released { try? await Task.sleep(for: .milliseconds(10)) }
                    }
                    await ask(control, onEvent, requestID: "req-mac-\(index + 1)", toolUseID: "toolu_mac_\(index + 1)",
                              toolName: server.toolNamespace + call.tool, inputJSON: call.input)
                }
                for finish in heldFinishes { await onEvent(finish) }
                heldFinishes.removeAll()
            }
        }
        await onEvent(.textSnapshot("Done."))
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID, actualModel: request.expectedResolvedModel,
            text: "Done.", confirmedActualModel: request.expectedResolvedModel))
    }

    private func ask(_ control: ClaudeTextTurnControl, _ onEvent: @Sendable (ClaudeTextOnlyEvent) async -> Void,
                     requestID: String, toolUseID: String, toolName: String, input: [String: Any]) async {
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
        await ask(control, onEvent, requestID: requestID, toolUseID: toolUseID, toolName: toolName, inputJSON: data)
    }

    /// Announces a call, asks about it, and waits for the app's answer.
    private func ask(_ control: ClaudeTextTurnControl, _ onEvent: @Sendable (ClaudeTextOnlyEvent) async -> Void,
                     requestID: String, toolUseID: String, toolName: String, inputJSON data: Data) async {
        await onEvent(.toolUse(ClaudeTextToolUse(id: toolUseID, toolName: toolName, inputJSON: data)))
        let request = ClaudeTextPermissionRequest(requestID: requestID, toolUseID: toolUseID, toolName: toolName, inputJSON: data)
        control.register(request)
        await onEvent(.permissionRequested(request))
        var allowed = false
        for _ in 0..<800 {
            let pending = control.takePending()
            if let answer = pending.first.map({ String(decoding: $0, as: UTF8.self) }) {
                answers[requestID] = answer
                allowed = answer.contains("\"behavior\":\"allow\"")
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if finishesAtEnd { heldFinishes.append(.toolFinished(toolUseID: toolUseID, failed: !allowed)) }
        else { await onEvent(.toolFinished(toolUseID: toolUseID, failed: !allowed)) }
    }
}

private enum MacControlTestError: Error { case timedOut }

private actor MacControlProgressLog {
    private(set) var approvals: [ClaudeTextApproval] = []
    private(set) var questions: [ClaudeTextQuestion] = []
    private(set) var activities: [String] = []
    private(set) var resolved: [UUID] = []

    func append(_ progress: ClaudeTextTurnProgress) {
        switch progress {
        case .approvalRequired(let approval): approvals.append(approval)
        case .approvalResolved(let id): resolved.append(id)
        case .questionAsked(let question): questions.append(question)
        case .activity(let line): activities.append(line)
        default: break
        }
    }

    func waitForQuestion() async throws -> ClaudeTextQuestion {
        for _ in 0..<800 {
            if let first = questions.first { return first }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MacControlTestError.timedOut
    }

    func waitForApproval(count: Int = 1) async throws -> ClaudeTextApproval {
        for _ in 0..<800 {
            if approvals.count >= count { return approvals[count - 1] }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MacControlTestError.timedOut
    }
}

/// The store's approvals, with the next insert held until the test lets it go.
private actor HeldApprovals: ApprovalRepository {
    private let store: SQLiteStore
    private var holdingNext = false
    private(set) var holding = false
    private var gate: CheckedContinuation<Void, Never>?
    init(_ store: SQLiteStore) { self.store = store }

    func holdNextInsert() { holdingNext = true }
    func release() { gate?.resume(); gate = nil }
    func waitUntilHolding() async throws {
        for _ in 0..<800 {
            if holding { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MacControlTestError.timedOut
    }

    func approval(id: ApprovalID) async throws -> ApprovalRequest? { try await store.approval(id: id) }
    func insert(_ approval: ApprovalRequest) async throws {
        if holdingNext {
            holdingNext = false
            holding = true
            await withCheckedContinuation { gate = $0 }
            holding = false
        }
        try await store.insert(approval)
    }
    func update(_ approval: ApprovalRequest, expectedState: ApprovalState) async throws {
        try await store.update(approval, expectedState: expectedState)
    }
}

/// Yogurt works in its own folder; Zed holds Control this Mac and nothing else.
private struct MacControlAccess: ClaudeTextReplyWebAccessResolving {
    static let serverName = "openbots_" + String(repeating: "c", count: 64)
    let yogurt: TeammateID
    let workAccess: ClaudeTextWorkAccess

    func allowedTextReplyTools(teammateID: TeammateID) async -> Set<ClaudeTextOnlyTool> { [] }
    func webAccessChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func workAccess(teammateID: TeammateID) async -> ClaudeTextWorkAccess? { teammateID == yogurt ? workAccess : nil }
    func connectorAccess(teammateID: TeammateID, runID: UUID) async -> ClaudeTextConnectorAccess? {
        guard teammateID != yogurt else { return nil }
        return try? ClaudeTextConnectorAccess(servers: [
            ClaudeTextConnectorServer(name: Self.serverName, role: .macControl,
                program: .installedTool(URL(fileURLWithPath: "/private/tmp/openbots-peekaboo-fixture")),
                options: [], environment: [:]),
        ])
    }
    func grantedConnectorNames(teammateID: TeammateID) async -> Set<String> {
        teammateID == yogurt ? [] : [Self.serverName]
    }
}

private struct MacControlPreparer: ClaudeTextLaunchPreparing {
    let target: ClaudeConnectionTarget
    func prepareTextLaunch(runID: UUID) async -> ClaudeTextLaunchPreparation { .ready(target) }
}

private struct MacControlTurnFixture: Sendable {
    let directory: URL
    let protection: ProtectionDecisionReceipt
    let yogurt = TeammateID(UUID()), zed = TeammateID(UUID()), kite = TeammateID(UUID())
    let yogurtChat = ConversationID(UUID()), zedChat = ConversationID(UUID()), kiteChat = ConversationID(UUID())
    let date = Date(timeIntervalSince1970: 4_000)

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextMacControl-\(UUID()).noindex", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(
            fileURL: directory.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
    }

    func seed(_ store: SQLiteStore) async throws {
        for (id, chat, name, seed) in [(yogurt, yogurtChat, "Yogurt", 6), (zed, zedChat, "Zed", 7), (kite, kiteChat, "Kite", 8)] {
            let teammate = try Teammate(id: id,
                profile: TeammateProfile(displayName: name, role: "Teammate", detailedInstructions: nil),
                appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: UInt64(seed),
                    silhouette: "round", paletteToken: "sky", eyeDialect: "bright",
                    nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"),
                createdAt: date, updatedAt: date)
            try await store.provisionDirectChat(teammate: teammate,
                conversation: Conversation(id: chat, kind: .direct(teammateID: id), createdAt: date, updatedAt: date),
                fixtureGreeting: nil, selectConversation: false)
        }
    }

    func submission(for teammate: TeammateID) -> ClaudeTextTurnSubmission {
        ClaudeTextTurnSubmission(conversationID: teammate == yogurt ? yogurtChat : teammate == kite ? kiteChat : zedChat,
            teammateID: teammate,
            userMessageID: MessageID(UUID()), text: "Please get on with it.")
    }

    func service(_ store: SQLiteStore, runner: any ClaudeTextOnlyRunning,
                 approvals: (any ApprovalRepository)? = nil) -> OfficialClaudeTextReplyService {
        // Force-unwrapped fixtures: every value below is a literal that the
        // domain types accept, so a throw here is a broken test, not input.
        let target = try! ClaudeConnectionTarget(executableURL: URL(fileURLWithPath: "/fixture/claude"),
            expectedExecutableSHA256: String(repeating: "a", count: 64),
            profileURL: URL(fileURLWithPath: "/fixture/MacControl.noindex/CLIProfile"),
            workingDirectoryURL: URL(fileURLWithPath: "/fixture/MacControl.noindex/Work"),
            temporaryDirectoryURL: URL(fileURLWithPath: "/fixture/MacControl.noindex/Temp"),
            homeDirectoryURL: URL(fileURLWithPath: "/fixture"))
        let work = try! ClaudeTextWorkAccess(workingDirectoryURL: directory.appendingPathComponent("Bots/Yogurt"),
            protectedPaths: [directory.appendingPathComponent("home/.ssh").path])
        return OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store,
            messages: store, preparer: MacControlPreparer(target: target), runner: runner,
            appOwnerID: UUID(), webAccess: MacControlAccess(yogurt: yogurt, workAccess: work),
            approvals: approvals ?? store, activity: store)
    }
}
