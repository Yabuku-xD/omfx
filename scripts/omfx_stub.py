import json
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = {"n": 0}


def _messages(req: dict) -> list:
    return req.get("messages") or []


def _is_count_prompt(req: dict) -> bool:
    blob = json.dumps(req).lower()
    return "count" in blob and "2000" in blob


def _stream_count(wfile, max_n: int = 2000, delay: float = 0.02) -> None:
    for i in range(1, max_n + 1):
        chunk = {
            "choices": [{"delta": {"content": "%d\n" % i}, "index": 0}],
        }
        wfile.write(("data: %s\n\n" % json.dumps(chunk)).encode())
        wfile.flush()
        time.sleep(delay)
    wfile.write(b"data: [DONE]\n\n")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        try:
            req = json.loads(body)
        except Exception:
            req = {}
        stream = bool(req.get("stream"))
        if "flaky-retry" in json.dumps(req):
            # Two overloads, then a reply: proves transient statuses retry
            # instead of ending the turn.
            STATE["flaky"] = STATE.get("flaky", 0) + 1
            if STATE["flaky"] <= 2:
                raw = b'{"error":{"message":"overloaded"}}'
                self.send_response(503)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            chunk = {"choices": [{"delta": {"content": "RETRY_OK after %d" % STATE["flaky"]}, "index": 0}]}
            self.wfile.write(("data: %s\n\n" % json.dumps(chunk)).encode())
            done = {"choices": [{"delta": {}, "finish_reason": "stop", "index": 0}]}
            self.wfile.write(("data: %s\n\ndata: [DONE]\n\n" % json.dumps(done)).encode())
            return
        if "echo-probe" in json.dumps(req):
            # Says whether a file's contents reached the request, so a test can
            # tell an expanded @mention from a verbatim one.
            seen = "MENTION_EXPANDED" if "MARKER_CONTENT" in json.dumps(req) else "MENTION_VERBATIM"
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            c = {"choices": [{"delta": {"content": seen}, "index": 0}]}
            done = {"choices": [{"delta": {}, "finish_reason": "stop", "index": 0}]}
            self.wfile.write(f"data: {json.dumps(c)}\n\ndata: {json.dumps(done)}\n\ndata: [DONE]\n\n".encode())
            return
        if "unicode-probe" in json.dumps(req):
            # json.dumps escapes non-ASCII as \uXXXX (and emoji as a surrogate
            # pair), as many gateways do.
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            c = {"choices": [{"delta": {"content": "café Привет \U0001F600"}, "index": 0}]}
            done = {"choices": [{"delta": {}, "finish_reason": "stop", "index": 0}]}
            self.wfile.write(f"data: {json.dumps(c)}\n\ndata: {json.dumps(done)}\n\ndata: [DONE]\n\n".encode())
            return
        if "esc-reply" in json.dumps(req):
            # The model's own text carries control sequences (a prompt
            # injection can make it echo them); they must not reach the tty.
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for piece in ("hi \u001b]0;PWNED\u0007", "\u001b[2J", " REPLY_DONE"):
                c = {"choices": [{"delta": {"content": piece, "reasoning_content": piece}, "index": 0}]}
                self.wfile.write(f"data: {json.dumps(c)}\n\n".encode())
            done = {"choices": [{"delta": {}, "finish_reason": "stop", "index": 0}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\ndata: [DONE]\n\n".encode())
            return
        if "esc-probe" in json.dumps(req):
            # Turn one runs a command whose output carries terminal control
            # sequences; turn two answers once the tool result is back.
            seen_tool = any(m.get("role") == "tool" or "Tool bash result" in str(m.get("content")) for m in _messages(req))
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            if seen_tool:
                chunks = [{"choices": [{"delta": {"content": "ESC_DONE"}, "index": 0}]},
                          {"choices": [{"delta": {}, "finish_reason": "stop", "index": 0}]}]
            else:
                cmd = "printf 'before\\033]0;PWNED\\007\\033[2Jafter\\n'"
                chunks = [{"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "c1", "type": "function",
                           "function": {"name": "bash", "arguments": json.dumps({"command": cmd})}}]}, "index": 0}]},
                          {"choices": [{"delta": {}, "finish_reason": "tool_calls", "index": 0}]}]
            for c in chunks:
                self.wfile.write(f"data: {json.dumps(c)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            return
        if _is_count_prompt(req):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            _stream_count(self.wfile)
            return
        STATE["n"] += 1
        turn = STATE["n"]
        if turn == 1:
            msg = {
                "role": "assistant",
                "content": "I'll list the root.",
                "tool_calls": [
                    {
                        "id": "call_1",
                        "type": "function",
                        "function": {"name": "list", "arguments": '{"path":"."}'},
                    }
                ],
            }
            fr = "tool_calls"
        elif turn == 2:
            # Intentionally wrong: read a directory (docs exists in x-algorithm)
            msg = {
                "role": "assistant",
                "content": "Let me get oriented and read the docs folder.",
                "tool_calls": [
                    {
                        "id": "call_2",
                        "type": "function",
                        "function": {"name": "read", "arguments": '{"path":"docs"}'},
                    }
                ],
            }
            fr = "tool_calls"
        else:
            msg = {
                "role": "assistant",
                "content": "SUMMARY_OK: root listed; docs is a folder — use list not read.",
            }
            fr = "stop"
        if stream:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            if msg.get("tool_calls"):
                tc = msg["tool_calls"][0]
                chunks = [
                    {
                        "choices": [
                            {
                                "delta": {
                                    "role": "assistant",
                                    "content": msg.get("content") or "",
                                },
                                "index": 0,
                            }
                        ]
                    },
                    {
                        "choices": [
                            {
                                "delta": {
                                    "tool_calls": [
                                        {
                                            "index": 0,
                                            "id": tc["id"],
                                            "type": "function",
                                            "function": {
                                                "name": tc["function"]["name"],
                                                "arguments": "",
                                            },
                                        }
                                    ]
                                },
                                "index": 0,
                            }
                        ]
                    },
                    {
                        "choices": [
                            {
                                "delta": {
                                    "tool_calls": [
                                        {
                                            "index": 0,
                                            "function": {
                                                "arguments": tc["function"]["arguments"]
                                            },
                                        }
                                    ]
                                },
                                "index": 0,
                            }
                        ]
                    },
                    {"choices": [{"delta": {}, "finish_reason": fr, "index": 0}]},
                ]
            else:
                chunks = [
                    {
                        "choices": [
                            {
                                "delta": {
                                    "role": "assistant",
                                    "content": msg["content"],
                                },
                                "index": 0,
                            }
                        ]
                    },
                    {"choices": [{"delta": {}, "finish_reason": "stop", "index": 0}]},
                ]
            for c in chunks:
                self.wfile.write(f"data: {json.dumps(c)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            return
        payload = {
            "id": f"chatcmpl-{turn}",
            "object": "chat.completion",
            "choices": [{"index": 0, "message": msg, "finish_reason": fr}],
        }
        raw = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


if __name__ == "__main__":
    port = int(os.environ.get("OMFX_STUB_PORT", "8765"))
    # Bind before announcing: the harness starts omfx as soon as it reads this
    # line, and on a slow runner a request sent before the bind is refused and
    # spends one of omfx's retries (mock-retry then ran out of them).
    server = HTTPServer(("127.0.0.1", port), H)
    print("listening %d" % port, flush=True)
    server.serve_forever()
