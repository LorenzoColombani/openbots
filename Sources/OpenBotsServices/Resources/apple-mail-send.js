#!/usr/bin/env node
"use strict";
/*
 * OpenBots apple-mail-send — send/draft mail through the user's own Mail.app.
 *
 * This app answers the CLI's permission channel, so the
 * approval card is the gate and the tool call itself only runs once the user has
 * approved it. The connector uses argv-only
 * AppleScript, the no-default-account rule, the create-last ordering that
 * leaks no phantom message on a refusal, and the timeout wording that refuses
 * to call an unknown outcome a failure.
 *
 * The mail-app connector is READ-ONLY by construction, so
 * the only way a mail teammate could send through Apple Mail was driving the whole
 * Mac via the mac-control grant — the broadest capability in the catalog
 * standing in for the narrowest need. This server is the narrow need: two
 * verbs, Mail.app only, nothing else reachable.
 *
 * NO default sending account: Mail can hold materially different identities.
 * Every send/draft must name one explicitly, and the agent asks the user when
 * no account was specified.
 *
 * Scripting mechanics:
 *  - `tell application id "com.apple.mail"` is the form that compiles
 *    reliably; the by-name form can produce terminology errors.
 *  - Values travel as argv into `on run argv`, never interpolated into
 *    AppleScript source, so nothing can break out of a string.
 */

const { execFile } = require("child_process");

// Env override is for TESTS ONLY (stub scripts) — production never sets it.
const OSASCRIPT = process.env.OPENBOTS_OSASCRIPT || "/usr/bin/osascript";
// The app name comes in from the Swift side (AppleMailSendPreparation passes
// OPENBOTS_APP_NAME) so the permission hint never names an app the user cannot
// find in System Settings.
const APP_NAME = process.env.OPENBOTS_APP_NAME || "OpenBots Next";

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

/// argv: 1 mode (send or draft), 2 account name, 3 subject, 4 body, 5 comma-separated to, 6 cc,
/// 7 bcc, 8 signature name (empty means automatic).
/// Resolve the account by exact name before creating a message. Script-created mail needs
/// `message signature` set explicitly. Use a named signature, refusing unknown names. Without a
/// name, use a sole signature; if several exist, use none and report that so the user can
/// choose.
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
	-- because a compose object created with visible:false is an
	-- invisible phantom that neither delete nor close removes — it holds the
	-- body and sender until Mail restarts. The old order abandoned one on
	-- every unknown-signature error; creating last leaks nothing on refusals.
	set matched to (every account whose name is theAccount)
	if (count of matched) is 0 then error "no Mail account named " & quoted form of theAccount
	-- 'whose name is' matches case-insensitively; two accounts differing only
	-- by case would resolve arbitrarily — refuse instead.
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

// Rejects invisible/bidi characters outright: a zero-width space inside an address looks
// identical to the real one in every confirmation the user reads, while addressing someone
// else. What is stripped from the words the user reads. U+200C and U+200D are deliberately NOT here:
// the joiner is what makes 👩‍💻 one emoji instead of two, and the non-joiner is orthographically
// required in Persian and Urdu. Stripping them scrambled real subjects, and the card scrambled
// them the same way, so they could not see it happen. `HIDDEN_IN_ADDRESS` below is wider than
// this list on purpose, because an address needs none of them and cannot show them which one it
// carries.
const INVISIBLES = /[\u200b\u200e\u200f\u202a-\u202e\u2060-\u2069\u061c\ufeff]/g;
/// Reject Unicode default-ignorable characters in addresses using the Unicode property rather
/// than an incomplete hand-maintained list. Otherwise distinct recipient strings can render
/// identically on the approval card. Subjects use a narrower stripping set because variation
/// selectors and joiners can be meaningful content there.
/// A variation selector in an emoji domain is refused even when IDNA would ignore it. The
/// refusal names the character so the user can supply an address whose displayed and approved
/// forms agree.
const HIDDEN_IN_ADDRESS = /\p{Default_Ignorable_Code_Point}/u;
/// Exactly what the card does to a subject before it draws it: drop the characters that hide or
/// reorder, then collapse every run of whitespace to one space. Trimming alone was not the same
/// thing — a subject with blank lines in it read as one line on the card and reached Mail with
/// the blank lines still there. U+0085 is whitespace to Unicode and to Swift, and is NOT in
/// JavaScript's `\s`, so it has to be named: without it the card said "Invoice March" and the
/// mail carried the line break.
/// It is named ONCE, here, and every rule about a space is built from it. The same gap
/// once appeared one field over: U+0085 was named for the subject and forgotten for
/// the addresses, so the card drew `alice@example.test` while the mail went to that address
/// with a line break on the end of it — a recipient the card never showed. Two copies of a set
/// drift apart; one cannot.
const WHITESPACE = "\\s\\u0085";
const oneLineSubject = (value) => String(value).replace(INVISIBLES, "")
    .split(new RegExp("[" + WHITESPACE + "]+", "u")).filter((part) => part !== "").join(" ");

