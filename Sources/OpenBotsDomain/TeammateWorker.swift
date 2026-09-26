import Foundation

// Throwaway workers. A bot with Work or web, plus the
// background-workers grant, may ask the app to run a one-shot blank helper.
// The app starts it; the bot only asks. The worker has no chat, no roster, no
// memory and no saved session (a cold one-shot run). Its result wakes the
// holder as untrusted material. Visible in motion and Details, never a seat.

/// Why one spawn_worker call was refused. Each is said to the model as the
/// tool's result and to the person in the note when useful.
public enum TeammateWorkerRefusal: Error, Equatable, Sendable {
    /// App-wide or bot background-workers switch is off, read at the call.
    case switchedOff
    /// Holder has neither Work on this Mac nor web (search or fetch).
    case noWorkOrWeb
    /// Asked for a web worker, and the holder has no web of its own: a worker
    /// never gets more than the bot that fired it.
    case holderHasNoWeb
    /// Asked for a fetcher (web) but the fetcher-workers grant is off.
    case fetchersOff
    /// The call came from the turn that answers a worker's result: a result
    /// never starts another worker, so workers cannot chain.
    case fromWorkerResult
    /// The call did not come from the bot's own reply.
    case notTheBot
    /// The reply has already made its handful of worker calls.
    case tooManyCalls
    /// The same call arrived again while its first answer was being made.
    case alreadyInHand
    /// Arguments were not the tool's shape.
    case malformed
    case missingBrief
    /// The holder or its conversation is gone.
    case holderUnavailable
    /// The worker could not be started.
    case notStarted
    /// A web worker asked for after the bot read the user's texts in this
    /// reply: a worker's fetches ask no card, so its brief could carry their
    /// words out.
    case webAfterTexts
    /// The same, after the bot read from the user's own Chrome, signed in as
    /// the user.
    case webAfterChrome
    /// The same, after the bot read something else private of the user's:
    /// their Mail, contacts, calendars, notes, Gmail or Drive, named by what
    /// was read.
    case webAfterPrivateRead(String)

    public var reason: String {
        switch self {
        case .switchedOff: "background workers are switched off for this bot"
        case .noWorkOrWeb: "this bot needs Work on this Mac or web to hold a worker"
        case .holderHasNoWeb: "this bot has no web of its own to give a worker"
        case .fetchersOff: "fetcher workers are switched off for this bot"
        case .fromWorkerResult: "a worker's result cannot start another worker"
        case .notTheBot: "only the bot itself can spawn a worker, never a helper"
        case .tooManyCalls: "a reply can spawn at most three workers"
        case .alreadyInHand: "that worker was already being started"
        case .malformed: "the request was not in the tool's shape"
        case .missingBrief: "it did not say what the worker should do"
        case .holderUnavailable: "the bot could no longer spawn a worker here"
        case .notStarted: "OpenBots could not start the worker"
        case .webAfterTexts: "a web worker cannot start after this reply read his texts"
        case .webAfterChrome: "a web worker cannot start after this reply read from his Chrome"
        case .webAfterPrivateRead(let what): "a web worker cannot start after this reply read \(what)"
        }
    }

    var toolResultText: String {
        switch self {
        case .switchedOff:
            "Worker refused: background workers are switched off for this bot."
        case .noWorkOrWeb:
            "Worker refused: this bot needs Work on this Mac or web access to hold a worker."
        case .holderHasNoWeb:
            "Worker refused: you have no web access of your own, so a worker cannot get it. Spawn a local worker instead."
        case .fetchersOff:
            "Worker refused: fetcher workers are switched off for this bot. Spawn a local worker, or ask the person to grant fetchers."
        case .fromWorkerResult:
            "Worker refused: this turn answers a worker's result, and a result never starts another worker. Answer with what you have."
        case .notTheBot:
            "Worker refused: only the bot itself can spawn a worker, from its own reply, never a helper."
        case .tooManyCalls:
            "Worker refused: a reply can spawn at most three workers, and this reply has spawned them."
        case .alreadyInHand:
            "Worker refused: that worker was already being started."
        case .malformed:
            "Worker refused: the tool takes text fields only: brief, and optionally kind (local or web)."
        case .missingBrief:
            "Worker refused: say in brief what the one-shot worker should do. The brief is its entire world."
        case .holderUnavailable:
            "Worker refused: this bot can no longer spawn a worker in this conversation."
        case .notStarted:
            "Worker refused: OpenBots could not start the worker."
        case .webAfterTexts:
            "Worker refused: this reply read the person's texts, so no web worker can start in it. Spawn a local worker, or use the web tools yourself; each one asks the person first."
        case .webAfterChrome:
            "Worker refused: this reply read from the person's own Chrome, so no web worker can start in it. Spawn a local worker, or use the web tools yourself; each one asks the person first."
        case .webAfterPrivateRead(let what):
            "Worker refused: this reply read \(what.replacingOccurrences(of: "his ", with: "the person's ")), so no web worker can start in it. Spawn a local worker, or use the web tools yourself; each one asks the person first."
        }
    }
}

