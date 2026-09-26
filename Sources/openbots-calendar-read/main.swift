import EventKit
import Foundation

/*
 * openbots-calendar-read — the app's own read-only window onto Calendar.
 *
 * WHY A BINARY AND NOT JXA, which is what `apple-contacts.js` uses. Two checks
 * came before any code, and both of them came back against Apple Events,
 * measured against a well-filled calendar store:
 *
 *   - A per-calendar `events.whose({start date ≥ … ≤ …})` over several
 *     calendars can take tens of seconds for ANY window — about the same for a
 *     week, a month or a year. The cost is per event STORED, not per event found (a few ms
 *     each, and bulk column reads cost the same), so a range cap is the wrong
 *     lever entirely. EventKit answers the same questions in milliseconds.
 *   - Worse, and decisive: a recurring event has ONE `start date`, its first,
 *     and `iCal.sdef` exposes `recurrence` only as an RRULE string with no
 *     excluded dates and no recurrence-id. So a series cannot be expanded
 *     correctly at any price. Over a year JXA misses most occurrences of
 *     recurring events that EventKit finds, and even over the next month a
 *     `whose start date` query misses a large share of them.
 *   - A third defect: `calendarIdentifier` is IN the sdef and unreadable
 *     through the bridge ("Can't convert types"), and two calendars can both
 *     be named "Calendar" — so a JXA `list_calendars` could not keep its
 *     promise. EventKit has the identifier.
 *
 * WHAT THIS IS NOT. It is not the MCP server. `apple-calendar.js` is, and it
 * keeps the read-only dispatch table, the argv discipline and the fence exactly
 * as Contacts has them. This binary is the seam that file already had for
 * `osascript`: a program that takes a verb and values as argv, prints one JSON
 * object, and decides nothing about what is shown. It compares nothing, folds
 * nothing and filters no text — the ONE NORMALISER rule of the Contacts reader
 * is why, and it holds here for the same reason.
 *
 * READ-ONLY BY CONSTRUCTION. Three verbs, and no EventKit write API is called
 * anywhere in this file: no `save`, no `remove`, no `EKEvent(eventStore:)`.
 * There is no verb for one to be reached through.
 */

// ───────────────────────────────────────────────────────────────── Plumbing

/// The cap on how many events one answer may carry. A bot that asks for more
/// gets the cap, and the answer says how many matched in all — so "there are
/// forty things that week" is still an answer it can act on, rather than a
/// truncation it cannot see. It is not needed for speed (EventKit is fast);
/// it is kept because an unbounded list in front of a model is its own problem.
let maximumEvents = 100
let defaultEvents = 50

struct HelperError: Error { let message: String }

func fail(_ message: String) -> Never {
    let payload = ["error": message]
    if let data = try? JSONSerialization.data(withJSONObject: payload),
       let text = String(data: data, encoding: .utf8) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
    exit(1)
}

func emit(_ object: [String: Any]) -> Never {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: data, encoding: .utf8) else {
        fail("The calendar reader could not encode its answer.")
    }
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
    exit(0)
}

/// Dates cross this boundary as ISO 8601 with an offset, both ways. A bare
/// "2026-09-12" would be read in whichever zone each side happened to assume,
/// and a day boundary read in the wrong zone moves every all-day event.
// `nonisolated(unsafe)` because a formatter is not Sendable and every verb
// below is a plain function. It is written once here and only read after,
// and this process is single-threaded past the access callback.
nonisolated(unsafe) let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    // THIS MAC's zone, not GMT, which is what ISO8601DateFormatter uses if it
    // is not told. Without it an all-day event in a UTC+2 zone comes back as
    // the previous day at 22:00Z under a header naming the event's own day —
    // two dates for one event, and the one a model would quote back is the wrong
    // one. Parsing is unaffected: a string carrying its own offset still reads
    // as the instant it names.
    f.timeZone = .current
    return f
}()

func parseDate(_ value: String, _ what: String) -> Date {
    if let date = isoFormatter.date(from: value) { return date }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: value) { return date }
    fail("\(what) is not an ISO 8601 date and time with a zone offset: \(value)")
}