/// The whole body as the card shows it. The same hiding characters as the subject are dropped and
/// nothing else is changed: the line breaks are the mail's own, so the body is
/// not flattened as a subject is. The card's `visibleBody` is the same rule,
/// and AppleMailBodyReadsAlikeTests runs both over one input.
const visibleBody = (value) => String(value).replace(INVISIBLES, "");
/// Whether anything but whitespace is left. The card says "This mail has no
/// words in it" by the same test, over the same whitespace set: `trim()`
/// alone let a body of one U+0085 through while the card called it empty.
const hasWords = (text) => String(text).replace(new RegExp("[" + WHITESPACE + "]", "gu"), "") !== "";

/// An address may carry no whitespace of any kind, and it is refused rather
/// than trimmed to fit: no real address needs one, and an address trimmed into
/// shape is a different recipient from the one that was named. A leading or
/// trailing space is the exception and is trimmed away first, by `trim()`
/// below — the card collapses those too, so the two sides still draw one
/// address.
/// Both consumers of `WHITESPACE` take the `u` flag, which is not decoration:
/// without it `\p{\u2026}` in that constant would be read as the letter `p`, and
/// the address rule would silently begin refusing every address containing a
/// "p" rather than throwing.
/// The apostrophe is allowed in the local part and nowhere else:
/// `o'brien@example.test` is valid, `'` is RFC 5321
/// `atext`, and it was refused with advice to drop a `Name <addr>` form it
/// never had. No host name carries one, so the domain's two classes keep it
/// out. The card draws an address as given, so this widens what the script
/// accepts without changing what the user reads (AppleMailApostropheAddressTests).
const ADDRESS = new RegExp("^[^" + WHITESPACE + "@<>,;:\"\\\\]+"
    + "@[^" + WHITESPACE + "@<>,;:\"'\\\\.]+"
    + "\\.[^" + WHITESPACE + "@<>,;:\"'\\\\]+$", "u");
const ONE_SPACE = new RegExp("[" + WHITESPACE + "]", "u");

const isEmail = (s) => {
    const t = String(s || "").trim();
    return !HIDDEN_IN_ADDRESS.test(t) && ADDRESS.test(t);
};

/// An address is echoed back with everything invisible named. The refusal used to print the
/// offending address raw, so a hidden character was hidden in the error too: it read `to
/// contains "alice@example.test", which is not an email address \u2014 pass bare addresses, not
/// names or 'Name <addr>' forms`, which is not merely unhelpful but untrue, since the address
/// *is* bare and following the advice changes nothing. An ordinary space is not one of these: a
/// space in an address almost always means a `Name <addr>` form, and that advice is right there
/// and wrong for everything else.
const cannotBeSeen = (character) => HIDDEN_IN_ADDRESS.test(character)
    || (ONE_SPACE.test(character) && character !== " ");

const named = (character) =>
    "U+" + character.codePointAt(0).toString(16).toUpperCase().padStart(4, "0");

