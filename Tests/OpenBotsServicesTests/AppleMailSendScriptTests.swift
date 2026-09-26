import Foundation
import Testing
import OpenBotsRuntime
@testable import OpenBotsServices

/// The sender is 400 lines of JavaScript that decides whether a mail goes out
/// as the user, and until now every test about it asserted the *text of the file*.
/// These run it. `OPENBOTS_OSASCRIPT` was left in the port for exactly this:
/// a stub that records what it was handed and answers what the test wants, so
/// the argument order, the refusals and the subject check are exercised rather
/// than described.
private struct ScriptHarness {
    let root: URL
    let stub: URL
    let script: URL

    init(resolveAnswer: String = "", resolveFails: String = "", replyAnswer: String = "replied") throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("openbots-mail-script-\(UUID().uuidString)", isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: true)
        script = try #require(AppOwnedConnectorCatalog.appleMailSendScriptURL)
        stub = root.appendingPathComponent("osascript-stub.sh")
        // The real osascript reads the script on stdin and takes values in
        // argv; the stub records exactly that and answers on stdout.
        // The answers live in files, not inside the shell script: a fixture
        // containing a quote used to break the stub rather than fail a test.
        try Data(resolveAnswer.utf8).write(to: root.appendingPathComponent("resolve-answer.txt"))
        try Data(resolveFails.utf8).write(to: root.appendingPathComponent("resolve-error.txt"))
        try Data(replyAnswer.utf8).write(to: root.appendingPathComponent("reply-answer.txt"))
        let body = """
        #!/bin/sh
        here=$(dirname "$0")
        cat > "$here/last-script.txt"
        : > "$here/last-argv.txt"
        : > "$here/last-argv0.bin"
        for value in "$@"; do printf '%s\\n' "$value" >> "$here/last-argv.txt"; done
        for value in "$@"; do printf '%s\\0' "$value" >> "$here/last-argv0.bin"; done
        if grep -q 'set midBare to item 1 of argv' "$here/last-script.txt"; then
          if [ -s "$here/resolve-error.txt" ]; then cat "$here/resolve-error.txt" >&2; exit 1; fi
          cat "$here/resolve-answer.txt"
          exit 0
        fi
        cat "$here/reply-answer.txt"
        exit 0
        """
        try Data(body.utf8).write(to: stub)
        try FileManager().setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))],
                                        ofItemAtPath: stub.path)
    }

    /// One tools/call against the real script, over its real stdio protocol.
    func call(_ tool: String, _ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let node = try #require(InstalledToolResolution()
            .firstResolved(of: BrowserConnectorPreparation.defaultInterpreterURLs))
        let process = Process()
        process.executableURL = node
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["OPENBOTS_OSASCRIPT"] = stub.path
        environment["OPENBOTS_APP_NAME"] = "OpenBots Next"
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let frames = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                        "clientInfo": ["name": "test", "version": "1"]]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": tool, "arguments": arguments]],
        ]
        for frame in frames {
            var data = try JSONSerialization.data(withJSONObject: frame)
            data.append(10)
            input.fileHandleForWriting.write(data)
        }
        input.fileHandleForWriting.closeFile()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        for line in String(decoding: out, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == 2,
                  let result = object["result"] as? [String: Any] else { continue }
            let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            return (text, (result["isError"] as? Bool) ?? false)
        }
        return ("", false)
    }

    /// Every argument, empty ones included: a value that lands in the wrong
    /// slot as "" must shift the array and fail an order assertion, not vanish.
    func lastArgv() throws -> [String] {
        let raw = try String(contentsOf: root.appendingPathComponent("last-argv.txt"), encoding: .utf8)
        var parts = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// The same arguments split on the NUL the stub ends each with, for values
    /// that carry line breaks of their own — a body, which the line record
    /// above would split into several arguments.
    func lastArgvExact() throws -> [String] {
        let raw = try Data(contentsOf: root.appendingPathComponent("last-argv0.bin"))
        var parts = raw.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    func remove() { try? FileManager().removeItem(at: root) }

    /// Drop the stub's record, so the next assertion cannot read the last
    /// call's arguments when this call never reached AppleScript.
    func forgetArgv() {
        try? FileManager().removeItem(at: root.appendingPathComponent("last-argv.txt"))
        try? FileManager().removeItem(at: root.appendingPathComponent("last-argv0.bin"))
    }
}

private struct ScriptSessionEnded: Error {}

/// One `node` process answering many frames. A sweep that asks every
/// character Unicode can produce is thousands of calls, and a spawn each
/// would cost minutes; the app spawns the server once and talks to it, so
/// this is also the shape the app actually uses. Frames go one at a time and
/// the answer is read before the next is sent, so the stub's record of what
/// AppleScript was handed always belongs to the call being asserted.
private final class ScriptSession {
    private let harness: ScriptHarness
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var buffer = Data()
    private var nextID = 2

    init(_ harness: ScriptHarness) throws {
        self.harness = harness
        let node = try #require(InstalledToolResolution()
            .firstResolved(of: BrowserConnectorPreparation.defaultInterpreterURLs))
        process.executableURL = node
        process.arguments = [harness.script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["OPENBOTS_OSASCRIPT"] = harness.stub.path
        environment["OPENBOTS_APP_NAME"] = "OpenBots Next"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        // A file, not a pipe: a pipe nobody drains fills at 64 KB and wedges
        // the process, and a wedged process here wedges the test run rather than
        // failing a test. The script writes nothing to its own stderr today,
        // which is exactly the assumption that should not be load-bearing.
        let errors = harness.root.appendingPathComponent("session-stderr.txt")
        FileManager().createFile(atPath: errors.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: errors)
        try process.run()
        _ = try request(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                         "params": ["protocolVersion": "2025-06-18",
                                    "capabilities": [String: Any](),
                                    "clientInfo": ["name": "test", "version": "1"]]], id: 1)
    }

    func call(_ tool: String, _ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let id = nextID
        nextID += 1
        let object = try request(["jsonrpc": "2.0", "id": id, "method": "tools/call",
                                  "params": ["name": tool, "arguments": arguments]], id: id)
        let result = object["result"] as? [String: Any] ?? [:]
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, (result["isError"] as? Bool) ?? false)
    }

    private func request(_ frame: [String: Any], id: Int) throws -> [String: Any] {
        var data = try JSONSerialization.data(withJSONObject: frame)
        data.append(10)
        input.fileHandleForWriting.write(data)
        // An input this server never answered — a raw U+2028 in a subject once
        // split its line-framed protocol and the id was never seen — would
        // hang the test run on a blocking read instead of failing a test, so the
        // process is killed at the deadline and the empty read becomes an
        // error. The deadline is shorter than the test run's own
        // timeout, because a wedge here is instantaneous rather than slow.
        let watchdog = DispatchWorkItem { [process] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
        defer { watchdog.cancel() }
        while true {
            while let line = takeLine() {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (object["id"] as? NSNumber)?.intValue == id else { continue }
                return object
            }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { throw ScriptSessionEnded() }
            buffer.append(chunk)
        }
    }

    private func takeLine() -> Data? {
        guard let index = buffer.firstIndex(of: 10) else { return nil }
        let line = Data(buffer[buffer.startIndex..<index])
        buffer.removeSubrange(buffer.startIndex...index)
        return line
    }

    func finish() {
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
    }
}

