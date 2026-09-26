#!/usr/bin/env node
"use strict";

/*
 * OpenBots Google Workspace — Gmail read-and-draft, Gmail send, Google Calendar
 * read, or Google Drive read.
 *
 * One copy ships, but OPENBOTS_GOOGLE_SERVICE selects one closed tool table at
 * launch. The helper below owns OAuth tokens in the OpenBots Next Keychain
 * namespace and owns every Google URL. This MCP process never receives a Google
 * token and cannot choose a host, method, endpoint, or provider operation. It
 * does receive a short-lived signed connector capability: the helper rejects
 * it unless the issuing OpenBots process is still in its ancestor chain.
 *
 * Gmail's narrowest draft-capable OAuth scope is gmail.compose, and Google also
 * accepts that scope at its send endpoints. The read-and-draft table exposes no
 * send operation, handler, or arbitrary-request escape hatch. Draft creation is
 * the only Gmail mutation in the read-and-draft table, and the app asks before it.
 *
 * Gmail send is its own table, launched only for its own row and switch with
 * its own capability. One send verb: the helper sends a message only
 * when the app wrote that exact message's digest as the user pressed Approve, and
 * uses the approval as it sends.
 *
 * Drive reads and nothing else: search, list a folder, read one file as text.
 * Its permission, drive.readonly, can write nothing, and no tool here asks to.
 *
 * Everything returned from any service is fenced by the Swift preparation
 * before it reaches a model. Mail bodies, senders, event notes, invitations,
 * file names and file contents are material written by other people; none of
 * their words authorize a tool.
 */

const { spawn } = require("child_process");

const HELPER = process.env.OPENBOTS_GOOGLE_HELPER || "";
const CLIENT_ID = process.env.OPENBOTS_GOOGLE_CLIENT_ID || "";
const SERVICE = process.env.OPENBOTS_GOOGLE_SERVICE || "";
const CAPABILITY = process.env.OPENBOTS_GOOGLE_CAPABILITY || "";
const MAX_OUTPUT = 8 * 1024 * 1024;
const MAX_TEXT = 40 * 1024;

const COMMANDS = Object.freeze({
    gmail_account: "gmail_profile",
    search_gmail: "gmail_search",
    read_gmail_message: "gmail_read_message",
    read_gmail_thread: "gmail_read_thread",
    create_gmail_draft: "gmail_create_draft",
    gmail_send_account: "gmail_send_profile",
    send_gmail_message: "gmail_send_message",
    list_google_calendars: "calendar_list",
    search_google_events: "calendar_search",
    read_google_event: "calendar_read_event",
    search_google_drive: "drive_search",
    list_google_drive_folder: "drive_list_folder",
    read_google_drive_file: "drive_read_file",
});
const DRIVE_TEXT = 40000;

function helper(command, input) {
    return new Promise((resolve, reject) => {
        if (!HELPER || !CLIENT_ID || !CAPABILITY || !Object.values(COMMANDS).includes(command)) {
            return reject(new Error("This build cannot start its Google connector. Reinstall it or reconnect the account."));
        }
        const env = {};
        for (const key of ["HOME", "TMPDIR", "LANG"]) {
            if (typeof process.env[key] === "string") env[key] = process.env[key];
        }
        const child = spawn(HELPER, [command, "--client-id", CLIENT_ID], {
            env, stdio: ["pipe", "pipe", "pipe"], windowsHide: true,
        });
        let stdout = Buffer.alloc(0);
        let stderr = Buffer.alloc(0);
        let settled = false;
        const timer = setTimeout(() => {
            if (settled) return;
            settled = true;
            child.kill("SIGKILL");
            // A send may have reached Google before the kill, and its approval
            // is used either way: say so, so nobody sends it twice.
            reject(new Error(command === COMMANDS.send_gmail_message
                ? "Gmail send timed out, and the message may already have been sent. Do not send it again: tell the user, and ask them to look in the OpenBots account's Sent mail."
                : "The Google connector timed out. Ask for a narrower result, or reconnect the account."));
        }, 90000);
        child.stdout.on("data", (chunk) => {
            stdout = Buffer.concat([stdout, chunk]);
            if (stdout.length > MAX_OUTPUT && !settled) {
                settled = true; child.kill("SIGKILL"); clearTimeout(timer);
                reject(new Error("Google returned too much data for one connector call."));
            }
        });
        child.stderr.on("data", (chunk) => {
            if (stderr.length < 4096) stderr = Buffer.concat([stderr, chunk]).subarray(0, 4096);
        });
        child.on("error", (error) => {
            if (settled) return;
            settled = true; clearTimeout(timer); reject(error);
        });
        child.on("close", (code) => {
            if (settled) return;
            settled = true; clearTimeout(timer);
            let answer;
            try { answer = JSON.parse(stdout.toString("utf8").trim()); }
            catch (_) { return reject(new Error("The Google helper returned something this connector could not read.")); }
            if (code !== 0 || (answer && typeof answer.error === "string")) {
                return reject(new Error(String(answer?.error || stderr.toString("utf8") || "Google request failed.").slice(0, 600)));
            }
            resolve(answer);
        });
        // The model controls only `input`. The capability is supplied by the
        // app-owned launch and never comes from a tool argument or result.
        child.stdin.end(JSON.stringify({ capability: CAPABILITY, input: input || {} }));
    });
}