function describeAddress(value) {
    const text = String(value);
    let shown = "";
    let hidden = null;
    let spaced = null;
    let capped = false;
    for (const character of text) {
        let piece = character;
        if (cannotBeSeen(character)) {
            if (HIDDEN_IN_ADDRESS.test(character)) {
                if (hidden === null) hidden = named(character);
            } else if (spaced === null) {
                spaced = named(character);
            }
            piece = "<" + named(character) + ">";
        } else if (character === "<") {
            // A bot that types the four ASCII characters `<`, `U`, `+`, `>`
            // around a code point would otherwise read back as an address
            // carrying the character it only described.
            piece = "<" + named(character) + ">";
        }
        // 320 soft hyphens made a 2,791-character refusal, so the echo stops at 120. It stops
        // rather than skipping what does not fit: skipping dropped a named character out of the
        // MIDDLE and closed the gap, so the text either side read as one address and the single
        // trailing ellipsis looked like an ordinary cut at the end. The scan keeps going after
        // the echo stops, because the character that explains the refusal can sit past the cut.
        if (capped) continue;
        if (shown.length + piece.length > 120) { capped = true; continue; }
        shown += piece;
    }
    return { shown: capped ? shown + "\u2026" : shown, hidden, spaced,
             angled: /[<>]/.test(text) };
}

/// Resolve a reply target before creating a Mail reply object. Use RFC 5322 Message-ID, which
/// the reader exposes as `rfc_message_id`, instead of Mail's per-store internal id. Compare
/// normalized subjects exactly, never by substring. Check the resolver's result in JavaScript
/// before any mutation so an approved message cannot resolve to a different account's copy.
const RESOLVE = `on run argv
set midBare to item 1 of argv
set hintAccount to item 2 of argv
tell application id "com.apple.mail"
	set found to missing value
	set foundAccount to ""
	if hintAccount is not "" then
		set matched to (every account whose name is hintAccount)
		if (count of matched) is 0 then error "NO_SUCH_ACCOUNT"
		-- 'whose name is' matches case-insensitively, so two accounts differing
		-- only by case would resolve arbitrarily — the compose path refuses that
		-- and so does this one.
		if (count of matched) > 1 then error "AMBIGUOUS_ACCOUNT"
		try
			set acc to item 1 of matched
			repeat with mb in mailboxes of acc
				try
					set found to first message of mb whose (message id is midBare or message id is ("<" & midBare & ">"))
					set foundAccount to name of acc
					exit repeat
				end try
			end repeat
		end try
	end if
	-- No silent fallback for a named account. A Message-ID can exist in both
	-- an inbox and Sent, and Mail answers from the copy it finds. Refuse a
	-- missing message in the selected account rather than changing the sender.
	if found is missing value and hintAccount is not "" then error "NOT_IN_THAT_ACCOUNT"
	if found is missing value then
		repeat with acc in accounts
			try
				repeat with mb in mailboxes of acc
					try
						set found to first message of mb whose (message id is midBare or message id is ("<" & midBare & ">"))
						set foundAccount to name of acc
						exit repeat
					end try
				end repeat
			end try
			if found is not missing value then exit repeat
		end repeat
	end if
	if found is missing value then error "NO_SUCH_MESSAGE"
	return (id of found as text) & tab & foundAccount & tab & (subject of found)
end tell
end run`;

/// argv: 1 mode (send or draft), 2 resolved Mail internal id, 3 resolved account, 4 body, 5 all
/// for reply-to-all.
/// Pass the resolved account to prevent the second lookup from selecting another store. Mail's
/// reply verb chooses the sender from the account addressed by the original.
const REPLY = `on run argv
set theMode to item 1 of argv
set theID to item 2 of argv
set theAccount to item 3 of argv
set theBody to item 4 of argv
set replyAll to (item 5 of argv is "all")
tell application id "com.apple.mail"
	set origMsg to missing value
	try
		set acc to first account whose name is theAccount
		repeat with mb in mailboxes of acc
			try
				set origMsg to first message of mb whose id is theID
				exit repeat
			end try
		end repeat
	end try
	if origMsg is missing value then error "NO_SUCH_MESSAGE"
	if replyAll then
		set m to reply origMsg opening window false reply to all true
	else
		set m to reply origMsg opening window false
	end if
	-- Directly setting "content of m" is silently ignored for a reply object.
	-- Set it through "properties" so the body is included without changing
	-- other message properties.
	--
	-- Mail's own quote cannot be read back off the outgoing message: reading
	-- the content of one returns a one-character stub on this macOS, before AND
	-- after a save, so the line this replaces was appending nothing anyway. A
	-- quote could be assembled from the original message, whose content IS
	-- readable; it is not done here. Mail adds the signature itself when it
	-- sends, which is why a reply still carries one.
	set properties of m to {content:theBody}
	set fromWho to sender of m
	set toCount to (count of to recipients of m) + (count of cc recipients of m)
	if theMode is "send" then
		send m
		return "sent from " & fromWho & " to " & toCount & " recipient(s)"
	else
		save m
		return "saved as a draft from " & fromWho & " to " & toCount & " recipient(s)"
	end if
end tell
end run`;