/// `--name value` pairs, and nothing else. Values never become part of a query
/// language here — EventKit takes them as typed arguments — so there is no
/// string for one to break out of.
func options(_ arguments: [String]) -> [String: String] {
    var result: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let token = arguments[index]
        guard token.hasPrefix("--") else { fail("unexpected argument: \(token)") }
        let key = String(token.dropFirst(2))
        guard index + 1 < arguments.count else { fail("--\(key) needs a value") }
        result[key] = arguments[index + 1]
        index += 2
    }
    return result
}

// ────────────────────────────────────────────────────────────────── Access

/// What the wait for Calendar access came to.
enum CalendarAccessAnswer: Equatable {
    /// EventKit's own completion said yes.
    case granted
    /// The completion never came, but the status turned to full access while
    /// waiting. The store asked before the grant may not see calendars yet.
    case grantedByStatus
    case refused(String?)
    case timedOut
}

/// The completion's answer, written from whichever queue EventKit uses.
final class AccessReply: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Bool, String?)?
    func set(_ granted: Bool, _ error: (any Error)?) {
        lock.withLock { value = (granted, error?.localizedDescription) }
    }
    var answer: (Bool, String?)? { lock.withLock { value } }
}

/// Waits for EventKit's answer without trusting the completion alone (the
/// first read after the prompt could otherwise take the full 120 s).
///
/// The old wait blocked the main thread on a semaphore that only the
/// completion could signal. If EventKit delivers that completion on the main
/// queue, it could not run until the deadline, whatever the user clicked. So every
/// `pollInterval` this spins the main run loop (letting such a completion
/// land) and reads the status itself: full access goes on at once, denied or
/// restricted stops at once. Write-only access is not full access and keeps
/// waiting. Which of the two causes it was is unproved; this covers both.
/// Proving it live needs a reset of the user's Calendars permission.
///
/// Everything comes in as a parameter, so the tests drive it without EventKit
/// and without touching this file's globals (under test the top-level code
/// below never runs).
func awaitCalendarAccess(
    request: (@escaping @Sendable (Bool, (any Error)?) -> Void) -> Void,
    status: () -> EKAuthorizationStatus,
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.5
) -> CalendarAccessAnswer {
    // Already allowed: no prompt, no wait, and the store made before this call
    // is the one to use. Only a
    // status that turns full DURING the wait means the store predates the grant.
    if status() == .fullAccess { return .granted }
    let reply = AccessReply()
    let arrived = DispatchSemaphore(value: 0)
    request { ok, error in reply.set(ok, error); arrived.signal() }
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if let (ok, message) = reply.answer { return ok ? .granted : .refused(message) }
        switch status() {
        case .fullAccess: return .grantedByStatus
        case .denied, .restricted: return .refused(nil)
        default: break
        }
        let left = deadline.timeIntervalSinceNow
        if left <= 0 { return .timedOut }
        let slice = min(pollInterval, left)
        let started = Date()
        // On the main thread this services the main queue. Off it (tests), or
        // when the run loop returns early, the semaphore covers the rest.
        _ = RunLoop.current.run(mode: .default, before: started.addingTimeInterval(slice))
        let rest = slice - Date().timeIntervalSince(started)
        if rest > 0 { _ = arrived.wait(timeout: .now() + rest) }
    }
}

/// Ask once, synchronously, and say plainly which System Settings pane the user
/// needs if the answer is no.
///
/// This is NOT the Automation pane the mail and contacts rows send the user
/// to — EventKit sends no Apple Events — and naming the wrong pane sends the
/// user to fix the wrong thing, so the sentence names the right one.
func authorizedStore() -> EKEventStore {
    let store = EKEventStore()
    // Generous on purpose: the first call puts a prompt on the user's screen
    // and they have to read it. A short deadline here would report "refused"
    // for someone who was still reaching for the mouse.
    let answer = awaitCalendarAccess(
        request: { store.requestFullAccessToEvents(completion: $0) },
        status: { EKEventStore.authorizationStatus(for: .event) },
        timeout: 120)
    switch answer {
    case .granted:
        return store
    case .grantedByStatus:
        // Asked before the grant, this store may still see no calendars, and
        // "no calendars" would be a quiet wrong answer. A fresh one is cheap.
        return EKEventStore()
    case .timedOut:
        fail("Calendar access was neither allowed nor refused in time. If a permission prompt is "
            + "waiting on screen, answer it and try again.")
    case .refused(let message):
        let detail = message.map { ": \($0)" } ?? ""
        fail("Calendar refused\(detail)\n(Calendars must be allowed for OpenBots Next in System "
            + "Settings → Privacy & Security → Calendars. This is NOT the Automation pane the mail "
            + "and contacts connectors use — macOS asks about calendars separately.)")
    }
}

