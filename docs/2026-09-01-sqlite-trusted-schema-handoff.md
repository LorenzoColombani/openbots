# Handoff — SQLite trusted_schema vs. FTS5 triggers (release/v0.5.0), 2026-09-01

Written for the maintainer of the private tree (`~/Developer/OpenBotsNext`) to port back.
Everything below is verified state, not recollection.

## What broke
CI run 33533182168 on `release/v0.5.0` @ `f164160` (runner `macos-15`, macOS 15.7.7):
forbidden-content scan green; test job hit the 3 h ceiling and was cancelled after
199 test failures in the first 7 minutes. 156 of them carry the same error:

    SQLite prepare failed (1): unsafe use of virtual table "conversation_message_search"

The remaining 43 are downstream expectation failures in the same suites (nothing was saved).

## Root cause (receipts)
- `SQLiteStore.init` runs `PRAGMA trusted_schema=OFF` on every connection (SQLiteStore.swift).
- `SchemaMigrator` maintains the FTS5 table `conversation_message_search` from triggers on
  `messages` / `message_parts` (SchemaMigrator.swift ~L319-350).
- Under an untrusted schema SQLite treats a virtual table inside a trigger as direct-only
  unless the module is tagged `SQLITE_VTAB_INNOCUOUS`. FTS5 got that tag in **SQLite 3.44.0
  (2023-11-01)** — https://sqlite.org/changes.html.
- The package links the *system* `libsqlite3`. macOS 26 ships 3.51.0 (dev machine, works).
  macOS 15 ships 3.43.2 and macOS 14 ships 3.39.x (both fail). Minimum target is macOS 14.
- Reproduced outside the app by compiling the 3.43.2 amalgamation with FTS5: same trigger
  fails with `trusted_schema=OFF`, passes with `ON`. On 3.51 both pass.

So this is a product bug for every macOS 14/15 user (no message can be saved), not a CI quirk.

## Decision (Lorenzo, 2026-09-01): option A — version-gated trust
Keep `trusted_schema=OFF` where SQLite is new enough to allow FTS5 in triggers; set it `ON`
only when the linked library is older than 3.44.0. The app decides per machine at open time
by asking the library (`sqlite3_libversion_number()`); nothing is stored in the database file,
so databases move freely between macOS versions.

Alternatives considered and parked: (B) `ON` everywhere — simplest, drops a deliberate
hardening; (C) bundle a modern SQLite — fixes root for good, build-system change, later;
(D) maintain the search index from Swift instead of triggers — most work, riskiest pre-release.

## Change set
Two commits on `release/v0.5.0`, to cherry-pick into the private tree:

- `ac7f5e5` — Persistence: trust the SQLite schema only where FTS5 cannot run inside triggers
  - `Sources/OpenBotsPersistence/SQLiteC.swift` — binding for `sqlite3_libversion_number`.
  - `Sources/OpenBotsPersistence/SQLiteSchemaTrust.swift` — NEW. The rule
    (`requiresTrustedSchema(libraryVersionNumber:)`, boundary `3_044_000`) and the pragma string.
  - `Sources/OpenBotsPersistence/SQLiteStore.swift` — the single `PRAGMA trusted_schema=OFF;`
    line becomes `SQLiteSchemaTrust.trustedSchemaPragma`. No other behaviour changed.
  - `Tests/OpenBotsPersistenceTests/SQLiteStoreTests.swift` — three tests (see Verification).
  - `Scripts/test-inventory.txt` — 1491 → 1494 (the three tests).
- `58b34c5` — Tests: search-reopen test follows the schema-trust rule instead of hard-coding OFF
  - `Tests/OpenBotsPersistenceTests/SQLiteConversationSearchRepositoryTests.swift` — the reopen
    test asserted `PRAGMA trusted_schema == 0` unconditionally; it now asserts the
    `SQLiteSchemaTrust` decision for the linked library. Found by the first CI run of `ac7f5e5`.

Behaviour by machine after the change:

| linked SQLite | macOS | `trusted_schema` |
|---|---|---|
| < 3.44.0 | 14, 15 | ON (was OFF → every message insert failed) |
| ≥ 3.44.0 | 26 | OFF (unchanged) |