/// Recipients must be a comma-separated string or absent. The card reads to/cc/bcc as strings,
/// so accepting an array here could send recipients the card did not show. Refuse any input
/// shape the card cannot describe.
function normaliseAddresses(field, value, verb) {
    if (value !== undefined && value !== null && typeof value !== "string") {
        throw new Error(`${field} must be a comma-separated STRING of bare addresses. It arrived as `
            + `${Array.isArray(value) ? "an array" : typeof value}, which the approval card cannot `
            + `show him, so nothing was ${verb}. Pass "a@x.test, b@y.test".`);
    }
    const list = String(value || "").split(",");
    const out = [];
    for (const raw of list) {
        const a = String(raw).trim();
        if (!a) continue;
        if (a.length > 320) {
            throw new Error(`${field} contains an address of ${a.length} characters. No real `
                + `address is that long, and the approval card cannot show it, so nothing was ${verb}.`);
        }
        if (!isEmail(a)) {
            const seen = describeAddress(a);
            // An address can be wrong in more than one way at once, and being told about only
            // the invisible half sends the caller back for a second round trip. Each fault is
            // its own sentence and the last sentence says what to do: a refusal that only
            // diagnoses is the same wrong message as one whose remedy changes nothing, with the
            // sign flipped.
            const why = [`${field} contains "${seen.shown}", which is not an email address.`];
            if (seen.hidden) {
                why.push(`It carries ${seen.hidden}, which nothing on screen can show, so the `
                    + "address on the card and the address the mail would use are not the same one.");
            }
            if (seen.spaced) {
                why.push(`It carries ${seen.spaced}, which you cannot tell from an ordinary space.`);
            }
            if (seen.angled || why.length === 1) {
                why.push("Pass bare addresses, not names or 'Name <addr>' forms.");
            }
            if (seen.hidden || seen.spaced) {
                why.push(seen.hidden && seen.spaced
                    ? "Send it again with those characters taken out."
                    : "Send it again with that character taken out.");
            }
            throw new Error(why.join(" "));
        }
        out.push(a);
    }
    return out;
}

/**
 * Foundation's JSONSerialization removes one leading U+FEFF from strings; JSON.parse preserves
 * it. The app parses both the card and the approved input returned to the CLI. A body still
 * starting with that mark therefore differs from what the app approved and is refused. After
 * this check, `visibleBody` applies the same display rule as the card, removing U+FEFF wherever
 * it occurs.
 */
function refuseLeadingByteOrderMark(body, verb) {
    if (body.startsWith("\uFEFF")) {
        throw new Error("`body` begins with an invisible byte-order mark that the app's reading of this call "
            + `would not have kept, so nothing was ${verb}. Leave that character out.`);
    }
}

/**
 * Shared validation — no Mail.app and no permission prompt reached from here.
 * `verb` is what a refusal says did not happen: "sent" for send_mail, "saved"
 * for draft_mail, whose refusals used to say a draft was not sent.
 */