@Suite("Running the mail sender, not reading it")
struct AppleMailSendScriptTests {
    @Test("A new mail with no account is refused, and the refusal names the move")
    func aNewMailWithNoAccountIsRefusedAtRuntime() throws {
        let harness = try ScriptHarness(); defer { harness.remove() }
        let answer = try harness.call("send_mail", ["to": "a@example.test", "subject": "s", "body": "b"])
        #expect(answer.isError)
        #expect(answer.text.contains("he chooses which address a new mail goes from"))
        #expect(answer.text.contains("ASK HIM with your question tool"))
        // "ask" is not an account either.
        let asAsk = try harness.call("send_mail",
            ["account": "ask", "to": "a@example.test", "subject": "s", "body": "b"])
        #expect(asAsk.isError && asAsk.text.contains("Do not choose for him"))
    }

    @Test("The compose values reach AppleScript as values, in the documented order")
    func theComposeArgvOrderIsExact() throws {
        let harness = try ScriptHarness(replyAnswer: "sent from me@example.test · signature: none")
        defer { harness.remove() }
        let answer = try harness.call("send_mail", [
            "account": "iCloud", "to": "a@example.test", "cc": "b@example.test",
            "bcc": "c@example.test", "subject": "Subject here", "body": "Body here",
            "signature": "Work",
        ])
        #expect(!answer.isError)
        let argv = try harness.lastArgv()
        // The leading "-" is the whole safety property: the script arrives on
        // stdin and every value after it is an argv item, so nothing a bot or a
        // stranger writes can be read as AppleScript. Then: mode, account,
        // subject, body, to, cc, bcc, signature — swapping cc and bcc used to
        // pass every test here.
        #expect(argv == ["-", "send", "iCloud", "Subject here", "Body here",
                         "a@example.test", "b@example.test", "c@example.test", "Work"])
    }

    @Test("A reply keyed on Mail's internal id is refused before anything is looked up")
    func anInternalIdIsRefused() throws {
        let harness = try ScriptHarness(); defer { harness.remove() }
        let answer = try harness.call("reply_mail",
            ["rfc_message_id": "483920", "body": "hi", "expect_subject": "Anything",
             "account": "iCloud"])
        #expect(answer.isError)
        #expect(answer.text.contains("not an RFC Message-ID"))
    }

    @Test("A claimed subject that is not the message's subject refuses the reply, and nothing is written")
    func aMismatchedSubjectRefusesTheReply() throws {
        // The message really is about the NDA; the bot claims "a", which the
        // old substring check accepted (proved on a real Mac).
        let harness = try ScriptHarness(
            resolveAnswer: "12345\tiCloud\tLawyer: sign the NDA today")
        defer { harness.remove() }
        let answer = try harness.call("reply_mail", [
            "rfc_message_id": "abc123@mail.example", "body": "sure", "expect_subject": "a",
            "account": "iCloud",
        ])
        #expect(answer.isError)
        #expect(answer.text.contains("different subject than the one you named"))
        // And the stranger's subject is not read back into the turn.
        #expect(!answer.text.contains("NDA"))
        // The reply script was never run: the last thing the stub saw was the
        // resolve, so no reply object was ever created.
        let script = try String(contentsOf: harness.root.appendingPathComponent("last-script.txt"),
                                encoding: .utf8)
        #expect(script.contains("set midBare to item 1 of argv"))
        #expect(!script.contains("set m to reply origMsg"))
    }

    /// The AppleScript itself cannot be executed by a test on this Mac, but it
    /// does not have to be read off disk either: the stub records exactly what
    /// `osascript` was handed, so the assertion can be about the script that
    /// reached Mail on a real `reply_mail` call rather than about text that
    /// exists somewhere in a file.
    ///
    /// What it pins is the line that was wrong for the whole life of the reply
    /// tool. Mail silently ignores `set content of m` on a message returned by
    /// `reply` — no error, nothing in the log — so every reply went out
    /// carrying only the user's signature, until this was fixed. `set properties`
    /// takes. The ordering matters as much as the form: the same assignment
    /// after the send would be the same defect again.
    @Test("The reply script handed to Mail sets the body through properties, before anything leaves",
          arguments: ["reply_mail", "draft_reply"])
    func theReplyScriptSetsTheBodyThroughProperties(_ tool: String) throws {
        let harness = try ScriptHarness(resolveAnswer: "12345\tiCloud\tHello",
                                        replyAnswer: "sent from a@b.test to 1 recipient(s)")
        defer { harness.remove() }
        let answer = try harness.call(tool, ["rfc_message_id": "abc123@mail.example",
                                             "body": "the words", "expect_subject": "Hello",
                                             "account": "iCloud"])
        #expect(!answer.isError, Comment(rawValue: answer.text))
        let handed = try String(contentsOf: harness.root.appendingPathComponent("last-script.txt"),
                                encoding: .utf8)
        // Comments are stripped before the negative match: this file's comments
        // name the broken form on purpose, and a prose edit should not be able
        // to fail a test about behaviour.
        let code = handed.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") ? "" : String($0) }
            .joined(separator: "\n")
        #expect(code.contains("set m to reply origMsg"))
        #expect(!code.contains("set content of m to"))
        let assignment = try #require(code.range(of: "set properties of m to {content:theBody}"))
        let leaves = try #require(code.range(of: "if theMode is \"send\" then"))
        #expect(assignment.upperBound < leaves.lowerBound,
                Comment(rawValue: "the body goes in before the send/save split, or a reply leaves empty"))
    }

    @Test("The same subject with a Re: prefix and odd spacing is the same subject")
    func theSubjectComparisonIsHumanButExact() throws {
        let harness = try ScriptHarness(
            resolveAnswer: "12345\tWork\tRe:  OpenBots   send test ",
            replyAnswer: "sent from me@work.example to 1 recipient(s)")
        defer { harness.remove() }
        let answer = try harness.call("reply_mail", [
            "rfc_message_id": "abc123@mail.example", "body": "all good",
            "expect_subject": "OpenBots send test", "account": "Work",
        ])
        #expect(!answer.isError, Comment(rawValue: answer.text))
        // The claim is echoed, never the real subject.
        #expect(answer.text.contains("\"OpenBots send test\""))
        let argv = try harness.lastArgv()
        #expect(argv == ["-", "send", "12345", "Work", "all good", "one"])
    }

    @Test("Reply-to-all reaches the script as such, and a missing message says so")
    func replyAllAndMissingMessage() throws {
        let all = try ScriptHarness(resolveAnswer: "9\tiCloud\tHello", replyAnswer: "sent")
        defer { all.remove() }
        let sent = try all.call("reply_mail", ["rfc_message_id": "x@y", "body": "b",
                                               "expect_subject": "Hello", "account": "iCloud",
                                               "reply_all": true])
        #expect(!sent.isError, Comment(rawValue: sent.text))
        #expect(try all.lastArgv().last == "all")

        let gone = try ScriptHarness(resolveFails: "execution error: NO_SUCH_MESSAGE (-1728)")
        defer { gone.remove() }
        let answer = try gone.call("reply_mail", ["rfc_message_id": "x@y", "body": "b",
                                                  "expect_subject": "Hello", "account": "iCloud"])
        #expect(answer.isError && answer.text.contains("No message on this Mac has that Message-ID"))
    }

    @Test("Listing the user's accounts runs and comes back as text")
    func listingAccountsRuns() throws {
        let harness = try ScriptHarness(replyAnswer: "iCloud — me@example.test\n")
        defer { harness.remove() }
        let answer = try harness.call("list_mail_accounts", [:])
        #expect(!answer.isError)
        #expect(answer.text.contains("iCloud"))
    }
}

