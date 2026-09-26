# Renewing the rounds on the same pipe, Claude Code 2.1.281

Captured with Claude Code 2.1.281 and a probe script in the work shape (the app's file and shell set,
the question tool, the helper, WebSearch and WebFetch), model `claude-sonnet-5`,
`--max-turns 4`, every Bash question allowed as an approved card would, and
told to send a second message, so that at the first `result` the probe wrote one more user
message on the same stdin instead of closing it. Scrubbed of the account block, `apiKeySource`
(which a replay maps back to `none`) and the run folder (now `$RUN`), then the `rate_limit_event`
trimmed to its type and status. Guarded by the tests in `ClaudeCLIRoundsRenewalReplayTests.swift`.

- `wire.jsonl`: both directions in arrival order, `{"t", "dir": "cli"|"host", "frame"}`.
  The host wrote the initialize request, the message ("Run these with the Bash tool, one
  command per step … 1) head -c 8 /dev/urandom | xxd -p … 6) echo six. After all six, tell
  me the exact output of the first command."), one allow, and at 5.724 s the second message.
- The first message ran four rounds (the first four commands) and ended with `result`
  `error_max_turns`, `terminal_reason` `max_turns`, naming the first message's id.
- Then the CLI, still running: `command_lifecycle` completed for the first message; queued
  and started for the second; a second `system`/`init` for the same session and model; a
  `status`; the second message's replay (`isReplay: true`, its own id); a `message_start`
  tagged with that id (`user_message_uuid`); steps five and six; the answer, which is the
  first command's exact output (`0617b958849bf135`), so the earlier rounds were still in
  context; `result` `success` naming the second message; `command_lifecycle` completed.
- `argv.json`, `meta.json`, `system-prompt.md`: the command, what the launch was, the probe's
  own system prompt. The app launches a Control this Mac turn with `--max-turns 64`; this
  capture used 4 so that the cap came quickly, and the work shape because Control this Mac
  cannot be driven in a probe without a person at the screen. The renewal does not depend on the shape:
  the CLI counts `--max-turns` afresh for every message it reads.