## Verification
Sprint 1 — tests first, then the fix (TDD, red → green):
- `SQLiteStoreTests` filtered run: red (type missing), then 23/23 green with the fix. The three new tests:
  - `testSchemaIsTrustedOnlyOnSQLiteOlderThanInnocuousFTS5` — rule at its boundaries
    (3.39.5, 3.43.2, 3.43.999 → trusted; 3.44.0, 3.51.0 → untrusted).
  - `testOpenedConnectionTrustsSchemaExactlyWhenTheLinkedSQLiteNeedsIt` — reads
    `PRAGMA trusted_schema` on a real opened store and compares it with the rule for
    `sqlite3_libversion_number()`. On the runner this asserts 1; on macOS 26 it asserts 0.
  - `testTriggerMaintainedSearchIndexAcceptsInsertsOnTheLinkedSQLite` — creates an FTS5 table
    fed by a trigger (same tokenizer, same statement shape as the production index) and
    inserts through it. This is the exact operation that failed on the runner.

Sprint 2 — full serial suite on the dev machine (macOS 26.6.2, SQLite 3.51.0, `OFF` path):
- `Scripts/swiftpm-public.sh test --no-parallel`: 513 XCTest + 981 Swift Testing = **1494 tests,
  0 failures**, 2026-09-01 20:37:51Z → 20:39:12Z. Proves the modern path did not move.

Sprint 3 — CI on `macos-15` (SQLite 3.43.2, `ON` path):
- Run 33556621177 @ `ac7f5e5`: scan success. Test job: `unsafe use of virtual table` count **0**
  (was 156); no hang (job 5 min, was 3 h). XCTest 513 run / 34 failures (was 46);
  Swift Testing 981 run / **1 issue** — the hard-coded `trusted_schema == 0` fixed in `58b34c5`.
- Run 33557466777 @ `58b34c5`: scan success. **Swift Testing 981/981 passed.**
  XCTest 513 run / 33 failures, all in the 8 pre-existing `OpenBotsUITests` cases below;
  **0 failures outside the UI module.** The persistence change is fully green on 3.43.2.

Sprint 2 repeated after `58b34c5` on the dev machine: 1494/1494 green (20:45Z).

Out-of-app reproduction (kept for the record, not in the repo): SQLite 3.43.2 amalgamation compiled
with `-DSQLITE_ENABLE_FTS5`; FTS5 table + insert trigger; `trusted_schema=OFF` →
`unsafe use of virtual table`; `trusted_schema=ON` → row indexed. Same script on 3.51.0 → both pass.

## Follow-through, 2026-09-01 evening → 09-02: the UI failures, probed and fixed on the test side

Additional commits on `release/v0.5.0` (all cherry-pickable; none change app views):

- `619c063` — `Scripts/ci-ax-probe.swift` + `.github/workflows/ax-probe.yml` (diagnostic, matrix
  macos-15/26); `ci.yml` test job becomes a matrix on `macos-15` and `macos-26`.
- `e4bebd4` — OCR evidence captured at 2x (`NormalAppPresentationTests.captureRenderedText`).
- `bd361d1` — OCR positive phrase checks ignore whitespace/case (`ocrContains`); negatives exact.
- `cd172d9` — button assertions check `cell is NSButtonCell` instead of `accessibilityRole()`;
  geometry by `alignmentRect(forFrame:)`; CI uploads the rendered evidence PNGs as artifacts.
- `1291bb5` — evidence upload works from the dot-directory (`include-hidden-files: true`).
- `ab803e0` — Settings render evidence counts ink by contrast to the region's median, not an
  absolute 0.55: on macOS 15 the never-key fixture window dims sidebar labels (~0.38 over 0.10).
- `6ce21ba` — `OpenBotsNext.xcodeproj` gains the `SQLiteSchemaTrust.swift` entry. **Repo rule:**
  SwiftPM discovers sources; the preview-app xcodeproj lists them explicitly. A new source file
  needs 4 pbxproj lines (mirror `SQLiteC.swift`) or "Build the app (unsigned)" fails on CI.

Probe verdict (run 33560977997, both runners, matches the dev machine):
- Neither runner is headless: window-server session present, window visible, text renders,
  `AXIsProcessTrusted` true. Backing scale is 1.0 on both runners (dev machine 2.0).
