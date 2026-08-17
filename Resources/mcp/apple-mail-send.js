#!/usr/bin/env node
"use strict";
/*
 * agency apple-mail-send — send/draft mail through Lorenzo's own Mail.app.
 *
 * WHY (2026-08-13): the mail-app connector is READ-ONLY by construction, so
 * the only way Mailman could send through Apple Mail was driving the whole
 * Mac via the mac-control grant — the broadest capability in the catalog
 * standing in for the narrowest need. This server is the narrow need: two
 * verbs, Mail.app only, nothing else reachable.
 *
 * HIS RULE (question round 2026-08-13): NO default sending account. Mail may
 * have several accounts and they are materially
 * different identities — every send/draft must name one explicitly, and the
 * agent asks Lorenzo when he hasn't said.
 *
 * Mechanics proven live before writing this:
 *  - `tell application id "com.apple.mail"` is the form that compiles
 *    reliably here; the by-name form hit terminology errors on this Mac.
 *  - outgoing-message scripting works (created + deleted a probe draft).
 *  - Same zero-dependency osascript-argv pattern as messages-server.js:
 *    values travel as argv into `on run argv`, never interpolated into
 *    AppleScript source, so nothing can break out of a string.
 */

const { execFile } = require("child_process");
const readline = require("readline");

const OSASCRIPT = "/usr/bin/osascript";

