#!/bin/bash
# Phase 0 live gate: persona, memory, resume, handoff, fork-session — REAL claude calls.
# Costs subscription usage. Run at gates only, never in a loop.
set -e
cd "$(dirname "$0")/.."
BIN=.build/debug/agency-cli
CLAUDE_BIN="$(command -v claude || echo "$HOME/.local/bin/claude")"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --product agency-cli > /dev/null

echo "== 1. create two agents (already-exists is fine on re-runs)"
$BIN create alfredo 🧑‍🍳 research specialist || true
$BIN create bruno ✍️ writer and brief-assembler || true

echo ""
echo "== 2. persona + memory write"
$BIN chat alfredo "Remember: the codeword is MOONBASE. Confirm you stored it. One sentence."

echo ""
echo "== 3. persistence across separate invocations (resume)"
$BIN chat alfredo "What is the codeword? One sentence."   # MUST mention MOONBASE

echo ""
echo "== 4. handoff: bruno asks alfredo"
$BIN ask bruno alfredo "What is the codeword you were told? One sentence."  # MUST mention MOONBASE

echo ""
echo "== 5. fork-session behavior probe (spec open item)"
SID=$(python3 -c "import json;print([a for a in json.load(open('roster.json'))['agents'] if a['name']=='alfredo'][0]['sessionID'])")
echo "alfredo session: $SID"
FORK=$("$CLAUDE_BIN" -p --resume "$SID" --fork-session "What is the codeword? Reply with just it." --output-format json)
echo "$FORK" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('fork recalled:', d['result'])
print('fork new sid differs:', d['session_id'] != '$SID')"

echo ""
echo "== PHASE 0 GATE: PASS if MOONBASE appeared in steps 3, 4 and 5 =="