@Suite("The same Message-ID in two places")
struct AppleMailReplySideTests {
    @Test("A named account that does not hold the message is an error, not a search elsewhere")
    func aNamedAccountIsNotAHint() throws {
        // A mail sent between two of the user's own accounts exists twice —
        // in the receiving account's inbox and in the sender's Sent — and a
        // fallback across accounts once answered the Sent one, so the reply came out of the
        // wrong side of the conversation.
        let harness = try ScriptHarness(resolveFails: "execution error: NOT_IN_THAT_ACCOUNT (-1728)")
        defer { harness.remove() }
        let answer = try harness.call("reply_mail", [
            "rfc_message_id": "abc@mail.example", "body": "b", "expect_subject": "Hello",
            "account": "Work",
        ])
        #expect(answer.isError)
        #expect(answer.text.contains("does not hold a message with that Message-ID"))
        #expect(answer.text.contains("wrong side of the conversation"))
    }
}

@Suite("The card and the script read one input the same way")
struct AppleMailOneShapeTests {
    @Test("Addresses in any shape the card cannot show are refused, not sent")
    func arraysAreRefused() throws {
        let harness = try ScriptHarness(replyAnswer: "sent"); defer { harness.remove() }
        // The card reads to/cc/bcc as strings. An array used to vanish from the
        // card while every address still went out — a blind bcc.
        let answer = try harness.call("send_mail", [
            "account": "iCloud", "to": ["a@example.test", "b@example.test"],
            "bcc": ["hidden@example.test"], "subject": "s", "body": "b",
        ])
        #expect(answer.isError)
        #expect(answer.text.contains("comma-separated STRING"))
        #expect(answer.text.contains("nothing was sent"))
        // The same refusal on a draft says what did not happen to a draft.
        let draft = try harness.call("draft_mail", [
            "account": "iCloud", "to": ["a@example.test"], "subject": "s", "body": "b",
        ])
        #expect(draft.isError && draft.text.contains("nothing was saved") && !draft.text.contains("nothing was sent"),
                Comment(rawValue: draft.text))
        let long = try harness.call("draft_mail", [
            "account": "iCloud", "to": "a@example.test", "subject": String(repeating: "s", count: 401), "body": "b",
        ])
        #expect(long.isError && long.text.contains("nothing was saved"), Comment(rawValue: long.text))
    }

    @Test("A body that begins with a byte-order mark is refused on every path, and each refusal says what did not happen")
    func aLeadingByteOrderMarkIsRefused() throws {
        // Foundation's JSONSerialization drops one leading U+FEFF from every string it reads, and the
        // app both builds the card from such a read and hands the approved input back to the CLI from
        // it; node's JSON.parse keeps it (measured). This is about which input was
        // approved, not what the card draws: a body still beginning with one is not the body the app read.
        let harness = try ScriptHarness(resolveAnswer: "9\tiCloud\tHello", replyAnswer: "sent"); defer { harness.remove() }
        for (tool, verb, arguments) in [
            ("send_mail", "sent", ["account": "iCloud", "to": "a@example.test", "subject": "s", "body": "\u{FEFF}Hello"]),
            ("draft_mail", "saved", ["account": "iCloud", "to": "a@example.test", "subject": "s", "body": "\u{FEFF}Hello"]),
            ("reply_mail", "written", ["rfc_message_id": "abc@example.test", "body": "\u{FEFF}Hello", "expect_subject": "Hello", "account": "iCloud"]),
            ("draft_reply", "written", ["rfc_message_id": "abc@example.test", "body": "\u{FEFF}Hello", "expect_subject": "Hello", "account": "iCloud"]),
        ] as [(String, String, [String: Any])] {
            let answer = try harness.call(tool, arguments)
            #expect(answer.isError && answer.text.contains("byte-order mark"), "\(tool): \(answer.text)")
            // A draft that was refused was never going to be sent, so it does not say "sent".
            #expect(answer.text.contains("nothing was \(verb)"), "\(tool): \(answer.text)")
        }
        // The same character later in the body survives every reader alike, so it is not refused.
        let middle = try harness.call("send_mail", ["account": "iCloud", "to": "a@example.test", "subject": "s", "body": "Hello\u{FEFF}there"])
        #expect(!middle.text.contains("byte-order mark"))
    }

    @Test("A subject that is not a string is refused")
    func aNonStringSubjectIsRefused() throws {
        let harness = try ScriptHarness(); defer { harness.remove() }
        let answer = try harness.call("send_mail", [
            "account": "iCloud", "to": "a@example.test", "subject": ["Quarterly"], "body": "b",
        ])
        #expect(answer.isError && answer.text.contains("must be a string"))
    }

    @Test("reply_all must be a real boolean: the string \"false\" is refused, not treated as true")
    func replyAllMustBeABoolean() throws {
        let harness = try ScriptHarness(resolveAnswer: "9\tiCloud\tHello", replyAnswer: "sent")
        defer { harness.remove() }
        // JavaScript truthiness made "false" mean reply-to-all while the card
        // said "its sender".
        let answer = try harness.call("reply_mail", [
            "rfc_message_id": "x@y", "body": "b", "expect_subject": "Hello",
            "account": "iCloud", "reply_all": "false",
        ])
        #expect(answer.isError)
        #expect(answer.text.contains("must be true or false"))
        // Nothing was handed to AppleScript at all: the refusal happens before
        // the resolve, so the stub never ran.
        let ranAnything = FileManager().fileExists(
            atPath: harness.root.appendingPathComponent("last-argv.txt").path)
        #expect(!ranAnything)
    }

    @Test("A reply with no account is refused, so the Sent copy cannot be answered by accident")
    func aReplyNeedsTheAccount() throws {
        let harness = try ScriptHarness(resolveAnswer: "9\tiCloud\tHello"); defer { harness.remove() }
        let answer = try harness.call("reply_mail", [
            "rfc_message_id": "x@y", "body": "b", "expect_subject": "Hello",
        ])
        #expect(answer.isError)
        #expect(answer.text.contains("`account` is required for a reply"))
        #expect(answer.text.contains("wrong side of the conversation"))
    }

    @Test("A claim that is only a reply prefix is refused")
    func aPrefixOnlyClaimIsRefused() throws {
        let harness = try ScriptHarness(resolveAnswer: "9\tiCloud\t"); defer { harness.remove() }
        let answer = try harness.call("reply_mail", [
            "rfc_message_id": "x@y", "body": "b", "expect_subject": "Re:", "account": "iCloud",
        ])
        #expect(answer.isError && answer.text.contains("only a reply prefix"))
    }

    @Test("The recipient count a reply reports includes the copies reply-to-all adds")
    func theCountIncludesCopies() throws {
        let source = try String(contentsOf: try #require(AppOwnedConnectorCatalog.appleMailSendScriptURL),
                                encoding: .utf8)
        // Mail's reply-to-all puts the sender in To and everyone else in Cc, so
        // counting To alone told the user "1 recipient" for a mail that reached
        // twelve people.
        #expect(source.contains("(count of to recipients of m) + (count of cc recipients of m)"))
        // And the guard that the side test cannot reach from JavaScript alone.
        #expect(source.contains("if found is missing value and hintAccount is not \"\" then error \"NOT_IN_THAT_ACCOUNT\""))
        #expect(source.contains("if (count of matched) > 1 then error \"AMBIGUOUS_ACCOUNT\""))
    }
}

