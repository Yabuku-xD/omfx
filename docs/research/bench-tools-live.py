#!/usr/bin/env python3
"""Live grok-4.5 --effort low tool sweep. Two groups from the bench gap list."""

from __future__ import annotations

import json
import shutil
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OMFX = ROOT / "zig-out" / "bin" / "omfx"
WS = Path("/tmp/omfx-bench-tools")
ASK = [
    str(OMFX),
    "ask",
    "--provider",
    "xai-oauth",
    "--model",
    "grok-4.5",
    "--effort",
    "low",
    "--json",
    "--yolo",
]


def parse_jsonl(text: str) -> dict:
    kinds: dict[str, int] = {}
    tools: list[str] = []
    result = ""
    diagram = ""
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
        body = obj.get("text", "")
        if kind == "tool":
            tools.append(body[:160])
        elif kind == "result":
            result = body
        elif kind == "diagram":
            diagram = body
    return {"kinds": kinds, "tools": tools, "result": result[:1200], "diagram": diagram[:400]}


def run_ask(name: str, prompt: str, timeout: float = 180.0) -> dict:
    t0 = time.perf_counter()
    proc = subprocess.Popen(
        ASK + [prompt],
        cwd=str(WS),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    chunks: list[str] = []
    first = None
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
                if first is None:
                    first = time.perf_counter() - t0
                chunks.append(line)
                continue
            if proc.poll() is not None:
                rest = proc.stdout.read()
                if rest:
                    if first is None:
                        first = time.perf_counter() - t0
                    chunks.append(rest)
                break
            time.sleep(0.01)
        stderr = proc.stderr.read() if proc.stderr else ""
        if proc.poll() is None:
            proc.wait(timeout=2)
    except Exception as err:
        proc.kill()
        stderr = str(err)
    wall = time.perf_counter() - t0
    text = "".join(chunks)
    rec = {
        "name": name,
        "ok": (proc.returncode == 0) and not timed_out,
        "code": proc.returncode,
        "wall_s": round(wall, 4),
        "ttfb_s": None if first is None else round(first, 4),
        "timeout": timed_out,
        "stdout_bytes": len(text),
        "stderr_head": (stderr or "")[:400],
        "jsonl": parse_jsonl(text),
        "files": sorted(p.name for p in WS.iterdir() if p.is_file()),
    }
    recall = WS / ".omfx" / "recall"
    rec["recall"] = sorted(p.name for p in recall.glob("*.txt")) if recall.exists() else []
    diagrams = WS / ".omfx" / "diagrams"
    rec["diagrams"] = sorted(p.name for p in diagrams.iterdir()) if diagrams.exists() else []
    board = WS / ".omfx" / "board.md"
    rec["board_exists"] = board.exists()
    return rec


def main() -> int:
    if WS.exists():
        shutil.rmtree(WS)
    WS.mkdir(parents=True)
    (WS / "note.md").write_text("# note\nalpha beta\nhello omfx\n", encoding="utf-8")
    (WS / "hello.txt").write_text("hello omfx bench\n", encoding="utf-8")
    fat = ("x" * 200 + "\n") * 80
    (WS / "fat.txt").write_text(fat, encoding="utf-8")

    group_files = """Call tools. Do not skip tools. Do not only describe them.
1. write path=created.txt contents=created-by-omfx
2. read note.md then edit path=note.md old_string=alpha new_string=gamma
3. grep pattern=hello
4. glob pattern=*.txt
5. bash command='curl -sI https://example.com'
6. patch note.md to insert a line 'patched' after the title using the patch tool
When done, reply with one mermaid fence only:
```mermaid
graph LR
A-->B
```
"""

    group_harness = """Call tools. Do not skip tools.
1. memory action=list
2. board action=post line='FACT path=note.md board works'
3. mcp action=list
4. browser action=list
5. web_fetch url=https://example.com
6. web_search query=zig 0.16 release
7. compact
Then reply with one line: harness-done
"""

    out = {
        "model": "grok-4.5",
        "effort": "low",
        "groups": [
            run_ask("files", group_files, 240),
            run_ask("harness", group_harness, 240),
            run_ask(
                "recall",
                "Call read path=fat.txt. Then say cite-or-body and the first 20 chars you kept.",
                180,
            ),
            run_ask(
                "peer",
                "Call peer with goal='post FACT path=hello.txt peer-pong on the board, then stop'. Do not nest another peer.",
                240,
            ),
        ],
    }
    dest = ROOT / "docs" / "research" / ".bench-tools-live.json"
    dest.write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
