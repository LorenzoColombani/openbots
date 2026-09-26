#!/usr/bin/env node
"use strict";
/*
 * OpenBots apple-calendar — read-only reads of the user's own calendars.
 *
 * WHY THIS ROW EXISTS. A bot that reads the user's mail and looks people up in
 * Contacts still cannot answer "am I free Thursday" or "when is the conference
 * trip", and it cannot reason about anything it cannot see. A bot reads the
 * user's calendar with the switch on and cannot with it off.
 *
 * WHY THIS ONE IS NOT JXA, where `apple-contacts.js` is. Two checks were made
 * before any code and both came back against Apple Events:
 *
 *   - A `whose start date >= ... <= ...` query can take tens of SECONDS for any
 *     window — a week, a month and a year cost about the same, because the
 *     cost is per event STORED, not per event found. EventKit answers the same
 *     queries in milliseconds.
 *   - And, decisively, a recurring event has ONE start date, its first. Over a
 *     year the Apple Events reader misses every later occurrence of a repeating
 *     event — most of a busy calendar. It cannot be repaired: `iCal.sdef`
 *     gives `recurrence` as an RRULE string with no excluded dates and no
 *     recurrence-id, so a series cannot be expanded correctly at any price.
 *
 * So the reads happen in `openbots-calendar-read`, a small binary shipped in
 * the app bundle, and this file is what it always was for Contacts: the MCP
 * server, the read-only dispatch table, and the one place words are folded
 * before they are printed. The seam is the same one `apple-contacts.js` has for
 * `osascript` — a program that takes a verb and values as ARGV and hands back
 * one JSON object.
 *
 * READ-ONLY BY CONSTRUCTION, not by a flag. Three tools, three handlers, and no
 * writing verb anywhere in this file or in the binary it calls for one to be
 * reached through.
 *
 * VALUES TRAVEL AS ARGV. Nothing a bot types is ever interpolated into a
 * command line as text; every value is a separate argument, so there is no
 * string for one to break out of.
 *
 * ONE NORMALISER. The card in the app and the sender's own script drifted twice
 * over how they folded a subject. So folding
 * happens HERE, in node, in `oneLine`, and the binary compares and folds
 * nothing.
 *
 * NOTHING IS LAUNCHED. Contacts and Mail are driven by Apple Events, so their
 * readers start the app hidden first. EventKit reads the store directly:
 * Calendar.app need not be running, and this server never starts it. There is
 * no `pgrep`, no `open -g -j`, and no window to keep off the user's screen.
 */

const { execFile } = require("child_process");

// Env overrides are for TESTS ONLY (stub programs); production never sets them.
// The helper's path is resolved on the Swift side and passed in, so the row's
// badge and the program this actually runs cannot be two different copies —
// the failure that comes of looking the same thing up twice.
const HELPER = process.env.OPENBOTS_CALENDAR_HELPER || "";
// The app name comes in from the Swift side so the permission hint names the
// app the user will actually find in System Settings.
const APP_NAME = process.env.OPENBOTS_APP_NAME || "OpenBots Next";

/// The most events one answer may put in front of the model, and the default.
/// A bot that asks for more gets the cap, and the answer says how many matched
/// in all — a quietly truncated list is one a bot believes is complete. The cap
/// is enforced in the binary too; this pair is what the tool description
/// promises.
const MAX_RESULTS = 100;
const DEFAULT_RESULTS = 50;

/// How far a bare `search_events` looks when it is given no window at all.
const DEFAULT_WINDOW_DAYS = 7;
/// The widest window one call may ask for. Not a timing budget — a year costs
/// 18 ms — but a guard on how much can land in one answer.
const MAX_WINDOW_DAYS = 1100;

function run(cmd, args) {
    return new Promise((resolve, reject) => {
        execFile(cmd, args, { maxBuffer: 16 * 1024 * 1024, timeout: 180000 },
            (err, stdout, stderr) => {
                if (err) {
                    err.stderr = String(stderr || "");
                    err.stdout = String(stdout || "");
                    return reject(err);
                }
                resolve(String(stdout));
            });
    });
}

function readJSON(text) {
    const trimmed = String(text || "").trim();
    if (!trimmed) return null;
    try { return JSON.parse(trimmed); } catch (_) { return null; }
}