function validateCompose(args, verb) {
    // Every field the card shows the user must be a string, for the same reason as
    // the addresses: the card and this script have to read one input the same
    // way, or they approve words that do not describe the mail.
    for (const field of ["account", "subject", "body", "signature"]) {
        const value = args[field];
        if (value !== undefined && value !== null && typeof value !== "string") {
            throw new Error(`\`${field}\` must be a string; it arrived as `
                + `${Array.isArray(value) ? "an array" : typeof value}. The approval card is built `
                + `from these values, so nothing was ${verb}.`);
        }
    }
    // The reply path has capped its inputs since it was written; the compose path capped
    // nothing, so a 533-character "address" was accepted and a 50 KB subject was shown to the user
    // as its first few hundred characters. The limits are deliberately generous: the last
    // refusal rule added here broke every ordinary send.
    for (const [field, limit] of [["account", 200], ["subject", 400],
                                  ["signature", 200], ["body", 100000]]) {
        const value = String(args[field] || "");
        if (value.length > limit) {
            throw new Error(`\`${field}\` is implausibly long (${value.length} characters, `
                + `the limit is ${limit}). The approval card is built from these values, so `
                + `nothing was ${verb}.`);
        }
    }
    // The card strips invisible and bidi characters from the subject so what the user
    // reads cannot be reordered or hidden. If this script sent them anyway the
    // two would describe different mail, so the subject arrives here the same
    // way it reaches the card.
    if (args.subject !== undefined && args.subject !== null) {
        args = { ...args, subject: oneLineSubject(String(args.subject)) };
    }
    const account = String(args.account || "").trim();
    // A new mail requires an explicit sending account. If missing, ask with the available
    // accounts as choices and use only the selected one. For replies, Mail uses the account
    // addressed by the original.
    if (!account || account.toLowerCase() === "ask") {
        throw new Error("No account named, and there is no default — he chooses which address a new "
            + "mail goes from. Call list_mail_accounts, then ASK HIM with your question tool, one "
            + "option per account, and send from the one he picks. Do not choose for him, and do not "
            + "ask in prose and guess from the answer.");
    }
    const subject = String(args.subject || "").trim();
    const raw = String(args.body || "");
    refuseLeadingByteOrderMark(raw, verb);
    // The body reaches Mail the way it reaches the card: a hiding character
    // the card dropped and the mail kept would be words the user never read.
    const body = visibleBody(raw);
    const to = normaliseAddresses("to", args.to, verb);
    if (!subject) throw new Error("subject is required");
    if (!hasWords(body)) {
        throw new Error(`\`body\` has no words in it, so nothing was ${verb}. `
            + "Put the mail's words in `body`.");
    }
    if (!to.length) throw new Error("at least one `to` address is required");
    // No `|| []` defaults: absent remains absent. Recipient fields accept strings, so an array
    // default would incorrectly refuse messages without cc or bcc.
    const cc = normaliseAddresses("cc", args.cc, verb);
    const bcc = normaliseAddresses("bcc", args.bcc, verb);
    const signature = String(args.signature || "").trim();
    return { account, subject, body, to, cc, bcc, signature };
}

