import Foundation

/// Silent webhook sink + the prompt used by the optional review cron.
/// No model is invoked when the sink runs; `[SILENT]` tells Hermes to
/// ignore the event after the script writes the JSONL line.
public enum ScarfGoDebugHostAssets: Sendable {
    public static let webhookName = "scarfgo-debug"
    public static let cronJobName = "ScarfGo debug review"
    public static let defaultCronSchedule = "0 9 * * *"
    public static let sinkRelativePath = "scripts/scarfgo_debug_sink.py"
    public static let hostLogRelativePath = "logs/scarfgo-client.jsonl"
    public static let skillRelativePath = "skills/scarfgo-debug/SKILL.md"

    public static let sinkScript = #"""
#!/usr/bin/env python3
"""Append one ScarfGo debug JSON object from stdin to the host JSONL.

Prints [SILENT] so Hermes does not start an agent. Never logs the body.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

HOME = Path(os.path.expanduser("~"))
LOG = HOME / ".hermes" / "logs" / "scarfgo-client.jsonl"
MAX_BYTES = 1_000_000


def main() -> int:
    raw = sys.stdin.read()
    try:
        obj = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        obj = {"kind": "error", "code": "invalid-json", "message": "unparseable webhook body"}
    if not isinstance(obj, dict):
        obj = {"kind": "error", "code": "invalid-json", "message": "webhook body was not an object"}
    LOG.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(obj, separators=(",", ":"), ensure_ascii=False)
    if LOG.exists() and LOG.stat().st_size > MAX_BYTES:
        rotated = LOG.with_suffix(".jsonl.1")
        try:
            if rotated.exists():
                rotated.unlink()
            LOG.replace(rotated)
        except OSError:
            pass
    with LOG.open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")
    print("[SILENT]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
"""#

    public static let reviewPrompt = """
Read ~/.hermes/logs/scarfgo-client.jsonl if it exists. Summarize ScarfGo client events newer than the last 24 hours (or newer than your last run if you recorded a cursor). Group by `code`. Skip an empty file. Never echo secrets, tokens, passwords, or chat bodies. Do not write MEMORY.md. If the dedicated JSONL is missing, grep gateway.log for scarfgo-debug and say the analysis is weaker because ingest fell back to the mixed log.
"""

    public static let skillMarkdown = """
---
name: scarfgo-debug
description: Summarize ScarfGo client debug JSONL without echoing secrets.
---

# ScarfGo debug review

Read `~/.hermes/logs/scarfgo-client.jsonl`. One JSON object per line (`ts`, `app`, `kind`, `code`, `message`, `connection`, `serverFingerprint`).

- Only lines newer than the last run, or last 24h if you have no cursor.
- Summarize by `code`. Skip empty files.
- Never echo secrets. Do not write MEMORY.md.
- If the file is missing, say ingest may have fallen back to `gateway.log`.
"""
}
