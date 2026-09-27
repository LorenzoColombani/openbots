# Question cards on a setup turn, Claude Code 2.1.283

A new bot's setup turn captured with the app's launch shape: the `openbots` server
listing `set_up_self`, the shared and skills folders readable, the app's setup prompt,
model `sonnet`, and question cards answered as the app answers them, each held 20 s.
The turn: a Glob of `**/*`, the setup call, a sentence and a card of three questions,
then a sentence and a card of two, then the reply.

A setup turn of this shape once failed with `responseMismatch` two seconds after the
answers to its second card; this capture replays whole, and the app now keeps a failed
turn's latest frames so the next one names itself.

Scrubbed: the home folder to `/Users/probe`, the capture folder to
`/private/tmp/question-cards-probe.noindex`, the account to `probe@example.com`.
