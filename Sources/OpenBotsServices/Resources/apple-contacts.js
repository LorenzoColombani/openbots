#!/usr/bin/env node
"use strict";
/*
 * OpenBots apple-contacts — read-only lookups in the user's own Contacts.app.
 *
 * WHY THIS ROW EXISTS: without Contacts, the Messages and Mail connectors are
 * crippled. Messages needs a number or an address and must
 * never be handed a person's name; mail has the same hole. A bot told "write to
 * Charles" either asks the user for an address their Mac already holds, or guesses.
 * This server closes that, and does nothing else: search people, read one card.
 *
 * READ-ONLY BY CONSTRUCTION, not by a flag. There is no create, edit, delete or
 * save verb anywhere in this file, so there is no tool for one to be called
 * through. Contacts' own scripting dictionary has `add`, `remove` and `save`;
 * none of them is reachable from here.
 *
 * WHY JavaScript for Automation rather than AppleScript, which the mail sender
 * uses. Contacts hands back lists whose entries are `missing value` — a person
 * with no organisation, a card with no phone — and AppleScript cannot coerce
 * such a list to text without erroring, so an AppleScript version of this file
 * would be a page of text-item-delimiter bookkeeping around every field. JXA
 * returns `null` for the same value and `JSON.stringify` for the whole answer,
 * so the shape that reaches node is checked by a parser instead of by eye. The
 * safety property the mail sender was written for is kept exactly: values
 * travel as `argv` into `run(argv)` and are never interpolated into the script
 * source, so nothing a bot types can break out of a string.
 *
 * ONE NORMALISER. The card in the app and the sender's own script drifted twice
 * over how they folded a subject, so matching
 * here happens in ONE place: `normalise` in this file, in node. The scripts
 * that talk to Contacts return raw values and decide nothing. Nothing in the
 * JXA source below compares, folds or filters anything.
 *
 * CONTACTS IS LAUNCHED HIDDEN. An Apple event to an app that is not running
 * launches it, and a quiet lookup that throws a window onto the user's screen
 * mid-turn is a defect the suite cannot see. So it is started with
 * `open -g -j` — background, hidden — and only when it is not already running.
 */

const { execFile } = require("child_process");

// Env overrides are for TESTS ONLY (stub scripts); production never sets them.
const OSASCRIPT = process.env.OPENBOTS_OSASCRIPT || "/usr/bin/osascript";
const OPEN = process.env.OPENBOTS_OPEN || "/usr/bin/open";
const PGREP = process.env.OPENBOTS_PGREP || "/usr/bin/pgrep";
// Which Contacts to start, resolved on the Swift side and passed in, so the
// row's badge and the app this actually launches cannot be two different
// copies — the failure that comes of looking the same thing up twice.
const CONTACTS_APP = process.env.OPENBOTS_CONTACTS_APP || "/System/Applications/Contacts.app";
// The app name comes in from the Swift side (AppleContactsConnectorPreparation
// passes OPENBOTS_APP_NAME) so the permission hint names the app the user
// will actually find in System Settings.
const APP_NAME = process.env.OPENBOTS_APP_NAME || "OpenBots Next";

/// How long to wait for a hidden Contacts to come up. Deliberately generous:
/// a one-to-three-second deadline on a real child process is the thing that
/// makes five of this repo's test files flaky on a busy Mac, and a first launch
/// of Contacts on a cold disk is slower than an idle one.
const LAUNCH_DEADLINE_MS = 20000;
const LAUNCH_POLL_MS = 250;

/// The most cards one search may put in front of the model, and the default.
/// A bot that asks for more gets the cap, and the answer says how many matched
/// in total, so "there are forty Duponts" is still an answer it can act on.
const MAX_RESULTS = 25;
const DEFAULT_RESULTS = 10;

