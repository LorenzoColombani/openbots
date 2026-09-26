import Foundation
@testable import OpenBotsServices
import Testing

@Suite("Reply bubbles: a short first line, then the answer whole")
struct ReplyBubbleSplitterTests {
    @Test("A short first paragraph stands alone; the rest lands as one bubble")
    func firstLineThenAnswer() {
        let text = "Here is what I found.\n\nThe folder holds twelve invoices from 2026.\n\nThree are unpaid: April, June and August."
        #expect(ReplyBubbleSplitter.split(text) == [
            "Here is what I found.",
            "The folder holds twelve invoices from 2026.\n\nThree are unpaid: April, June and August."
        ])
    }

    @Test("One paragraph is one bubble; a long first paragraph is not a first line; blank text is nothing")
    func single() {
        #expect(ReplyBubbleSplitter.split("Just one thing to say.") == ["Just one thing to say."])
        let long = String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces)
        #expect(ReplyBubbleSplitter.split(long + "\n\nMore.") == [long + "\n\nMore."])
        #expect(ReplyBubbleSplitter.split("") == [])
        #expect(ReplyBubbleSplitter.split("\n\n  \n") == [])
        #expect(ReplyBubbleSplitter.split("  Trimmed.  \n\n\n\nAnswer.\n") == ["Trimmed.", "Answer."])
    }

    @Test("A fenced code block is never split, even with blank lines inside")
    func codeFence() {
        let text = "Here is the script.\n\n```sh\nls\n\necho done\n```\n\nRun it from the folder."
        #expect(ReplyBubbleSplitter.split(text) == [
            "Here is the script.",
            "```sh\nls\n\necho done\n```\n\nRun it from the folder."
        ])
        let fenceFirst = "```sh\nls\n```\n\nThat lists the folder."
        #expect(ReplyBubbleSplitter.split(fenceFirst) == [fenceFirst])
    }

    @Test("While the reply is arriving, only the first line is committed, once a blank line follows it, and it never changes")
    func committedIsMonotonic() {
        let full = "On it.\n\nChecking the folder.\n\nThe answer is long enough to be the answer, with a second sentence for good measure.\n\nDone."
        var previous: [String] = []
        for end in stride(from: 1, through: full.count, by: 5) {
            let partial = String(full.prefix(end))
            let committed = ReplyBubbleSplitter.committed(partial)
            #expect(committed.starts(with: previous), "committed bubbles shrank at \(end)")
            previous = committed
        }
        #expect(ReplyBubbleSplitter.committed("On it.") == [])
        #expect(ReplyBubbleSplitter.committed("On it.\n\nChe") == ["On it."])
        #expect(ReplyBubbleSplitter.committed(full) == ["On it."])
        #expect(ReplyBubbleSplitter.split(full).last?.hasPrefix("Checking the folder.") == true)
    }

    @Test("The bot's last short line is what it says before a tool round")
    func lastShortLine() {
        #expect(ReplyBubbleSplitter.lastShortLine("On it.\n\nChecking the folder.") == "Checking the folder.")
        #expect(ReplyBubbleSplitter.lastShortLine("On it.\n\n" + String(repeating: "long ", count: 40)) == nil)
        #expect(ReplyBubbleSplitter.lastShortLine("") == nil)
    }
}
