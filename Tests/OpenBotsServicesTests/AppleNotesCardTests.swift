import Foundation
import OpenBotsDomain
import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

/// The cards for Apple Notes, through the Claude Desktop extension. The
/// extension is pinned and cannot be changed, so the
/// card is the only side that checks anything: every value it shows is read
/// exactly as the extension's `server/index.js` reads it, and a value it could
/// not show exactly is refused before any card goes up.
@Suite("Apple Notes cards: reads are quiet, a write shows its exact text, an unshowable write is refused")
struct AppleNotesCardTests {
    private func notesQuestion(_ tool: String, _ input: [String: Any]) throws -> ClaudeTextPermissionRequest {
        ClaudeTextPermissionRequest(requestID: "req-1", toolUseID: "toolu_1",
            toolName: "mcp__claude_extension_notes__\(tool)",
            inputJSON: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
    }

    private func decide(_ tool: String, _ input: [String: Any]) throws -> ClaudeTextWorkDecision {
        ClaudeTextConnectorApprovalPolicy.decide(try notesQuestion(tool, input), botName: "Kite", role: .appleNotes)
    }

    private func card(_ tool: String, _ input: [String: Any]) throws -> ClaudeTextWorkCard {
        guard case .ask(let card) = try decide(tool, input) else {
            Issue.record("\(tool) did not ask"); throw CardMissing()
        }
        return card
    }
    private struct CardMissing: Error {}

    private func refusal(_ tool: String, _ input: [String: Any]) throws -> String? {
        guard case .denyQuietly(let reason, let activity) = try decide(tool, input) else { return nil }
        #expect(activity == ClaudeTextAppleNotesApprovalPolicy.refusalActivity)
        #expect(reason.hasSuffix("Nothing was written."), "\(reason)")
        return reason
    }

    @Test("The two reads are quiet and say which note or folder was read")
    func theReadsAreQuiet() throws {
        #expect(try decide("list_notes", [:]) == .allowQuietly(activity: "Listed your notes"))
        #expect(try decide("list_notes", ["folder": "Recipes", "limit": 5])
                == .allowQuietly(activity: "Listed your notes in “Recipes”"))
        #expect(try decide("get_note_content", ["note_name": "Shopping"])
                == .allowQuietly(activity: "Read your note “Shopping”"))
        // A read the extension would take a number for is still only a read.
        #expect(try decide("list_notes", ["folder": 3]) == .allowQuietly(activity: "Listed your notes"))
    }

    /// The review's list is held to the real server's `tools/list` by a
    /// separate probe of the extension; this holds the policy to it.
    @Test("The reads and writes the policy knows are exactly the tools the pinned extension announces")
    func theToolsAreTheExtensionsOwn() {
        let known = ClaudeTextAppleNotesApprovalPolicy.quietReads.union(
            [AppleNotesWriteProposal.addTool, AppleNotesWriteProposal.replaceTool])
        #expect(known == Set(ClaudeExtensionConnectorPreparation.notes.tools))
    }

    @Test("Adding a note shows its name, its folder and its exact text, and goes to Notes when no folder is named")
    func addingANoteShowsEverything() throws {
        let named = try card("add_note", ["name": "Groceries", "content": "Milk\nBread", "folder": "Home"])
        #expect(named.title == "Add a note")
        #expect(named.detail == "Adds a new note named “Groceries” to the folder “Home” in your Notes.\n\nMilk\nBread")
        #expect(named.target == "“Groceries” in “Home”")
        #expect(named.kind == .metadataMutation)
        #expect(named.activity == "Asked to add the note “Groceries”")
        // `folder || "Notes"` in the extension: absent, null and empty all mean Notes.
        for input: [String: Any] in [["name": "A", "content": "B"], ["name": "A", "content": "B", "folder": NSNull()],
                                     ["name": "A", "content": "B", "folder": ""]] {
            #expect(try card("add_note", input).detail.hasPrefix("Adds a new note named “A” to the folder “Notes”"))
        }
    }

    @Test("Replacing a note's text says everything in it goes, which note is meant, and shows the new text")
    func replacingANoteSaysItAll() throws {
        let anywhere = try card("update_note_content", ["note_name": "Groceries", "new_content": "Eggs"])
        #expect(anywhere.title == "Replace a note's text")
        #expect(anywhere.detail == "Replaces everything in the first note Notes finds named “Groceries”, in any "
            + "folder (capital letters may differ). What it holds now is not kept.\n\nEggs")
        #expect(anywhere.target == "“Groceries”")
        #expect(anywhere.kind == .overwrite)
        #expect(anywhere.activity == "Asked to replace the text of the note “Groceries”")
        // `if (folder)` in the extension: an empty folder is any folder.
        #expect(try card("update_note_content", ["note_name": "Groceries", "new_content": "Eggs", "folder": ""])
                .detail == anywhere.detail)
        let inFolder = try card("update_note_content", ["note_name": "Groceries", "new_content": "Eggs",
                                                        "folder": "Home"])
        #expect(inFolder.detail.hasPrefix("Replaces everything in the first note Notes finds named “Groceries” "
            + "in the folder “Home” (capital letters may differ)."))
        #expect(inFolder.target == "“Groceries” in “Home”")
    }

    @Test("A long text says how many lines it has, as a text card does")
    func aLongTextCountsItsLines() throws {
        let lines = (1...6).map { "Line \($0)" }.joined(separator: "\n")
        let card = try card("add_note", ["name": "Plan", "content": lines])
        #expect(card.detail.hasPrefix("Adds a new note named “Plan” to the folder “Notes” in your Notes. "
            + "The text is 6 lines long.\n\n"))
    }

    @Test("A write the card cannot show exactly is refused, and says why")
    func anUnshowableWriteIsRefused() throws {
        let add = { (input: [String: Any]) in try self.refusal("add_note", input) }
        #expect(try add(["name": "A", "content": "B", "colour": "red"])?.contains("`colour`") == true)
        #expect(try add(["content": "B"])?.contains("`name` is required") == true)
        #expect(try add(["name": "A", "content": "B", "folder": 3])?.contains("`folder` must be a string") == true)
        #expect(try add(["name": "", "content": "B"])?.contains("`name` is empty") == true)
        #expect(try add(["name": "A\nB", "content": "C"])?.contains("`name` must be one line") == true)
        #expect(try add(["name": " A", "content": "C"])?.contains("`name` begins or ends with a space") == true)
        #expect(try add(["name": "A", "content": "x\u{200B}y"])?.contains("U+200B") == true)
        #expect(try add(["name": "A", "content": "x\n\n\ny"])?.contains("two blank lines") == true)
        #expect(try add(["name": "A", "content": "x "])?.contains("ends with a space") == true)
        let long = String(repeating: "a", count: AppleNotesWriteProposal.maximumTextScalars + 1)
        #expect(try add(["name": "A", "content": long])?.contains("limit is") == true)
        let longName = String(repeating: "n", count: AppleNotesWriteProposal.maximumNameScalars + 1)
        #expect(try add(["name": longName, "content": "B"])?.contains("`name` is") == true)
        let replace = { (input: [String: Any]) in try self.refusal("update_note_content", input) }
        #expect(try replace(["note_name": "A"])?.contains("`new_content` is required") == true)
        #expect(try replace(["note_name": "A", "new_content": "B", "folder": ["x"]])?
            .contains("`folder` must be a string") == true)
    }

    /// Notes reads a note's text as web markup (the extension sets `body`), so
    /// `hunter&#50;2` shows as a secret the card never showed, `&#x200B;` as a
    /// character the card's rule refuses, and a tag as whatever it draws or
    /// fetches. Plain words only.
    @Test("A note's text carrying markup is refused, since Notes would not show what the card shows")
    func markupInANotesTextIsRefused() throws {
        for text in ["the code is hunter&#50;2", "x&#x200B;y", "<img src=\"https://example.test/?q=1\">",
                     "R&D budget", "<b>bold</b>", "3 < 4"] {
            let reason = try refusal("add_note", ["name": "A", "content": text])
            #expect(reason?.contains("web markup") == true, "\(text): \(reason ?? "asked")")
            #expect(try refusal("update_note_content", ["note_name": "A", "new_content": text]) != nil)
        }
        // A name and a folder are not markup: `&` there is shown as written.
        #expect(try card("add_note", ["name": "R&D", "content": "Budget", "folder": "Work & Life"])
                .target == "“R&D” in “Work & Life”")
    }

    @Test("The largest card either write can build keeps its whole text on the record")
    func theWorstCaseCardFitsTheRecord() throws {
        let name = String(repeating: "N", count: AppleNotesWriteProposal.maximumNameScalars)
        let folder = String(repeating: "F", count: AppleNotesWriteProposal.maximumFolderScalars)
        let text = (0..<AppleNotesWriteProposal.maximumTextScalars).map { $0 % 50 == 48 ? "\n" : "t" }.joined()
        for (tool, input) in [("add_note", ["name": name, "content": text, "folder": folder]),
                              ("update_note_content", ["note_name": name, "new_content": text, "folder": folder])] {
            let card = try card(tool, input)
            // The approvals record keeps the first 2,000 characters of a detail.
            #expect(card.detail.unicodeScalars.count <= 2_000, "\(tool): \(card.detail.unicodeScalars.count)")
            #expect(card.detail.hasSuffix(text))
        }
    }

    @Test("A tool the pinned extension never announced asks, in Notes' words")
    func anUnknownToolAsks() throws {
        let card = try card("delete_note", ["note_name": "Groceries"])
        #expect(card.title == "Do something in Notes")
        #expect(card.detail.contains("does not know what that does"))
    }

    @Test("A secret the user gave counts in a note's name, folder or text, and an unreadable write counts too")
    func aSecretInANoteIsFound() throws {
        func carries(_ tool: String, _ input: [String: Any], secrets: [String] = ["hunter22"]) throws -> Bool {
            AppleNotesWriteProposal.carriesASecret(tool: tool,
                try JSONSerialization.data(withJSONObject: input), secrets: secrets)
        }
        #expect(try carries("add_note", ["name": "keys", "content": "the key is hunter22"]))
        #expect(try carries("add_note", ["name": "hunter22", "content": "x"]))
        #expect(try carries("update_note_content", ["note_name": "a", "new_content": "b", "folder": "hunter22"]))
        #expect(try !carries("add_note", ["name": "keys", "content": "the hunt is on"]))
        #expect(AppleNotesWriteProposal.carriesASecret(tool: "add_note", Data("not a note".utf8), secrets: []))
    }
}
