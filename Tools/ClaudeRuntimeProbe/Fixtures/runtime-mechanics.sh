#!/bin/sh
set -eu

# Offline, model-free child-process fixture. It exists only to test the probe's
# process and stream mechanics; it is never shipped or exposed as an OpenBots
# command capability.

extract_uuid() {
  /usr/bin/printf '%s\n' "$1" \
    | /usr/bin/sed -nE 's/.*"uuid"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p'
}

emit_replay() {
  /usr/bin/printf '{"type":"user","uuid":"%s","session_id":"fixture-session"}\n' "$1"
}

mode=${1:-}
case "$mode" in
  stream)
    /usr/bin/printf '%s\n' '{"type":"system","subtype":"init","apiKeySource":"none","session_id":"fixture-session","tools":[],"mcp_servers":[],"permissionMode":"dontAsk","claude_code_version":"fixture"}'
    IFS= read -r first_input
    first_uuid=$(extract_uuid "$first_input")
    emit_replay "$first_uuid"
    IFS= read -r second_input
    second_uuid=$(extract_uuid "$second_input")
    emit_replay "$second_uuid"
    /usr/bin/printf '%s\n' '{"type":"result","result":"ACK-1","session_id":"fixture-session"}'
    /usr/bin/printf '%s\n' '{"type":"result","result":"ACK-2","session_id":"fixture-session"}'
    while IFS= read -r ignored; do :; done
    ;;

  result-eof)
    IFS= read -r input
    uuid=$(extract_uuid "$input")
    emit_replay "$uuid"
    # Deliberately omit the final newline to exercise the result/EOF race.
    /usr/bin/printf '%s' '{"type":"result","result":"ACK-EOF","session_id":"fixture-session"}'
    ;;

  stop-reading)
    /bin/sleep 30 &
    descendant=$!
    /usr/bin/printf 'TREE %s %s\n' "$$" "$descendant"
    wait "$descendant"
    ;;

  process-tree)
    record=${2:?process-tree requires a receipt path}
    /bin/sleep 30 &
    descendant=$!
    /usr/bin/printf '%s %s\n' "$$" "$descendant" > "$record"
    /usr/bin/printf 'TREE %s %s\n' "$$" "$descendant"
    wait "$descendant"
    ;;

  teardown-race)
    record=${2:?teardown-race requires a receipt path}
    IFS= read -r input
    uuid=$(extract_uuid "$input")
    # One read creates exactly one durable fixture receipt before acknowledgement.
    /usr/bin/printf '%s\n' "$uuid" >> "$record"
    /bin/sleep 30 &
    descendant=$!
    emit_replay "$uuid"
    /usr/bin/printf 'TREE %s %s\n' "$$" "$descendant" >&2
    wait "$descendant"
    ;;

  *)
    /usr/bin/printf 'unknown runtime fixture mode: %s\n' "$mode" >&2
    exit 64
    ;;
esac
