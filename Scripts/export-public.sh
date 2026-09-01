#!/bin/bash
# Build the PUBLIC tree for an OpenBots (Next) source drop.
#
# Policy (unchanged since the 2026-08-27 spec, reapplied 2026-09-01): the public
# repo is built by COPYING an explicit allowlist from the clean private tree
# with a FRESH history — never by carrying private git history. Sterilization =
# Scripts/export-manifest.txt (include list) + the transforms below + the gates
# below. Nothing here edits the private tree. The exporter stops after gating;
# committing, pushing, tagging and releasing are separate, human-authorized steps.
#
# Usage: Scripts/export-public.sh /path/to/clean/private/checkout
# Output: a fresh temp staging dir (path printed at the end).
#
# Gate allowlist (recorded deviations, re-verified 2026-09-01): synthetic
# fixtures use /Users/x/…; negative-test sentinels in
#   Tests/OpenBotsServicesTests/ConversationOutcomeHistoryServiceTests.swift
#   Tests/OpenBotsUITests/ConversationSearchTests.swift
#   Tests/OpenBotsUITests/PresentationModelsTests.swift
# embed /Users/… strings precisely to assert they are never disclosed; the
# bundle id com.lorenzocolombani.* and GitHub URLs carry the author's public
# handle by design. Anything else matching is a leak.
set -euo pipefail

PRIVATE="${1:?usage: export-public.sh /path/to/private/checkout}"
OUT=$(mktemp -d "${TMPDIR:-/tmp}/openbots-export.XXXXXX")
HERE=$(cd "$(dirname "$0")/.." && pwd)

step() { printf '\n==> %s\n' "$1"; }
fail() { printf '\n!! %s\n' "$1" >&2; exit 1; }

step "Copying the manifest allowlist from $PRIVATE into $OUT"
cd "$PRIVATE"
git diff --quiet && git diff --cached --quiet || fail "private checkout is dirty"
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue;; esac
  git archive HEAD -- "$line" | tar -x -C "$OUT" || fail "manifest entry failed: $line"
done < "$HERE/Scripts/export-manifest.txt"

step "Removing excluded files"
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue;; esac
  rm -rf "${OUT:?}/$line"
done < "$HERE/Scripts/export-exclude.txt"

step "Content transforms"
# Tracked-source content transforms (renames/rewrites) are applied on the
# private side before this exporter runs; this public copy performs the
# allowlist copy and the gates only.

step "Gate: competitor names"
grep -rqi "gr""ok" "$OUT" && fail "competitor reference survived the transform"

step "Gate: machine paths"
grep -rn "/Users/" "$OUT" \
  | grep -v "/Users/x/" \
  | grep -v "ConversationOutcomeHistoryServiceTests.swift" \
  | grep -v "ConversationSearchTests.swift" \
  | grep -v "PresentationModelsTests.swift" \
  | grep -v 'contains("/Users/")' \
  && fail "machine path leaked" || true

step "Gate: secrets and PII shapes"
grep -rnE "sk-ant-|BEGIN [A-Z]+ PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|xoxb-" "$OUT" && fail "secret shape found" || true
grep -rhoE "[A-Za-z0-9._%+-]{2,}@[A-Za-z0-9.-]{3,}\.[A-Za-z]{2,}" "$OUT" \
  | grep -v "example.invalid" | grep -v "example.com" | grep -q . && fail "non-fixture email found" || true

step "Gate: forbidden private files"
for p in AGENTS.md BUILD_JOURNAL.md BUILD_VARIANTS.md HANDOFF.md PLAN.md REFERENCE_AUDIT.md docs/workflow docs/specs docs/architecture docs/decisions docs/design docs/feasibility docs/legacy-mechanism-audit.md Tools; do
  [ ! -e "$OUT/$p" ] || fail "forbidden in export: $p"
done

step "Manifest freeze"
( cd "$OUT" && find . -type f ! -path "./.build*" ! -path "./.gate-evidence/*" -print0 \
  | xargs -0 shasum -a 256 | sort -k2 ) > "$OUT/.gate-evidence-manifest.sha256" || true

step "Done. Staging tree: $OUT"
echo "Next: run the full test gate in the staging tree, then layer into the airlock release branch (separate authorization)."