// ─────────────────────────────────────────────────────────────── Rendering

/// An event as a dictionary. Every value is either a string, a number, a bool
/// or null — never a date object — so the JSON that reaches node has one shape
/// and a parser can check it.
///
/// `start` and `end` are the OCCURRENCE's, not the series': EventKit hands back
/// an expanded occurrence, which is the whole reason this binary exists.
func describe(_ event: EKEvent) -> [String: Any] {
    [
        // An event with no identifier cannot be read again, and an empty string
        // is a handle a model will try to use. Null says plainly there is none.
        "uid": event.eventIdentifier.map { $0 as Any } ?? NSNull(),
        "summary": event.title ?? "",
        "start": event.startDate.map { isoFormatter.string(from: $0) } as Any? ?? NSNull(),
        "end": event.endDate.map { isoFormatter.string(from: $0) } as Any? ?? NSNull(),
        "allDay": event.isAllDay,
        "location": event.location ?? "",
        "calendar": event.calendar?.title ?? "",
        "calendarId": event.calendar?.calendarIdentifier ?? "",
        "recurring": event.hasRecurrenceRules,
    ]
}

// ──────────────────────────────────────────────────────────────── The verbs

func listCalendars(_ store: EKEventStore) -> Never {
    // Event calendars only. A Mac can also carry "Scheduled Reminders" and
    // "Siri Suggestions", which hold no events and which the Apple Events
    // bridge counts as calendars; they are not calendars a bot can be
    // asked about.
    let calendars = store.calendars(for: .event).map { calendar -> [String: Any] in
        [
            "id": calendar.calendarIdentifier,
            "name": calendar.title,
            "writable": calendar.allowsContentModifications,
            "account": calendar.source?.title ?? "",
        ]
    }
    emit(["calendars": calendars])
}