/// What each verb's answer must look like. The boundary between this server and
/// the reader is a contract, and until this existed nothing checked it: valid
/// JSON of the wrong shape passed the parse and the `error` test, and each
/// caller's own `Array.isArray(...) ? ... : []` then rendered it as "nothing
/// found". A reader that had broken reported an EMPTY CALENDAR — the most
/// plausible-looking wrong answer this connector can give.
const SHAPES = {
    list_calendars: (a) => Array.isArray(a.calendars),
    search_events: (a) => Array.isArray(a.events)
        && typeof a.total === "number" && typeof a.calendarsSearched === "number",
    read_event: (a) => a.event !== null && typeof a.event === "object",
};

/// One run of the reader. Every value the caller supplied is already a separate
/// element of `args`.
async function helper(args) {
    if (!HELPER) {
        throw new Error("This build is missing the calendar reader. Reinstall the app.");
    }
    let out;
    try {
        out = await run(HELPER, args);
    } catch (err) {
        // The binary prints its own JSON `error` and exits non-zero when it has
        // something to say — a refused permission above all — so that sentence
        // is preferred over the process failure that carried it.
        const said = readJSON(err.stdout);
        if (said && typeof said.error === "string") throw new Error(said.error);
        // A killed child says only "Command failed", which names nothing a
        // person could act on. The likeliest reason it was killed is the
        // permission prompt sitting unanswered on the user's screen.
        if (err.killed || err.signal) {
            throw new Error("The calendar reader did not finish in time. If a permission prompt "
                + "is waiting on screen, answer it and ask again.");
        }
        throw err;
    }
    const parsed = readJSON(out);
    if (parsed === null) {
        throw new Error("The calendar reader returned something this server cannot read: "
            + String(out).trim().slice(0, 200));
    }
    if (typeof parsed.error === "string") throw new Error(parsed.error);
    const shape = SHAPES[args[0]];
    if (shape && !shape(parsed)) {
        throw new Error("The calendar reader returned something this server cannot read. "
            + "This is not the same as an empty calendar.");
    }
    return parsed;
}

// --------------------------------------------------------------- Dates

/// A bot says "2026-09-17"; the user's Mac means midnight in THEIR zone, not in UTC.
/// A day boundary read in the wrong zone moves every all-day event by a day,
/// so the expansion happens here, where the local zone is known, and crosses
/// into the binary as an offset-bearing ISO string.
function startOfLocalDay(text) {
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text);
    if (!m) return null;
    return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), 0, 0, 0, 0);
}

/// N calendar days after a date, in the local zone — which is not the same as
/// N x 86,400,000 milliseconds, and the difference is exactly the bug that made
/// a query for 25 October 2026 end at 23:00 and report "nothing that day" for
/// an event at 23:15. A day the clocks change is 23 or 25 hours long, and only
/// the calendar-field construction knows that. `startOfLocalDay` above already
/// built dates this way; the window did not, so there were two notions of a day
/// in one file.
function addLocalDays(date, days) {
    return new Date(date.getFullYear(), date.getMonth(), date.getDate() + days,
                    date.getHours(), date.getMinutes(), date.getSeconds(),
                    date.getMilliseconds());
}

function parseWhen(value, what) {
    if (value === undefined || value === null || value === "") return null;
    const text = String(value).trim();
    const day = startOfLocalDay(text);
    if (day) return day;
    const parsed = new Date(text);
    if (Number.isNaN(parsed.getTime())) {
        throw new Error(what + " is not a date this server understands. Use YYYY-MM-DD, "
            + "or a full date and time such as 2026-09-17T14:00:00+02:00.");
    }
    return parsed;
}

/// ISO 8601 with this Mac's own offset — what the binary parses.
function isoLocal(date) {
    const pad = (n) => String(Math.abs(n)).padStart(2, "0");
    const offset = -date.getTimezoneOffset();
    const sign = offset >= 0 ? "+" : "-";
    return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate())
        + "T" + pad(date.getHours()) + ":" + pad(date.getMinutes()) + ":" + pad(date.getSeconds())
        + sign + pad(Math.floor(Math.abs(offset) / 60)) + ":" + pad(Math.abs(offset) % 60);
}