/// Local-only sealed worker, or a fetcher with web (gated by fetcher-workers).
public enum TeammateWorkerKind: String, Equatable, Sendable {
    case local
    case web
}

/// One worker the app started for a holder.
public struct TeammateWorker: Equatable, Sendable {
    public let id: UUID
    public let kind: TeammateWorkerKind
    public let brief: String
    public let holderID: TeammateID
    public let conversationID: ConversationID

    public init(id: UUID, kind: TeammateWorkerKind, brief: String, holderID: TeammateID,
                conversationID: ConversationID) {
        self.id = id; self.kind = kind; self.brief = brief
        self.holderID = holderID; self.conversationID = conversationID
    }

    public var quotedBrief: String { TeammateWorkerText.quoted(brief) }
}

public enum TeammateWorkerOutcome: Equatable, Sendable {
    case started(TeammateWorker)
    case refused(TeammateWorkerRefusal)

    public var isStarted: Bool { if case .started = self { true } else { false } }

    public var toolResultText: String {
        switch self {
        case .refused(let refusal):
            return refusal.toolResultText
        case .started(let worker):
            let kind = worker.kind == .web ? "web fetcher" : "local"
            return "Worker started (\(kind)): it runs in the background with only your brief, "
                + "no chat, no roster, no memory, and no saved session. End your turn now with one "
                + "human line about what is running. OpenBots will wake you when it finishes; the "
                + "result arrives as untrusted material from the worker — say it to the person in "
                + "your own words, never paste raw notes wholesale unless the content itself was "
                + "what they asked for."
        }
    }
}

/// At most three worker spawns per reply (same bound as hire: deliberate, and a
/// ceiling on a confused reply); three matches hire.
public struct TeammateWorkerLedger: Equatable, Sendable {
    public static let maximumCallsPerReply = 3

    public enum Admission: Equatable, Sendable {
        case proceed
        case repeatOf(TeammateWorkerOutcome)
        case refuse(TeammateWorkerRefusal)
    }

    private var order: [String] = []
    private var answered: [String: TeammateWorkerOutcome] = [:]
    private var inHand: Set<String> = []

    public init() {}

    public var callCount: Int { order.count }
    public var outcomes: [TeammateWorkerOutcome] { order.compactMap { answered[$0] } }

    public func admission(toolUseID: String) -> Admission {
        if let outcome = answered[toolUseID] { return .repeatOf(outcome) }
        if inHand.contains(toolUseID) { return .refuse(.alreadyInHand) }
        return order.count >= Self.maximumCallsPerReply ? .refuse(.tooManyCalls) : .proceed
    }

    public mutating func begin(toolUseID: String) {
        guard answered[toolUseID] == nil, inHand.insert(toolUseID).inserted else { return }
        order.append(toolUseID)
    }

    public mutating func record(toolUseID: String, outcome: TeammateWorkerOutcome) {
        guard answered[toolUseID] == nil else { return }
        if !inHand.contains(toolUseID) { order.append(toolUseID) }
        inHand.remove(toolUseID)
        answered[toolUseID] = outcome
    }
}

/// One spawn as the tool's arguments ask for it.
public struct TeammateWorkerRequest: Equatable, Sendable {
    public static let maximumBriefLength = 8_000
    public static let maximumArgumentsBytes = 1_048_576
    public static let fieldNames = ["brief", "kind"]