@Suite("The ordinary send, and the fields the card identifies a message by")
struct AppleMailPlainSendTests {
    @Test("A plain mail to one person, with no cc and no bcc, is sent")
    func aPlainSendWorks() throws {
        // This is the regression the type rule shipped with: the callers passed
        // `args.cc || []`, so every mail without a cc AND a bcc — which is most
        // of them — was refused by the new guard. It reached the installed app.
        let harness = try ScriptHarness(replyAnswer: "sent from me@example.test · signature: none")
        defer { harness.remove() }
        let answer = try harness.call("send_mail", [
            "account": "iCloud", "to": "a@example.test", "subject": "plain", "body": "one line",
        ])
        #expect(!answer.isError, Comment(rawValue: answer.text))
        #expect(answer.text.contains("accepted the message for delivery"))
        // cc and bcc arrive as empty strings, in their own slots.
        #expect(try harness.lastArgv() == ["-", "send", "iCloud", "plain", "one line",
                                           "a@example.test", "", "", ""])
    }

    @Test("A draft with no copies is saved too")
    func aPlainDraftWorks() throws {
        let harness = try ScriptHarness(replyAnswer: "draft saved under me@example.test · signature: none")
        defer { harness.remove() }
        let answer = try harness.call("draft_mail", [
            "account": "iCloud", "to": "a@example.test", "subject": "plain", "body": "one line",
        ])
        #expect(!answer.isError, Comment(rawValue: answer.text))
        #expect(answer.text.contains("Nothing was sent"))
    }

    @Test("The subject the card identifies the message by must be a string, or nothing is written")
    func expectSubjectMustBeAString() throws {
        let harness = try ScriptHarness(resolveAnswer: "9\tiCloud\tLawyer: sign the NDA today",
                                        replyAnswer: "sent")
        defer { harness.remove() }
        for claim in [["Lawyer: sign the NDA today"] as Any, 12345 as Any] {
            let answer = try harness.call("reply_mail", [
                "rfc_message_id": "x@y", "body": "b", "account": "iCloud", "expect_subject": claim,
            ])
            #expect(answer.isError)
            #expect(answer.text.contains("`expect_subject` must be a string"))
        }
        // Nothing was looked up, so no reply object existed at any point.
        #expect(!FileManager().fileExists(atPath: harness.root.appendingPathComponent("last-argv.txt").path))
    }

    @Test("The account, body and signature follow the same rule")
    func theOtherFieldsFollowTheRule() throws {
        let harness = try ScriptHarness(); defer { harness.remove() }
        for (field, value) in [("account", ["iCloud"] as Any), ("body", 42 as Any),
                               ("signature", ["Work"] as Any)] {
            var arguments: [String: Any] = ["account": "iCloud", "to": "a@example.test",
                                            "subject": "s", "body": "b"]
            arguments[field] = value
            let answer = try harness.call("send_mail", arguments)
            #expect(answer.isError, Comment(rawValue: "\(field) was accepted"))
            #expect(answer.text.contains("must be a string"))
        }
    }

    @Test("A named account Mail does not have, and two accounts sharing a name, each say so")
    func accountLookupFailuresAreNamed() throws {
        let missing = try ScriptHarness(resolveFails: "execution error: NO_SUCH_ACCOUNT (-1728)")
        defer { missing.remove() }
        let first = try missing.call("reply_mail", ["rfc_message_id": "x@y", "body": "b",
                                                   "expect_subject": "Hello", "account": "Nope"])
        #expect(first.isError && first.text.contains("no account with that name"))

        let twins = try ScriptHarness(resolveFails: "execution error: AMBIGUOUS_ACCOUNT (-1728)")
        defer { twins.remove() }
        let second = try twins.call("reply_mail", ["rfc_message_id": "x@y", "body": "b",
                                                   "expect_subject": "Hello", "account": "Work"])
        #expect(second.isError && second.text.contains("Two Mail accounts share that name"))
    }

    @Test("A subject written in decomposed form still matches the same words composed")
    func theSubjectComparisonNormalises() throws {
        // "Café" with a combining accent on the message, precomposed in the claim.
        let harness = try ScriptHarness(resolveAnswer: "9\tiCloud\tCafe\u{0301} plans",
                                        replyAnswer: "sent from a@b to 1 recipient(s)")
        defer { harness.remove() }
        let answer = try harness.call("reply_mail", [
            "rfc_message_id": "x@y", "body": "b", "account": "iCloud",
            "expect_subject": "Caf\u{00e9} plans",
        ])
        #expect(!answer.isError, Comment(rawValue: answer.text))
    }
}

/// The compose path once capped nothing, while the reply
/// path had capped its inputs from the start. The limits are deliberately
/// generous, and the first test here is the one that matters: the last refusal
/// rule added to this file broke every ordinary send and was installed for
/// twenty minutes before anyone noticed.
@Suite("What the sender refuses for being implausible, and what it must not")
struct AppleMailComposeLimitTests {
    @Test("An ordinary mail with an ordinary subject and ten recipients still goes")
    func anOrdinaryMailStillGoes() throws {
        let harness = try ScriptHarness(replyAnswer: "sent from me@example.test · signature: none")
        defer { harness.remove() }
        let answer = try harness.call("send_mail", [
            "account": "iCloud",
            "to": (1...5).map { "firstname.lastname\($0)@department.company.example" }
                .joined(separator: ", "),
            "cc": (1...5).map { "othername.surname\($0)@department.subsidiary.example" }
                .joined(separator: ", "),
            "subject": String(repeating: "a long but ordinary subject line ", count: 11).trimmingCharacters(in: .whitespaces),
            "body": String(repeating: "An ordinary paragraph of an ordinary mail. ", count: 500),
        ])
        #expect(!answer.isError, Comment(rawValue: answer.text))
    }

    @Test("An address no real mailbox could have is refused before Mail is touched")
    func anAbsurdlyLongAddressIsRefused() throws {
        let harness = try ScriptHarness(); defer { harness.remove() }
        let answer = try harness.call("send_mail", [
            "account": "iCloud", "to": String(repeating: "a", count: 533) + "@example.test",
            "bcc": "hidden@example.test", "subject": "Quarterly numbers", "body": "hi",
        ])
        #expect(answer.isError)
        #expect(answer.text.contains("No real address is that long"))
        // Nothing reached the stub, so no mail object can exist.
        #expect(!FileManager().fileExists(atPath: harness.root.appendingPathComponent("last-argv.txt").path))
    }

    @Test("A subject too long to show the user is refused, and one that fits is not")
    func anImplausibleSubjectIsRefused() throws {
        let harness = try ScriptHarness(replyAnswer: "sent from me@example.test")
        defer { harness.remove() }
        let over = try harness.call("send_mail", ["account": "iCloud", "to": "a@example.test",
                                                   "subject": String(repeating: "s", count: 401),
                                                   "body": "b"])
        #expect(over.isError && over.text.contains("implausibly long"))
        let under = try harness.call("send_mail", ["account": "iCloud", "to": "a@example.test",
                                                    "subject": String(repeating: "s", count: 400),
                                                    "body": "b"])
        #expect(!under.isError, Comment(rawValue: under.text))
    }

