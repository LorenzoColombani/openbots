import AppKit
import Darwin
import Foundation

/// Asks the user's own Chrome about its tabs, so a Control Chrome card can name
/// a tab by its site and title rather than by a number.
public protocol ChromeTabDirectory: Sendable {
    /// The process of the user's Chrome while it runs as an app they can see, or nil.
    /// Never starts it. A relaunched Chrome is a different process, and may
    /// hand out the same tab numbers for other tabs.
    func chromeProcessID() -> Int32?
    /// The tab with this number, as Chrome describes it now. Never starts
    /// Chrome, and gives up rather than wait long.
    func tab(id: Int) async -> ChromeTabLookup
}

public extension ChromeTabDirectory {
    func chromeIsOpen() -> Bool { chromeProcessID() != nil }
}

/// The real directory: `osascript` in JavaScript for Automation, which hands
/// back JSON, so a comma in a title cannot split it the way the extension's own
/// comma-joined lists split (its `list_tabs` and `get_current_tab`).
///
/// It asks `Application("Google Chrome")` by name, as the extension's
/// `tell application "Google Chrome"` does, so the two reach the same Chrome.
/// The Browser connector's headless Chrome registers under the same bundle as
/// a background-only app; with the user's own Chrome open, probing showed that
/// it is the one that answers. `chromeProcessID` counts only a Chrome with a
/// regular window, so nothing is asked of Chrome while the user's is closed.
///
/// The first call is what makes macOS ask the user whether OpenBots Next may
/// control Google Chrome; the prompt holds the call, the timeout ends it, and
/// the card's refusal says to answer macOS first.
public struct OsascriptChromeTabDirectory: ChromeTabDirectory {
    public static let bundleIdentifier = "com.google.Chrome"
    static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
    /// Long enough for a busy Chrome, short enough that a card is not held up.
    let timeout: TimeInterval

    public init(timeout: TimeInterval = 3) { self.timeout = timeout }

    /// Three Apple Events whatever the number of tabs: every tab's number,
    /// then the one tab's title and address. Both are cut by code point, never
    /// inside one, and a lone surrogate a page put in its title becomes U+FFFD,
    /// so the answer is always well-formed JSON that fits the pipe.
    static let script = """
        function clean(value, limit) {
          return Array.from(String(value)).slice(0, limit).map(function (c) {
            return c.length === 1 && c >= "\\uD800" && c <= "\\uDFFF" ? "\\uFFFD" : c;
          }).join("");
        }
        function run(argv) {
          var chrome = Application("Google Chrome");
          if (!chrome.running()) return JSON.stringify({ open: false });
          var ids = chrome.windows.tabs.id();
          for (var w = 0; w < ids.length; w++) {
            for (var t = 0; t < ids[w].length; t++) {
              if (String(ids[w][t]) === argv[0]) {
                var tab = chrome.windows[w].tabs[t];
                return JSON.stringify({ open: true, found: true,
                  title: clean(tab.title(), 500), url: clean(tab.url(), 4096) });
              }
            }
          }
          return JSON.stringify({ open: true, found: false });
        }
        """

    public func chromeProcessID() -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .first { $0.activationPolicy == .regular && !$0.isTerminated }?.processIdentifier
    }

    public func tab(id: Int) async -> ChromeTabLookup {
        guard chromeIsOpen() else { return .unanswered }
        return await Self.run(id: id, timeout: timeout)
    }

    /// One `osascript`, waited for without holding a thread: its end and the
    /// timeout race, and whichever comes first answers.
    static func run(id: Int, timeout: TimeInterval) async -> ChromeTabLookup {
        let process = Process()
        process.executableURL = osascript
        process.arguments = ["-l", "JavaScript", "-e", script, String(id)]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<ChromeTabLookup, Never>) in
            process.terminationHandler = { ended in
                // The answer is small by the script's own bounds; read after the end.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let said = errors.fileHandleForReading.readDataToEndOfFile()
                let lookup = ended.terminationStatus == 0 ? parse(data, id: id)
                    : refusal(String(decoding: said.prefix(4_096), as: UTF8.self))
                if once.claim() { continuation.resume(returning: lookup) }
            }
            do { try process.run() } catch {
                if once.claim() { continuation.resume(returning: .unanswered) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                }
                continuation.resume(returning: .unanswered)
            }
        }
    }

    /// What a failed `osascript` said: macOS refusing OpenBots Next control of
    /// Chrome (-1743) is its own answer; anything else did not answer.
    static func refusal(_ message: String) -> ChromeTabLookup {
        message.contains("-1743") ? .notAllowed : .unanswered
    }

    static func parse(_ data: Data, id: Int) -> ChromeTabLookup {
        guard data.count <= 64 * 1024,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
        guard object["open"] as? Bool == true else { return .unanswered }
        guard object["found"] as? Bool == true else { return .noSuchTab }
        guard let title = object["title"] as? String, let url = object["url"] as? String else { return .unreadable }
        return .found(ChromeTab(id: id, title: title, address: url))
    }

    /// The first of two racers wins.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func claim() -> Bool { lock.withLock { defer { taken = true }; return !taken } }
    }
}
