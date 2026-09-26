import Foundation

/// How a bot's reply becomes bubbles: a short first
/// line on its own, then the answer as one bubble that lands whole. The same
/// rule runs live, on the text so far, and on the saved reply, so a bubble
/// already read never changes shape. A fenced code block is never split. What
/// the bot says between its tool calls is not a bubble but the working line
/// under the creature, so a beat never becomes a stray paragraph in the answer.
public enum ReplyBubbleSplitter {
    /// A first paragraph up to this long stands alone as the reply's first line.
    public static let firstLineLimit = 240

    public static func split(_ text: String) -> [String] {
        let paragraphs = Self.paragraphs(text)
        guard let first = paragraphs.first else { return [] }
        guard paragraphs.count > 1, first.count <= firstLineLimit, !first.hasPrefix("```") else {
            return [paragraphs.joined(separator: "\n\n")]
        }
        return [first, paragraphs.dropFirst().joined(separator: "\n\n")]
    }

    /// The bubbles that will not change any more while the reply is still
    /// arriving: the first line once a blank line has followed it.
    public static func committed(_ text: String) -> [String] {
        Array(split(text).dropLast())
    }

    /// The last paragraph the bot wrote, when it is short: what it says it is
    /// about to do before a round of tool calls.
    public static func lastShortLine(_ text: String, limit: Int = 160) -> String? {
        guard let last = paragraphs(text).last, last.count <= limit, !last.hasPrefix("```") else { return nil }
        return last
    }

    /// Paragraphs split on blank lines, trimmed, empties dropped, code fences kept whole.
    static func paragraphs(_ text: String) -> [String] {
        var result: [String] = []
        var current: [Substring] = []
        var inFence = false
        func flush() {
            let joined = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { result.append(joined) }
            current.removeAll()
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            if trimmed.isEmpty, !inFence { flush(); continue }
            current.append(line)
        }
        flush()
        return result
    }
}