    @Test("A reply's body has the compose limit too: one too long is refused before Mail is touched")
    func anImplausibleReplyBodyIsRefused() throws {
        let harness = try ScriptHarness(); defer { harness.remove() }
        for tool in ["reply_mail", "draft_reply"] {
            let over = try harness.call(tool, ["rfc_message_id": "<a@example.test>", "account": "iCloud",
                                               "expect_subject": "Hello", "body": String(repeating: "b", count: 100_001)])
            #expect(over.isError && over.text.contains("implausibly long"), Comment(rawValue: "\(tool): \(over.text)"))
        }
        #expect(!FileManager().fileExists(atPath: harness.root.appendingPathComponent("last-argv.txt").path))
    }

    /// The card strips invisible and bidi characters from the subject so that
    /// what the user reads cannot be reordered or hidden. If the script sent them
    /// anyway, the card and the mail would carry different words.
    @Test("Invisible characters are gone from the subject that reaches Mail, as they are from the card")
    func theSubjectReachesMailTheWayTheCardShowsIt() throws {
        let harness = try ScriptHarness(replyAnswer: "sent from me@example.test")
        defer { harness.remove() }
        let answer = try harness.call("send_mail", [
            "account": "iCloud", "to": "a@example.test",
            "subject": "Invoice\u{200b}\u{202e}reversed", "body": "b",
        ])
        #expect(!answer.isError, Comment(rawValue: answer.text))
        let argv = try harness.lastArgv()
        #expect(argv.contains("Invoicereversed"))
        #expect(!argv.contains { $0.contains("\u{200b}") || $0.contains("\u{202e}") })
        // Exactly what the card renders for the same input.
        #expect(ClaudeTextAppleMailSendApprovalPolicy.oneLine("Invoice\u{200b}\u{202e}reversed")
            == "Invoicereversed")
    }

    /// The strip is for characters that hide or reorder. A joiner does
    /// neither — it is what makes 👩‍💻 one emoji and what Persian spelling
    /// requires — so it has to reach Mail intact, and identically on the card.
    @Test("Joiners reach Mail intact while the hiding characters do not")
    func joinersReachMailIntact() throws {
        let harness = try ScriptHarness(replyAnswer: "sent from me@example.test")
        defer { harness.remove() }
        let subject = "\u{1F469}\u{200D}\u{1F4BB} standup \u{645}\u{6CC}\u{200C}\u{631}\u{648}\u{645}\u{200B}\u{202E}"
        let answer = try harness.call("send_mail", ["account": "iCloud", "to": "a@example.test",
                                                     "subject": subject, "body": "b"])
        #expect(!answer.isError, Comment(rawValue: answer.text))
        let argv = try harness.lastArgv()
        let sent = try #require(argv.first { $0.contains("standup") })
        #expect(sent.contains("\u{1F469}\u{200D}\u{1F4BB}"))
        #expect(sent.contains("\u{645}\u{6CC}\u{200C}\u{631}\u{648}\u{645}"))
        #expect(!sent.contains("\u{200B}") && !sent.contains("\u{202E}"))
        // The card reads it the same way, which is the whole point of the rule.
        #expect(ClaudeTextAppleMailSendApprovalPolicy.oneLine(subject) == sent)
    }

    /// The card draws a subject as one line. Trimming alone was not the same
    /// rule, so a subject with blank lines read as one line on the card and
    /// reached Mail with the blank lines still in it.
    @Test("A subject with blank lines reaches Mail as the one line the card showed")
    func theSubjectLayoutMatchesTheCard() throws {
        let harness = try ScriptHarness(replyAnswer: "sent from me@example.test")
        defer { harness.remove() }
        let subject = "Invoice\n\n\n   March\t\treview"
        let answer = try harness.call("send_mail", ["account": "iCloud", "to": "a@example.test",
                                                     "subject": subject, "body": "b"])
        #expect(!answer.isError, Comment(rawValue: answer.text))
        let sent = try #require(try harness.lastArgv().first { $0.contains("Invoice") })
        #expect(sent == "Invoice March review")
        #expect(ClaudeTextAppleMailSendApprovalPolicy.oneLine(subject) == sent)
    }

    /// The card and the script each normalise the subject in their own
    /// language, and three times now they have drifted apart — over the
    /// joiners, then over U+0085, then over grapheme clusters against
    /// scalars. No fixture caught any of them, because a fixture only asks
    /// about the characters someone thought of; and the first sweep written
    /// to end that missed the third, because it varied the character and not
    /// the SHAPE — every one of those regressions lived next to a space.
    ///
    /// So the axis here is computed from Unicode itself rather than from
    /// either side's rule list: every character that separates, controls,
    /// formats or attaches to another, in all four positions a space can take
    /// around it. A character the script treats specially and the card does
    /// not is inside that net whether or not anyone remembered it — which is
    /// the direction both real defects ran. One exception, and it is named
    /// rather than left implied: U+2065 is unassigned, so no category above
    /// claims it, and it sits inside both sides' invisible ranges. They agree
    /// on it today; the net does not prove they always will.
    @Test("The card and the shipped script normalise a subject identically, character for character")
    func theTwoNormalisersAgree() throws {
        var units: [String] = []
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            // U+2028 and U+2029 are in: neither Foundation nor Node escapes
            // them, and a raw one once split this server's
            // line-framed protocol so the call was never answered. The server
            // now splits its input on 0x0A alone (AppOwnedServerFramingTests).
            // U+0000 is left out because the spawn refuses it: Node will not
            // put a null byte in an argument, so the call fails closed before
            // any argv exists and there is nothing to compare.
            if value == 0x0000 { continue }
            let interesting: Bool
            switch scalar.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator,
                 .control, .format, .nonspacingMark, .spacingMark, .enclosingMark:
                interesting = true
            default:
                interesting = scalar.properties.isWhitespace
            }
            guard interesting else { continue }
            for shape in ["a\(scalar)b", "a \(scalar)b", "a\(scalar) b", "a \(scalar) b"] {
                units.append(shape)
            }
        }
        // `subject` is capped at 400 characters by the script's own guard, so
        // the sweep is pumped through one process in batches under it.
        // The net is named by what it must hold, not by how big it is. A count
        // can only be a floor; the floor drifts every time a toolchain learns
        // new characters, and three of the categories above are already
        // covered by the `isWhitespace` fallback, so deleting one of those
        // changes no count at all — and deleting the enclosing marks changes
        // it by 52, which no honest floor would catch. These name what the sweep is for instead.
        // One per category the net names, each chosen so the `isWhitespace`
        // fallback cannot rescue it — U+0007 for the controls and U+0903 for
        // the spacing marks, because deleting either of those categories was
        // silent against the first version of this list while the count it
        // replaced would have caught them. U+000B would not do: it is a
        // control and whitespace both.
        // All four shapes, because the shape axis is where the third
        // divergence lived.
        for sentinel: UInt32 in [0x0007, 0x0020, 0x0085, 0x00A0, 0x0301, 0x0903,
                                 0x200B, 0x200C, 0x200D, 0x20DD, 0xFEFF] {
            let scalar = try #require(Unicode.Scalar(sentinel))
            for shape in ["a\(scalar)b", "a \(scalar)b", "a\(scalar) b", "a \(scalar) b"] {
                #expect(units.contains(shape),
                        Comment(rawValue: String(format: "the sweep lost U+%04X", sentinel)))
            }
        }
        var batches: [String] = []
        var batch = ""
        for unit in units {
            if batch.utf16.count + unit.utf16.count > 380 {
                batches.append(batch)
                batch = ""
            }
            batch += unit
        }
        if !batch.isEmpty { batches.append(batch) }

        let harness = try ScriptHarness(replyAnswer: "sent from me@example.test")
        defer { harness.remove() }
        let session = try ScriptSession(harness)
        defer { session.finish() }
        for probe in batches {
            // The stub's record is cleared first, so a refused batch fails on
            // the refusal rather than on the previous batch's arguments still
            // sitting in the file.
            harness.forgetArgv()
            let answer = try session.call("send_mail", ["account": "iCloud", "to": "a@example.test",
                                                         "subject": probe, "body": "b"])
            #expect(!answer.isError, Comment(rawValue: answer.text))
            let argv = try harness.lastArgv()
            let sent = try #require(argv.count > 3 ? argv[3] : nil)
            let drawn = ClaudeTextAppleMailSendApprovalPolicy.oneLine(probe)
            #expect(sent == drawn, Comment(rawValue: Self.disagreement(probe, card: drawn, mail: sent)))
        }
    }

    /// A sweep that fails has to say WHICH character, or the next reader is
    /// left diffing two thousand-character strings by eye.
    private static func disagreement(_ probe: String, card: String, mail: String) -> String {
        let a = Array(card.unicodeScalars), b = Array(mail.unicodeScalars)
        var index = 0
        while index < min(a.count, b.count) && a[index] == b[index] { index += 1 }
        let name = { (scalars: [Unicode.Scalar]) -> String in
            scalars[max(0, index - 3)..<min(scalars.count, index + 3)]
                .map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
        }
        return "the card and the mail part at scalar \(index)\n"
            + "  card: \(name(a))\n  mail: \(name(b))\n"
            + "  in a probe of \(probe.unicodeScalars.count) scalars"
    }

    @Test("An address with a joiner in it is still refused, because no address needs one")
    func anAddressWithAJoinerIsStillRefused() throws {
        let harness = try ScriptHarness(); defer { harness.remove() }
        let answer = try harness.call("send_mail", ["account": "iCloud",
                                                     "to": "a\u{200D}b@example.test",
                                                     "subject": "s", "body": "b"])
        #expect(answer.isError && answer.text.contains("not an email address"))
    }

    @Test("A reply claiming only a prefix is refused without a Mail round trip")
    func aPrefixOnlyClaimNeverReachesMail() throws {
        let harness = try ScriptHarness(resolveAnswer: "9\tiCloud\tAnything at all")
        defer { harness.remove() }
        let answer = try harness.call("reply_mail", ["rfc_message_id": "x@y", "body": "b",
                                                      "expect_subject": "Re: ", "account": "iCloud"])
        #expect(answer.isError && answer.text.contains("only a reply prefix"))
        // The guard depends on nothing the lookup returns, so the lookup never ran.
        #expect(!FileManager().fileExists(atPath: harness.root.appendingPathComponent("last-argv.txt").path))
    }

    /// The whitespace set the card reads and the set the script reads have to
    /// be one set. They were not: U+0085 was named for the subject and
    /// forgotten for the addresses, so the card drew `alice@example.test`
    /// while the mail went to an address with a line break on the end of it —
    /// a recipient the card never showed.
    /// An address refuses rather than strips, because no address needs one.
    @Test("An address carrying U+0085 is refused wherever it sits")
    func anAddressWithNextLineIsRefused() throws {
        let harness = try ScriptHarness(); defer { harness.remove() }
        for address in ["alice@example.test\u{0085}", "\u{0085}alice@example.test",
                        "al\u{0085}ice@example.test"] {
            let answer = try harness.call("send_mail", ["account": "iCloud", "to": address,
                                                         "subject": "s", "body": "b"])
            #expect(answer.isError, Comment(rawValue: "accepted \(address.debugDescription)"))
            #expect(answer.text.contains("not an email address"))
        }
    }

    /// The last refusal rule added to the address guard broke every ordinary
    /// send for twenty installed minutes, so the ordinary case is pinned
    /// beside the hostile one rather than assumed — and it is pinned in the
    /// shapes people actually use, because the rule has been widened twice
    /// since and each widening had the same exposure.
    @Test("Ordinary addresses still reach Mail after the whitespace rule")
    func ordinaryAddressesStillReachMail() throws {
        let harness = try ScriptHarness(replyAnswer: "sent from me@example.test")
        defer { harness.remove() }
        let answer = try harness.call("send_mail",
            ["account": "iCloud", "to": "alice@example.test, bob.smith@sub.example.co.uk",
             "cc": "carol@example.test", "subject": "s", "body": "b"])
        #expect(!answer.isError, Comment(rawValue: answer.text))
        let argv = try harness.lastArgv()
        #expect(argv.contains("alice@example.test,bob.smith@sub.example.co.uk"))
        #expect(argv.contains("carol@example.test"))

        let session = try ScriptSession(harness); defer { session.finish() }
        for address in ["alice+newsletter@example.com", "ALICE@EXAMPLE.test", "a@b.example",
                        "12345@67890.example", "alice@mail.corp.eu-west.example.co.uk",
                        "alice@example.international", "jos\u{e9}@example.com",
                        "\u{7530}\u{4E2D}@\u{4F8B}\u{3048}.jp", "alice@m\u{fc}nchen.de",
                        String(repeating: "a", count: 307) + "@example.test"] {
            harness.forgetArgv()
            let sent = try session.call("send_mail", ["account": "iCloud", "to": address,
                                                       "subject": "s", "body": "b"])
            #expect(!sent.isError, Comment(rawValue: "\(address) — \(sent.text)"))
            #expect(try harness.lastArgv().contains(address), Comment(rawValue: address))
        }
    }

    /// The address guard used to be a second hand-written list, and it named
    /// 22 characters out of the 4,174 Unicode itself calls ignorable. The
    /// rest, measured at the system font: `al<U+00AD>ice@…` and
    /// `alice@…` draw to the same width, to the same pixel, and both the card
    /// and the mail carried the hidden one — so the two sides agreed and the
    /// reader could not. It is a property now, not a list.
    @Test("Every character Unicode calls ignorable is refused in an address")
    func ignorableCharactersAreRefusedInAddresses() throws {
        let harness = try ScriptHarness(); defer { harness.remove() }
        let session = try ScriptSession(harness); defer { session.finish() }
        // One from each family the old list missed: the soft hyphen, a
        // variation selector, a Mongolian selector, the Hangul filler, the
        // character one past the end of the old range, and a tag character.
        for hidden: UInt32 in [0x00AD, 0xFE0F, 0x180B, 0x3164, 0x206F, 0xE0041, 0x034F] {
            let scalar = try #require(Unicode.Scalar(hidden))
            let answer = try session.call("send_mail",
                ["account": "iCloud", "to": "al\(scalar)ice@example.test",
                 "subject": "s", "body": "b"])
            #expect(answer.isError,
                    Comment(rawValue: String(format: "U+%04X reached Mail in an address", hidden)))
            // And the refusal names it, because printing the address raw hid
            // the character in the error too.
            #expect(answer.text.contains(String(format: "U+%04X", hidden)),
                    Comment(rawValue: answer.text))
        }
    }

    /// The refusal used to advise dropping a `Name <addr>` form that was never
    /// there, which is the expensive kind of wrong message: it describes a
    /// remedy that changes nothing.
    @Test("A refusal for a hidden character says so, instead of advising a bare address")
    func aHiddenCharacterRefusalNamesTheCharacter() throws {
        let harness = try ScriptHarness(); defer { harness.remove() }
        let answer = try harness.call("send_mail",
            ["account": "iCloud", "to": "alice@example.test\u{0085}", "subject": "s", "body": "b"])
        #expect(answer.isError)
        #expect(answer.text.contains("U+0085"), Comment(rawValue: answer.text))
        #expect(!answer.text.contains("'Name <addr>'"), Comment(rawValue: answer.text))
        // A shape that really is the wrong form still gets the old advice.
        let named = try harness.call("send_mail",
            ["account": "iCloud", "to": "Alice <alice@example.test>", "subject": "s", "body": "b"])
        #expect(named.isError)
        #expect(named.text.contains("'Name <addr>'"), Comment(rawValue: named.text))
        // Wrong in both ways at once is told both, rather than sent back for a
        // second round trip once the invisible one is removed.
        let both = try harness.call("send_mail",
            ["account": "iCloud", "to": "Alice <al\u{00AD}ice@example.test>",
             "subject": "s", "body": "b"])
        #expect(both.isError)
        // The echo always holds `<U+00AD>` for this input, so asserting on the
        // code point alone would pass whether or not the clause that explains
        // it was written.
        #expect(both.text.contains("nothing on screen can show")
                && both.text.contains("'Name <addr>'"), Comment(rawValue: both.text))
        // A no-break space is refused for a reason of its own: it is not
        // invisible, it is indistinguishable.
        let nbsp = try harness.call("send_mail",
            ["account": "iCloud", "to": "alice@example\u{00A0}.test", "subject": "s", "body": "b"])
        #expect(nbsp.isError)
        #expect(nbsp.text.contains("cannot tell from an ordinary space"), Comment(rawValue: nbsp.text))
        // The echo is cut at 120 characters, and the character that explains
        // the refusal can sit past that cut. It still has to be named, and
        // what is shown has to stop at the cut rather than close the gap.
        let late = try harness.call("send_mail",
            ["account": "iCloud",
             "to": String(repeating: "a", count: 200) + "\u{00AD}bc@example.test",
             "subject": "s", "body": "b"])
        #expect(late.isError)
        #expect(late.text.contains("U+00AD"), Comment(rawValue: late.text))
        let echo = String(late.text.split(separator: "\"")[1])
        #expect(echo.hasSuffix("\u{2026}") && !echo.contains("<U+"), Comment(rawValue: echo))
        // And the four ASCII characters that spell a code point are not read
        // back as the character itself.
        let typed = try harness.call("send_mail",
            ["account": "iCloud", "to": "al<U+00AD>ice@example.test", "subject": "s", "body": "b"])
        #expect(typed.isError)
        #expect(typed.text.contains("U+003C"), Comment(rawValue: typed.text))
    }
}

