#!/usr/bin/env node
"use strict";
/*
 * OpenBots apple-messages reads conversations and sends texts through Apple Messages using an
 * explicitly approved recipient, service and body.
 * The app's permission channel supplies approval before send_message runs, and fence-proxy
 * wraps tool results. Contact lookup is separate and requires the Contacts connector's own
 * grant.
 * Resolve the service before approval; do not accept auto on send. After approval, refuse
 * unsafe inputs rather than rewriting recipient or text. Messages can still choose a different
 * transport when sending into an existing chat; RCS without a chat uses the SMS relay because
 * its scriptable account is disabled.
 * A buddy lookup can resolve even for an invented number on the wrong service, so a successful
 * scripting call does not prove service support or delivery. Resolve service from message, chat
 * and handle history; check delivery outcomes in chat.db.
 * The child process attributes Full Disk Access and Automation permission to OpenBots Next. The
 * app supplies the database path because the CLI has an app-owned HOME. Reads use sqlite3
 * without launching Messages. Sends start Messages only when needed, hidden and in the
 * background.
 */

const { execFile } = require("child_process");

// Env overrides of the programs are for TESTS ONLY; production never sets them.
const SQLITE = process.env.OPENBOTS_SQLITE || "/usr/bin/sqlite3";
const OSASCRIPT = process.env.OPENBOTS_OSASCRIPT || "/usr/bin/osascript";
const OPEN = process.env.OPENBOTS_OPEN || "/usr/bin/open";
const PGREP = process.env.OPENBOTS_PGREP || "/usr/bin/pgrep";
// Resolved on the Swift side (AppleMessagesConnectorPreparation), so the row's
// badge and the database this reads cannot be two different files.
const DB = process.env.OPENBOTS_MESSAGES_DB || "";
const MESSAGES_APP = process.env.OPENBOTS_MESSAGES_APP || "/System/Applications/Messages.app";
const APP_NAME = process.env.OPENBOTS_APP_NAME || "OpenBots Next";

/** The complete set, from Messages.sdef's `service type` enumeration. */
const SERVICES = ["iMessage", "RCS", "SMS"];
/** Apple epoch (2001-01-01) → Unix epoch, seconds. */
const APPLE_EPOCH = 978307200;

/// How long to wait for a hidden Messages to come up. Generous on purpose, for
/// the same reason as the Contacts reader's: a short deadline on a real child
/// process is what makes tests and cold launches flaky.
const LAUNCH_DEADLINE_MS = 20000;
const LAUNCH_POLL_MS = 250;

// ─────────────────────────────────────────────── The shape a send may take
//
// The approval card and this sender must read the same input identically. Require strings,
// never trim recipients, and send text unchanged or refuse it whole.
// `AppleMessagesSendProposal` in ClaudeTextConnectorApprovalPolicy.swift mirrors these rules;
// AppleMessagesScriptTests sweeps characters through both implementations.

/// Counted in Unicode scalars on both sides (`Array.from` here,
/// `unicodeScalars.count` in Swift). The card's detail is a heading of under two
/// hundred scalars, a blank line, then the text, and the approvals record keeps
/// the first 2,000 characters of that detail; a character is never fewer than
/// one scalar, so 1,800 keeps every text whole on the record. The Swift side
/// pins that arithmetic with a worst-case card.
const MAX_TEXT_SCALARS = 1800;
/// RFC 5321's longest forward path, in ASCII characters.
const MAX_RECIPIENT = 254;

const SEND_FIELDS = ["recipient", "service", "text"];

const PHONE = /^\+?[0-9]{3,15}$/;
const EMAIL = /^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]{1,63}(?:\.[A-Za-z0-9-]{1,63})+$/;

/// Unicode 16's Default_Ignorable_Code_Point, written out rather than read from
/// `\p{Default_Ignorable_Code_Point}`: Node's ICU and Swift's tables carry
/// different Unicode versions, and a property that means two things on the two
/// sides of a card is exactly the drift this file exists to prevent. The mirror
/// is `AppleMessagesSendProposal.defaultIgnorableRanges`.
const DEFAULT_IGNORABLE = [
    [0x00AD, 0x00AD], [0x034F, 0x034F], [0x061C, 0x061C], [0x115F, 0x1160], [0x17B4, 0x17B5],
    [0x180B, 0x180F], [0x200B, 0x200F], [0x202A, 0x202E], [0x2060, 0x206F], [0x3164, 0x3164],
    [0xFE00, 0xFE0F], [0xFEFF, 0xFEFF], [0xFFA0, 0xFFA0], [0xFFF0, 0xFFF8], [0x1BCA0, 0x1BCA3],
    [0x1D173, 0x1D17A], [0xE0000, 0xE0FFF],
];

/// The tags after U+1F3F4 in the three subdivision flags Unicode recommends,
/// cancel tag included: gbeng, gbsct, gbwls.
const SUBDIVISION_FLAG_TAGS = [
    [0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F],
    [0xE0067, 0xE0062, 0xE0073, 0xE0063, 0xE0074, 0xE007F],
    [0xE0067, 0xE0062, 0xE0077, 0xE006C, 0xE0073, 0xE007F],
];

/// Refused wherever it stands, before the four exceptions are considered:
/// controls other than tab and newline (carriage return included), DEL and the
/// C1 controls (next line included), the line and paragraph separators, the
/// interlinear annotation marks, and every default-ignorable character — the
/// ones a renderer draws as nothing. REFUSED, never stripped: a text with a
/// character taken out is not the text the user approved.
function isRefusedAlone(cp) {
    if (cp === 0x09 || cp === 0x0A) return false;
    if (cp < 0x20 || (cp >= 0x7F && cp <= 0x9F) || cp === 0x2028 || cp === 0x2029) return true;
    // U+FFFC stands in for an attachment and U+2800 is an empty braille cell: both take up
    // space and draw nothing.
    if (cp === 0x2800 || cp === 0xFFFC) return true;
    if (cp >= 0xFFF9 && cp <= 0xFFFB) return true;
    // A lone surrogate cannot exist in a Swift string at all, so the card could
    // never have shown one. JavaScript can hold one; it is refused here.
    if (cp >= 0xD800 && cp <= 0xDFFF) return true;
    return DEFAULT_IGNORABLE.some(([low, high]) => cp >= low && cp <= high);
}

/// Unicode's White_Space property, written out for the same reason.
function isWhitespace(cp) {
    return (cp >= 0x09 && cp <= 0x0D) || cp === 0x20 || cp === 0x85 || cp === 0xA0 || cp === 0x1680
        || (cp >= 0x2000 && cp <= 0x200A) || cp === 0x2028 || cp === 0x2029 || cp === 0x202F
        || cp === 0x205F || cp === 0x3000;
}

