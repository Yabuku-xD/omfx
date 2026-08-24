#!/usr/bin/env python3
"""Time omfx CLI + grok-4.5 --effort low asks. Writes JSON to stdout."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OMFX = ROOT / "zig-out" / "bin" / "omfx"
ASK_BASE = [
    str(OMFX),
    "ask",
    "--provider",
    "xai-oauth",
    "--model",
    "grok-4.5",
    "--effort",
    "low",
    "--json",
]


def run(cmd: list[str], *, cwd: Path | None = None, timeout: float = 30.0, env: dict | None = None) -> dict:
    t0 = time.perf_counter()
    proc = subprocess.Popen(
        cmd,
        cwd=str(cwd) if cwd else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=env,
    )
    chunks: list[str] = []
    first_s = None
    timed_out = False
    try:
        assert proc.stdout is not None
        while True:
            if time.perf_counter() - t0 > timeout:
                proc.kill()
                timed_out = True
                break
            line = proc.stdout.readline()
            if line:
                if first_s is None:
                    first_s = time.perf_counter() - t0
                chunks.append(line)
                continue
            if proc.poll() is not None:
                rest = proc.stdout.read()
                if rest:
                    if first_s is None:
                        first_s = time.perf_counter() - t0
                    chunks.append(rest)
                break
            time.sleep(0.01)
        stderr = proc.stderr.read() if proc.stderr else ""
        if proc.poll() is None:
            proc.wait(timeout=2)
    except Exception as err:
        proc.kill()
        wall = time.perf_counter() - t0
        return {
            "cmd": cmd,
            "ok": False,
            "code": None,
            "wall_s": round(wall, 4),
            "ttfb_s": None,
            "stdout": "".join(chunks)[:4000],
            "stderr": str(err)[:2000],
            "timeout": True,
        }
    wall = time.perf_counter() - t0
    text = "".join(chunks)
    return {
        "cmd": cmd,
        "ok": (proc.returncode == 0) and not timed_out,
        "code": proc.returncode,
        "wall_s": round(wall, 4),
        "ttfb_s": None if first_s is None else round(first_s, 4),
        "stdout": text[:8000],
        "stderr": (stderr or "")[:2000],
        "timeout": timed_out,
        "stdout_bytes": len(text),
        "first_line": (text.splitlines()[0] if text.strip() else ""),
    }


def parse_jsonl(text: str) -> dict:
    kinds: dict[str, int] = {}
    tools: list[str] = []
    result = ""
    think = 0
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = obj.get("type", "")
        kinds[kind] = kinds.get(kind, 0) + 1
        if kind == "tool":
            tools.append(obj.get("text", "")[:120])
        elif kind == "result":
            result = obj.get("text", "")
        elif kind == "think":
            think += len(obj.get("text", ""))
    return {"kinds": kinds, "tools": tools, "result": result[:1500], "think_chars": think}


def main() -> int:
    if not OMFX.exists():
        print("missing ./zig-out/bin/omfx", file=sys.stderr)
        return 2

    out: dict = {"omfx": str(OMFX), "model": "grok-4.5", "effort": "low", "cli": [], "live": []}

    cli_cmds = [
        ([str(OMFX), "version"], 5),
        ([str(OMFX), "--version"], 5),
        ([str(OMFX), "help"], 5),
        ([str(OMFX), "-h"], 5),
        ([str(OMFX), "help", "ask"], 5),
        ([str(OMFX), "help", "login"], 5),
        ([str(OMFX), "help", "session"], 5),
        ([str(OMFX), "help", "doctor"], 5),
        ([str(OMFX), "help", "install"], 5),
        ([str(OMFX), "help", "browser-relay"], 5),
        ([str(OMFX), "doctor"], 5),
        ([str(OMFX), "login"], 5),
        ([str(OMFX), "session"], 5),
        ([str(OMFX), "session", "list"], 5),
        ([str(OMFX), "install"], 5),
        ([str(OMFX), "ask"], 5),
        ([str(OMFX), "not-a-command"], 5),
        ([str(OMFX), "--nope"], 5),
        ([str(OMFX), "browser-relay", "install"], 8),
    ]
    for cmd, timeout in cli_cmds:
        out["cli"].append(run(cmd, timeout=timeout))

    ws = Path("/tmp/omfx-bench-ws")
    if ws.exists():
        shutil.rmtree(ws)
    ws.mkdir(parents=True)
    (ws / "hello.txt").write_text("hello omfx bench\n", encoding="utf-8")
    (ws / "note.md").write_text("# note\nalpha beta\n", encoding="utf-8")

    live_prompts = [
        ("ping", "Reply with exactly: pong", False, 90),
        ("list", "Use the list tool on path=. then reply with the file names only.", True, 180),
        ("read", "Use the read tool on hello.txt then quote the first line.", True, 180),
        ("bash", "Use bash with command='printf hi' then reply with that output only.", True, 180),
        (
            "mermaid",
            "Reply with one mermaid flowchart fence only: graph LR; A-->B",
            False,
            120,
        ),
        (
            "compact_tool",
            "Call the compact tool now, then say done. Do not explain.",
            True,
            120,
        ),
    ]
    for name, prompt, yolo, timeout in live_prompts:
        cmd = list(ASK_BASE)
        if yolo:
            cmd.append("--yolo")
        cmd.append(prompt)
        rec = run(cmd, cwd=ws, timeout=timeout)
        rec["name"] = name
        rec["jsonl"] = parse_jsonl(rec.get("stdout", ""))
        out["live"].append(rec)

    json.dump(out, sys.stdout, indent=2)
    sys.stdout.write("\n")
    dest = ROOT / "docs" / "research" / ".bench-grok-45-low.json"
    dest.write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