/// `o'brien@example.ie` is a real address — the apostrophe is RFC 5321
/// `atext` — and it was once refused with advice to drop a `Name <addr>` form
/// it never had. The apostrophe is allowed in a local part. Only there: the
/// domain rule does not move, because no host name carries one.
@Suite("An apostrophe in a local part is a real address")
struct AppleMailApostropheAddressTests {
    @Test("An address with an apostrophe goes to Mail exactly as the card drew it, in every field")
    func anApostropheReachesMailAsTheCardDrewIt() throws {
        let harness = try ScriptHarness(replyAnswer: "sent from me@example.test")
        defer { harness.remove() }
        let input: [String: Any] = ["account": "iCloud", "to": "o'brien@example.ie, alice@example.test",
                                    "cc": "d'arcy@example.fr", "bcc": "'quoted'@example.test",
                                    "subject": "s", "body": "b"]
        for tool in ["send_mail", "draft_mail"] {
            harness.forgetArgv()
            let answer = try harness.call(tool, input)
            #expect(!answer.isError, Comment(rawValue: "\(tool): \(answer.text)"))
            let argv = try harness.lastArgv()
            // The card and the script read one input: the card's list of
            // every address, field by field, is what reaches AppleScript.
            let drawn = ClaudeTextAppleMailSendApprovalPolicy.recipients(input)
            #expect(drawn == "o'brien@example.ie, alice@example.test, cc: d'arcy@example.fr, "
                    + "bcc: 'quoted'@example.test")
            #expect(argv.count == 9 && argv[5...7] == ["o'brien@example.ie,alice@example.test",
                                                         "d'arcy@example.fr", "'quoted'@example.test"],
                    Comment(rawValue: "\(tool): \(argv)"))
        }
    }

    @Test("An apostrophe in the domain is still refused, and nothing reaches Mail")
    func anApostropheInTheDomainIsRefused() throws {
        let harness = try ScriptHarness(); defer { harness.remove() }
        for address in ["alice@exa'mple.ie", "alice@example.i'e", "alice@'example.ie", "o'brien@exa'mple.ie"] {
            harness.forgetArgv()
            let answer = try harness.call("send_mail", ["account": "iCloud", "to": address,
                                                         "subject": "s", "body": "b"])
            #expect(answer.isError && answer.text.contains("not an email address"),
                    Comment(rawValue: "accepted \(address)"))
            #expect(!FileManager().fileExists(atPath: harness.root.appendingPathComponent("last-argv.txt").path))
        }
    }
}