/// The letters of the scripts that spell words with a zero-width non-joiner.
/// The mirror is `AppleMessagesSendProposal.joiningScriptRanges`.
const JOINS_WORDS = [
    [0x0600, 0x06FF], [0x0700, 0x074F], [0x0750, 0x077F], [0x0780, 0x07BF], [0x07C0, 0x07FF],
    [0x0840, 0x085F], [0x0860, 0x086F], [0x0870, 0x089F], [0x08A0, 0x08FF], [0x0900, 0x0DFF],
    [0x0F00, 0x0FFF], [0x1000, 0x109F], [0x1780, 0x17FF], [0x1800, 0x18AF], [0x1B00, 0x1B7F],
    [0xA800, 0xA82F], [0xA980, 0xA9DF], [0xFB50, 0xFDFF], [0xFE70, 0xFEFF],
    [0x10AC0, 0x10AFF], [0x10D00, 0x10D3F], [0x10F30, 0x10F6F], [0x11000, 0x110CF],
    [0x11100, 0x1114F], [0x11180, 0x111DF], [0x1E900, 0x1E95F],
];
const joinsWords = (cp) => JOINS_WORDS.some(([low, high]) => cp >= low && cp <= high);

/// The viramas that join consonants. The mirror is `AppleMessagesSendProposal.viramas`.
const VIRAMAS = new Set([
    0x094D, 0x09CD, 0x0A4D, 0x0ACD, 0x0B4D, 0x0BCD, 0x0C4D, 0x0CCD, 0x0D4D, 0x0DCA,
    0x0E3A, 0x0F84, 0x1039, 0x17D2, 0x1B44, 0xA806, 0xA8C4, 0xA953, 0xABED, 0x11046,
]);

/// The three characters a keycap is built on: 0-9, # and *.
const isKeycapBase = (cp) => cp === 0x23 || cp === 0x2A || (cp >= 0x30 && cp <= 0x39);

/// A character a presentation selector or an emoji joiner may lean on: what
/// Unicode calls an emoji, less the keycap bases. Each side reads its own
/// Unicode tables here; the wire sweep holds them together, and a difference
/// refuses a text rather than sending a different one. The mirror is
/// `AppleMessagesSendProposal.takesSelector`.
const EMOJI = /\p{Emoji}/u;
const EMOJI_PRESENTATION = /\p{Emoji_Presentation}/u;
const takesSelector = (cp) => !isKeycapBase(cp) && EMOJI.test(String.fromCodePoint(cp));
/// A character Unicode draws as an emoji unless it is asked for text.
const drawnAsEmoji = (cp) => EMOJI_PRESENTATION.test(String.fromCodePoint(cp));

/// The sentence refusing a text whose lines the card would lay out as empty space, or null. The
/// first and the last line must hold something other than whitespace, and no two blank lines
/// may follow each other: the card's box shows about six lines before it scrolls and a trackpad
/// hides the scroller, so "Sure, see you then", forty line breaks and a second paragraph read
/// as the first line alone. One blank line between paragraphs passes. The mirror is
/// `AppleMessagesSendProposal.lineShapeRefusal`.
function lineShapeRefusal(cps) {
    const blankLines = [];
    let blank = true;
    for (const cp of cps) {
        if (cp === 0x0A) {
            blankLines.push(blank);
            blank = true;
        } else if (!isWhitespace(cp)) {
            blank = false;
        }
    }
    blankLines.push(blank);
    if (blankLines[0] || blankLines[blankLines.length - 1]) {
        return "`text` begins or ends with a blank line, which the approval card shows as empty space. Send "
            + "it again without the blank line at the start or the end. Nothing was sent.";
    }
    for (let index = 1; index < blankLines.length; index++) {
        if (blankLines[index] && blankLines[index - 1]) {
            return "`text` has two blank lines in a row, which can push words below what the approval card "
                + "shows at first. Use at most one blank line between paragraphs. Nothing was sent.";
        }
    }
    return null;
}

/// Return the first disallowed code point's index or -1. Default-ignorable characters can carry
/// content invisible on the approval card.
/// Allow U+200C within scripts that use it, U+200D between emoji past one selector and skin
/// tone or after a virama, U+FE0F when selecting emoji presentation or keycaps, and U+FE0E when
/// selecting text presentation. Allow tags only inside England, Scotland and Wales flag
/// sequences. Mirror `AppleMessagesSendProposal.firstRefused(in:)`.
function firstRefusedIndex(cps) {
    const flagTags = new Set();
    for (let start = 0; start < cps.length; start++) {
        if (cps[start] !== 0x1F3F4) continue;
        for (const tags of SUBDIVISION_FLAG_TAGS) {
            if (start + tags.length < cps.length && tags.every((tag, k) => cps[start + 1 + k] === tag)) {
                for (let k = 1; k <= tags.length; k++) flagTags.add(start + k);
            }
        }
    }
    for (let index = 0; index < cps.length; index++) {
        const cp = cps[index];
        if (!isRefusedAlone(cp)) continue;
        if (cp === 0x200C) {
            if (index > 0 && index + 1 < cps.length && joinsWords(cps[index - 1])
                    && joinsWords(cps[index + 1])) continue;
        } else if (cp === 0x200D) {
            let before = index - 1;
            if (before >= 0 && (cps[before] === 0xFE0E || cps[before] === 0xFE0F)) before -= 1;
            if (before >= 0 && VIRAMAS.has(cps[before])) continue;
            if (before >= 0 && cps[before] >= 0x1F3FB && cps[before] <= 0x1F3FF) before -= 1;
            if (before >= 0 && index + 1 < cps.length && takesSelector(cps[before])
                    && takesSelector(cps[index + 1])) continue;
        } else if (cp === 0xFE0F) {
            if (index > 0 && takesSelector(cps[index - 1]) && !drawnAsEmoji(cps[index - 1])) continue;
            if (index > 0 && isKeycapBase(cps[index - 1]) && index + 1 < cps.length
                    && cps[index + 1] === 0x20E3) continue;
        } else if (cp === 0xFE0E) {
            if (index > 0 && drawnAsEmoji(cps[index - 1])) continue;
        } else if (cp >= 0xE0020 && cp <= 0xE007F) {
            if (flagTags.has(index)) continue;
        }
        return index;
    }
    return -1;
}

const codePointName = (cp) => "U+" + cp.toString(16).toUpperCase().padStart(4, "0");

function kindOf(value) {
    if (Array.isArray(value)) return "an array";
    return typeof value === "object" ? "an object" : `a ${typeof value}`;
}