function run(cmd, args, stdin) {
    return new Promise((resolve, reject) => {
        const child = execFile(
            cmd, args, { maxBuffer: 16 * 1024 * 1024, timeout: 60000 },
            (err, stdout, stderr) => {
                if (err) { err.stderr = String(stderr || ""); return reject(err); }
                resolve(String(stdout));
            });
        if (stdin !== undefined) {
            child.stdin.on("error", () => {});
            child.stdin.end(stdin);
        }
    });
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function isContactsRunning() {
    // Scoped to this user, and that is not a detail. A bare `pgrep -x` matches
    // every account's processes, so under fast user switching another user's
    // Contacts would answer "already running", the hidden launch would be
    // skipped, and the Apple event would then start Contacts for THIS user with
    // no -g and no -j — a window on their screen, which is the one thing this
    // function exists to prevent.
    try { await run(PGREP, ["-U", String(process.getuid()), "-x", "Contacts"]); return true; }
    catch (_) { return false; }        // pgrep exits non-zero when nothing matches
}

/// Start Contacts without letting it take the screen, and only if it is not
/// already the user's own open window. `-g` keeps it behind, `-j` launches it hidden.
async function ensureContactsRunning() {
    if (await isContactsRunning()) return;
    try { await run(OPEN, ["-g", "-j", "-a", CONTACTS_APP]); }
    catch (err) {
        throw new Error(`Contacts could not be started: ${(err.stderr || err.message || "").trim()}`);
    }
    const deadline = Date.now() + LAUNCH_DEADLINE_MS;
    while (Date.now() < deadline) {
        if (await isContactsRunning()) return;
        await sleep(LAUNCH_POLL_MS);
    }
    throw new Error("Contacts did not finish starting, so nothing could be looked up.");
}

/// One JXA run. The source is this file's own constant; every value the caller
/// supplies travels in `argv` and is never part of the source.
async function jxa(source, argv) {
    await ensureContactsRunning();
    const out = await run(OSASCRIPT, ["-l", "JavaScript", "-", ...argv], source);
    const text = out.trim();
    if (!text) throw new Error("Contacts returned nothing.");
    try { return JSON.parse(text); }
    catch (_) { throw new Error(`Contacts returned something this server cannot read: ${text.slice(0, 200)}`); }
}

// ────────────────────────────────────────────────────────────────────── JXA

/// Shared by both scripts: read one property across a whole collection in a
/// single Apple event where the bridge allows it, and one card at a time where
/// it does not. The fallback is not defensive dressing — an address book is
/// read through a bridge whose bulk form is undocumented for some elements, and
/// a connector that silently returns nothing when the fast path is unavailable
/// is the failure this repo keeps paying for.
const JXA_PRELUDE = `
function column(collection, key) {
    const count = collection.length;
    try {
        const bulk = collection[key]();
        // The length check is the whole guard, and it is not paranoia. Most
        // cards have no organisation and no nickname, and plenty of addresses
        // carry no label; a bridge that OMITS the empty ones rather than
        // returning a hole gives back a shorter column, and a shorter column
        // read alongside a full one silently pairs person 5's id with person
        // 6's organisation. Nothing downstream could ever notice. So a column
        // that does not line up with the collection it came from is not used:
        // the per-element path below is index-correct by construction, and
        // slower is the right price.
        if (Array.isArray(bulk) && bulk.length === count) {
            return bulk.map(function (v) { return v === undefined ? null : v });
        }
    } catch (e) {}
    const out = [];
    for (let i = 0; i < count; i++) {
        try { const v = collection[i][key](); out.push(v === undefined ? null : v); }
        catch (e) { out.push(null); }
    }
    return out;
}
function pairs(collection) {
    const labels = column(collection, "label");
    const values = column(collection, "value");
    const out = [];
    for (let i = 0; i < values.length; i++) {
        if (values[i] === null || values[i] === "") continue;
        // Loose on purpose: an absent label must read as no label, never as
        // the word "undefined" printed where "work" or "home" belongs. Which
        // of the two an address is, is how a bot picks the right one.
        out.push({ label: labels[i] == null ? "" : String(labels[i]), value: String(values[i]) });
    }
    return out;
}
`;

/// Every person's identifying fields, in as few Apple events as the bridge
/// allows. Nothing is filtered here: node owns the one matcher.
const JXA_ROSTER = `${JXA_PRELUDE}
function run(argv) {
    const app = Application("com.apple.AddressBook");
    const people = app.people;
    const rows = {
        id: column(people, "id"),
        name: column(people, "name"),
        firstName: column(people, "firstName"),
        lastName: column(people, "lastName"),
        nickname: column(people, "nickname"),
        organization: column(people, "organization"),
        company: column(people, "company"),
    };
    return JSON.stringify(rows);
}`;

/// The cards named in argv, in the order they were asked for. Looked up by
/// position inside this one run rather than by a `whose` filter: `id` is read
/// in the same script that indexes the collection, so the two cannot disagree
/// even if the user edits a card between two tool calls.
const JXA_CARDS = `${JXA_PRELUDE}
function run(argv) {
    const app = Application("com.apple.AddressBook");
    const people = app.people;
    const ids = column(people, "id");
    // Null-prototype on purpose: an id can come from the model, and a plain
    // object would answer "yes, I have that" to "__proto__" and hand back a
    // card of nulls marked found instead of saying there is no such card.
    const positions = Object.create(null);
    for (let i = 0; i < ids.length; i++) {
        if (ids[i] !== null && !(ids[i] in positions)) positions[ids[i]] = i;
    }
    const out = [];
    for (let a = 0; a < argv.length; a++) {
        const wanted = argv[a];
        if (!(wanted in positions)) { out.push({ id: wanted, found: false }); continue; }
        const person = people[positions[wanted]];
        const card = { id: wanted, found: true };
        const scalars = ["name", "firstName", "lastName", "nickname", "organization",
                         "jobTitle", "department", "company"];
        for (let s = 0; s < scalars.length; s++) {
            let v = null;
            try { v = person[scalars[s]](); } catch (e) { v = null; }
            card[scalars[s]] = v === undefined ? null : v;
        }
        try { card.emails = pairs(person.emails); } catch (e) { card.emails = []; }
        try { card.phones = pairs(person.phones); } catch (e) { card.phones = []; }
        try {
            const addresses = person.addresses;
            const labels = column(addresses, "label");
            const formatted = column(addresses, "formattedAddress");
            const list = [];
            for (let i = 0; i < formatted.length; i++) {
                if (formatted[i] === null || formatted[i] === "") continue;
                list.push({ label: labels[i] === null ? "" : String(labels[i]),
                            value: String(formatted[i]) });
            }
            card.addresses = list;
        } catch (e) { card.addresses = []; }
        out.push(card);
    }
    return JSON.stringify(out);
}`;

// ──────────────────────────────────────────────────────────── The matcher

/// The one place a name is folded for comparison, and the reason there is only
/// one: two of them drift, and the drift is invisible until it answers with the
/// wrong person. Accents come off both sides — many names carry accents, and
/// "Duran" must find "Duràn" — case is folded, and the ordinary
/// punctuation of a name is treated as a space, so "O'Brien", "O Brien" and
/// "OBrien" are one query.
function normalise(value) {
    return String(value === null || value === undefined ? "" : value)
        .normalize("NFD")
        .replace(/[̀-ͯ]/g, "")
        .toLowerCase()
        .replace(/[^\p{L}\p{N}@.+_-]+/gu, " ")
        .trim()
        .replace(/\s+/g, " ");
}

/// Every word of the query has to appear somewhere on the card. "charles
/// dupont" finds the Charles whose surname is Dupont and not the other four
/// Charleses, and the words may arrive in either order.
function matches(haystack, tokens) {
    return tokens.every((token) => haystack.includes(token));
}

function tokensOf(query) {
    const folded = normalise(query);
    return folded ? folded.split(" ") : [];
}

/// The searchable text of one person: everything a human would call them by.
function haystackOf(roster, index) {
    return normalise([roster.name[index], roster.firstName[index], roster.lastName[index],
                      roster.nickname[index], roster.organization[index]]
        .filter((v) => v !== null && v !== undefined && v !== "").join(" "));
}

// ─────────────────────────────────────────────────────────────── Rendering

/// Everything a card carries is rendered into a line-per-fact answer, so a
/// field holding a line break could write a line of its own — a second
/// "Email (work):" under a real person, or a fake "id:" the bot would then
/// pass to read_contact. An address book is mostly its owner's own typing, but a
/// vCard arrives from whoever sent it. So every value is folded to one line
/// before it becomes part of a line. The postal address is the single
/// exception, and it is handled where it is rendered: its lines are real, and
/// they are indented under their own heading rather than left at the margin.
function oneLine(value) {
    return String(value === null || value === undefined ? "" : value)
        .replace(/[\r\n\u2028\u2029\u0085]+/g, " ")
        .replace(/\s+/g, " ")
        .trim();
}

/// AddressBook stores Apple's own labels as `_$!<Work>!$_`, not as "work".
/// In a real address book most numbers carry `_$!<Mobile>!$_`, and
/// `_$!<Work>!$_`, `_$!<Home>!$_`, `_$!<Other>!$_`, `_$!<Main>!$_` and
/// `_$!<WorkFAX>!$_` are common too — most labels wear the wrapper. Printed raw, the one thing a bot needs the label for
/// — is this the work address or the home one — is buried in punctuation.
/// A label the user typed ("Personal", "Sam Gmail") arrives as the words they
/// typed and must be left exactly as it is, so only a whole string wearing the
/// wrapper is unwrapped. Nothing here translates: `_$!<WorkFAX>!$_` becomes
/// `WorkFAX`, because inventing prettier words is how two renderings of the
/// same label start to disagree.
const APPLE_LABEL = /^_\$!<(.*)>!\$_$/;
/// Every opening and closing bracket Unicode knows — ( [ { and their
/// full-width, small, superscript and ornate look-alikes — by general category,
/// not by a list that misses the next one. ASCII < and > are not in it: they
/// are maths signs, not brackets, and do not pass for the card's own ( ).
const LABEL_BRACKETS = /[\p{Ps}\p{Pe}]/gu;
function labelText(value) {
    // Fold first, unwrap second. The fold is what stops a label writing a line
    // of its own, and it does that in either order — this order is about what
    // is left to unwrap. A JavaScript `.` does not match a line terminator, so
    // matching the raw value would miss every wrapper with a line break inside
    // it and print the punctuation after all; folded, there are none left to
    // miss, and `(.*)` catches the empty label the same way.
    const folded = oneLine(value);
    const wrapped = APPLE_LABEL.exec(folded);
    const label = wrapped ? wrapped[1] : folded;
    // Then its brackets go. The card prints the label inside brackets it supplies, so a label
    // reading `Work): someone@elsewhere.test — Email (Home` closes them early
    // and reads as a second, tidy address. The words stay; only a label's
    // brackets are taken out, never a value's — "(555) 123" is the user's data.
    return label.replace(LABEL_BRACKETS, "").replace(/\s+/g, " ").trim();
}

function displayName(card) {
    const name = oneLine(card.name);
    if (name) return name;
    const parts = [card.firstName, card.lastName].map(oneLine).filter(Boolean);
    if (parts.length) return parts.join(" ");
    return oneLine(card.organization) || "a card with no name";
}

/// One line per address or number. `multiline` is passed only by the postal
/// addresses, whose line breaks are real: Contacts' own dictionary says the
/// street is carriage-return separated, and running them together turns
/// "1 rue de l'Exemple / Paris" into one unreadable string. Those lines are indented
/// under their own heading, so they read as part of the address rather than as
/// facts of their own.
function renderPairs(label, list, multiline = false) {
    if (!list || !list.length) return [];
    return list.map((entry) => {
        const shown = labelText(entry.label);
        const head = `  ${label}${shown ? ` (${shown})` : ""}:`;
        if (!multiline) return `${head} ${oneLine(entry.value)}`;
        const lines = String(entry.value).split(/\r\n|\r|\n|\u2028|\u2029|\u0085/)
            .map((line) => oneLine(line)).filter(Boolean);
        if (lines.length <= 1) return `${head} ${lines[0] || ""}`;
        return [head, ...lines.map((line) => `    ${line}`)].join("\n");
    });
}

function renderCard(card) {
    const title = displayName(card);
    const lines = [title];
    // A company card has no person's name on it, so the organisation IS the
    // title; printing it again underneath reads like two different facts.
    const where = [card.jobTitle, card.department, card.organization]
        .map(oneLine).filter((v) => v && v !== title).join(", ");
    if (where) lines.push(`  ${card.company ? "Company" : "Work"}: ${where}`);
    lines.push(...renderPairs("Email", card.emails));
    lines.push(...renderPairs("Phone", card.phones));
    lines.push(...renderPairs("Address", card.addresses, true));
    if (lines.length === 1) lines.push("  (no email address, phone number or postal address on this card)");
    lines.push(`  id: ${oneLine(card.id)}`);
    return lines.join("\n");
}

/// What a refusal from macOS looks like, said once and in plain words. Automation
/// is asked for per target app, so a Mac that already lets this app drive Mail
/// still has to be asked about Contacts, and the first lookup is when macOS
/// asks.
function failureText(err, what) {
    const detail = (err.stderr || err.message || "").trim();
    const refused = /not authori[sz]ed|-1743|User canceled|not allowed to send Apple events/i.test(detail);
    if (refused) {
        return `Contacts refused: ${detail}\n(Automation → Contacts must be allowed for ${APP_NAME} in `
             + "System Settings → Privacy & Security. macOS asks the first time, and it asks about "
             + "Contacts separately from every other app.)";
    }
    return `${what}: ${detail || "no detail"}`;
}

// ─────────────────────────────────────────────────────────────── The tools

async function searchContacts(args) {
    const raw = typeof args.query === "string" ? args.query : "";
    // The words are echoed back inside the answer's own sentences, so they are
    // folded and bounded where they enter, not where the sentence ends —
    // otherwise a query carrying a line break writes a line of its own.
    const query = oneLine(raw).slice(0, 120);
    const tokens = tokensOf(raw);
    if (!tokens.length) {
        return { isError: true,
                 text: "Say who to look for: `query` has to carry at least one letter or digit." };
    }
    const asked = Number.isFinite(args.limit) ? Math.floor(args.limit) : DEFAULT_RESULTS;
    const limit = Math.max(1, Math.min(MAX_RESULTS, asked));
    let roster;
    try { roster = await jxa(JXA_ROSTER, []); }
    catch (err) { return { isError: true, text: failureText(err, "Contacts could not be read") }; }
    if (!roster || !Array.isArray(roster.id)) {
        return { isError: true, text: "Contacts answered in a shape this server does not understand." };
    }
    // An address book with nothing in it is not "that person isn't in your
    // contacts" — that answer would send the bot off to ask the user for an address on the
    // strength of a read that never worked. Almost always this is Contacts
    // still loading its accounts, or a book that genuinely holds nobody.
    if (roster.id.length === 0) {
        return { isError: true,
                 text: "His Contacts came back empty — not \"nobody matches\", but no cards at all. "
                     + "Do not conclude the person is missing: say the address book could not be "
                     + "read, and ask him to check Contacts is set up on this Mac." };
    }
    // The columns are separate reads of the same collection, so they are only
    // one another's rows while they are the same length. Short-circuit loudly
    // rather than pair one person's name with another's organisation.
    for (const [field, values] of Object.entries(roster)) {
        if (!Array.isArray(values) || values.length !== roster.id.length) {
            return { isError: true,
                     text: `Contacts answered inconsistently — it returned ${roster.id.length} people `
                         + `but a different number of "${field}" values, so no answer here could be `
                         + "trusted to belong to the right person. Nothing was read." };
        }
    }
    const hits = [];
    for (let i = 0; i < roster.id.length; i++) {
        if (roster.id[i] === null) continue;
        if (matches(haystackOf(roster, i), tokens)) hits.push(roster.id[i]);
    }
    if (!hits.length) {
        return { isError: false,
                 text: `No one in his Contacts matches "${query}". Say so rather than guessing an `
                     + "address, and ask him how the person is filed." };
    }
    const shown = hits.slice(0, limit);
    let cards;
    try { cards = await jxa(JXA_CARDS, shown); }
    catch (err) { return { isError: true, text: failureText(err, "That card could not be read") }; }
    const rendered = (Array.isArray(cards) ? cards : []).filter((c) => c && c.found).map(renderCard);
    if (!rendered.length) {
        return { isError: false,
                 text: `"${query}" matched ${hits.length} ${hits.length === 1 ? "card" : "cards"}, but `
                     + "none of them could be read back. Nothing was changed; tell him that." };
    }
    const head = hits.length > shown.length
        ? `${hits.length} people match "${query}"; here are the first ${rendered.length}. Narrow the `
          + "search, or ask him which one."
        : `${rendered.length} ${rendered.length === 1 ? "person matches" : "people match"} "${query}".`;
    const tail = rendered.length > 1
        ? "\n\nMore than one person came back — name them to him and let him pick, rather than "
          + "choosing an address for him."
        : "";
    return { isError: false, text: `${head}\n\n${rendered.join("\n\n")}${tail}` };
}

async function readContact(args) {
    const id = typeof args.id === "string" ? args.id.trim() : "";
    if (!id) {
        return { isError: true,
                 text: "`id` is required: it is the `id:` line search_contacts printed under the person." };
    }
    let cards;
    try { cards = await jxa(JXA_CARDS, [id]); }
    catch (err) { return { isError: true, text: failureText(err, "That card could not be read") }; }
    const card = Array.isArray(cards) ? cards[0] : null;
    if (!card || !card.found) {
        return { isError: true,
                 text: "There is no card with that id in his Contacts any more. Search again by name "
                     + "rather than reusing an id from earlier in the conversation." };
    }
    return { isError: false, text: renderCard(card) };
}

// ─────────────────────────────────────────────────────────── MCP plumbing

const TOOLS = [
    {
        name: "search_contacts",
        description: "Look someone up in the user's own Contacts and read their email addresses and "
            + "phone numbers. Use this BEFORE asking him for an address or a number — his Mac "
            + "already holds them, and asking for what he has saved is the thing this connector "
            + "exists to stop. Matches on first name, last name, the full name, a nickname and the "
            + "organisation; every word you pass has to appear on the card, so add a surname to "
            + "narrow it. Read-only: nothing can be added, changed or deleted from here.",
        inputSchema: { type: "object",
            properties: {
                query: { type: "string", description: "The person, as he would say it: \"Charles\", \"Charles Dupont\", or an organisation." },
                limit: { type: "number", description: `How many cards to return, 1 to ${MAX_RESULTS}. Defaults to ${DEFAULT_RESULTS}.` },
            },
            required: ["query"] },
    },
    {
        name: "read_contact",
        description: "Read one card in full — name, organisation, every email address, phone number "
            + "and postal address on it — by the `id` search_contacts returned for it. Read-only.",
        inputSchema: { type: "object",
            properties: {
                id: { type: "string", description: "The `id:` line search_contacts printed under that person. Ids belong to this Mac's Contacts; never invent one." },
            },
            required: ["id"] },
    },
];

const HANDLERS = {
    search_contacts: searchContacts,
    read_contact: readContact,
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
                     serverInfo: { name: "openbots-apple-contacts", version: "1.0.0" } };
        case "tools/list": return { tools: TOOLS };
        case "tools/call": {
            // Own names only: `constructor` or `toString` would otherwise resolve
            // through the prototype to a built-in and run as a tool.
            const fn = Object.prototype.hasOwnProperty.call(HANDLERS, params?.name) ? HANDLERS[params.name] : null;
            if (!fn) throw new Error(`unknown tool: ${params?.name}`);
            const res = await fn(params.arguments || {});
            return { content: [{ type: "text", text: res.text }], isError: !!res.isError };
        }
        case "ping": return {};
        default: { const e = new Error(`method not found: ${method}`); e.code = -32601; throw e; }
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