func searchEvents(_ store: EKEventStore, _ opts: [String: String]) -> Never {
    guard let fromText = opts["from"] else { fail("--from is required") }
    guard let toText = opts["to"] else { fail("--to is required") }
    let from = parseDate(fromText, "--from")
    let to = parseDate(toText, "--to")
    guard to > from else { fail("--to must be after --from") }

    var limit = defaultEvents
    if let text = opts["limit"] {
        guard let value = Int(text), value > 0 else { fail("--limit must be a whole number above zero") }
        limit = min(value, maximumEvents)
    }

    var calendars: [EKCalendar]? = nil
    if let identifier = opts["calendar"] {
        guard let match = store.calendar(withIdentifier: identifier) else {
            fail("There is no calendar with the id \(identifier) on this Mac. Call list_calendars first.")
        }
        calendars = [match]
    }

    let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
    var events = store.events(matching: predicate)
    // EventKit's own ordering is not documented as chronological, and a bot
    // reading "what is on Thursday" will read the first line as the first
    // thing. Sorted here, once, before anything is dropped by the cap.
    events.sort { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }

    // The text match is the ONE place words are compared, and it happens here
    // rather than in a predicate, so the bridge decides nothing about matching.
    if let query = opts["query"], !query.trimmingCharacters(in: .whitespaces).isEmpty {
        let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        events = events.filter { event in
            let haystack = [event.title, event.location, event.notes]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    let total = events.count
    let shown = Array(events.prefix(limit))
    emit([
        "events": shown.map(describe),
        "total": total,
        // Said, not implied. A quietly truncated list is a list a bot believes
        // is complete.
        "capped": total > shown.count,
        // A cold Calendar can answer before iCloud has filled it in, so "no
        // events" and "no calendars to look in" are different answers and the
        // caller is told which it has.
        "calendarsSearched": (calendars ?? store.calendars(for: .event)).count,
    ])
}

func readEvent(_ store: EKEventStore, _ opts: [String: String]) -> Never {
    guard let uid = opts["uid"] else { fail("--uid is required") }

    // A recurring series shares one identifier across every occurrence, so an
    // identifier alone cannot name a Thursday. When the caller passes the
    // occurrence's start — search_events always prints one — the occurrence is
    // found by looking in a window around it and matching the identifier, which
    // is the only way to read the right one of fifty-two.
    var found: EKEvent?
    var askedForOccurrence = false
    var matchedOccurrence = false

    // A DAY was named, not an instant: any occurrence starting that local day
    // is the one meant. Sent as its own argument because normalising a day to
    // midnight and matching it as an instant reported a live weekly series as
    // gone — no occurrence starts at midnight.
    if let dayText = opts["start-day"] {
        let dayStart = parseDate(dayText, "--start-day")
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        found = store.events(matching: predicate)
            .filter { $0.eventIdentifier == uid }
            .min { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
        askedForOccurrence = true
        matchedOccurrence = found != nil
    }

    if let startText = opts["start"], found == nil {
        let start = parseDate(startText, "--start")
        let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-86400),
                                                 end: start.addingTimeInterval(86400),
                                                 calendars: nil)
        found = store.events(matching: predicate).first { event in
            event.eventIdentifier == uid
                && abs((event.startDate ?? .distantPast).timeIntervalSince(start)) < 1
        }
        // Fall through to the series' own answer rather than refusing: a start
        // that no longer names an occurrence (the user moved it) should still read.
        // But the caller is TOLD, below — a bot that asked for Thursday and was
        // handed the series' first occurrence months earlier would read that
        // date and believe it, which is the same quiet lie as a truncated list.
        askedForOccurrence = true
        matchedOccurrence = found != nil
    }
    if found == nil {
        found = store.event(withIdentifier: uid)
    }
    guard let event = found else {
        fail("There is no event with that id on this Mac. Ids come from search_events; never invent one.")
    }

    var payload = describe(event)
    // Two separate facts, because conflating them hid a defect. `Matched` is
    // false only when an occurrence WAS asked for and none was found. `Asked`
    // says whether one was named at all — and for a recurring series that was
    // not, what comes back is `event(withIdentifier:)`, the series' FIRST
    // occurrence, which can be months from the day the caller had in mind.
    payload["occurrenceMatched"] = askedForOccurrence ? matchedOccurrence : true
    payload["occurrenceAsked"] = askedForOccurrence
    payload["notes"] = event.notes ?? ""
    payload["url"] = event.url?.absoluteString ?? ""
    payload["status"] = {
        switch event.status {
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "cancelled"
        default: return ""
        }
    }()
    // A bot may read attendees' names AND their email addresses, so it can
    // write to everyone on a meeting without the user looking them up.
    payload["attendees"] = (event.attendees ?? []).map { attendee -> [String: Any] in
        [
            "name": attendee.name ?? "",
            // EventKit hands an attendee's address back as a mailto: URL.
            "email": attendee.url.scheme?.lowercased() == "mailto"
                ? attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                : attendee.url.absoluteString,
            "status": {
                switch attendee.participantStatus {
                case .accepted: return "accepted"
                case .declined: return "declined"
                case .tentative: return "tentative"
                case .pending: return "pending"
                default: return ""
                }
            }(),
            // Whether THIS attendee is the one who called the meeting — not
            // whether the organiser happens to be the user, which is a
            // different question and the one this line asked until it was run
            // against a real calendar and answered false for every row.
            "organizer": event.organizer.map { $0.url == attendee.url } ?? false,
            "isMe": attendee.isCurrentUser,
        ]
    }
    // Who called the meeting, said once at the top rather than left to be
    // inferred from a flag on a list a bot may have to scan.
    payload["organizer"] = event.organizer?.name ?? ""
    // Alarms are deliberately absent: a reminder time tells a bot nothing and
    // is one more thing to render.
    emit(["event": payload])
}

// ───────────────────────────────────────────────────────────────── Dispatch

/// Read-only is this table, not a flag. There is no fourth entry, and no
/// EventKit write call anywhere above for a fourth entry to reach.
let arguments = Array(CommandLine.arguments.dropFirst())
guard let verb = arguments.first else {
    fail("usage: openbots-calendar-read <list_calendars|search_events|read_event> [--name value …]")
}
let rest = options(Array(arguments.dropFirst()))

switch verb {
case "list_calendars": listCalendars(authorizedStore())
case "search_events": searchEvents(authorizedStore(), rest)
case "read_event": readEvent(authorizedStore(), rest)
default: fail("unknown verb: \(verb)")
}