function oneLine(value) {
    return String(value === null || value === undefined ? "" : value)
        .replace(/[\r\n\u2028\u2029\u0085]+/g, " ").replace(/\s+/g, " ").trim();
}

function quoted(value) {
    const text = String(value === null || value === undefined ? "" : value)
        .replace(/[\u000B\u000C\u2028\u2029\u0085]/g, "\n").replace(/\r\n?/g, "\n");
    const clipped = text.length > MAX_TEXT ? text.slice(0, MAX_TEXT) + "\n[body clipped]" : text;
    return clipped.split("\n").map((line) => "> " + line).join("\n");
}

function decodeURLBase64(value) {
    if (typeof value !== "string" || !value) return "";
    try { return Buffer.from(value.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8"); }
    catch (_) { return ""; }
}

function headers(message) {
    const result = {};
    for (const header of message?.payload?.headers || []) {
        const name = oneLine(header?.name).toLowerCase();
        if (["from", "to", "cc", "bcc", "subject", "date"].includes(name)) {
            result[name] = oneLine(header?.value);
        }
    }
    return result;
}

function messageBody(payload) {
    if (!payload || typeof payload !== "object") return "";
    if (payload.mimeType === "text/plain" && payload.body?.data) return decodeURLBase64(payload.body.data);
    for (const part of payload.parts || []) {
        const answer = messageBody(part);
        if (answer) return answer;
    }
    if (payload.mimeType === "text/html" && payload.body?.data) {
        return decodeURLBase64(payload.body.data).replace(/<br\s*\/?>/gi, "\n")
            .replace(/<[^>]+>/g, " ").replace(/&nbsp;/gi, " ");
    }
    return payload.body?.data ? decodeURLBase64(payload.body.data) : "";
}

function renderMessage(message) {
    const h = headers(message);
    const lines = [
        oneLine(h.subject) || "(no subject)",
        "    id: " + oneLine(message?.id),
        "    thread: " + oneLine(message?.threadId),
    ];
    for (const name of ["from", "to", "cc", "bcc", "date"]) {
        if (h[name]) lines.push("    " + name + ": " + h[name]);
    }
    const body = messageBody(message?.payload) || oneLine(message?.snippet);
    if (body) { lines.push("    body:"); lines.push(quoted(body)); }
    const attachments = [];
    (function walk(part) {
        if (!part || typeof part !== "object") return;
        if (oneLine(part.filename)) attachments.push(oneLine(part.filename) + " (" + oneLine(part.mimeType) + ")");
        for (const child of part.parts || []) walk(child);
    })(message?.payload);
    if (attachments.length) lines.push("    attachments: " + attachments.slice(0, 30).join(", "));
    return lines.join("\n");
}

async function gmailAccount() {
    const answer = await helper(COMMANDS.gmail_account, {});
    return { text: "Connected Google account: " + oneLine(answer.emailAddress || "(address unavailable)") };
}

async function searchGmail(args) {
    const answer = await helper(COMMANDS.search_gmail, args);
    const messages = Array.isArray(answer.messages) ? answer.messages : [];
    const lines = messages.map((message) => "message " + oneLine(message.id) + " · thread " + oneLine(message.threadId));
    let text = messages.length ? lines.join("\n") : "No Gmail messages matched that search.";
    if (answer.nextPageToken) text += "\n    next page token: " + oneLine(answer.nextPageToken);
    return { text };
}

async function readGmailMessage(args) {
    const answer = await helper(COMMANDS.read_gmail_message, args);
    return { text: renderMessage(answer) };
}

async function readGmailThread(args) {
    const answer = await helper(COMMANDS.read_gmail_thread, args);
    const messages = Array.isArray(answer.messages) ? answer.messages : [];
    return { text: messages.length ? messages.map(renderMessage).join("\n\n") : "That Gmail thread had no readable messages." };
}

async function createGmailDraft(args) {
    const answer = await helper(COMMANDS.create_gmail_draft, args);
    const id = oneLine(answer.id);
    return { text: "Draft saved in Gmail" + (id ? " (id " + id + ")" : "") + ". Nothing was sent." };
}

async function gmailSendAccount() {
    const answer = await helper(COMMANDS.gmail_send_account, {});
    return { text: "Sends from: " + oneLine(answer.emailAddress || "(address unavailable)")
        + "\nPass this address as `from`, exactly." };
}

async function sendGmailMessage(args) {
    const answer = await helper(COMMANDS.send_gmail_message, args);
    const id = oneLine(answer.id);
    return { text: "Sent from the OpenBots Gmail account" + (id ? " (message id " + id + ")" : "")
        + ", exactly as the card showed it." };
}

function calendarWhen(event) {
    const start = oneLine(event?.start?.dateTime || event?.start?.date);
    const end = oneLine(event?.end?.dateTime || event?.end?.date);
    return start + (end ? " to " + end : "");
}

function renderEvent(event) {
    const lines = [
        calendarWhen(event) + " — " + (oneLine(event?.summary) || "(no title)"),
        "    calendar id: " + oneLine(event?.openbotsCalendarID || event?.organizer?.email),
        "    event id: " + oneLine(event?.id),
    ];
    if (oneLine(event?.openbotsCalendar)) lines.push("    calendar: " + oneLine(event.openbotsCalendar));
    if (oneLine(event?.location)) lines.push("    where: " + oneLine(event.location));
    if (oneLine(event?.organizer?.email)) lines.push("    organiser: " + oneLine(event.organizer.email));
    const attendees = Array.isArray(event?.attendees) ? event.attendees : [];
    if (attendees.length) {
        lines.push("    attendees:");
        for (const attendee of attendees.slice(0, 100)) {
            const name = oneLine(attendee.displayName);
            const email = oneLine(attendee.email);
            lines.push("        " + (name && email && name !== email ? name + " <" + email + ">"
                : (email || name || "(unnamed)")));
        }
    }
    if (String(event?.description || "").trim()) { lines.push("    notes:"); lines.push(quoted(event.description)); }
    return lines.join("\n");
}

async function listGoogleCalendars() {
    const answer = await helper(COMMANDS.list_google_calendars, {});
    const calendars = Array.isArray(answer.items) ? answer.items : [];
    return { text: calendars.length ? calendars.map((calendar) =>
        (oneLine(calendar.summary) || "(unnamed)") + "\n    id: " + oneLine(calendar.id)
        + (calendar.primary ? " · primary" : "") + " · " + oneLine(calendar.accessRole)).join("\n\n")
        : "The connected Google account has no readable calendars." };
}

function localDate(value, endOfDay) {
    if (value === undefined || value === null || value === "") return null;
    if (typeof value !== "string" || !value.trim()) throw new Error("The calendar date must be text.");
    const text = value.trim();
    if (/^\d{4}-\d{2}-\d{2}$/.test(text)) {
        const date = new Date(text + "T00:00:00");
        if (endOfDay) date.setDate(date.getDate() + 1);
        return date;
    }
    const date = new Date(text);
    if (Number.isNaN(date.getTime())) throw new Error("The calendar date is invalid; use YYYY-MM-DD or a full date and time.");
    return date;
}

async function searchGoogleEvents(args) {
    const input = Object.assign({}, args);
    let from = localDate(args.from, false);
    let to = localDate(args.to, true);
    if (!from) { from = new Date(); from.setHours(0, 0, 0, 0); }
    if (!to) { to = new Date(from); to.setDate(to.getDate() + 7); }
    input.from = from.toISOString(); input.to = to.toISOString();
    const answer = await helper(COMMANDS.search_google_events, input);
    const events = Array.isArray(answer.events) ? answer.events : [];
    let text = events.length ? events.map(renderEvent).join("\n\n") : "No Google Calendar events matched that window.";
    if (answer.truncated) text += "\n\nThe result was capped. Ask for a narrower window or one calendar.";
    return { text };
}

async function readGoogleEvent(args) {
    const answer = await helper(COMMANDS.read_google_event, args);
    return { text: renderEvent(answer) };
}

const DRIVE_KINDS = Object.freeze({
    "application/vnd.google-apps.document": "Google Doc",
    "application/vnd.google-apps.spreadsheet": "Google Sheet",
    "application/vnd.google-apps.presentation": "Google Slides",
    "application/vnd.google-apps.folder": "folder",
    "application/vnd.google-apps.shortcut": "shortcut",
    "application/vnd.google-apps.form": "Google Form",
    "application/vnd.google-apps.drawing": "Google Drawing",
    "application/pdf": "PDF",
});

function driveKind(type) {
    const mime = oneLine(type);
    if (DRIVE_KINDS[mime]) return DRIVE_KINDS[mime];
    if (mime.startsWith("text/")) return "text file";
    if (mime.startsWith("image/")) return "picture";
    return mime ? "file (" + mime + ")" : "file";
}

function renderDriveFile(file) {
    const lines = [
        oneLine(file?.name) || "(no name)",
        "    id: " + oneLine(file?.id),
        "    kind: " + driveKind(file?.mimeType),
    ];
    if (oneLine(file?.shortcutDetails?.targetId)) {
        lines.push("    shortcut to: " + oneLine(file.shortcutDetails.targetId)
            + " (" + driveKind(file.shortcutDetails.targetMimeType) + ")");
    }
    if (oneLine(file?.modifiedTime)) lines.push("    modified: " + oneLine(file.modifiedTime));
    const owners = Array.isArray(file?.owners) ? file.owners : [];
    if (owners.length) {
        lines.push("    owner: " + owners.slice(0, 5).map((owner) => {
            const name = oneLine(owner?.displayName);
            const email = oneLine(owner?.emailAddress);
            return name && email && name !== email ? name + " <" + email + ">" : (email || name || "(unnamed)");
        }).join(", "));
    }
    if (oneLine(file?.size)) lines.push("    size: " + oneLine(file.size) + " bytes");
    if (oneLine(file?.webViewLink)) lines.push("    link: " + oneLine(file.webViewLink));
    return lines.join("\n");
}

function renderDriveList(answer, empty) {
    const files = Array.isArray(answer?.files) ? answer.files : [];
    let text = files.length ? files.map(renderDriveFile).join("\n\n") : empty;
    if (answer?.incompleteSearch) text += "\n\nDrive said this search did not cover everything; narrow it to be sure.";
    if (answer?.nextPageToken) text += "\n\nMore: call again with page_token: " + oneLine(answer.nextPageToken);
    return { text };
}

async function searchGoogleDrive(args) {
    return renderDriveList(await helper(COMMANDS.search_google_drive, args),
        "No files in the OpenBots Google Drive matched that search.");
}

async function listGoogleDriveFolder(args) {
    return renderDriveList(await helper(COMMANDS.list_google_drive_folder, args), "That folder is empty.");
}

function startOffset(value) {
    if (value === undefined || value === null || value === "") return 0;
    const number = Number(value);
    if (!Number.isInteger(number) || number < 0) throw new Error("start must be a whole number of characters, 0 or more.");
    return number;
}

async function readGoogleDriveFile(args) {
    const start = startOffset(args.start);
    const input = Object.assign({}, args);
    delete input.start;
    const answer = await helper(COMMANDS.read_google_drive_file, input);
    const text = typeof answer?.text === "string" ? answer.text : "";
    const lines = [renderDriveFile(answer?.file), "    read as: " + oneLine(answer?.readAs)];
    if (!text.length) {
        lines.push("    The file is empty.");
        return { text: lines.join("\n") };
    }
    if (start >= text.length) {
        lines.push("    The file has " + text.length + " characters; start " + start + " is past its end.");
        return { text: lines.join("\n") };
    }
    const end = Math.min(text.length, start + DRIVE_TEXT);
    lines.push("    characters " + start + " to " + end + " of " + text.length + ":");
    lines.push(quoted(text.slice(start, end)));
    if (end < text.length) lines.push("    continues: call again with the same id and start: " + end);
    return { text: lines.join("\n") };
}

const GMAIL_TOOLS = [
    { name: "gmail_account", description: "Show which OpenBots Google account is connected. Read-only.",
      inputSchema: { type: "object", properties: {} } },
    { name: "search_gmail", description: "Search the connected OpenBots Gmail mailbox. Returns message and thread ids; call a read tool for contents. Read-only.",
      inputSchema: { type: "object", properties: {
          query: { type: "string", description: "A Gmail search query, such as `from:person@example.com newer_than:30d`." },
          limit: { type: "number", description: "1 to 50; defaults to 25." },
          page_token: { type: "string", description: "The next-page token from an earlier search." },
      } } },
    { name: "read_gmail_message", description: "Read one Gmail message, including its text body and attachment names. Read-only.",
      inputSchema: { type: "object", properties: { id: { type: "string", description: "A message id returned by search_gmail." } }, required: ["id"] } },
    { name: "read_gmail_thread", description: "Read every message in one Gmail thread. Read-only.",
      inputSchema: { type: "object", properties: { id: { type: "string", description: "A thread id returned by search_gmail." } }, required: ["id"] } },
    { name: "create_gmail_draft", description: "Save a new draft in the connected OpenBots Gmail account. Nothing is sent. OpenBots shows an approval card first.",
      inputSchema: { type: "object", properties: {
          to: { type: "string", description: "Comma-separated email addresses; every address must fit on the approval card." },
          cc: { type: "string", description: "Optional comma-separated email addresses." },
          bcc: { type: "string", description: "Optional comma-separated email addresses. At most 10 recipients total." },
          subject: { type: "string", description: "At most 120 characters, shown in full on the approval card." },
          body: { type: "string", description: "Plain text, at most 1,300 characters, shown in full on the approval card. No invisible or reordering characters." },
      }, required: ["to", "subject", "body"] } },
];

const GMAIL_SEND_TOOLS = [
    { name: "gmail_send_account", description: "Show the address Gmail send sends from. Call it before send_gmail_message and pass the address as `from`. Read-only.",
      inputSchema: { type: "object", properties: {} } },
    { name: "send_gmail_message", description: "Send a new plain-text email from the connected OpenBots Gmail account. OpenBots shows the user a card with the account, every recipient, the subject and the whole body first; only that exact message can go.",
      inputSchema: { type: "object", properties: {
          from: { type: "string", description: "The address gmail_send_account names, exactly." },
          to: { type: "string", description: "One to three plain email addresses separated by commas, such as a@example.com. No names or angle brackets." },
          subject: { type: "string", description: "One line, at most 120 characters, no space at either end." },
          body: { type: "string", description: "Plain text, at most 1,300 characters; at most one blank line between paragraphs, none at the start or the end." },
      }, required: ["from", "to", "subject", "body"], additionalProperties: false } },
];

const CALENDAR_TOOLS = [
    { name: "list_google_calendars", description: "List calendars visible to the connected OpenBots Google account and the ids used by the other tools. Read-only.",
      inputSchema: { type: "object", properties: {} } },
    { name: "search_google_events", description: "Read events in the connected account between two dates. Searches all readable calendars unless one id is supplied. Read-only.",
      inputSchema: { type: "object", properties: {
          from: { type: "string", description: "First day as YYYY-MM-DD, or a full date and time. Defaults to today." },
          to: { type: "string", description: "Last day as YYYY-MM-DD (included), or a full date and time. Defaults to seven days after from." },
          query: { type: "string" }, calendar_id: { type: "string" },
          limit: { type: "number", description: "1 to 100; defaults to 50." },
      } } },
    { name: "read_google_event", description: "Read one Google Calendar event in full. Read-only.",
      inputSchema: { type: "object", properties: {
          calendar_id: { type: "string", description: "The calendar id printed by search_google_events." },
          event_id: { type: "string", description: "The event id printed by search_google_events." },
      }, required: ["calendar_id", "event_id"] } },
];

const DRIVE_TOOLS = [
    { name: "search_google_drive", description: "Search every file the connected OpenBots Google account can see in Drive, by words in the name or the contents. With no query, lists the most recently changed files. Returns ids for the other tools. Read-only.",
      inputSchema: { type: "object", properties: {
          query: { type: "string", description: "Plain words to look for, such as `budget 2026`. Not Drive's query language." },
          limit: { type: "number", description: "1 to 50; defaults to 25." },
          page_token: { type: "string", description: "The page_token from an earlier answer, for more results." },
      } } },
    { name: "list_google_drive_folder", description: "List the files and folders directly inside one Drive folder, folders first. With no folder_id, the top of the account's Drive. Read-only.",
      inputSchema: { type: "object", properties: {
          folder_id: { type: "string", description: "A folder id from an earlier answer." },
          limit: { type: "number", description: "1 to 100; defaults to 50." },
          page_token: { type: "string", description: "The page_token from an earlier answer, for more results." },
      } } },
    { name: "read_google_drive_file", description: "Read one Drive file as text: Google Docs and Slides as plain text, Google Sheets as CSV (the first sheet), and plain-text files up to 1 MB. A shortcut is followed to its file. PDFs, pictures and Office files cannot be read. Read-only.",
      inputSchema: { type: "object", properties: {
          id: { type: "string", description: "A file id from search_google_drive or list_google_drive_folder." },
          start: { type: "number", description: "For a long file: the character to continue from, as the last answer said. Defaults to 0." },
      }, required: ["id"] } },
];

const GMAIL_HANDLERS = Object.freeze({
    gmail_account: gmailAccount,
    search_gmail: searchGmail,
    read_gmail_message: readGmailMessage,
    read_gmail_thread: readGmailThread,
    create_gmail_draft: createGmailDraft,
});
const GMAIL_SEND_HANDLERS = Object.freeze({
    gmail_send_account: gmailSendAccount,
    send_gmail_message: sendGmailMessage,
});
const CALENDAR_HANDLERS = Object.freeze({
    list_google_calendars: listGoogleCalendars,
    search_google_events: searchGoogleEvents,
    read_google_event: readGoogleEvent,
});

const DRIVE_HANDLERS = Object.freeze({
    search_google_drive: searchGoogleDrive,
    list_google_drive_folder: listGoogleDriveFolder,
    read_google_drive_file: readGoogleDriveFile,
});

const TABLES = Object.freeze({
    gmail: [GMAIL_TOOLS, GMAIL_HANDLERS],
    gmail_send: [GMAIL_SEND_TOOLS, GMAIL_SEND_HANDLERS],
    calendar: [CALENDAR_TOOLS, CALENDAR_HANDLERS],
    drive: [DRIVE_TOOLS, DRIVE_HANDLERS],
});
const [TOOLS, HANDLERS] = Object.prototype.hasOwnProperty.call(TABLES, SERVICE) ? TABLES[SERVICE] : [[], {}];

function write(object) { process.stdout.write(JSON.stringify(object) + "\n"); }

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
    case "initialize": return { protocolVersion: /^\d{4}-\d{2}-\d{2}$/.test(params?.protocolVersion || "")
            ? params.protocolVersion : "2024-11-05", capabilities: { tools: {} },
        serverInfo: { name: "openbots-google-" + (SERVICE || "invalid"), version: "1.0.0" } };
    case "tools/list": return { tools: TOOLS };
    case "tools/call": {
        // Own names only: `constructor` or `toString` would otherwise resolve
        // through the prototype to a built-in and run as a tool.
        const name = params?.name;
        const fn = typeof name === "string" && Object.prototype.hasOwnProperty.call(HANDLERS, name)
            ? HANDLERS[name] : undefined;
        if (!fn) throw new Error("unknown tool: " + name);
        const result = await fn(params.arguments || {});
        return { content: [{ type: "text", text: result.text }], isError: !!result.isError };
    }
    case "ping": return {};
    default: { const error = new Error("method not found: " + method); error.code = -32601; throw error; }
    }
}

onRequestLine(process.stdin, async (line) => {
    const raw = line.trim(); if (!raw) return;
    let message;
    try { message = JSON.parse(raw); }
    catch (_) { return write({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } }); }
    if (message.id === undefined || message.id === null) return;
    try { write({ jsonrpc: "2.0", id: message.id, result: await dispatch(message.method, message.params) }); }
    catch (error) {
        if (message.method === "tools/call") {
            write({ jsonrpc: "2.0", id: message.id, result: {
                content: [{ type: "text", text: String(error.message || error).slice(0, 600) }], isError: true,
            } });
        } else {
            write({ jsonrpc: "2.0", id: message.id,
                error: { code: error.code || -32603, message: String(error.message || error).slice(0, 600) } });
        }
    }
});
