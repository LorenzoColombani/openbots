#!/usr/bin/env python3
"""Forbidden-content gate for the OpenBots tree: secrets, real home folders,
machine temp paths and real-looking email addresses.

Usage: Scripts/public-gate.py [tree]   (default: the current directory)

Plain grep misses text that a recorded Claude Code run streams across several
delta frames, so a path or an email can hide in pieces. This gate searches
every file as written AND, for each *.jsonl recording, the text rebuilt by
joining each content block's deltas in order. Exit 1 on any finding.
"""
import json
import os
import re
import sys

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
SKIP_DIRS = {".git", ".build", ".build.noindex", ".swiftpm", "DerivedData"}
SKIP_FILES = {"Scripts/public-gate.py"}
BINARY_EXT = {".png", ".icns", ".jpg", ".jpeg", ".gif", ".pdf"}

# Reserved names (RFC 2606 / RFC 6761) and the fixture roots the tests use.
EMAIL = re.compile(r"[A-Za-z0-9._%+'-]{1,}@[A-Za-z0-9.-]{1,}\.[A-Za-z]{2,}")
EMAIL_OK = re.compile(
    r"@([A-Za-z0-9-]+\.)*(example|test|invalid|localhost)$"
    r"|@([A-Za-z0-9-]+\.)*example\.(com|org|net|fr|ie|co\.uk|co|international|edu)$"
    r"|@([A-Za-z0-9-]+\.)*(invalid\.local)$"
    r"|@group\.v\.calendar\.google\.com$"
    r"|@users\.noreply\.github\.com$"
    r"|@console\.cloud\.google\.com$"
    r"|@[.]*([A-Za-z0-9-]+[.]+)*example[.]+[A-Za-z.]+$",
    re.I,
)

# Home folders the tests use on purpose; any other /Users/<name> is a leak.
SYNTHETIC_HOMES = {
    "x", "probe", "alex", "example", "someone", "somebody", "you", "USER",
    "private", "Shared", "name", "me", "user", "test", "a", "b",
}
HOME = re.compile(r"/Users/([A-Za-z0-9._-]+)")

RULES = [
    ("machine temp path", re.compile(r"/var/folders/(?!xx/)[a-z0-9_]{2}/[a-z0-9_]{20,}")),
    ("secret shape", re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}|BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{30,}|xox[bp]-[0-9]|GOCSPX-[A-Za-z0-9_-]{24,}|\d{6,}-[a-z0-9]{20,}\.apps\.googleusercontent\.com")),
]

# The author's public identity: copyright, bundle ids and the repo slug.
ALLOW = [
    re.compile(r"Copyright © 2026 Lorenzo Colombani"),
    re.compile(r"com\.lorenzocolombani\b"),
    re.compile(r"LorenzoColombani/openbots"),
]


def rebuilt_texts(path):
    """Yield the text of each content block rebuilt from its streamed deltas."""
    blocks = {}
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    frame = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(frame, dict):
                    continue
                frame = frame.get("frame", frame) if isinstance(frame.get("frame"), dict) else frame
                event = frame.get("event", frame) if isinstance(frame.get("event"), dict) else frame
                if not isinstance(event, dict) or event.get("type") != "content_block_delta":
                    if isinstance(event, dict) and event.get("type") == "message_start":
                        for text in blocks.values():
                            yield "".join(text)
                        blocks = {}
                    continue
                delta = event.get("delta", {})
                piece = delta.get("text") or delta.get("thinking") or delta.get("partial_json") or ""
                blocks.setdefault(event.get("index", 0), []).append(piece)
    except OSError:
        return
    for text in blocks.values():
        yield "".join(text)


def scrub_allowed(text):
    for pattern in ALLOW:
        text = pattern.sub("", text)
    return text


def check_text(rel, text, where, findings):
    clean = scrub_allowed(text)
    for label, pattern in RULES:
        for match in pattern.finditer(clean):
            findings.append(f"{rel} [{where}] {label}: {match.group(0)!r}")
    for match in HOME.finditer(clean):
        if match.group(1) not in SYNTHETIC_HOMES:
            findings.append(f"{rel} [{where}] home folder: {match.group(0)!r}")
    for match in EMAIL.finditer(clean):
        address = match.group(0)
        if not EMAIL_OK.search(address):
            findings.append(f"{rel} [{where}] real-looking email: {address!r}")


def main():
    findings = []
    for directory, subdirs, files in os.walk(ROOT):
        subdirs[:] = [d for d in subdirs if d not in SKIP_DIRS]
        files = [f for f in files if not (directory == ROOT and f == ".git")]
        for name in files:
            path = os.path.join(directory, name)
            rel = os.path.relpath(path, ROOT)
            if rel in SKIP_FILES or os.path.splitext(name)[1].lower() in BINARY_EXT:
                continue
            try:
                with open(path, encoding="utf-8") as handle:
                    text = handle.read()
            except (UnicodeDecodeError, OSError):
                continue
            check_text(rel, text, "file", findings)
            if name.endswith(".jsonl"):
                for block in rebuilt_texts(path):
                    check_text(rel, block, "rebuilt deltas", findings)
    for line in sorted(set(findings)):
        print(line)
    print(f"public-gate: {len(set(findings))} finding(s) in {ROOT}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