const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/// How an event's time reads in the answer. Written here rather than taken from
/// `toLocaleString`, whose output depends on the Mac's region and would make
/// the same event read two ways on two machines.
function whenText(startText, endText, allDay) {
    const start = startText ? new Date(startText) : null;
    const end = endText ? new Date(endText) : null;
    if (!start || Number.isNaN(start.getTime())) return "(no date)";
    const pad = (n) => String(n).padStart(2, "0");
    const dayOf = (d) => DAYS[d.getDay()] + " " + d.getDate() + " " + MONTHS[d.getMonth()] + " " + d.getFullYear();
    const timeOf = (d) => pad(d.getHours()) + ":" + pad(d.getMinutes());
    if (allDay) {
        // An all-day event ends a second before the next midnight, so the raw
        // end date reads as the following day and a one-day event would print
        // as two.
        if (!end || Number.isNaN(end.getTime())) return dayOf(start) + " (all day)";
        const lastDay = new Date(end.getTime() - 1000);
        const same = lastDay.toDateString() === start.toDateString();
        return same ? dayOf(start) + " (all day)"
                    : dayOf(start) + " to " + dayOf(lastDay) + " (all day)";
    }
    if (!end || Number.isNaN(end.getTime())) return dayOf(start) + ", " + timeOf(start);
    const sameDay = end.toDateString() === start.toDateString();
    return sameDay ? dayOf(start) + ", " + timeOf(start) + "-" + timeOf(end)
                   : dayOf(start) + ", " + timeOf(start) + " to " + dayOf(end) + ", " + timeOf(end);
}

// ----------------------------------------------------------- Rendering

/// Every value becomes part of a line-per-fact answer, so a title holding a
/// line break could write a line of its own — a second "calendar:" under a real
/// event, or a fake "id:" the bot would then pass to read_event. An invitation's
/// title, location and notes are written by whoever sent it, so every one of
/// them is folded to a single line before it becomes part of a line. Notes are
/// the single exception and are handled where they are rendered: their lines
/// are real, and they are indented under their own heading rather than left at
/// the margin.
/// The answer's own structure lives at exactly this depth, and nowhere else
/// writes at it. Named once because the earlier version of this file chose the
/// same four spaces twice — in `renderEvent` and in `indented` — and a
/// stranger's notes landed exactly where the answer's own facts sit, so every
/// one of `id:`, `calendar:`, `occurrence:`, `organiser:`, `status:`, `url:`
/// and the NOTE line was forgeable. Two writers, one convention, no single
/// place holding it: the drift this repo keeps rediscovering.
const FACT = "    ";
/// A deeper level for a list the answer itself writes, such as the attendees.
const SUB = "        ";
/// And the mark every line of someone else's prose carries. It is a PREFIX, not
/// an indent, because depth alone can always be matched by a line of prose —
/// the quote mark cannot, since no structural line above ever carries one.
const QUOTED = "    > ";

function oneLine(value) {
    return String(value === null || value === undefined ? "" : value)
        .replace(/[\r\n\u2028\u2029\u0085]+/g, " ")
        .replace(/\s+/g, " ")
        .trim();
}

/// A block of someone else's prose, every line of it marked as quoted so that
/// none of them can pass for a line this answer wrote.
///
/// The line breaks are kept — it is prose, and folding it would lose the
/// paragraphs — so the fold that protects every other value is not available
/// here. The quote mark is what replaces it, and it is added to EVERY line
/// including blank ones, so there is no gap for a line to sit in unmarked.
function quoted(value) {
    return String(value === null || value === undefined ? "" : value)
        // Vertical tab and form feed are in here with the unicode separators
        // because some readers break a line on them. `oneLine` folds them
        // everywhere else; a note that kept one would have put an unquoted line
        // at the margin in whatever renders this next.
        .replace(/[\u000B\u000C\u2028\u2029\u0085]/g, "\n")
        .replace(/\r\n?/g, "\n")
        .split("\n").map((line) => QUOTED + line.trim()).join("\n")
        .trimEnd();
}

function renderEvent(event) {
    const lines = [];
    const title = oneLine(event.summary) || "(no title)";
    lines.push(whenText(event.start, event.end, !!event.allDay) + " - " + title);
    const facts = [];
    if (oneLine(event.calendar)) facts.push("calendar: " + oneLine(event.calendar));
    if (event.recurring) facts.push("repeats");
    if (oneLine(event.location)) facts.push("where: " + oneLine(event.location));
    if (facts.length) lines.push(FACT + facts.join(" | "));
    lines.push(FACT + "id: " + oneLine(event.uid));
    if (event.start) lines.push(FACT + "occurrence: " + oneLine(event.start));
    return lines.join("\n");
}