/// The sentence that refuses a send, or null when the three values may go on a
/// card and be sent exactly as they are.
function sendRefusal(args) {
    // Only the three fields a card shows. Foundation, which builds the card,
    // drops one leading U+FEFF from every key it reads, so {"﻿text": A,
    // "text": B} is one field to the card and two here; any field besides the
    // three is refused rather than read past. The mirror is
    // `AppleMessagesSendProposal.fields`.
    for (const key of Object.keys(args)) {
        if (!SEND_FIELDS.includes(key)) {
            const shown = Array.from(key).slice(0, 40)
                .map((c) => (/^[\x21-\x7E]$/.test(c) ? c : codePointName(c.codePointAt(0)))).join("");
            return `\`${shown}\` is not a field of a text: a text takes only recipient, service and text, and `
                + "the approval card cannot show anything else. Nothing was sent.";
        }
    }
    for (const field of SEND_FIELDS) {
        const value = args[field];
        if (value === undefined || value === null) {
            return `\`${field}\` is required. Nothing was sent.`;
        }
        if (typeof value !== "string") {
            return `\`${field}\` must be a string; it arrived as ${kindOf(value)}. The approval card is built `
                + "from these values. Nothing was sent.";
        }
    }
    const { recipient, service, text } = args;
    if (service === "auto") {
        return "`service` cannot be \"auto\" here: he approves the service on the card, so call "
            + "check_message_service first and pass the service it names — iMessage, RCS or SMS. "
            + "Nothing was sent.";
    }
    if (!SERVICES.includes(service)) {
        return `\`service\` must be exactly one of ${SERVICES.join(", ")}, as check_message_service `
            + "names it. Nothing was sent.";
    }
    if (!recipient.length) return "`recipient` is required. Nothing was sent.";
    let plain = recipient.length <= MAX_RECIPIENT;
    for (let i = 0; i < recipient.length && plain; i++) {
        const unit = recipient.charCodeAt(i);
        plain = unit >= 0x21 && unit <= 0x7E;
    }
    if (!plain || !(PHONE.test(recipient) || EMAIL.test(recipient))) {
        return "`recipient` must be exactly the handle check_message_service returned: a phone number "
            + "written as digits with an optional leading +, or a plain email address, with no spaces, "
            + "punctuation or letters from other alphabets. Never a person's name: look them up with the "
            + "Contacts connector first. Nothing was sent.";
    }
    if (!text.length) return "`text` is empty, so there is nothing to send. Nothing was sent.";
    const scalars = Array.from(text);
    if (scalars.length > MAX_TEXT_SCALARS) {
        return `\`text\` is ${scalars.length} characters long and the limit is ${MAX_TEXT_SCALARS}, so it `
            + "could not be shown to him whole. Split it into shorter texts. Nothing was sent.";
    }
    const codePoints = scalars.map((scalar) => scalar.codePointAt(0));
    const refused = firstRefusedIndex(codePoints);
    if (refused !== -1) {
        return `\`text\` carries ${codePointName(codePoints[refused])}, which the approval card `
            + "cannot show as it would be sent. Send it again without that character — a line break is fine "
            + "as a plain newline. Nothing was sent.";
    }
    const shape = lineShapeRefusal(codePoints);
    if (shape) return shape;
    // A space at the very end is one the user cannot see on the card, and the
    // approvals record, which trims both ends of a detail, would keep the text
    // without it. The mirror is `AppleMessagesSendProposal.Refusal.endsWithWhitespace`.
    if (isWhitespace(codePoints[codePoints.length - 1])) {
        return "`text` ends with a space, which the approval card cannot show and its record would drop. Send "
            + "it again without the space at the end. Nothing was sent.";
    }
    return null;
}

// ─────────────────────────────────────────────────────────── process helpers