async function compose(mode, args) {
    const v = validateCompose(args, mode === "send" ? "sent" : "saved");
    // No outbox here. In OpenBots Next the app answers the CLI's permission
    // channel before a tool runs, so the approval card stands between the bot's
    // call and this line: by the time we are here, the user has read the account, the
    // recipient and the subject and pressed Approve. The old app had to queue
    // the send and execute it afterwards because it had no such gate.
    const { account, subject, body, to, cc, bcc, signature } = v;
    let result;
    try {
        result = (await osascript(COMPOSE, [mode, account, subject, body,
                                            to.join(","), cc.join(","), bcc.join(","),
                                            signature])).trim();
    } catch (err) {
        // A TIMEOUT is not a refusal: execFile kills the child after 60s, but `send m` may
        // already have handed the message to Mail — reporting it as a clean failure invites a
        // retry and a DUPLICATE send as the user. Likeliest trigger: the first-use
        // Automation→Mail permission prompt sitting unanswered.
        if (err.killed || err.signal) {
            // Deliberately NOT an error: `is_error` becomes "failed" on the
            // record, and a send that may well have gone out must not be
            // written down as a failure. The words carry the uncertainty
            // instead, which is the same rule the activity lines follow.
            return { isError: false,
                     text: mode === "send"
                        ? "TIMED OUT waiting for Mail.app — the message MAY OR MAY NOT have been sent. "
                          + "Say exactly that. Do NOT retry until the user checks Mail's Sent mailbox "
                          + "(and whether a macOS permission prompt for Automation → Mail is waiting "
                          + "to be answered)."
                        : "TIMED OUT waiting for Mail.app — check for a pending Automation → Mail "
                          + "permission prompt. The draft may or may not have been saved." };
        }
        const detail = (err.stderr || err.message || "").trim();
        // "Mail.app refused" only when Mail actually spoke.
        const label = detail.includes("execution error") ? "Mail.app refused" : "The mail helper failed";
        return { isError: true,
                 text: `${label}: ${detail}\n(If this names permissions, Automation → Mail `
                     + `must be allowed for ${APP_NAME} in System Settings → Privacy & Security. If it `
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

/// Subjects as a person compares them: same words, ignoring the reply prefix
/// Mail adds, the case, and any run of spaces. Exact after that — a substring
/// test would let a one-letter claim match anything.
/// Built on `oneLineSubject`, the card's own rule: JavaScript's `\s` alone
/// keeps invisibles and would distinguish subjects the card draws alike.
function normaliseSubject(value) {
    // Composed after the invisibles are gone: one standing between a letter
    // and its accent would block NFC.
    return oneLineSubject(String(value == null ? "" : value)).normalize("NFC")
        .replace(/^((re|fw|fwd|aw|antw|tr) ?: ?)+/i, "")
        .trim()
        .toLowerCase();
}

async function replyTo(mode, args) {
    // Same rule as the compose path, and `expect_subject` most of all: it is
    // the field the card uses to say WHICH message is being answered, so a
    // shape the card cannot read would put "a message in your Mail" in front
    // of the user while a real reply went out as them.
    for (const field of ["rfc_message_id", "body", "expect_subject", "account"]) {
        const value = args[field];
        if (value !== undefined && value !== null && typeof value !== "string") {
            throw new Error(`\`${field}\` must be a string; it arrived as `
                + `${Array.isArray(value) ? "an array" : typeof value}. The approval card is built `
                + "from these values, so nothing was written.");
        }
    }
    const rfc = String(args.rfc_message_id || "").trim().replace(/^<|>$/g, "");
    const raw = String(args.body ?? "");
    refuseLeadingByteOrderMark(raw, "written");
    // Apply the same body limit to compose and reply.
    if (raw.length > 100000) {
        throw new Error(`\`body\` is implausibly long (${raw.length} characters, the limit is 100000). `
            + "The approval card is built from these values, so nothing was written.");
    }
    // As on the compose path: the body Mail gets is the body the card showed.
    const body = visibleBody(raw);
    const claimed = String(args.expect_subject ?? "").trim();
    const hint = String(args.account || "").trim();
    if (!rfc) {
        throw new Error("`rfc_message_id` is required: pass the `rfc_message_id` the reading tools "
            + "returned for that message, not Mail's internal id. The internal id is per-account and "
            + "the same number names a different message elsewhere, so a reply keyed on it could "
            + "answer the wrong thread as him.");
    }
    if (/^[0-9]+$/.test(rfc)) {
        throw new Error("That looks like Mail's internal id, not an RFC Message-ID. Read the message "
            + "again and pass its `rfc_message_id` — the internal id is not unique across accounts.");
    }
    if (!hasWords(body)) throw new Error("`body` is required: a reply with no words is not a reply");
    // The card says "its sender" or "everyone on that thread" from this flag, and it reads a
    // real boolean. A string "false" is truthy in JavaScript, so accepting one meant the card
    // could say "its sender" while the reply went to the whole thread.
    if (args.reply_all !== undefined && args.reply_all !== null
            && typeof args.reply_all !== "boolean") {
        throw new Error("`reply_all` must be true or false, not "
            + `${Array.isArray(args.reply_all) ? "an array" : typeof args.reply_all} — the approval `
            + "card is built from it, so nothing was written.");
    }
    if (typeof args.account !== "string" || !args.account.trim()) {
        throw new Error("`account` is required for a reply: pass the account you read the message in. "
            + "The same Message-ID can also sit in Sent from when he wrote it, and answering that "
            + "copy replies from the wrong side of the conversation.");
    }
    if (!claimed) {
        throw new Error("`expect_subject` is required: the approval card is built from it, so it is "
            + "checked against the real message before anything is written.");
    }
    if (rfc.length > 400 || claimed.length > 400 || hint.length > 200) {
        throw new Error("`rfc_message_id`, `expect_subject` or `account` is implausibly long");
    }
    // This depends on nothing the lookup returns, so it belongs with the other cheap guards
    // rather than after a Mail round trip: a claim that is only a reply prefix would match any
    // message with no subject.
    if (!normaliseSubject(claimed)) {
        throw new Error("`expect_subject` is only a reply prefix, which would match any message "
            + "with no subject. Read the message again and use its exact subject. Nothing was "
            + "written.");
    }

    let resolved;
    try {
        resolved = (await osascript(RESOLVE, [rfc, hint])).trim().split("\t");
    } catch (err) {
        const detail = (err.stderr || err.message || "").trim();
        if (detail.includes("NO_SUCH_ACCOUNT")) {
            return { isError: true,
                     text: "Mail has no account with that name. Call list_mail_accounts for the exact "
                         + "spelling. Nothing was written." };
        }
        if (detail.includes("AMBIGUOUS_ACCOUNT")) {
            return { isError: true,
                     text: "Two Mail accounts share that name, so there is no unambiguous way to pick "
                         + "one. Nothing was written." };
        }
        if (detail.includes("NOT_IN_THAT_ACCOUNT")) {
            return { isError: true,
                     text: "That account does not hold a message with that Message-ID. Nothing was "
                         + "written. Read it again and pass the account it is actually in — the same "
                         + "Message-ID can also sit in Sent, and answering that copy replies from the "
                         + "wrong side of the conversation." };
        }
        if (detail.includes("NO_SUCH_MESSAGE")) {
            return { isError: true,
                     text: "No message on this Mac has that Message-ID. Search for it again; nothing "
                         + "was written." };
        }
        if (err.killed || err.signal) {
            return { isError: true,
                     text: "TIMED OUT looking the message up — a Message-ID search is not indexed and "
                         + "a large archive can be slow. Nothing was written. Pass `account` from what "
                         + "you read so the search does not have to walk every account." };
        }
        return { isError: true, text: `Could not look that message up: ${detail}. Nothing was written.` };
    }
    const [internalID, foundAccount, realSubject] = resolved;
    if (!internalID) {
        return { isError: true, text: "Mail answered with no id for that Message-ID; nothing was written." };
    }
    // The card the user approved was built from the claim, so a claim that does not
    // match the message means the card described a different mail. Refused, and
    // the real subject is NOT echoed back: it is a stranger's words, and this
    // server is the one that is not fenced.
    if (normaliseSubject(realSubject) !== normaliseSubject(claimed)) {
        return { isError: true,
                 text: "That Message-ID belongs to a message with a different subject than the one "
                     + "you named, so the approval would have described the wrong mail. Nothing was "
                     + "written. Read the message again and use its exact subject." };
    }

    let result;
    try {
        result = (await osascript(REPLY, [mode, internalID, foundAccount || "", body,
                                          args.reply_all === true ? "all" : "one"])).trim();
    } catch (err) {
        if (err.killed || err.signal) {
            // Not a failure: Mail may already have sent it. Reported as an
            // ordinary result so the record does not claim a failed send.
            return { isError: false,
                     text: mode === "send"
                        ? "TIMED OUT waiting for Mail.app. The reply MAY OR MAY NOT have been sent — "
                          + "say exactly that, do NOT retry, and ask him to check Mail's Sent mailbox."
                        : "TIMED OUT waiting for Mail.app. The draft may or may not have been saved; "
                          + "ask him to check Mail's Drafts." };
        }
        const detail = (err.stderr || err.message || "").trim();
        if (detail.includes("NO_SUCH_MESSAGE")) {
            return { isError: true, text: "The message moved while it was being answered; nothing was written." };
        }
        const label = detail.includes("execution error") ? "Mail.app refused" : "The mail helper failed";
        return { isError: true,
                 text: `${label}: ${detail}\n(If this names permissions, Automation → Mail must be `
                     + `allowed for ${APP_NAME} in System Settings → Privacy & Security.)` };
    }
    // The claimed subject is echoed, never the real one: same reason as above.
    return { isError: false,
             text: mode === "send"
                ? `Mail.app accepted the reply to "${claimed}" — ${result}. It answered from the `
                  + `account the original was addressed to; Mail sends asynchronously, so report this `
                  + `as handed to Mail.`
                : `Reply to "${claimed}" saved as a draft — ${result}. Nothing was sent.` };
}

// ─────────────────────────────────────────────────────────────── MCP plumbing

const TOOLS = [
    {
        name: "reply_mail",
        description: "Reply to one message in the user's own Mail.app, as the user. Mail answers "
            + "from the account the original was addressed to — you never choose the sending "
            + "identity — but you MUST pass the `account` you read the message in, so the lookup "
            + "cannot land on the copy in Sent and answer from the wrong side. Find the message first (the read-only mail tools return its id) "
            + "and pass its `rfc_message_id` and its exact subject — the reply is refused if they "
            + "disagree, because the card he approves is built from what you claimed. Prefer draft_reply when the wording was not dictated or confirmed.",
        inputSchema: { type: "object",
            properties: {
                rfc_message_id: { type: "string", description: "The `rfc_message_id` the reading tools returned for that message — NOT Mail's internal id, which is not unique across accounts." },
                body: { type: "string", description: "Your words. Mail's quoted original stays underneath." },
                expect_subject: { type: "string", description: "That message's exact subject, as you read it. Checked for a match before anything is written, because the approval card is built from it." },
                account: { type: "string", description: "REQUIRED: the account you read the message in. The same Message-ID can also sit in Sent from when he wrote it, and answering that copy replies from the wrong side of the conversation. Named and not found is an error, never a silent search elsewhere." },
                reply_all: { type: "boolean", description: "Answer everyone on the original rather than only its sender. Say so when you ask him to approve it." },
            },
            required: ["rfc_message_id", "body", "expect_subject", "account"] },
    },
    {
        name: "draft_reply",
        description: "The same as reply_mail, but the answer is saved as a draft in the user's Mail "
            + "and nothing is sent. The safe choice whenever the wording was not confirmed.",
        inputSchema: { type: "object",
            properties: {
                rfc_message_id: { type: "string" }, body: { type: "string" },
                expect_subject: { type: "string" },
                account: { type: "string", description: "REQUIRED: the account you read it in." },
                reply_all: { type: "boolean" },
            },
            required: ["rfc_message_id", "body", "expect_subject", "account"] },
    },
    {
        name: "send_mail",
        description: "Send an email through the user's own Mail.app, AS the user, from an "
            + "explicitly named account. `account` has NO default and you never choose it: for a "
            + "NEW mail the user picks the address it goes from. Call list_mail_accounts, put the "
            + "choice to him with your question tool — one option per account — and send from the "
            + "one he picks. (Answering an existing message is different: use reply_mail, which "
            + "answers from the address it was sent to and still needs the account you read the "
            + "message in.) Name every recipient you are about to add, including cc and bcc, "
            + "when you ask him. Prefer "
            + "draft_mail whenever the wording wasn't dictated or confirmed.",
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
                    + "none is and the result says so — ask the user rather than pick." },
            },
            required: ["account", "to", "subject", "body"] },
    },
    {
        name: "draft_mail",
        description: "Create a DRAFT in the user's Mail.app under an explicitly named account — "
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
    reply_mail: (a) => replyTo("send", a),
    draft_reply: (a) => replyTo("draft", a),
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
            return { protocolVersion: /^\d{4}-\d{2}-\d{2}$/.test(params?.protocolVersion || "")
                        ? params.protocolVersion : "2024-11-05",
                     capabilities: { tools: {} },
                     serverInfo: { name: "openbots-apple-mail-send", version: "1.0.0" } };
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