function failureText(err, what) {
    const detail = (err.message || err.stderr || "").trim();
    // Narrow on purpose. `denied` and `Privacy` alone matched failures that had
    // nothing to do with permission, and sending the user to a settings pane that is
    // not the problem is worse than saying nothing: the user is sent to fix
    // the wrong thing. These are the phrasings EventKit and the reader actually use.
    const refused = /Calendar refused|not authori[sz]ed|access denied|access to calendar/i.test(detail);
    if (refused) {
        return detail + "\n(Calendars must be allowed for " + APP_NAME + " in System Settings -> "
             + "Privacy & Security -> Calendars. That is a different pane from Automation, which "
             + "is where the mail and contacts connectors are granted; macOS asks about calendars "
             + "separately, and it asks the first time.)";
    }
    return what + ": " + (detail || "no detail");
}

// ---------------------------------------------------------- The tools

async function listCalendars() {
    let answer;
    try { answer = await helper(["list_calendars"]); }
    catch (err) { return { text: failureText(err, "The calendars could not be listed"), isError: true }; }

    const calendars = Array.isArray(answer.calendars) ? answer.calendars : [];
    if (!calendars.length) {
        return { text: "There are no calendars on this Mac. That is not the same as an empty week: "
                     + "Calendar itself holds nothing to look in." };
    }
    const lines = calendars.map((calendar) => {
        const name = oneLine(calendar.name) || "(unnamed)";
        const account = oneLine(calendar.account);
        // Two calendars can both be named "Calendar" — the account is what
        // tells them apart, and the id is what a search should be given.
        const where = account ? " (" + account + ")" : "";
        const readOnly = calendar.writable ? "" : " | read-only in Calendar";
        return name + where + readOnly + "\n" + FACT + "id: " + oneLine(calendar.id);
    });
    return { text: calendars.length + " calendar" + (calendars.length === 1 ? "" : "s")
                 + ":\n\n" + lines.join("\n") };
}

async function searchEvents(args) {
    let from, to;
    try {
        from = parseWhen(args.from, "`from`");
        to = parseWhen(args.to, "`to`");
    } catch (err) { return { text: String(err.message), isError: true }; }

    if (!from) from = startOfLocalDay(isoLocal(new Date()).slice(0, 10));
    if (!to) to = addLocalDays(from, DEFAULT_WINDOW_DAYS);
    // A bare day as `to` means the END of that day, not its midnight — "from
    // Monday to Friday" that stopped at Friday 00:00 would drop all of Friday.
    if (/^\d{4}-\d{2}-\d{2}$/.test(String(args.to || "").trim())) {
        to = addLocalDays(to, 1);
    }
    if (!(to > from)) {
        return { text: "`to` has to be after `from`.", isError: true };
    }
    if ((to - from) / 86400000 > MAX_WINDOW_DAYS) {
        return { text: "That window is longer than " + MAX_WINDOW_DAYS + " days. Ask for a narrower one.",
                 isError: true };
    }

    const argv = ["search_events", "--from", isoLocal(from), "--to", isoLocal(to)];
    if (typeof args.query === "string" && args.query.trim()) argv.push("--query", args.query.trim());
    if (typeof args.calendar_id === "string" && args.calendar_id.trim()) {
        argv.push("--calendar", args.calendar_id.trim());
    }
    // A nonsense limit falls back to the DEFAULT, not to one. Clamping -3 up to
    // 1 would hand a bot a single event and let it believe that was the whole
    // day — the same class of lie as a silent truncation, which is why the cap
    // says it capped.
    const asked = parseInt(args.limit, 10);
    const limit = Number.isFinite(asked) && asked >= 1
        ? Math.min(asked, MAX_RESULTS) : DEFAULT_RESULTS;
    argv.push("--limit", String(limit));

    let answer;
    try { answer = await helper(argv); }
    catch (err) { return { text: failureText(err, "The calendar could not be read"), isError: true }; }

    const events = Array.isArray(answer.events) ? answer.events : [];
    const firstDay = whenText(isoLocal(from), null, true).replace(" (all day)", "");
    const lastDay = whenText(isoLocal(new Date(to.getTime() - 1000)), null, true).replace(" (all day)", "");
    const window = firstDay + " to " + lastDay;
    if (!events.length) {
        // A cold Calendar can answer before iCloud has filled it in, so "nothing
        // that week" and "nothing to look in" are different answers and the
        // caller is told which one it has.
        if (!answer.calendarsSearched) {
            return { text: "There are no calendars on this Mac to look in, so this is not the same "
                         + "as an empty week." };
        }
        const scope = answer.calendarsSearched === 1
            ? "that calendar" : "all " + answer.calendarsSearched + " calendars";
        return { text: "Nothing from " + window + " in " + scope + "." };
    }
    const head = answer.capped
        ? answer.total + " events from " + window + "; the first " + events.length + " are below."
        : events.length + " event" + (events.length === 1 ? "" : "s") + " from " + window + ":";
    return { text: head + "\n\n" + events.map(renderEvent).join("\n\n") };
}

