#!/usr/bin/env python3
"""
The control group. Same workload, same HTTP layer, same crypto -- but running
as an ordinary process on the parent instance, with the data key sitting in
normal host RAM.

Run this on the SAME instance type in the SAME AZ as the enclave test, or the
comparison means nothing. The number you want is the delta, and the delta is
small enough that instance-to-instance variance will swamp it if you get lazy.
"""

from __future__ import annotations

import base64
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from common.workload import handle  # noqa: E402

PORT = int(os.environ.get("BASELINE_PORT", "8081"))
# The baseline's whole point: this key sits in ordinary host RAM. In production
# it would come from a plain KMS Decrypt with no attestation condition, which is
# exactly why root on the box can read every record.
DATA_KEY = (base64.b64decode(os.environ["DATA_KEY_B64"])
            if os.environ.get("DATA_KEY_B64") else b"\x00" * 32)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    # Without this every latency pins to ~40ms: headers and body go out
    # as two writes, Nagle holds the second waiting for an ACK, and the
    # peer's delayed-ACK timer holds the ACK. Pure artifact, and the
    # single most common way people "discover" enclave overhead.
    disable_nagle_algorithm = True

    def do_POST(self):  # noqa: N802
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        t0 = time.perf_counter()
        try:
            resp = handle(DATA_KEY, json.loads(body))
            code = 200
        except Exception as exc:  # noqa: BLE001
            resp, code = {"ok": False, "error": str(exc)}, 500
        resp["service_us"] = round((time.perf_counter() - t0) * 1e6, 1)
        out = json.dumps(resp).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_GET(self):  # noqa: N802
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"[baseline] listening on :{PORT}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