/// The card now shows the body, so the body is one
/// more field the card and the script must read alike: a body the card drew
/// without its hiding characters while the mail carried them would be words the user
/// approved that are not the words sent.
@Suite("The body reaches Mail as the card shows it")
struct AppleMailBodyReadsAlikeTests {
    /// The body as the card draws it: whatever follows the one line that
    /// introduces the words. A new mail's card puts its labelled To, Subject
    /// and Signature lines between the sentence and that line,
    /// so the introduction is found by its words, after a blank line that a
    /// one-line subject cannot forge.
    private static func bodyOnCard(_ tool: String, _ input: [String: Any]) throws -> String? {
        let request = ClaudeTextPermissionRequest(requestID: "req-1", toolUseID: "toolu_01",
            toolName: "mcp__openbots_" + String(repeating: "d", count: 64) + "__" + tool,
            inputJSON: try JSONSerialization.data(withJSONObject: input))
        guard case .ask(let card) = ClaudeTextConnectorApprovalPolicy.decide(request, botName: "Kite",
                                                                            role: .appleMailSend) else { return nil }
        for introduction in ["\n\nWhat the mail says:\n", "\n\nWhat the reply says (Mail puts the original below it):\n"] {
            if let split = card.detail.range(of: introduction) { return String(card.detail[split.upperBound...]) }
        }
        return nil
    }

    private static let probes = [
        "Plain words.",
        "Pay \u{202E}evil\u{202C} now\u{200B}, \u{2066}isolated\u{2069}, \u{061C}marked\u{200F}.",
        "Mid\u{FEFF}dle and \u{2060}joined\u{2060}.",
        "\u{1F469}\u{200D}\u{1F4BB} and \u{645}\u{6CC}\u{200C}\u{631}\u{648}\u{645} keep their joiners.",
        "Line one\nLine two\n\nAfter a blank line\r\nAfter a CRLF\u{0085}After a next line",
        "  Indented\n\tTabbed, and trailing spaces  ",
    ]