async function readEvent(args) {
    const id = typeof args.id === "string" ? args.id.trim() : "";
    if (!id) return { text: "`id` is required. It is the `id:` line search_events printed.", isError: true };
    const argv = ["read_event", "--uid", id];
    // Through the SAME normaliser as `from` and `to` — raw, a bare day reached
    // the reader, whose parser requires a zone offset, and a model that
    // paraphrased the occurrence line got a hard parse error.
    //
    // But a DAY and an INSTANT are different questions, so they travel as
    // different arguments. Normalising a bare day to local midnight and sending
    // it as `--start` was worse than the error it replaced: no real occurrence
    // starts at midnight, so a live weekly series came back as "the repeat you
    // asked for is not on the calendar any more" — confidently, and falsely.
    if (typeof args.occurrence === "string" && args.occurrence.trim()) {
        const asked = args.occurrence.trim();
        let when;
        try { when = parseWhen(asked, "`occurrence`"); }
        catch (err) { return { text: String(err.message), isError: true }; }
        if (when) {
            const isDayOnly = /^\d{4}-\d{2}-\d{2}$/.test(asked);
            argv.push(isDayOnly ? "--start-day" : "--start", isoLocal(when));
        }
    }

    let answer;
    try { answer = await helper(argv); }
    catch (err) { return { text: failureText(err, "That event could not be read"), isError: true }; }

    const event = answer && answer.event;
    if (!event) return { text: "That event could not be read.", isError: true };

    const lines = [renderEvent(event)];
    // The reader falls back to the series' own entry when the occurrence asked
    // for no longer exists, and a bot that asked for Thursday would otherwise
    // read whatever date came back and believe it was Thursday.
    if (event.occurrenceMatched === false) {
        lines.push(FACT + "NOTE: the repeat you asked for is not on the calendar any more. "
            + "This is the series' own entry, on the date shown above, not the one you asked for.");
    } else if (event.occurrenceAsked === false && event.recurring) {
        // No occurrence was named, so this is the series' first — not whichever
        // week the caller had in mind. Said out loud, because the date above
        // looks exactly as authoritative either way.
        lines.push(FACT + "NOTE: this repeats, and you did not say which one, so this is its "
            + "first occurrence. Pass the `occurrence:` line from search_events to read "
            + "a particular day.");
    }
    if (oneLine(event.organizer)) lines.push(FACT + "organiser: " + oneLine(event.organizer));
    if (oneLine(event.status)) lines.push(FACT + "status: " + oneLine(event.status));
    if (oneLine(event.url)) lines.push(FACT + "url: " + oneLine(event.url));
    const attendees = Array.isArray(event.attendees) ? event.attendees : [];
    if (attendees.length) {
        lines.push(FACT + attendees.length + " attendee" + (attendees.length === 1 ? "" : "s") + ":");
        for (const attendee of attendees) {
            const name = oneLine(attendee.name);
            const email = oneLine(attendee.email);
            const marks = [];
            if (attendee.organizer) marks.push("organiser");
            if (attendee.isMe) marks.push("him");
            if (oneLine(attendee.status)) marks.push(oneLine(attendee.status));
            const label = name && name !== email ? name + " <" + email + ">"
                                                 : (email || name || "(no address)");
            lines.push(SUB + label + (marks.length ? " - " + marks.join(", ") : ""));
        }
    }
    if (String(event.notes || "").trim()) {
        lines.push(FACT + "notes:");
        lines.push(quoted(event.notes));
    }
    return { text: lines.join("\n") };
}

// ------------------------------------------------------- MCP plumbing

