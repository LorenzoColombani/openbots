import Foundation
import Testing
@testable import OpenBotsServices

/// The app's own MCP servers read newline-delimited JSON-RPC on stdin: one
/// frame, one 0x0A. Node's `readline` ends a line at U+000D, U+2028 and U+2029
/// as well (measured on Node v26.8.2), and `JSON.stringify`,
/// which is how the CLI writes a frame, leaves U+2028 and U+2029 raw inside a
/// string. So a call whose arguments carried one arrived as two or three
/// halves, each a parse error with no id, and the call itself was never
/// answered: the bot's turn waited on it. The fence proxy has always split on
/// the byte; these run every shipped server the way the app does and hold all
/// of them to it.
@Suite("The app's own servers frame a request on its newline, and nowhere else")
struct AppOwnedServerFramingTests {
    /// Every app-owned server that ships as a script in the bundle.
    static let scripts: [(name: String, url: URL?)] = [
        ("apple-messages", AppOwnedConnectorCatalog.appleMessagesScriptURL),
        ("apple-mail-send", AppOwnedConnectorCatalog.appleMailSendScriptURL),
        ("apple-contacts", AppOwnedConnectorCatalog.appleContactsScriptURL),
        ("apple-calendar", AppOwnedConnectorCatalog.appleCalendarScriptURL),
        ("google-workspace", AppOwnedConnectorCatalog.googleWorkspaceScriptURL),
    ]

    /// Frames as raw bytes, never through JSONSerialization, so the characters
    /// under test reach the server exactly as the CLI's writer leaves them.
    /// `ping` touches nothing outside the process in any of the five.
    static func frame(_ id: Int, note: String) -> Data {
        Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"ping\",\"params\":{\"note\":\"\(note)\"}}\n".utf8)
    }

    @Test("A request carrying U+2028, U+2029, a carriage return or a character split across reads is answered",
          arguments: AppOwnedServerFramingTests.scripts.map(\.name))
    func everyRequestIsAnswered(_ name: String) throws {
        let script = try #require(Self.scripts.first { $0.name == name }?.url, "the bundle lacks \(name)")
        let node = try #require(InstalledToolResolution()
            .firstResolved(of: BrowserConnectorPreparation.defaultInterpreterURLs))
        let process = Process()
        process.executableURL = node
        process.arguments = [script.path]
        // Nothing the servers could reach the world with is left pointing at a
        // real program; a ping should need none of them.
        process.environment = [
            "PATH": "/usr/bin:/bin", "OPENBOTS_OSASCRIPT": "/usr/bin/false", "OPENBOTS_OPEN": "/usr/bin/false",
            "OPENBOTS_PGREP": "/usr/bin/false", "OPENBOTS_SQLITE": "/usr/bin/false",
        ]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let watchdog = DispatchWorkItem { [process] in if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
        defer { watchdog.cancel() }

        let writer = input.fileHandleForWriting
        writer.write(Self.frame(1, note: "before\u{2028}after"))
        writer.write(Self.frame(2, note: "before\u{2029}after"))
        // A carriage return between two tokens is JSON whitespace.
        writer.write(Data("{\"jsonrpc\":\"2.0\",\r\"id\":3,\"method\":\"ping\"}\n".utf8))
        // Next line travels raw, as JSON.stringify leaves it; the two controls
        // travel escaped, since JSON has no other way to carry them.
        writer.write(Self.frame(4, note: "before\u{0085}after\\u000b\\u000c"))
        // One frame in two writes, parted inside the two bytes of "é".
        let parted = Self.frame(5, note: "caf\u{E9} cr\u{E8}me")
        let cut = try #require(parted.firstIndex(of: 0xC3)) + 1
        writer.write(parted[parted.startIndex..<cut])
        Thread.sleep(forTimeInterval: 0.2)
        writer.write(parted[cut...])
        // The last frame ends where the input does, with no newline after it.
        writer.write(Data("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"ping\"}".utf8))
        writer.closeFile()

        let out = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var answered: [Int] = []
        var parseErrors = 0
        for line in out.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let id = (object["id"] as? NSNumber)?.intValue, object["result"] != nil {
                answered.append(id)
            } else if object["error"] != nil {
                parseErrors += 1
            }
        }
        #expect(answered.sorted() == [1, 2, 3, 4, 5, 6],
                Comment(rawValue: "\(name) answered \(answered.sorted()) with \(parseErrors) errors: "
                    + String(decoding: out, as: UTF8.self)))
        #expect(parseErrors == 0, Comment(rawValue: "\(name) reported \(parseErrors) parse errors"))
    }

    /// A tool name is looked up among the server's own tools and nowhere else:
    /// read through a plain object, `constructor` or `toString` resolved to a
    /// built-in function and ran as a tool.
    @Test("A tool named like a built-in of JavaScript is an unknown tool in every shipped server",
          arguments: AppOwnedServerFramingTests.scripts.map(\.name))
    func builtInNamesAreUnknownTools(_ name: String) throws {
        let script = try #require(Self.scripts.first { $0.name == name }?.url, "the bundle lacks \(name)")
        let node = try #require(InstalledToolResolution()
            .firstResolved(of: BrowserConnectorPreparation.defaultInterpreterURLs))
        let process = Process()
        process.executableURL = node
        process.arguments = [script.path]
        process.environment = [
            "PATH": "/usr/bin:/bin", "OPENBOTS_OSASCRIPT": "/usr/bin/false", "OPENBOTS_OPEN": "/usr/bin/false",
            "OPENBOTS_PGREP": "/usr/bin/false", "OPENBOTS_SQLITE": "/usr/bin/false",
        ]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let watchdog = DispatchWorkItem { [process] in if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
        defer { watchdog.cancel() }
        let names = ["constructor", "toString", "valueOf", "hasOwnProperty", "__proto__"]
        for (index, tool) in names.enumerated() {
            input.fileHandleForWriting.write(Data(("{\"jsonrpc\":\"2.0\",\"id\":\(index + 1),\"method\":\"tools/call\","
                + "\"params\":{\"name\":\"\(tool)\",\"arguments\":{}}}\n").utf8))
        }
        input.fileHandleForWriting.closeFile()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var refused: [Int] = []
        for line in out.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue else { continue }
            let result = object["result"] as? [String: Any]
            let words = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String)
                ?? ((object["error"] as? [String: Any])?["message"] as? String) ?? ""
            if (result == nil || result?["isError"] as? Bool == true), words.contains("unknown tool") {
                refused.append(id)
            }
        }
        #expect(refused.sorted() == Array(1...names.count),
                Comment(rawValue: "\(name) refused \(refused.sorted()): " + String(decoding: out, as: UTF8.self)))
    }

    @Test("No shipped server frames its input with readline")
    func noServerUsesReadline() throws {
        for (name, url) in Self.scripts {
            let source = try String(contentsOf: try #require(url, "the bundle lacks \(name)"), encoding: .utf8)
            #expect(!source.contains("require(\"readline\")") && !source.contains("readline.createInterface"),
                    Comment(rawValue: "\(name) still reads its requests with readline"))
        }
    }
}
