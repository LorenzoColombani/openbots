"""Fixed synthetic protocol peer. Never Claude, auth, a shell or containment.

It reads only fixture CSV and writes fixed receipt/report names in its test cwd.
Tool command text is compared exactly and never evaluated or executed.
"""
import csv
import json
import os
import sys
import uuid
from pathlib import Path

role, session, mode, tools = sys.argv[1:]
tools = tools.split(",") if tools else []
Path("fixture-started").write_text(str(os.getpid()))


def emit(value):
    print(json.dumps(value, sort_keys=True), flush=True)


def read():
    line = sys.stdin.readline(65537)
    if not line:
        return None
    assert len(line) <= 65536
    return json.loads(line)


initialize = read()
assert initialize["request"]["subtype"] == "initialize"
assert bool(initialize["request"]["hooks"]) == (role == "worker")
emit({"type": "control_response", "response": {"request_id": initialize["request_id"],
      "subtype": "success", "response": {}}})
initial = read()
emit({"type": "keep_alive"})
emit({"type": "command_lifecycle", "command_uuid": initial["uuid"], "session_id": session,
      "uuid": str(uuid.uuid4()), "state": "queued"})
emit({"type": "system", "subtype": "status", "session_id": session, "status": "requesting"})
emit({**initial, "isReplay": True, "message": {"role": "user",
      "content": [{"type": "text", "text": initial["message"]["content"]}]}})
emit({"type": "system", "subtype": "init", "session_id": session,
      "tools": tools, "mcp_servers": [], "plugins": [], "permissionMode": "default", "apiKeySource": "none"})

if role == "conversation":
    emit({"type": "assistant", "session_id": session, "message": {"role": "assistant",
          "content": [{"type": "text", "text": "Synthetic direction acknowledged."}]}})
    sys.stdin.read()
    sys.exit(0)

number = 0
pending = {}
latest_text = initial["message"]["content"]


def request(text):
    global number
    number += 1
    request_id, tool_id = "report-" + str(number), "report-tool-" + str(number)
    tool_input = {"command": "fixture-report --sample sample.csv --output report.md --step " + str(number)}
    pending[request_id] = (tool_id, tool_input, text, number)
    emit({"type": "assistant", "session_id": session, "message": {"role": "assistant",
          "content": [{"type": "tool_use", "id": tool_id, "name": "Bash", "input": tool_input}]}})
    emit({"type": "control_request", "request_id": request_id, "request": {
        "subtype": "hook_callback", "callback_id": "openbots-first-job-bash", "tool_use_id": tool_id,
        "input": {"hook_event_name": "PreToolUse", "session_id": session, "tool_name": "Bash",
                  "tool_use_id": tool_id, "tool_input": tool_input}}})


if mode == "websearch":
    # The worker looks something up before its first command, whether or not
    # the plan launched WebSearch; the host must refuse it when it did not.
    query = "sample totals"
    web_input = {"query": query}
    emit({"type": "assistant", "session_id": session, "message": {"role": "assistant",
          "content": [{"type": "tool_use", "id": "web-tool-1", "name": "WebSearch", "input": web_input}]}})
    emit({"type": "control_request", "request_id": "web-1", "request": {
        "subtype": "hook_callback", "callback_id": "openbots-first-job-websearch", "tool_use_id": "web-tool-1",
        "input": {"hook_event_name": "PreToolUse", "session_id": session, "tool_name": "WebSearch",
                  "tool_use_id": "web-tool-1", "tool_input": web_input}}})
    decision = read()
    if decision is None:
        sys.exit(0)
    web_allowed = decision["response"]["response"]["hookSpecificOutput"]["permissionDecision"] == "allow"
    if web_allowed:
        Path("web-search-used.txt").write_text(query)
    emit({"type": "user", "session_id": session, "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "web-tool-1", "is_error": not web_allowed, "content": "fixture search result"}]}})

request(latest_text)
queued = []
while True:
    record = read()
    if record is None:
        break
    if record["type"] == "user":
        # Like the real CLI: an input that arrives while a
        # turn is open is queued; the open turn ends with its own result first,
        # then the queued input is replayed and answered.
        if pending:
            queued.append(record)
            continue
        latest_text = record["message"]["content"]
        emit(record)
        request(latest_text)
        continue
    assert record["type"] == "control_response"
    response = record["response"]
    tool_id, tool_input, text, request_number = pending.pop(response["request_id"])
    hook = response["response"]["hookSpecificOutput"]
    allowed = hook["permissionDecision"] == "allow"
    if allowed:
        assert hook["updatedInput"] == tool_input
        if request_number < number:
            Path("obsolete-approval-used").write_text(response["request_id"])
        with open("sample.csv", newline="") as source:
            rows = list(csv.DictReader(source))
        if "Exclude test rows." in text:
            rows = [row for row in rows if row["environment"] != "test"]
        total = sum(int(row["amount"]) for row in rows)
        Path("report.md").write_text("Synthetic report: rows=" + str(len(rows)) + ", total=" + str(total) + ".\n")
    emit({"type": "user", "session_id": session, "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": tool_id, "is_error": not allowed, "content": "fixture result"}]}})
    if not pending and queued:
        emit({"type": "result", "session_id": session, "is_error": False, "result": "turn superseded"})
        record = queued.pop(0)
        latest_text = record["message"]["content"]
        emit(record)
        request(latest_text)
        continue
    if not pending and (allowed or mode == "report"):
        emit({"type": "result", "session_id": session, "is_error": not allowed, "result": "synthetic report.md"})
        if mode == "bad-exit":
            sys.exit(7)
        sys.stdin.read()
        break
    if not pending and not allowed:
        # Redirect: the denied turn ends on its own; the correction arrives next.
        emit({"type": "result", "session_id": session, "is_error": False, "result": "turn ended after denial"})