const TOOLS = [
    {
        name: "list_calendars",
        description: "List the calendars on this Mac — their names, which account each belongs to, "
            + "and the id to pass to search_events. Call this first when the user names a calendar "
            + "(\"my work calendar\"), because two calendars can share a name and only the id tells "
            + "them apart. Read-only: nothing can be added, changed or deleted from here.",
        inputSchema: { type: "object", properties: {} },
    },
    {
        name: "search_events",
        description: "Read what is on the user's calendar between two dates — every occurrence, including "
            + "repeating events. Use this BEFORE asking the user whether they are free, what a meeting is, "
            + "or when something happens: their Mac already holds the answer. Searches every calendar "
            + "unless you pass one. Read-only: nothing can be added, changed or deleted from here.",
        inputSchema: { type: "object",
            properties: {
                from: { type: "string", description: "The first day, as YYYY-MM-DD, or a full date and time. Defaults to today." },
                to: { type: "string", description: "The last day, as YYYY-MM-DD (the whole day is included), or a full date and time. Defaults to " + DEFAULT_WINDOW_DAYS + " days after `from`." },
                query: { type: "string", description: "Optional words that must all appear in the title, the location or the notes." },
                calendar_id: { type: "string", description: "Optional id from list_calendars, to look in one calendar only." },
                limit: { type: "number", description: "How many events to return, 1 to " + MAX_RESULTS + ". Defaults to " + DEFAULT_RESULTS + "." },
            } },
    },
    {
        name: "read_event",
        description: "Read one event in full — its notes, its organiser, and the attendees with their "
            + "names and email addresses, so you can write to everyone on a meeting without asking "
            + "the user for an address. Takes the `id` search_events printed; pass the `occurrence` line "
            + "too for a repeating event, or you may read a different week's. Read-only.",
        inputSchema: { type: "object",
            properties: {
                id: { type: "string", description: "The `id:` line search_events printed. Ids belong to this Mac's Calendar; never invent one." },
                occurrence: { type: "string", description: "The `occurrence:` line search_events printed for that event. Names which repeat to read." },
            },
            required: ["id"] },
    },
];

const HANDLERS = {
    list_calendars: listCalendars,
    search_events: searchEvents,
    read_event: readEvent,
};

function write(obj) { process.stdout.write(JSON.stringify(obj) + "\n"); }

/// One request per 0x0A, split on that byte and nowhere else: the fence proxy's
/// own framing. `readline` also ends a line at U+000D, U+2028 and U+2029, and
/// JSON.stringify leaves the last two raw inside a string, so a call carrying
/// one arrived as halves that were each a parse error, and the call itself was
/// never answered (Node v26.8.2). Split as bytes, a
/// character cut across two reads is whole again before it is decoded.
function onRequestLine(input, handle) {
    let pending = Buffer.alloc(0);
    input.on("data", (chunk) => {
        pending = Buffer.concat([pending, chunk]);
        let newline;
        while ((newline = pending.indexOf(0x0a)) !== -1) {
            const line = pending.subarray(0, newline);
            pending = pending.subarray(newline + 1);
            handle(line.toString("utf8"));
        }
    });
    input.on("end", () => {
        if (pending.length) handle(pending.toString("utf8"));
        pending = Buffer.alloc(0);
    });
}

async function dispatch(method, params) {
    switch (method) {
        case "initialize":
            return { protocolVersion: /^\d{4}-\d{2}-\d{2}$/.test(params?.protocolVersion || "")
                        ? params.protocolVersion : "2024-11-05",
                     capabilities: { tools: {} },
                     serverInfo: { name: "openbots-apple-calendar", version: "1.0.0" } };
        case "tools/list": return { tools: TOOLS };
        case "tools/call": {
            // Own names only: `constructor` or `toString` would otherwise resolve
            // through the prototype to a built-in and run as a tool.
            const fn = Object.prototype.hasOwnProperty.call(HANDLERS, params?.name) ? HANDLERS[params.name] : null;
            if (!fn) throw new Error("unknown tool: " + params?.name);
            const res = await fn(params.arguments || {});
            return { content: [{ type: "text", text: res.text }], isError: !!res.isError };
        }
        case "ping": return {};
        default: { const e = new Error("method not found: " + method); e.code = -32601; throw e; }
    }
}

onRequestLine(process.stdin, async (line) => {
    const raw = line.trim();
    if (!raw) return;
    let msg;
    try { msg = JSON.parse(raw); }
    catch (_) { return write({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } }); }
    if (msg.id === undefined || msg.id === null) return;   // notifications are not answered
    try {
        write({ jsonrpc: "2.0", id: msg.id, result: await dispatch(msg.method, msg.params) });
    } catch (err) {
        if (msg.method === "tools/call") {
            write({ jsonrpc: "2.0", id: msg.id,
                    result: { content: [{ type: "text", text: String(err.message || err) }], isError: true } });
        } else {
            write({ jsonrpc: "2.0", id: msg.id,
                    error: { code: err.code || -32603, message: String(err.message || err) } });
        }
    }
});