- macOS 15: a SwiftUI `Button` in `NSHostingController` becomes a `SwiftUIAppKitButton`
  (NSButton subclass). macOS 26: no NSButton at all — so the role assertions never ran on 26.
- `accessibilityRole()` returns AXUnknown for every NSButton in-process, on 15, 26 and the dev
  machine, even inside an ordered-front window after `finishLaunching`. Only an external AX client
  (VoiceOver — verified by hand on the real app) receives AXButton. The assertion was invalid;
  the app's buttons are fine.
- Pixel tests: 1x rendering made Vision misread "Stop"→"Ston", "earlier"→"earller",
  "Local only"→"Localonly". Fixed by 2x capture + whitespace-insensitive positives.

**Gate result:** run 33565035649 @ `1291bb5`, `macos-26` job **success** — 513 XCTest + 981 Swift
Testing, and "Build the app (unsigned)" green. Run 33565968927 @ `ab803e0`: `macos-26` **success** again;
`macos-15` **1493/1494** (513 XCTest with 1 failure, 981 Swift Testing green). From 199 failures
and a 3 h hang at the start of 2026-09-01 to one open test.

Still open on `macos-15`, one test: `CharacterMotionVisibilityTests.testWindowSubscriptionsFollowOnlyTheOwningWindow`
(failed 4 of 5 runs there, never on 26). After the view moves to another window, one resize
notification from the OLD window still produces an assessment (count 2, expected 1). That is a
macOS 15 ordering difference in the view's window-subscription handling, i.e. a real code path in
`OpenBotsUI`, not a test artefact — deserves a deliberate look rather than a threshold change.
Also flaky on the runner, unrelated: `LocalRunShutdownTests` "Grace drains…" (`.gateNotReached`),
passed on rerun — the wall-clock family `ci.yml` already warns about.

## Pre-existing, unrelated: 8–9 UI tests fail on the `macos-15` runner (state as of 2026-09-01 20:55Z)
Not caused by this change and not touched by it. They fail identically in runs
33513822221 (13:30Z) and 33533182168 (16:40Z), both before any persistence change, and none of
them imports or references SQLite (all `@testable import OpenBotsUI`, AppKit/SwiftUI render tests):

- `ReferenceUtilitySurfaceTests.testAllSettingsSectionsRenderAtMinimumWithoutSetupOrAccountActions`
  — "Settings navigation labels must render" (0 > 150 failed)
- `NormalAppPresentationTests.testPendingChatKeepsStopAndContextOmissionVisible`
  — "Stop control disappeared from pixels" (OCR of a rendered bitmap)
- `ComposerDraftStatusViewTests` × 3 — `AXUnknown` where `AXButton` is expected
- `CharacterMotionVisibilityTests.testWindowSubscriptionsFollowOnlyTheOwningWindow` — 2 ≠ 1 / 4 ≠ 3
  (failed in the first three runs, passed in run 33557466777: flaky on the runner)
- `AttachmentPreviewPresentationTests` × 3 — `AXUnknown` where `AXButton` is expected

Twenty of the 34 assertion failures are the same `AXUnknown` vs `AXButton` accessibility-role
mismatch. Two candidate causes, not yet separated: SwiftUI/AppKit on macOS 15 exposes these
controls differently than macOS 26 does (a real behaviour difference users on 15 would see), or the
runner's headless session never realises the accessibility tree / pixels. Deciding which needs a
macOS 15 machine with a real login session. Until then the `macos-15` job cannot be green even
with the persistence fix in place, so the release gate needs a ruling: fix these first, run the
UI suite only on a runner that can render, or accept the scan + non-UI suites as the gate for v0.5.0.

## Known follow-ups (not in this change)
- The CI job hung for ~3 h after the DB failures: suite "Official text replies with an inert
  runtime" started at 16:47:09Z and never produced another line. Some wait has no deadline.
  Give it a timeout in its own change.
- Add a `macos-26` runner (or the newest available) alongside `macos-15` so CI covers BOTH
  trust paths; today only the dev machine exercises `OFF`.
- Option C (bundled SQLite) if system-library drift bites again.