function run(cmd, args, stdin) {
    return new Promise((resolve, reject) => {
        const child = execFile(
            cmd, args, { maxBuffer: 16 * 1024 * 1024, timeout: 60000 },
            (err, stdout, stderr) => {
                if (err) {
                    err.stderr = String(stderr || "");
                    return reject(err);
                }
                resolve(String(stdout));
            });
        if (stdin !== undefined) {
            // An EPIPE on a child's stdin is an unhandled 'error' event, which
            // would take the whole server down. The execFile callback already
            // reports the real failure.
            child.stdin.on("error", () => {});
            child.stdin.end(stdin);
        }
    });
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** sqlite3 -readonly: nothing here ever writes to the user's message database. */
async function sql(query) {
    if (!DB) {
        const err = new Error("This build did not tell the Messages connector where his message history is, "
            + "so nothing could be read.");
        err.noDatabase = true;
        throw err;
    }
    const out = await run(SQLITE, ["-readonly", "-json", DB, query]);
    const trimmed = out.trim();
    return trimmed ? JSON.parse(trimmed) : [];
}

/// What a refused read looks like, said once and in the user's words. Full Disk Access
/// is never asked for by macOS: it is a switch they turn on themselves, and until they
/// do, sqlite3 cannot open the database at all.
function readFailure(err) {
    if (err && err.noDatabase) return err.message;
    const detail = String((err && (err.stderr || err.message)) || "").trim();
    if (/authori[sz]ation denied|unable to open database|operation not permitted|not authori[sz]ed/i.test(detail)) {
        return `His Messages history could not be read: ${detail}\n(Full Disk Access must be turned on for `
            + `${APP_NAME} in System Settings → Privacy & Security → Full Disk Access. macOS never asks for `
            + "this one. If it is already on, Messages may have no history on this Mac.)";
    }
    return `His Messages history could not be read: ${detail || "no detail"}`;
}

async function isMessagesRunning() {
    // Scoped to this user. A bare `pgrep -x` matches every account's processes,
    // so under fast user switching another user's Messages would answer
    // "already running", the hidden launch would be skipped, and the Apple
    // event would then start Messages for THIS user with a window on their screen.
    try { await run(PGREP, ["-U", String(process.getuid()), "-x", "Messages"]); return true; }
    catch (_) { return false; }        // pgrep exits non-zero when nothing matches
}

/// Start Messages without letting it take the screen, and only if it is not
/// already running. `-g` keeps it behind, `-j` launches it hidden.
async function ensureMessagesRunning() {
    if (await isMessagesRunning()) return;
    try { await run(OPEN, ["-g", "-j", "-a", MESSAGES_APP]); }
    catch (err) {
        throw new Error(`Messages could not be started: ${(err.stderr || err.message || "").trim()}`);
    }
    const deadline = Date.now() + LAUNCH_DEADLINE_MS;
    while (Date.now() < deadline) {
        if (await isMessagesRunning()) return;
        await sleep(LAUNCH_POLL_MS);
    }
    throw new Error("Messages did not finish starting.");
}

/**
 * Pass recipient and body as argv to `osascript -`, which reads source from stdin and passes
 * remaining arguments to `on run argv`. Unicode, line breaks, quotes and backslashes remain
 * values rather than executable source.
 */
function osascript(script, argv) {
    return run(OSASCRIPT, ["-", ...argv], script);
}

// ────────────────────────────────────────────────────── recipient lookups
//
// Looking someone up is lenient about formatting, because people and their
// address books write numbers every way there is. Sending is not: the lookup
// hands back the exact handle, and that handle is what the card shows.

// Invisible and bidi characters are rejected outright even in a lookup: a
// zero-width space inside a handle reads identically to the real one while
// matching a different string.
const NO_INVISIBLES = /^[^\u200b-\u200f\u202a-\u202e\u2060-\u2069\u061c\ufeff]*$/;
const isEmail = (s) => /@/.test(String(s)) && NO_INVISIBLES.test(String(s));
const digitsOf = (s) => String(s || "").replace(/\D+/g, "");
const sqlText = (s) => "'" + String(s).replace(/'/g, "''") + "'";
const appleToUnix = (d) => {
    const n = Number(d) || 0;
    // Current Messages rows store nanoseconds; older macOS versions stored plain seconds.
    return (n > 1e11 ? n / 1e9 : n) + APPLE_EPOCH;
};
const iso = (d) => new Date(appleToUnix(d) * 1000).toISOString();

/// Folded to one line: a handle or a service name is written into a line of this
/// server's own answer, and a line break inside one could write a line of its own.
function oneLine(value) {
    return String(value === null || value === undefined ? "" : value)
        .replace(/[\r\n\u2028\u2029\u0085\u000B\u000C]+/g, " ")
        .replace(/\s+/g, " ")
        .trim();
}

/**
 * A recipient we are willing to LOOK UP. A bare `/@/` test once let "ask
 * bob@work about it", "Sarah <sarah@example.com>" and even "@" through, so the
 * whole string must BE an address, not merely contain an @; and a number must
 * be digits and the punctuation people write numbers with.
 */
function lookupShapeError(recipient) {
    if (typeof recipient !== "string") {
        return `\`recipient\` must be a string; it arrived as ${kindOf(recipient)}.`;
    }
    const r = recipient.trim();
    const ok = NO_INVISIBLES.test(r) && r.length <= MAX_RECIPIENT
        && (/^[^\s@<>,;:"'\\]+@[^\s@<>,;:"'\\.]+\.[^\s@<>,;:"'\\]+$/.test(r)
            || (/^\+?[\d\s().-]+$/.test(r) && digitsOf(r).length >= 3));
    return ok ? null
        : `"${oneLine(r).slice(0, 80)}" is not a phone number or email address. Look the person up with the `
          + "Contacts connector and pass the number or address it returns, or ask him for it — never guess one.";
}

/**
 * How many trailing digits make a suffix match safe. Nine is enough to be
 * effectively unique while still absorbing country-code and formatting
 * variance ("06 39 98 12 34" vs "+33639981234").
 */
const TAIL_DIGITS = 9;

/**
 * A SQL predicate matching one recipient against a handle-ish column. Phone
 * numbers match on their last 9 digits, so "06 39 98 12 34", "+33639981234"
 * and "0639981234" all find the same person — chat.db stores E.164, the user and their
 * contacts do not. This lives in the LOOKUP only: a send addresses exactly the
 * handle on the card.
 */
function matchClause(recipient, column) {
    if (isEmail(recipient)) {
        return `lower(${column}) = ${sqlText(String(recipient).toLowerCase().trim())}`;
    }
    const digits = digitsOf(recipient);
    if (!digits) return "0";
    // Short recipient inputs require exact matching. Suffix matching could resolve a short
    // arbitrary digit sequence to an unrelated contact. Legitimate short-code senders remain
    // supported through exact matches.
    if (digits.length < TAIL_DIGITS) {
        return `(${column} = ${sqlText(digits)} OR ${column} = ${sqlText("+" + digits)})`;
    }
    return `${column} LIKE ${sqlText("%" + digits.slice(-TAIL_DIGITS))}`;
}

/**
 * Resolve service from three independent signals, strongest first: message.service records the
 * latest actual transport; chat.service_name records the conversation transport; handle.service
 * records resolved address services. Retained messages can be sparse, so chat and handle data
 * remain necessary fallbacks. An iMessage handle indicates that Apple's directory recognized
 * the address.
 */
const PREFERENCE = { iMessage: 3, RCS: 2, SMS: 1 };

async function detect(recipient) {
    const handles = await sql(
        `SELECT ROWID AS rowid, id, service FROM handle WHERE ${matchClause(recipient, "id")}`);
    // Group threads are identified as "chat<digits>" and could collide with a
    // digit-tail match — exclude them explicitly rather than trusting style codes.
    // GLOB, not LIKE: LIKE ignores case and `chat%` needs no digit, so it also
    // dropped every one-to-one conversation with an address beginning "chat".
    const chats = await sql(
        `SELECT chat_identifier, service_name, guid, last_read_message_timestamp AS ts FROM chat
         WHERE ${matchClause(recipient, "chat_identifier")} AND chat_identifier NOT GLOB 'chat[0-9]*'`
            .replace(/\s+/g, " "));
    const rowids = handles.map((h) => Number(h.rowid)).filter(Number.isFinite);
    const msgs = rowids.length
        ? await sql(`SELECT service, date, is_from_me, was_downgraded FROM message
                     WHERE handle_id IN (${rowids.join(",")}) AND service IS NOT NULL
                     ORDER BY date DESC LIMIT 200`.replace(/\s+/g, " "))
        : [];

    // Ignore outgoing downgraded sends as service evidence. A send through a disabled RCS
    // scripting account may be recorded as SMS with was_downgraded=1 even when incoming
    // messages prove RCS support.
    const downgraded = msgs.filter((m) => Number(m.is_from_me) && Number(m.was_downgraded));
    const evidence = msgs.filter((m) => !(Number(m.is_from_me) && Number(m.was_downgraded)));

    const seen = {};      // service → newest apple-date on it
    for (const m of evidence) {
        const s = String(m.service);
        if (!(s in seen) || Number(m.date) > seen[s]) seen[s] = Number(m.date);
    }

    let service = null, reason = null;
    if (evidence.length) {
        service = String(evidence[0].service);
        reason = `you last exchanged messages with them on ${service} (${iso(seen[service])})`;
    } else if (chats.length) {
        const best = chats.slice().sort((a, b) => Number(b.ts || 0) - Number(a.ts || 0))[0];
        service = String(best.service_name);
        reason = `their conversation in Messages is an ${service} thread`;
    } else if (handles.length) {
        const best = handles.slice().sort(
            (a, b) => (PREFERENCE[b.service] || 0) - (PREFERENCE[a.service] || 0))[0];
        service = String(best.service);
        reason = service === "iMessage"
            ? "Messages has them registered as an iMessage address"
            : `Messages only knows them as ${service} — no iMessage address exists for them`;
    }
    // A value this file does not know is not a service it can send on.
    if (service !== null && !SERVICES.includes(service)) { service = null; reason = null; }

    // The string Messages itself files this person under (E.164), not whatever
    // format the request came in as.
    const canonical = (handles.find((h) => String(h.service) === service) || handles[0])?.id
        || chats[0]?.chat_identifier || null;

    return {
        recipient, handles, chats, seen, service, canonical, reason,
        downgraded: downgraded.length,
        known: new Set([
            ...handles.map((h) => String(h.service)),
            ...chats.map((c) => String(c.service_name)),
            ...Object.keys(seen),
        ]),
    };
}

/**
 * The decision for someone this Mac has no history with. Deliberately
 * conservative for a stranger's number: SMS reaches every phone on earth, while
 * a wrong iMessage guess fails silently — the exact bug this server exists to
 * fix. An email address can only be an iMessage address.
 */
function chooseService(det) {
    if (det.service) return { service: det.service, why: det.reason };
    if (isEmail(det.recipient)) {
        return { service: "iMessage", why: "an email address can only be an iMessage address" };
    }
    return {
        service: "SMS",
        why: "this Mac knows nothing about the number, so SMS — it reaches any phone, where a wrong "
           + "iMessage guess would fail silently",
    };
}

/// The handle a send should address when Messages has no row for this person:
/// the number as the user gave it with only the formatting taken out, or the address
/// as they gave it. Nothing is added — no country code is guessed.
function handleAsGiven(recipient) {
    const r = String(recipient).trim();
    if (isEmail(r)) return r;
    return (r.startsWith("+") ? "+" : "") + digitsOf(r);
}

// ─────────────────────────────────────────────────────────────────── reading

/**
 * Message bodies may reside in `attributedBody` rather than `message.text`. Decode the NeXT
 * streamtyped archive after its class names: `NSString`, bytes 01 94 84 01 2b, length, then
 * UTF-8 data. The length is one byte, 0x81 plus uint16le, or 0x82 plus uint32le.
 */
function decodeAttributedBody(hex) {
    if (!hex) return null;
    const buf = Buffer.from(hex, "hex");
    const marker = buf.indexOf(Buffer.from("NSString", "latin1"));
    if (marker < 0) return null;
    // The type marker sits within a handful of bytes of the class name; a
    // wider search could hit a 0x2b ("+") inside the message text itself.
    const rel = buf.slice(marker, marker + 24).indexOf(0x2b);
    if (rel < 0) return null;
    let p = marker + rel + 1;
    let len = buf[p++];
    // Bounds-checked BEFORE reading: buf[i] returns undefined past the end, but
    // readUInt16LE/readUInt32LE THROW, and one truncated blob would take down
    // the whole read instead of costing a single message's text.
    if (len === 0x81) {
        if (p + 2 > buf.length) return null;
        len = buf.readUInt16LE(p); p += 2;
    } else if (len === 0x82) {
        if (p + 4 > buf.length) return null;
        len = buf.readUInt32LE(p); p += 4;
    }
    if (!Number.isFinite(len) || len <= 0 || p + len > buf.length) return null;
    return buf.slice(p, p + len).toString("utf8");
}

const bodyOf = (row) => {
    if (row.text && String(row.text).trim()) return String(row.text);
    // One unparseable blob costs that message's text, never the whole call.
    try { return decodeAttributedBody(row.blob) || ""; } catch (_) { return ""; }
};

/// Own message headings start at the margin with a date. Prefix every line of untrusted message
/// text with a quote marker so embedded line breaks cannot forge a new heading, sender or
/// service. Indentation alone is insufficient because ordinary prose can imitate it.
const QUOTED = "    > ";

function quoted(value) {
    return String(value === null || value === undefined ? "" : value)
        // Vertical tab, form feed and the unicode separators are line breaks
        // to some readers, so they become real ones and get their own mark.
        .replace(/[\u000B\u000C\u2028\u2029\u0085]/g, "\n")
        .replace(/\r\n?/g, "\n")
        .split("\n").map((line) => QUOTED + line.trimEnd()).join("\n");
}

// ───────────────────────────────────────────── the chats this bot may read

/**
 * Limit reads to exact Messages chat.guid values supplied by the app as a base64 JSON array
 * (`AppleMessagesChatScope.environmentValue`). Missing, malformed or empty-guid inputs become
 * null, which reads nothing. Compare guids byte-for-byte, without trimming or folding, matching
 * the app's conversation directory.
 */
const CHAT_SCOPE = parseChatScope(process.env.OPENBOTS_MESSAGES_CHATS);
const NOTHING_READ = "Nothing was read.";

function parseChatScope(raw) {
    if (typeof raw !== "string" || raw.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(raw)) return null;
    let list;
    try { list = JSON.parse(Buffer.from(raw, "base64").toString("utf8")); } catch (_) { return null; }
    if (!Array.isArray(list) || !list.every((guid) => typeof guid === "string" && guid.length > 0)) return null;
    return [...new Set(list)];
}

/// The name the user knows a conversation by: the group's name when it has one, the
/// address or sender Messages files it under otherwise. Written by whoever
/// named the group, so folded to one line like every other such value.
function chatLabel(row) {
    return (oneLine(row.name) || oneLine(row.id) || "a conversation with no name").slice(0, 80);
}

const labels = (chats) => chats.map((chat) => chat.label).join(", ");

/// The named conversations Messages still keeps. A guid is a literal here and
/// nowhere else, and this query is never folded: collapsing its whitespace
/// would change a guid that carries two spaces.
async function namedChats() {
    const rows = await sql("SELECT ROWID AS rowid, chat_identifier AS id, display_name AS name FROM chat "
        + `WHERE guid IN (${CHAT_SCOPE.map(sqlText).join(",")}) ORDER BY ROWID`);
    return rows.map((row) => ({ rowid: Number(row.rowid), label: chatLabel(row) }))
        .filter((chat) => Number.isFinite(chat.rowid));
}

/// Of the named conversations, the ones with this person in them: the
/// one-to-one conversation filed under their address, and every group they
/// are a member of. A group is never matched by the digits in its own
/// `chat<digits>` id, which could end in anybody's last nine.
async function chatsWith(recipient, chats) {
    const rows = await sql(`SELECT c.ROWID AS rowid FROM chat c WHERE c.ROWID IN (${chats.map((c) => c.rowid).join(",")}) `
        + `AND ((${matchClause(recipient, "c.chat_identifier")} AND c.chat_identifier NOT GLOB 'chat[0-9]*') `
        + "OR c.ROWID IN (SELECT j.chat_id FROM chat_handle_join j JOIN handle h ON h.ROWID = j.handle_id "
        + `WHERE ${matchClause(recipient, "h.id")}))`);
    const hit = new Set(rows.map((row) => Number(row.rowid)));
    return chats.filter((chat) => hit.has(chat.rowid));
}

async function readMessages(args) {
    const { recipient, limit } = args;
    const unreadOnly = args.unread_only === true;
    // Integer-clamped: a non-integer limit was once interpolated straight into
    // SQL and came back as a raw sqlite syntax error.
    const n = Math.min(Math.max(Math.floor(Number(limit)) || 20, 1), 100);
    if (CHAT_SCOPE === null) {
        return { isError: true, text: "This build did not tell the Messages connector which chats this bot may "
            + `read. ${NOTHING_READ}` };
    }
    if (!CHAT_SCOPE.length) {
        return { isError: true, text: `No chats are named for this bot in ${APP_NAME}, so it may read none. `
            + NOTHING_READ };
    }
    const named = recipient !== undefined && recipient !== null && recipient !== "";
    if (named) {
        const refused = lookupShapeError(recipient);
        if (refused) return { isError: true, text: refused };
    }
    let chats, covered;
    try {
        chats = await namedChats();
        covered = named && chats.length ? await chatsWith(recipient, chats) : chats;
    } catch (err) {
        return { isError: true, text: readFailure(err) };
    }
    // The same words whether or not the user has a conversation with them elsewhere:
    // saying which would be a read of the chats this bot may not read.
    if (named && !covered.length) {
        return { isError: true, text: `None of the chats this bot may read is with ${oneLine(recipient)}. `
            + `It may read: ${chats.length ? labels(chats) : "none that Messages still keeps"}. ${NOTHING_READ}` };
    }
    if (!covered.length) {
        return { isError: true, text: `Messages no longer keeps any of the chats named for this bot. ${NOTHING_READ}` };
    }
    const who = `${named ? `with ${oneLine(recipient)} ` : ""}from the chats this bot may read (${labels(covered)})`;
    let scope = "m.ROWID IN (SELECT message_id FROM chat_message_join WHERE chat_id IN ("
        + `${covered.map((chat) => chat.rowid).join(",")}))`;
    if (unreadOnly) scope += " AND m.is_read = 0 AND m.is_from_me = 0";

    let rows;
    try {
        rows = await sql(`SELECT m.date AS date, m.is_from_me AS mine, m.service AS service,
                                 m.text AS text, hex(m.attributedBody) AS blob,
                                 m.error AS error, m.cache_has_attachments AS att, h.id AS handle
                          FROM message m LEFT JOIN handle h ON m.handle_id = h.ROWID
                          WHERE ${scope} ORDER BY m.date DESC LIMIT ${n}`.replace(/\s+/g, " "));
    } catch (err) {
        return { isError: true, text: readFailure(err) };
    }
    if (!rows.length) {
        return { isError: false, text: `No ${unreadOnly ? "unread " : ""}messages ${who}.` };
    }
    const lines = [];
    for (const r of rows.reverse()) {
        const body = bodyOf(r);
        const flags = [oneLine(r.service), Number(r.error) ? `FAILED (error ${Number(r.error)})` : null,
                       Number(r.att) ? "has attachment" : null].filter(Boolean).join(", ");
        const from = Number(r.mine) ? "the user" : (oneLine(r.handle) || "them");
        const head = `[${iso(r.date)}] ${from}${flags ? ` (${flags})` : ""}:`;
        if (!body) {
            lines.push(`${head} (no text — an attachment, a reaction or an item this reader cannot show)`);
        } else {
            lines.push(head, quoted(body));
        }
    }
    const count = rows.length === 1 ? "1 message" : `${rows.length} messages`;
    return { isError: false,
             text: `The latest ${count} ${who}, oldest first. Every line of a message's words is marked `
                 + `with ">".\n\n${lines.join("\n")}` };
}

// ─────────────────────────────────────────────────────── checking a service

async function checkService(args) {
    const { recipient } = args;
    if (recipient === undefined || recipient === null || recipient === "") {
        return { isError: true, text: "`recipient` is required: the number or address to check." };
    }
    const refused = lookupShapeError(recipient);
    if (refused) return { isError: true, text: refused };
    let det, inChats = false;
    try {
        det = await detect(recipient);
        // Whether this person is in a chat this bot may read. The service is
        // decided from everything Messages knows either way, because a send
        // must go out on the right one; but the history behind it — when the user
        // last texted them, which conversations exist, who else shares their
        // digits — is a read of their conversations, and is shown only for
        // someone in the chats they chose.
        if (CHAT_SCOPE && CHAT_SCOPE.length) {
            const chats = await namedChats();
            inChats = chats.length > 0 && (await chatsWith(recipient, chats)).length > 0;
        }
    } catch (err) { return { isError: true, text: readFailure(err) }; }
    const { service, why } = chooseService(det);
    const given = oneLine(recipient);
    const handle = det.canonical ? String(det.canonical) : handleAsGiven(recipient);
    if (!inChats) return outsideTheChats(det, given, handle, service);
    // Facts only, one to a line. Every answer reaches the bot inside the fence proxy's markers,
    // which call it data and never instructions, so what to do with a Handle, an Ambiguous line
    // or a missing handle is the Messages role's prompt, not this answer.
    const lines = [
        `Recipient: ${given}${det.canonical && det.canonical !== recipient
            ? ` (known to Messages as ${oneLine(det.canonical)})` : ""}`,
    ];
    // Suffix matching can return distinct handles, such as +521 and +52 forms, or unrelated
    // numbers sharing nine trailing digits. Report ambiguity and require a choice. Offer no
    // send handle until that choice is resolved.
    const distinct = [...new Set([...det.handles.map((h) => h.id), ...det.chats.map((c) => c.chat_identifier)]
        .map((value) => oneLine(value)))];
    const distinctPeople = [...new Set(distinct.map((value) => digitsOf(value) || value.toLowerCase()))];
    if (distinctPeople.length > 1) {
        lines.push("Handle: none, because more than one handle matches");
        lines.push(`Ambiguous: ${distinct.join(", ")}`);
    } else if (sendRefusal({ recipient: handle, service, text: "x" }) === null) {
        lines.push(`Handle: ${handle}`);
    } else {
        lines.push(`Handle: none, because Messages files them as "${oneLine(handle).slice(0, 80)}", which this `
            + "connector cannot address");
    }
    lines.push(`Service: ${service}`, `Why this service: ${why}`);
    if (det.known.size) {
        lines.push("Evidence on this Mac:");
        for (const s of Object.keys(det.seen).sort((a, b) => det.seen[b] - det.seen[a])) {
            lines.push(`  • messages exchanged on ${oneLine(s)}, last ${iso(det.seen[s])}`);
        }
        // One line per SERVICE, not per row: a contact with several chats or
        // handles on the same service repeated the same sentence.
        for (const s of [...new Set(det.chats.map((c) => oneLine(c.service_name)))].sort()) {
            lines.push(`  • an ${s} conversation exists`);
        }
        for (const s of [...new Set(det.handles.map((h) => oneLine(h.service)))].sort()) {
            lines.push(`  • registered as an ${s} address`);
        }
        if (det.downgraded) {
            lines.push(`  • ${det.downgraded} of his recent sends to them were DOWNGRADED to SMS by Messages `
                + "(asked for a richer service it could not use at that moment) — not counted as evidence");
        }
        lines.push(det.known.has("iMessage")
            ? "They have an iMessage address, so they are on an Apple device."
            : "NO iMessage address at all — almost certainly an Android phone. Sending as iMessage would fail silently.");
    } else {
        lines.push("Nothing known about this recipient on this Mac — the service cannot be determined from here.");
    }
    return { isError: false, text: lines.join("\n") };
}

/// The answer for someone in none of the chats this bot may read: the Handle
/// and the Service a send needs, and nothing of the history behind them. The
/// same words whether or not the user has ever texted them, as a refused read is.
function outsideTheChats(det, given, handle, service) {
    const lines = [`Recipient: ${given}`];
    const people = new Set([...det.handles.map((h) => h.id), ...det.chats.map((c) => c.chat_identifier)]
        .map((value) => digitsOf(oneLine(value)) || oneLine(value).toLowerCase()));
    if (people.size > 1) {
        lines.push("Handle: none, because more than one handle matches",
                   "Ambiguous: more than one address on this Mac ends in these digits");
    } else if (sendRefusal({ recipient: handle, service, text: "x" }) === null) {
        lines.push(`Handle: ${handle}`);
    } else {
        lines.push("Handle: none, because Messages files them under a name this connector cannot address");
    }
    lines.push(`Service: ${service}`,
               "Why this service: decided from what Messages keeps about this address. None of the chats this "
               + "bot may read is with them, so the history behind it is not shown.");
    return { isError: false, text: lines.join("\n") };
}

// ─────────────────────────────────────────────────────────────────── sending

const SEND_SCRIPT = (type) => `on run argv
set theRecipient to item 1 of argv
set theText to item 2 of argv
tell application "Messages"
	set theService to 1st service whose service type = ${type}
	send theText to buddy theRecipient of theService
end tell
return "sent"
end run`;

/**
 * Send into an existing conversation using `any;-;<number>` chat ids. Messages selects
 * transport per message. This supports RCS where the scriptable RCS service is disabled and a
 * direct buddy send would downgrade to SMS.
 * Use `tell application "Messages"`; its bundle-id equivalent is `application id
 * "com.apple.MobileSMS"`.
 */
const SEND_TO_CHAT_SCRIPT = `on run argv
set theChat to item 1 of argv
set theText to item 2 of argv
tell application "Messages"
	send theText to chat id theChat
end tell
return "sent"
end run`;

/**
 * Exact-match lookup of the conversation Messages keeps for the handle on the
 * card — no suffix matching and no preference decision: it only decides how to
 * address the very same recipient the user approved.
 */
async function conversationGUID(recipient) {
    try {
        const rows = await sql(`SELECT guid FROM chat WHERE chat_identifier = ${sqlText(recipient)}
                                AND chat_identifier NOT GLOB 'chat[0-9]*' AND guid IS NOT NULL
                                ORDER BY last_read_message_timestamp DESC LIMIT 1`.replace(/\s+/g, " "));
        return rows.length ? String(rows[0].guid) : null;
    } catch (_) {
        return null;
    }
}

/**
 * Messages' own wording for a conversation its scripting layer cannot see, and nothing else:
 * the error has to END with that sentence about the very conversation asked for, with either
 * apostrophe. -1728 is Apple's "no such object", which Messages raises for more than an
 * unloaded conversation, and after any other failure the first send may have gone: the buddy
 * route would then send a second text no card showed. Matching any -1728 did exactly that. A
 * text that names a chat id never falls back either, since an error quoting its words could end
 * with the sentence.
 */
function isUnaddressableChat(err, chat, text) {
    const detail = String((err && (err.stderr || err.message)) || "").trim();
    if (/chat id/i.test(String(text))) return false;
    return ["’", "'"].some((apostrophe) =>
        detail.endsWith(`Can${apostrophe}t get chat id "${chat}". (-1728)`));
}

/**
 * Best-effort outcome check. The send call itself proves nothing, so look for
 * the row Messages wrote and report what it says. Anything unknown is reported
 * as unknown — never as success, and a hand-off is never called a delivery.
 */
async function confirm(rowids, sinceUnix, sentText, requested) {
    if (!rowids.length) return null;
    const sinceApple = (sinceUnix - APPLE_EPOCH - 2) * 1e9;
    const wanted = String(sentText || "").trim();
    for (let attempt = 0; attempt < 6; attempt++) {
        await sleep(attempt === 0 ? 800 : 1000);
        let rows = [];
        try {
            rows = await sql(`SELECT service, error, is_sent, is_delivered, was_downgraded, date,
                                     text, hex(attributedBody) AS blob FROM message
                              WHERE handle_id IN (${rowids.join(",")}) AND is_from_me = 1
                                AND date > ${Math.round(sinceApple)}
                              ORDER BY date DESC LIMIT 5`.replace(/\s+/g, " "));
        } catch (_) {
            return null;   // a WAL or permission hiccup: say nothing rather than guess
        }
        // Matched on the TEXT: the window is time-based, so a text the user types to
        // the same person on their iPhone mid-poll would otherwise be reported as
        // THIS send's outcome.
        const r = rows.find((row) => bodyOf(row).trim() === wanted);
        if (!r) continue;
        const on = oneLine(r.service) || "an unrecorded service";
        if (Number(r.error)) {
            return { ok: false,
                     text: `Messages recorded a FAILURE on ${on} (error code ${Number(r.error)}) — it did not go through.` };
        }
        // Messages records a text it could not send on the richer service as
        // `was_downgraded = 1` on the SMS row. Said as one fact, not two.
        const downgrade = Number(r.was_downgraded)
            ? ` — Messages DOWNGRADED it to ${on}${requested !== on ? ` (the card said ${requested})` : ""}: `
              + "they could not be reached on the richer service at that moment, so it went as a plain text"
            : "";
        if (Number(r.is_delivered)) {
            return { ok: true, text: `delivered on ${on}${downgrade}` };
        }
        if (Number(r.is_sent)) {
            return { ok: true, text: `sent on ${on}; delivery not confirmed yet${downgrade}` };
        }
    }
    return null;
}

async function sendMessage(args) {
    const refused = sendRefusal(args);
    if (refused) return { isError: true, text: refused };
    // No outbox here, and no lookup that could change the answer. The card the user
    // approved showed exactly these three values, and they are sent as they are.
    const { recipient, service, text } = args;
    const startedAt = Date.now() / 1000;

    // Address the conversation when Messages already keeps one for this exact
    // handle; otherwise a buddy of a service that can actually carry a first
    // message. The disabled RCS account cannot; the SMS relay can, and Messages
    // upgrades it to RCS when the other side supports it — which is why the RCS
    // card says Messages may still send it as SMS, and every other card that
    // Messages may still send it on another service.
    const chat = await conversationGUID(recipient);
    const buddyService = service === "RCS" ? "SMS" : service;
    const buddyRoute = `as ${buddyService}`
        + (buddyService !== service
            ? " (the disabled RCS account cannot carry it — the SMS relay upgrades to RCS when it can)" : "");
    try {
        await ensureMessagesRunning();
    } catch (err) {
        return { isError: true, text: `${err.message} Nothing was handed to Messages, so nothing was sent.` };
    }
    let route;
    try {
        if (chat) {
            try {
                await osascript(SEND_TO_CHAT_SCRIPT, [chat, text]);
                route = `into their conversation (${oneLine(chat)}) — Messages picks iMessage, RCS or SMS itself`;
            } catch (err) {
                // Messages' scripting layer exposes only the recently loaded conversations, so
                // a conversation chat.db holds can still be unaddressable. The conversation
                // route is an optimisation; the buddy route is what always worked. A timeout is
                // NOT this error and falls through to the outcome-unknown answer below.
                if (!isUnaddressableChat(err, chat, text) || err.killed || err.signal) throw err;
                await osascript(SEND_SCRIPT(buddyService), [recipient, text]);
                route = `${buddyRoute} (their conversation exists but Messages could not address it by id — only recently loaded conversations are)`;
            }
        } else {
            await osascript(SEND_SCRIPT(buddyService), [recipient, text]);
            route = buddyRoute + (buddyService !== service ? "" : " (no conversation yet)");
        }
    } catch (err) {
        if (err.killed || err.signal) {
            // Deliberately NOT an error: a failure goes on the record as a
            // failed send, and a text that may well have gone out must not be
            // written down as one. The words carry the uncertainty instead.
            return { isError: false,
                     text: "TIMED OUT waiting for Messages — the outcome is UNKNOWN: the text MAY OR MAY NOT have "
                         + "been sent. Not yet checked: the conversation itself, and whether a macOS permission "
                         + "prompt for Automation → Messages is waiting to be answered." };
        }
        const detail = (err.stderr || err.message || "").trim();
        return { isError: true,
                 text: `Messages did not take the text on ${service}: ${detail}\n(If this names permissions, `
                     + `Automation → Messages must be allowed for ${APP_NAME} in System Settings → Privacy & `
                     + "Security → Automation.)" };
    }

    // This lookup only READS chat.db to find the row Messages just wrote; the
    // text has already gone to the recipient and service above, and nothing
    // here can change where it went. Suffix-matched handles are how the row is
    // found for a formatting variant or a first-time contact.
    let handles = [];
    try { handles = (await detect(recipient)).handles; } catch (_) {}
    const rowids = handles.map((h) => Number(h.rowid)).filter(Number.isFinite);
    const check = await confirm(rowids, startedAt, text, service);
    const lines = [
        `Handed to Messages ${route} → ${recipient}`,
        `Service on the card: ${service}`,
    ];
    if (check) {
        lines.push(`Status: ${check.text}`);
    } else {
        lines.push("Status: NOT CONFIRMED — Messages had not recorded the outcome yet, and a red 'Not "
            + "Delivered' can still appear afterwards.");
    }
    return { isError: check ? !check.ok : false, text: lines.join("\n") };
}

// ─────────────────────────────────────────────────────────────── MCP plumbing

const TOOLS = [
    {
        name: "send_message",
        description:
            "Send a text through Apple Messages as the user, from his own number. Call "
            + "check_message_service first, then pass EXACTLY the Handle and the Service it "
            + "returned — iMessage, RCS or SMS. There is no automatic choice here: he approves the "
            + "recipient, the service and the exact words on a card before anything is sent, and the text "
            + "goes out exactly as you pass it. Never pass a person's name; look them up with the Contacts "
            + "connector first.",
        inputSchema: {
            type: "object",
            properties: {
                recipient: { type: "string", description: "The handle check_message_service returned: digits with an optional leading +, or a plain email address." },
                service: { type: "string", enum: SERVICES, description: "The service check_message_service named." },
                text: { type: "string", description: `The exact words, at most ${MAX_TEXT_SCALARS} characters. Plain newlines are fine.` },
            },
            required: ["recipient", "service", "text"],
        },
    },
    {
        name: "read_messages",
        description:
            "Read his Messages history as real text — the bodies Apple keeps in an archived form are "
            + "decoded. It reads only the chats he chose for this bot in the app; omit `recipient` to read "
            + "across all of them, or name a person to read the chosen chats they are in.",
        inputSchema: {
            type: "object",
            properties: {
                recipient: { type: "string", description: "Phone number or email. Omit for all the chats this bot may read." },
                limit: { type: "number", description: "How many messages (1-100, default 20)." },
                unread_only: { type: "boolean", description: "Only unread incoming messages." },
            },
        },
    },
    {
        name: "check_message_service",
        description:
            "Report which Service (iMessage, RCS or SMS) a text to this person should go out on, the exact "
            + "Handle to send it to (none when more than one matches, listed under Ambiguous), and the "
            + "history this Mac has with them — without sending anything. Call it before every "
            + "send_message and pass its Handle and Service on.",
        inputSchema: {
            type: "object",
            properties: {
                recipient: { type: "string", description: "Phone number (any format) or email address." },
            },
            required: ["recipient"],
        },
    },
];

const HANDLERS = {
    send_message: sendMessage,
    read_messages: readMessages,
    check_message_service: checkService,
};

function write(obj) { process.stdout.write(JSON.stringify(obj) + "\n"); }

/// Use one request per 0x0A byte, matching fence-proxy framing. `readline` also splits at
/// U+000D, U+2028 and U+2029, while JSON.stringify can leave the last two inside strings. Byte
/// framing prevents valid calls from splitting into parse errors and rejoins split UTF-8
/// characters before decoding.
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
            return {
                // Echo the client's protocol version when it looks like one:
                // disagreeing on the string is the classic reason a server
                // never appears.
                protocolVersion: /^\d{4}-\d{2}-\d{2}$/.test(params?.protocolVersion || "")
                    ? params.protocolVersion : "2024-11-05",
                capabilities: { tools: {} },
                serverInfo: { name: "openbots-apple-messages", version: "1.0.0" },
            };
        case "tools/list":
            return { tools: TOOLS };
        case "tools/call": {
            const fn = Object.prototype.hasOwnProperty.call(HANDLERS, params?.name) ? HANDLERS[params.name] : null;
            if (!fn) throw new Error(`unknown tool: ${params?.name}`);
            const argumentsObject = params.arguments && typeof params.arguments === "object"
                && !Array.isArray(params.arguments) ? params.arguments : {};
            const res = await fn(argumentsObject);
            return { content: [{ type: "text", text: res.text }], isError: !!res.isError };
        }
        case "ping":
            return {};
        default: {
            const e = new Error(`method not found: ${method}`);
            e.code = -32601;
            throw e;
        }
    }
}

onRequestLine(process.stdin, async (line) => {
    const raw = line.trim();
    if (!raw) return;
    let msg;
    try {
        msg = JSON.parse(raw);
    } catch (_) {
        return write({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } });
    }
    // Notifications carry no id and MUST NOT be answered.
    if (msg.id === undefined || msg.id === null) return;
    try {
        write({ jsonrpc: "2.0", id: msg.id, result: await dispatch(msg.method, msg.params) });
    } catch (err) {
        // A failing TOOL is a normal result with isError, not a protocol error —
        // otherwise the agent sees a dead server instead of a message it can act on.
        if (msg.method === "tools/call") {
            write({ jsonrpc: "2.0", id: msg.id,
                    result: { content: [{ type: "text", text: String(err.message || err) }], isError: true } });
        } else {
            write({ jsonrpc: "2.0", id: msg.id,
                    error: { code: err.code || -32603, message: String(err.message || err) } });
        }
    }
});
