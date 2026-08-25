import json
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = {"n": 0}


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
    print("listening 8765", flush=True)
    HTTPServer(("127.0.0.1", 8765), H).serve_forever()
