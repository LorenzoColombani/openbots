import Foundation
import Testing
@testable import OpenBotsDomain

// A new bot sets itself up: the set_up_self arguments
// read by the hire's own rules plus a fixed switch list, and what the model
// and the conversation are told.

struct BotSelfSetupRequestTests {
    private func parse(_ object: Any) throws -> Result<BotSelfSetupRequest, BotSelfSetupRefusal> {
        BotSelfSetupRequest.parse(argumentsJSON: try JSONSerialization.data(withJSONObject: object))
    }

    @Test("The probe's own call reads as a profile and two switches (fixture s2-competitor-prices)")
    func probeCall() throws {
        let request = try parse([
            "handle": "PriceWatch", "purpose": "Watches competitor prices and flags drops",
            "instructions": "Check each product page.\nReport drops first.",
            "purview": "Competitor prices", "escalate": "Anything that needs a login",
            "switches": ["web_search", "web_fetch"]
        ]).get()
        #expect(request.profileFields.handle == "PriceWatch")
        #expect(request.profileFields.purpose == "Watches competitor prices and flags drops")
        #expect(request.profileFields.instructions == "Check each product page.\nReport drops first.")
        #expect(request.profileFields.seat?.purview == "Competitor prices")
        #expect(request.switches == [.webSearch, .webFetch])
    }

    @Test("Switches are optional, kept once each and in the list's order")
    func switchOrder() throws {
        #expect(try parse(["handle": "Tidy", "purpose": "Sorts Downloads"]).get().switches == [])
        #expect(try parse(["handle": "Tidy", "purpose": "Sorts Downloads", "switches": []]).get().switches == [])
        let request = try parse(["handle": "Tidy", "purpose": "x", "switches": ["work", "web_fetch", "work"]]).get()
        #expect(request.switches == [.webFetch, .work])
    }

    @Test("A switch outside the list is refused, never dropped: hire, workers, a master, a connector")
    func unknownSwitch() throws {
        for name in ["hire", "workers", "fetchers", "messages", "control_this_mac", "Web_Search", ""] {
            #expect(try parse(["handle": "A", "purpose": "b", "switches": [name]]) == .failure(.unknownSwitch))
        }
    }

    @Test("A switches field that is not a list of text, or an unknown field, is malformed")
    func malformed() throws {
        #expect(try parse(["handle": "A", "purpose": "b", "switches": "web_search"]) == .failure(.malformed))
        #expect(try parse(["handle": "A", "purpose": "b", "switches": [1]]) == .failure(.malformed))
        #expect(try parse(["handle": "A", "purpose": "b", "role": "c"]) == .failure(.malformed))
        #expect(try parse(["handle": "A", "purpose": 3]) == .failure(.malformed))
        #expect(BotSelfSetupRequest.parse(argumentsJSON: Data("[]".utf8)) == .failure(.malformed))
    }

    @Test("The hire's rules hold: a plain handle, not a reserved name, a purpose")
    func hireRules() throws {
        #expect(try parse(["handle": "Price Watch", "purpose": "b"]) == .failure(.profile(.invalidHandle)))
        #expect(try parse(["handle": "you", "purpose": "b"]) == .failure(.profile(.reservedHandle)))
        #expect(try parse(["handle": "A", "purpose": "  "]) == .failure(.profile(.missingPurpose)))
        #expect(try parse(["handle": "@Scout", "purpose": "b"]).get().profileFields.handle == "Scout")
    }

    @Test("Arguments rewritten to the approved switches keep every other field")
    func keptSwitches() throws {
        let original = try JSONSerialization.data(withJSONObject: [
            "handle": "PriceWatch", "purpose": "p", "switches": ["web_search", "work"]])
        let rewritten = try #require(BotSelfSetupRequest.arguments(original, keepingSwitches: []))
        let request = try BotSelfSetupRequest.parse(argumentsJSON: rewritten).get()
        #expect(request.switches == [])
        #expect(request.profileFields.handle == "PriceWatch")
        let some = try #require(BotSelfSetupRequest.arguments(original, keepingSwitches: [.work]))
        #expect(try BotSelfSetupRequest.parse(argumentsJSON: some).get().switches == [.work])
    }
}

