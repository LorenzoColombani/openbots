# Self-setup probe, Claude Code 2.1.280

Captured with a probe script in its hire-only shape, set up for self-setup: the CLI
launched as the app launches a turn whose only grant is the app-hosted `openbots`
server, here listing `set_up_self` instead of `hire_teammate`, questions over
`--permission-prompt-tool stdio`. Each run's `system-prompt.md` is the draft setup
section. Paths are scrubbed to `/private/tmp/self-setup-probe.noindex`, the account
to `probe@example.com`.

- `s2-competitor-prices`: the acceptance sentence, after the prompt said a bot remembers
  without any switch (an earlier wording also asked for `work`, to keep a price file).
  Handle `PriceWatch`, switches `web_search` and `web_fetch` only. Its role copied the
  example phrase in the prompt word for word, so the app's text uses an unrelated example.
- `s3-vague`: "hi there". No tool call; one question back.

Other runs of the same probe are not shipped. Over eight jobs with the app's final setup
section (the two above, tidying files, replies to emails, renaming photos, news, a tutor,
a site's uptime), Claude chose the expected switches 8 of 8. Four of the jobs, run again
on `sonnet` (the model a new bot gets), gave the same acceptance answer; there the news
job asked for `web_search` only. A role can copy the prompt's own example phrase when
the job resembles it.

What the app must build for:

- The tool call reaches the host first as `can_use_tool` for
  `mcp__openbots__set_up_self` (no allow rule), then as `tools/call`. The switch card
  is answered at the permission step, which has no timeout; the `tools/call` answer
  is bounded by the server's 60-second call timeout, too short for a person.
- The model finishes in the same reply after the tool answers (two turns), with one
  line saying what it became.