    @Test("Compose and reply hand Mail the body the card showed, scalar for scalar")
    func theBodyThatReachesMailIsTheBodyOnTheCard() throws {
        let harness = try ScriptHarness(resolveAnswer: "12345\tiCloud\tQuarterly",
                                        replyAnswer: "sent from me@example.test")
        defer { harness.remove() }
        let session = try ScriptSession(harness); defer { session.finish() }
        for tool in ["send_mail", "draft_mail", "reply_mail", "draft_reply"] {
            for probe in Self.probes {
                let input: [String: Any] = ["send_mail", "draft_mail"].contains(tool)
                    ? ["account": "iCloud", "to": "a@example.test", "subject": "Quarterly", "body": probe]
                    : ["rfc_message_id": "abc@mail.example", "account": "iCloud",
                       "expect_subject": "Quarterly", "body": probe]
                harness.forgetArgv()
                let answer = try session.call(tool, input)
                #expect(!answer.isError, Comment(rawValue: "\(tool): \(answer.text)"))
                let argv = try harness.lastArgvExact()
                let sent = try #require(argv.count > 4 ? argv[4] : nil)
                let shown = try #require(try Self.bodyOnCard(tool, input), Comment(rawValue: tool))
                #expect(sent.unicodeScalars.elementsEqual(shown.unicodeScalars),
                        Comment(rawValue: "\(tool), \(probe.debugDescription): mail \(sent.debugDescription), "
                                + "card \(shown.debugDescription)"))
            }
        }
    }

    @Test("A body with no words in it is refused by the script, as the card says it has none")
    func aWordlessBodyIsRefused() throws {
        let harness = try ScriptHarness(resolveAnswer: "12345\tiCloud\tQuarterly")
        defer { harness.remove() }
        let session = try ScriptSession(harness); defer { session.finish() }
        for body in ["\u{0085}", "\u{200B}\u{200E}\u{2060}", " \u{202E} \n"] {
            for tool in ["send_mail", "reply_mail"] {
                let input: [String: Any] = tool == "send_mail"
                    ? ["account": "iCloud", "to": "a@example.test", "subject": "Quarterly", "body": body]
                    : ["rfc_message_id": "abc@mail.example", "account": "iCloud",
                       "expect_subject": "Quarterly", "body": body]
                harness.forgetArgv()
                let answer = try session.call(tool, input)
                #expect(answer.isError, Comment(rawValue: "\(tool) accepted \(body.debugDescription)"))
                #expect(!FileManager().fileExists(atPath: harness.root.appendingPathComponent("last-argv.txt").path),
                        Comment(rawValue: "\(tool) reached AppleScript with \(body.debugDescription)"))
            }
        }
    }
}

/// The reply card
/// names the message by `oneLine(expect_subject)`, and the server found it by
/// its own `normaliseSubject`, which kept U+0085 and every invisible. Two
/// subjects the card drew alike were two messages to the server. The sweep is
/// the one the compose path uses, over the same Unicode-computed axis, run
/// through the shipped script's reply path in both directions.
@Suite("The reply card and the server find a message by one subject rule")
struct AppleMailReplySubjectRuleTests {
    @Test("A subject the card draws alike matches the real message, whichever side carries the character")
    func theCardsSubjectFindsTheSameMessage() throws {
        var units: [String] = []
        for value in UInt32(1)...0x10FFFF {
            // U+0009 is left out: the lookup's answer is tab-separated, and a
            // tab in a real subject cuts it short, which refuses (fails closed).
            guard value != 0x0009, let scalar = Unicode.Scalar(value) else { continue }
            let interesting: Bool
            switch scalar.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator,
                 .control, .format, .nonspacingMark, .spacingMark, .enclosingMark:
                interesting = true
            default:
                interesting = scalar.properties.isWhitespace
            }
            guard interesting else { continue }
            units.append(contentsOf: ["a\(scalar)b", "a \(scalar)b", "a\(scalar) b", "a \(scalar) b"])
        }
        for sentinel: UInt32 in [0x0085, 0x00A0, 0x200B, 0x200E, 0x2028, 0xFEFF] {
            let scalar = try #require(Unicode.Scalar(sentinel))
            #expect(units.contains("a \(scalar) b"), Comment(rawValue: String(format: "lost U+%04X", sentinel)))
        }
        var batches: [String] = [], batch = ""
        for unit in units {
            if batch.utf16.count + unit.utf16.count > 380 { batches.append(batch); batch = "" }
            batch += unit
        }
        if !batch.isEmpty { batches.append(batch) }
        let harness = try ScriptHarness(replyAnswer: "sent from me@example.test to 1 recipient(s)")
        defer { harness.remove() }
        let session = try ScriptSession(harness)
        defer { session.finish() }
        var refused: [String] = []
        for probe in batches {
            let drawn = ClaudeTextAppleMailSendApprovalPolicy.oneLine(probe)
            for (real, claim) in [(probe, drawn), (drawn, probe)] {
                try Data("9\tiCloud\t\(real)".utf8).write(to: harness.root.appendingPathComponent("resolve-answer.txt"))
                let answer = try session.call("reply_mail", ["rfc_message_id": "x@y", "body": "b",
                                                             "account": "iCloud", "expect_subject": claim])
                if answer.isError {
                    refused.append(probe.unicodeScalars.filter { $0.value > 0x7E || $0.value < 0x20 }
                        .prefix(6).map { String(format: "U+%04X", $0.value) }.joined(separator: " ") + ": " + answer.text.prefix(80))
                }
            }
        }
        #expect(refused.isEmpty, Comment(rawValue: "\(refused.count) refused, first: \(refused.prefix(3))"))
    }

    @Test("An invisible between a letter and its accent still matches the composed letter")
    func anInvisibleBeforeAnAccentMatches() throws {
        for hidden in ["\u{200B}", "\u{200F}", "\u{FEFF}"] {
            let harness = try ScriptHarness(resolveAnswer: "9\tiCloud\tCaf\u{00E9} plans")
            defer { harness.remove() }
            let answer = try harness.call("reply_mail", ["rfc_message_id": "x@y", "body": "b", "account": "iCloud",
                                                          "expect_subject": "Cafe\(hidden)\u{0301} plans"])
            #expect(!answer.isError, Comment(rawValue: answer.text))
        }
    }

    @Test("A claim that is only a reply prefix once its invisibles are gone is refused before Mail is asked")
    func aHiddenPrefixOnlyClaimIsRefused() throws {
        let harness = try ScriptHarness(resolveAnswer: "9\tiCloud\tAnything")
        defer { harness.remove() }
        let answer = try harness.call("reply_mail", ["rfc_message_id": "x@y", "body": "b", "account": "iCloud",
                                                      "expect_subject": "Re:\u{200B} \u{0085}"])
        #expect(answer.isError && answer.text.contains("only a reply prefix"), Comment(rawValue: answer.text))
    }

    @Test("A different subject is still refused")
    func aDifferentSubjectIsStillRefused() throws {
        let harness = try ScriptHarness(resolveAnswer: "9\tiCloud\tInvoice March")
        defer { harness.remove() }
        let answer = try harness.call("reply_mail", ["rfc_message_id": "x@y", "body": "b", "account": "iCloud",
                                                      "expect_subject": "Invoice May"])
        #expect(answer.isError && answer.text.contains("different subject"))
    }
}