struct BotSelfSetupTextTests {
    @Test("Refusals speak of setup, never of hiring")
    func refusalTexts() {
        let refusals: [BotSelfSetupRefusal] = [.notPending, .notTheBot, .malformed, .unknownSwitch, .notSaved,
            .profile(.invalidHandle), .profile(.reservedHandle), .profile(.missingPurpose),
            .profile(.nameTaken(existingName: "Scout")), .profile(.nameArchived(existingName: "Scout"))]
        for refusal in refusals {
            #expect(refusal.toolResultText.hasPrefix("Setup refused: "))
            #expect(!refusal.toolResultText.lowercased().contains("hire"))
        }
        #expect(BotSelfSetupRefusal.profile(.nameTaken(existingName: "Scout")).toolResultText.contains("Scout"))
    }

    @Test("The note says what the bot became and what was turned on, the purpose quoted")
    func noteLine() {
        let setup = BotSelfSetup(previousName: "New Bot", name: "PriceWatch", purpose: "Watches \"prices\"",
                                 wroteProfile: true, turnedOn: [.webFetch, .webSearch], offForTheApp: [])
        #expect(setup.noteLine == "New Bot set itself up as PriceWatch (\"Watches \\\"prices\\\"\"). Turned on for it: web search and web fetch.")
        #expect(setup.toolResultText.contains("Turned on for you: web search and web fetch. They take effect from your next reply."))
    }

    @Test("A master still off is named with where to turn it on; no switches is said too")
    func masterOff() {
        let setup = BotSelfSetup(previousName: "New Bot", name: "Tidy", purpose: "Sorts files",
                                 wroteProfile: true, turnedOn: [.work], offForTheApp: [.work, .webSearch])
        #expect(setup.offForTheApp == [.work])
        #expect(setup.noteLine.hasSuffix("Turned on for it: Work on this Mac. Work on this Mac is off for the whole app: turn it on in Settings."))
        #expect(setup.toolResultText.contains("Work on this Mac is still off for the whole app"))
        let none = BotSelfSetup(previousName: "New Bot", name: "Tidy", purpose: "p", wroteProfile: true,
                                turnedOn: [], offForTheApp: [])
        #expect(none.noteLine.hasSuffix("No switches turned on."))
        #expect(none.toolResultText.contains("No switch was turned on."))
    }

    @Test("When the person had written the profile first, both texts say their words stay")
    func thePersonsProfileStays() {
        let setup = BotSelfSetup(previousName: "New Bot", name: "Ledger", purpose: "ignored", wroteProfile: false,
                                 turnedOn: [], offForTheApp: [])
        #expect(setup.noteLine == "Ledger kept the profile you wrote. No switches turned on.")
        #expect(setup.toolResultText.hasPrefix("The person had already written your profile"))
    }
}

struct BotProfileChangeNoteTests {
    @Test("The person's edit of a bot's words is one line; a change that is not a word says nothing")
    func lines() throws {
        let before = try TeammateProfile(displayName: "PriceWatch", role: "Watches prices")
        #expect(BotProfileChangeNote.line(before: before, after: before) == nil)
        #expect(BotProfileChangeNote.line(before: before, after: try before.revised(displayName: "Scout"))
            == "You renamed PriceWatch to Scout.")
        #expect(BotProfileChangeNote.line(before: before, after: try before.revised(role: "Watches rents"))
            == "You changed PriceWatch's role.")
        #expect(BotProfileChangeNote.line(before: before,
            after: try before.revised(title: "Analyst", role: "Watches rents", detailedInstructions: "Weekly."))
            == "You changed PriceWatch's title, role and instructions.")
        #expect(BotProfileChangeNote.line(before: before, after: try before.revised(displayName: "Scout", role: "x"))
            == "You renamed PriceWatch to Scout and changed its role.")
        // A revision bump alone, as a model choice makes, is not a word.
        #expect(BotProfileChangeNote.line(before: before, after: try before.revised()) == nil)
    }
}