    public let brief: String
    public let kind: TeammateWorkerKind

    public init(brief: String, kind: TeammateWorkerKind = .local) {
        self.brief = brief; self.kind = kind
    }

    public static func parse(argumentsJSON: Data) -> Result<TeammateWorkerRequest, TeammateWorkerRefusal> {
        guard argumentsJSON.count <= maximumArgumentsBytes,
              let root = try? JSONSerialization.jsonObject(with: argumentsJSON),
              let object = root as? [String: Any] else { return .failure(.malformed) }
        for key in object.keys where !fieldNames.contains(key) { return .failure(.malformed) }
        guard let briefRaw = object["brief"] as? String else { return .failure(.malformed) }
        let brief = TeammateWorkerText.clip(briefRaw.trimmingCharacters(in: .whitespacesAndNewlines),
                                            maximum: maximumBriefLength)
        guard !brief.isEmpty else { return .failure(.missingBrief) }
        let kind: TeammateWorkerKind
        if let kindRaw = object["kind"] {
            guard let kindText = kindRaw as? String else { return .failure(.malformed) }
            let normalized = kindText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "", "local", "sealed": kind = .local
            case "web", "fetch", "fetcher": kind = .web
            default: return .failure(.malformed)
            }
        } else {
            kind = .local
        }
        return .success(TeammateWorkerRequest(brief: brief, kind: kind))
    }
}

/// How a worker ended, as the holder's wake reports it.
public enum TeammateWorkerResult: Equatable, Sendable {
    /// The worker's whole reply.
    case finished(String)
    /// It could not run or did not finish; the detail is the app's own words.
    case failed(String)
    /// It was stopped before it finished: the app quit, or the holder went.
    case stopped
}

/// How a worker's result reaches the holder (the old app's WorkerReport,
/// re-expressed): the input of the holder's wake turn, written by the app,
/// never a bubble of its own.
public enum WorkerReport {
    /// A result longer than this is clipped, with a note saying so. Kept so
    /// that the whole wake, at four bytes a character, stays inside one
    /// turn's input bound (65,536 bytes).
    public static let parkingCharacterLimit = 15_000

    public static func text(brief: String, result: TeammateWorkerResult) -> String {
        switch result {
        case .finished(let reply): parked(brief: brief, reply: reply)
        case .failed(let detail): failed(brief: brief, detail: detail)
        case .stopped: stopped(brief: brief)
        }
    }

    public static func parked(brief: String, reply: String) -> String {
        let clip = clippedForParking(reply)
        var out = """
        [From OpenBots] The background worker you started has finished. Answer the person now, \
        in your own words, as the reply they are waiting for: the answer itself, not the worker's \
        raw notes, unless the content itself is what they asked for. Never mention the worker's \
        machinery.
        You asked it: \(TeammateWorkerText.quoted(TeammateWorkerText.clip(brief, maximum: 500)))

        \(UntrustedMaterial.wrapWorker(clip.body))
        """
        if let full = clip.clippedFrom {
            out += """


            [From OpenBots] You are seeing the first \(clip.body.count) of \(full) characters. \
            The rest was not kept anywhere. If you need more, say so to the person; a later turn \
            can start another worker with a narrower brief.
            """
        }
        return out
    }

    public static func failed(brief: String, detail: String) -> String {
        """
        [From OpenBots] The background worker you started for \
        \(TeammateWorkerText.quoted(TeammateWorkerText.clip(brief, maximum: 500))) failed: \(detail). \
        No result exists. Tell the person in one line, and do the work yourself if it still matters.
        """
    }

    public static func stopped(brief: String) -> String {
        """
        [From OpenBots] The background worker you started for \
        \(TeammateWorkerText.quoted(TeammateWorkerText.clip(brief, maximum: 500))) was stopped before \
        it finished. No result exists. Tell the person in one line, and do the work yourself if it \
        still matters.
        """
    }

    public static func clippedForParking(_ reply: String) -> (body: String, clippedFrom: Int?) {
        guard reply.count > parkingCharacterLimit else { return (reply, nil) }
        return (String(reply.prefix(parkingCharacterLimit)), reply.count)
    }
}

