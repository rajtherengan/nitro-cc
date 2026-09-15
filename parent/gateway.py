#!/usr/bin/env python3
"""
Runs on the PARENT EC2 instance. Untrusted -- it never sees plaintext records.

Its jobs:
  * terminate HTTP from the outside world
  * hold a pool of vsock connections to the enclave
  * fetch instance-role credentials from IMDSv2 and pass them in at init so the
    enclave can call KMS (the enclave has no route to IMDS)

Connection pooling is not an optimization detail here -- it is the difference
between measuring your service and measuring vsock connection setup. Open one
socket per request and you will add a few hundred microseconds to every p50
that no production deployment would ever pay.
"""

from __future__ import annotations

import json
import os
import queue
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from common.protocol import connect_socket, recv_frame, send_frame  # noqa: E402

LISTEN_PORT = int(os.environ.get("GATEWAY_PORT", "8080"))
POOL_SIZE = int(os.environ.get("POOL_SIZE", "16"))
WRAPPED_KEY = os.environ.get("WRAPPED_DATA_KEY", "")
DEV_MODE = os.environ.get("DEV_MODE") == "1"


class EnclavePool:
    """Fixed pool of long-lived vsock connections, each initialized once."""

    def __init__(self, size: int):
        self._free: queue.Queue = queue.Queue()
        self.init_ms = None
        for _ in range(size):
            self._free.put(self._new_conn())

    def _new_conn(self):
        sock = connect_socket()
        t0 = time.perf_counter()
        send_frame(sock, {
            "op": "init",
            "wrapped_key": WRAPPED_KEY,
            "creds": {} if DEV_MODE else instance_credentials(),
        })
        resp = recv_frame(sock)
        if not resp.get("ok"):
            raise RuntimeError(f"enclave init failed: {resp}")
        if self.init_ms is None:
            self.init_ms = (time.perf_counter() - t0) * 1000
        return sock

    def call(self, payload: dict) -> dict:
        sock = self._free.get()
        try:
            send_frame(sock, payload)
            return recv_frame(sock)
        except (ConnectionError, OSError):
            sock = self._new_conn()   # enclave restarted; heal the pool
            raise
        finally:
            self._free.put(sock)


def instance_credentials() -> dict:
    """IMDSv2. Short-lived role credentials, refreshed by re-initializing."""
    req = urllib.request.Request(
        "http://169.254.169.254/latest/api/token", method="PUT",
        headers={"X-aws-ec2-metadata-token-ttl-seconds": "300"})
    token = urllib.request.urlopen(req, timeout=2).read().decode()
    base = "http://169.254.169.254/latest/meta-data/iam/security-credentials/"
    hdr = {"X-aws-ec2-metadata-token": token}
    role = urllib.request.urlopen(
        urllib.request.Request(base, headers=hdr), timeout=2).read().decode()
    return json.loads(urllib.request.urlopen(
        urllib.request.Request(base + role, headers=hdr), timeout=2).read())


POOL: EnclavePool | None = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    # Without this every latency pins to ~40ms: headers and body go out
    # as two writes, Nagle holds the second waiting for an ACK, and the
    # peer's delayed-ACK timer holds the ACK. Pure artifact, and the
    # single most common way people "discover" enclave overhead.
    disable_nagle_algorithm = True   # keep-alive; otherwise you time TCP setup

    def do_POST(self):  # noqa: N802
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        t0 = time.perf_counter()
        try:
            resp = POOL.call(json.loads(body))
            resp["gateway_us"] = round((time.perf_counter() - t0) * 1e6, 1)
            code = 200
        except Exception as exc:  # noqa: BLE001
            resp, code = {"ok": False, "error": str(exc)}, 502
        out = json.dumps(resp).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_GET(self):  # noqa: N802
        out = json.dumps({"ok": True, "pool_init_ms": POOL.init_ms}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *args):  # silence per-request logging: it costs ms
        pass


if __name__ == "__main__":
    POOL = EnclavePool(POOL_SIZE)
    print(f"[gateway] pool ready, first-connection init {POOL.init_ms:.1f} ms")
    print(f"[gateway] listening on :{LISTEN_PORT}")
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