function run(cmd, args, stdin) {
    return new Promise((resolve, reject) => {
        const child = execFile(
            cmd, args, { maxBuffer: 4 * 1024 * 1024, timeout: 60000 },
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

const osascript = (script, argv) => run(OSASCRIPT, ["-", ...argv], script);

// ─────────────────────────────────────────────────────────────── AppleScript

const LIST_ACCOUNTS = `on run argv
tell application id "com.apple.mail"
	set out to ""
	repeat with a in accounts
		set addrs to email addresses of a
		set AppleScript's text item delimiters to ", "
		set out to out & (name of a) & " — " & (addrs as text) & linefeed
	end repeat
	return out
end tell
end run`;

/// argv: 1 mode ("send"|"draft") · 2 account name · 3 subject · 4 body ·
///       5 to (comma-separated) · 6 cc · 7 bcc · 8 signature name ("" = auto)
/// The account is resolved FIRST and by exact name — an unknown account is an
/// error before any message object exists.
///
/// SIGNATURE (his report after the first live send: "he didn't add the
/// signature"): Mail does NOT apply signatures to script-created messages —
/// `message signature` must be set explicitly (verified live: settable and
/// readable on a probe draft). Auto rule: a named signature is used (unknown
/// name = error listing the real ones); with no name, a SOLE signature is
/// applied, and with several, none is, reported so
/// the agent can ask rather than pick an identity for him.
const COMPOSE = `on run argv
set theMode to item 1 of argv
set theAccount to item 2 of argv
set theSubject to item 3 of argv
set theBody to item 4 of argv
set toList to my splitAddrs(item 5 of argv)
set ccList to my splitAddrs(item 6 of argv)
set bccList to my splitAddrs(item 7 of argv)
set theSig to item 8 of argv
tell application id "com.apple.mail"
	-- EVERYTHING that can fail resolves BEFORE the message object exists
	-- (review finding I-1): a compose object created with visible:false is an
	-- invisible phantom that neither delete nor close removes — it holds the
	-- body and sender until Mail restarts. The old order abandoned one on
	-- every unknown-signature error; creating last leaks nothing on refusals.
	set matched to (every account whose name is theAccount)
	if (count of matched) is 0 then error "no Mail account named " & quoted form of theAccount
	-- 'whose name is' matches case-insensitively; two accounts differing only
	-- by case would resolve arbitrarily (review finding I-3) — refuse instead.
	if (count of matched) > 1 then error (count of matched) & " Mail accounts are named " & quoted form of theAccount & " — rename one in Mail, or there is no unambiguous way to pick"
	set theSender to item 1 of (get email addresses of item 1 of matched)
	set sigNote to "none"
	set theSigObj to missing value
	if theSig is not "" then
		set sigMatch to (every signature whose name is theSig)
		if (count of sigMatch) is 0 then
			set AppleScript's text item delimiters to ", "
			error "no signature named " & quoted form of theSig & " — available: " & ((name of every signature) as text)
		end if
		set theSigObj to item 1 of sigMatch
		set sigNote to theSig
	else if (count of signatures) is 1 then
		set theSigObj to signature 1
		set sigNote to (get name of signature 1)
	else if (count of signatures) > 1 then
		set sigNote to "none (several exist and none was named)"
	end if
	set m to make new outgoing message with properties {subject:theSubject, content:theBody, visible:false}
	set sender of m to theSender
	if theSigObj is not missing value then set message signature of m to theSigObj
	repeat with r in toList
		tell m to make new to recipient at end of to recipients with properties {address:r}
	end repeat
	repeat with r in ccList
		tell m to make new cc recipient at end of cc recipients with properties {address:r}
	end repeat
	repeat with r in bccList
		tell m to make new bcc recipient at end of bcc recipients with properties {address:r}
	end repeat
	if theMode is "send" then
		send m
		return "sent from " & theSender & " · signature: " & sigNote
	else
		save m
		return "draft saved under " & theSender & " · signature: " & sigNote
	end if
end tell
end run
on splitAddrs(s)
	if s is "" then return {}
	set AppleScript's text item delimiters to ","
	set parts to text items of s
	set out to {}
	repeat with p in parts
		set t to my trimmed(p as text)
		if t is not "" then set end of out to t
	end repeat
	return out
end splitAddrs
on trimmed(t)
	repeat while t begins with " "
		set t to text 2 thru -1 of t
	end repeat
	repeat while t ends with " "
		set t to text 1 thru -2 of t
	end repeat
	return t
end trimmed`;

// ─────────────────────────────────────────────────────────────────── helpers

// Rejects invisible/bidi characters outright (review minor, both servers): a
// zero-width space inside an address looks identical to the real one in every
// confirmation Lorenzo reads, while addressing someone else.
const NO_INVISIBLES = /^[^\u200b-\u200f\u202a-\u202e\u2060-\u2069\u061c\ufeff]*$/;
const isEmail = (s) => {
    const t = String(s || "").trim();
    return NO_INVISIBLES.test(t)
        && /^[^\s@<>,;:"'\\]+@[^\s@<>,;:"'\\.]+\.[^\s@<>,;:"'\\]+$/.test(t);
};

function normaliseAddresses(field, value) {
    const list = Array.isArray(value) ? value : String(value || "").split(",");
    const out = [];
    for (const raw of list) {
        const a = String(raw).trim();
        if (!a) continue;
        if (!isEmail(a)) {
            throw new Error(`${field} contains "${a}", which is not an email address — `
                + "pass bare addresses, not names or 'Name <addr>' forms.");
        }
        out.push(a);
    }
    return out;
}

async function compose(mode, args) {
    const account = String(args.account || "").trim();
    if (!account) {
        throw new Error("`account` is required and has NO default (Lorenzo's rule — Mail has "
            + "several accounts and they are different identities). Ask Lorenzo which account to "
            + "use, or call list_mail_accounts to see the exact names.");
    }
    const subject = String(args.subject || "").trim();
    const body = String(args.body || "");
    const to = normaliseAddresses("to", args.to);
    if (!subject) throw new Error("subject is required");
    if (!body.trim()) throw new Error("body is required");
    if (!to.length) throw new Error("at least one `to` address is required");
    const cc = normaliseAddresses("cc", args.cc || []);
    const bcc = normaliseAddresses("bcc", args.bcc || []);

    const signature = String(args.signature || "").trim();
    let result;
    try {
        result = (await osascript(COMPOSE, [mode, account, subject, body,
                                            to.join(","), cc.join(","), bcc.join(","),
                                            signature])).trim();
    } catch (err) {
        // A TIMEOUT is not a refusal (review finding I-2): execFile kills the
        // child after 60s, but `send m` may already have handed the message to
        // Mail — reporting it as a clean failure invites a retry and a
        // DUPLICATE send as Lorenzo. Likeliest trigger: the first-use
        // Automation→Mail permission prompt sitting unanswered.
        if (err.killed || err.signal) {
            return { isError: true,
                     text: mode === "send"
                        ? "TIMED OUT waiting for Mail.app — the message MAY OR MAY NOT have been sent. "
                          + "Do NOT retry until Lorenzo checks Mail's Sent mailbox (and whether a macOS "
                          + "permission prompt for Automation → Mail is waiting to be answered)."
                        : "TIMED OUT waiting for Mail.app — check for a pending Automation → Mail "
                          + "permission prompt. The draft may or may not have been saved." };
        }
        const detail = (err.stderr || err.message || "").trim();
        // "Mail.app refused" only when Mail actually spoke (review minor: a
        // helper crash was mislabelled as a Mail refusal).
        const label = detail.includes("execution error") ? "Mail.app refused" : "The mail helper failed";
        return { isError: true,
                 text: `${label}: ${detail}\n(If this names permissions, Automation → Mail `
                     + `must be allowed for Agency in System Settings → Privacy & Security. If it `
                     + `names the account, call list_mail_accounts for the exact spelling.)` };
    }
    const who = to.join(", ") + (cc.length ? ` (cc: ${cc.join(", ")})` : "")
        + (bcc.length ? ` (bcc: ${bcc.join(", ")})` : "");
    return { isError: false,
             text: mode === "send"
                ? `Mail.app accepted the message for delivery — ${result} → ${who}, subject "${subject}". `
                  + `Mail sends asynchronously; a connection problem would surface in Mail.app itself, `
                  + `so report this as handed to Mail, not as delivered.`
                : `Draft saved in Mail.app (${result}) → ${who}, subject "${subject}". Nothing was sent.` };
}

// ─────────────────────────────────────────────────────────────── MCP plumbing

const TOOLS = [
    {
        name: "send_mail",
        description: "Send an email through Lorenzo's own Mail.app, AS Lorenzo, from an "
            + "explicitly named account. `account` has NO default — Mail has several accounts "
            + "and Lorenzo decides per send; ask him if he hasn't said. Prefer draft_mail "
            + "whenever the wording wasn't dictated or confirmed.",
        inputSchema: { type: "object",
            properties: {
                account: { type: "string", description: "Exact Mail account name (see list_mail_accounts). Required, no default." },
                to: { type: "string", description: "Recipient address(es), comma-separated bare emails." },
                subject: { type: "string" },
                body: { type: "string", description: "Plain-text body." },
                cc: { type: "string", description: "Optional, comma-separated." },
                bcc: { type: "string", description: "Optional, comma-separated." },
                signature: { type: "string", description: "Optional Mail signature name. "
                    + "Omitted: the sole signature is applied automatically; if several exist, "
                    + "none is and the result says so — ask Lorenzo rather than pick." },
            },
            required: ["account", "to", "subject", "body"] },
    },
    {
        name: "draft_mail",
        description: "Create a DRAFT in Lorenzo's Mail.app under an explicitly named account — "
            + "nothing is sent. The safe default whenever a send wasn't explicitly confirmed.",
        inputSchema: { type: "object",
            properties: {
                account: { type: "string", description: "Exact Mail account name. Required, no default." },
                to: { type: "string" }, subject: { type: "string" }, body: { type: "string" },
                cc: { type: "string" }, bcc: { type: "string" },
                signature: { type: "string", description: "Optional Mail signature name; the sole "
                    + "signature is applied automatically when omitted." },
            },
            required: ["account", "to", "subject", "body"] },
    },
    {
        name: "list_mail_accounts",
        description: "List Mail.app's accounts (exact names + their addresses) so `account` can "
            + "be spelled correctly. Read-only.",
        inputSchema: { type: "object", properties: {} },
    },
];

const HANDLERS = {
    send_mail: (a) => compose("send", a),
    draft_mail: (a) => compose("draft", a),
    list_mail_accounts: async () => {
        try {
            const out = (await osascript(LIST_ACCOUNTS, [])).trim();
            return { isError: false, text: out ? `Mail accounts:\n${out}` : "Mail has no accounts configured." };
        } catch (err) {
            return { isError: true,
                     text: `Could not list accounts: ${(err.stderr || err.message || "").trim()}` };
        }
    },
};

function write(obj) { process.stdout.write(JSON.stringify(obj) + "\n"); }

async function dispatch(method, params) {
    switch (method) {
        case "initialize":
            return { protocolVersion: /^\d{4}-\d{2}-\d{2}$/.test(params?.protocolVersion || "")
                        ? params.protocolVersion : "2024-11-05",
                     capabilities: { tools: {} },
                     serverInfo: { name: "agency-apple-mail-send", version: "1.0.0" } };
        case "tools/list": return { tools: TOOLS };
        case "tools/call": {
            const fn = HANDLERS[params?.name];
            if (!fn) throw new Error(`unknown tool: ${params?.name}`);
            const res = await fn(params.arguments || {});
            return { content: [{ type: "text", text: res.text }], isError: !!res.isError };
        }
        case "ping": return {};
        default: { const e = new Error(`method not found: ${method}`); e.code = -32601; throw e; }
    }
}

readline.createInterface({ input: process.stdin }).on("line", async (line) => {
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