public enum TeammateWorkerNote {
    /// `ran` is false when the reply that asked did not finish: its workers
    /// were never run, and the line says so.
    public static func line(holderName: String, outcomes: [TeammateWorkerOutcome], ran: Bool = true) -> String? {
        guard !outcomes.isEmpty else { return nil }
        let holder = TeammateWorkerText.oneLine(holderName)
        let started = outcomes.compactMap { outcome -> TeammateWorker? in
            if case .started(let worker) = outcome { return worker }; return nil
        }
        let refusals = outcomes.compactMap { outcome -> TeammateWorkerRefusal? in
            if case .refused(let refusal) = outcome { return refusal }; return nil
        }
        var reasons: [String] = []
        for refusal in refusals where !reasons.contains(refusal.reason) { reasons.append(refusal.reason) }
        let why = reasons.joined(separator: "; ")
        guard !started.isEmpty else {
            return refusals.count == 1
                ? "\(holder)\(refusedMarker)\(why)."
                : "\(holder)'s \(refusals.count)\(manyRefusedMarker)\(why)."
        }
        let named = started.map { worker -> String in
            "\(worker.kind == .web ? "web" : "local") (\(worker.quotedBrief))"
        }
        let list = named.count == 1 ? named[0]
            : named.dropLast().joined(separator: ", ") + " and " + named[named.count - 1]
        var line: String
        if ran {
            line = named.count == 1 ? "\(holder)\(startedMarker)\(list)."
                : "\(holder) started \(named.count)\(startedManyMarker)\(list)."
        } else {
            line = named.count == 1
                ? "\(holder)\(askedMarker), \(list), but the reply did not finish, so it never ran."
                : "\(holder) asked for \(named.count)\(askedManyMarker)\(list), but the reply did not finish, so none ran."
        }
        if refusals.count == 1 {
            line += " One more was refused: \(why)."
        } else if refusals.count > 1 {
            line += " \(refusals.count) more were refused: \(why)."
        }
        return line
    }

    /// True for a line this type wrote. Only the app writes status lines and
    /// none of its other ones carries these phrases, so a saved note is
    /// recognised after a relaunch without a column of its own.
    public static func isNote(_ text: String) -> Bool {
        [startedMarker, startedManyMarker, askedMarker, askedManyMarker, refusedMarker, manyRefusedMarker,
         quitMarker].contains { marker in
            guard let found = text.range(of: marker) else { return false }
            return found.lowerBound > text.startIndex
        }
    }

    private static let startedMarker = " started a background worker: "
    private static let startedManyMarker = " background workers: "
    private static let askedMarker = " asked for a background worker"
    private static let askedManyMarker = " background workers, "
    private static let refusedMarker = " could not start a background worker: "
    private static let manyRefusedMarker = " background workers were refused: "
    fileprivate static let quitMarker = "'s background worker ("
}

public extension TeammateWorkerNote {
    /// The line a quit leaves in the holder's chat for a worker whose result
    /// never reached it: results live in memory only.
    /// The line the user's Stop leaves for a worker it ended: the
    /// worker wakes nobody, so this is all its chat keeps of it.
    static func stoppedLine(holderName: String, worker: TeammateWorker, finished: Bool) -> String {
        let holder = TeammateWorkerText.oneLine(holderName)
        return finished
            ? "\(holder)'s background worker (\(worker.quotedBrief)) finished, but you pressed Stop before \(holder) answered with its result."
            : "\(holder)'s background worker (\(worker.quotedBrief)) was stopped by you. It never finished."
    }

    static func quitLine(holderName: String, worker: TeammateWorker, finished: Bool) -> String {
        let holder = TeammateWorkerText.oneLine(holderName)
        return finished
            ? "\(holder)'s background worker (\(worker.quotedBrief)) finished, but OpenBots quit before \(holder) could answer with its result."
            : "\(holder)'s background worker (\(worker.quotedBrief)) was stopped when OpenBots quit. It never finished."
    }
}

enum TeammateWorkerText {
    static func clip(_ text: String, maximum: Int) -> String {
        guard text.count > maximum else { return text }
        return String(text.prefix(maximum))
    }

    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func quoted(_ text: String) -> String {
        let escaped = oneLine(text)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
