#!/usr/bin/env python3
"""
Runs INSIDE the Nitro Enclave.

Boot sequence, and what each step costs you (measure these separately -- they
are one-time, and folding them into per-request latency is the most common way
people report wrong numbers):

  1. EIF load + kernel boot          ~4-12 s   depends on image size
  2. NSM attestation document        ~5-20 ms  /dev/nsm ioctl
  3. KMS Decrypt with Recipient      ~40-150 ms  one network round trip via
                                     vsock-proxy, gated on PCR0
  4. steady-state request serving    <-- this is what the benchmark measures

The enclave has no network, no persistent storage, and no interactive access.
vsock is the only way in or out. That is the isolation guarantee, and it is
also why every dependency has to be baked into the image.
"""

from __future__ import annotations

import base64
import os
import socket
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from common.protocol import listen_socket, recv_frame, send_frame  # noqa: E402
from common.workload import handle  # noqa: E402

REGION = os.environ.get("AWS_REGION", "us-east-1")
KMS_PROXY_PORT = os.environ.get("KMS_PROXY_PORT", "8000")
DEV_MODE = os.environ.get("DEV_MODE") == "1"

_state: dict = {"data_key": None, "boot_ms": {}}


def log(msg: str) -> None:
    # Only visible via `nitro-cli console`, and only in --debug-mode.
    print(f"[enclave] {msg}", flush=True)


# --------------------------------------------------------------------------- #
# attestation-gated key release
# --------------------------------------------------------------------------- #
def kms_decrypt(ciphertext_b64: str, creds: dict) -> bytes:
    """Unwrap the data key through KMS, gated on this enclave's PCR values.

    kmstool_enclave_cli builds the NSM attestation document, sends it as the
    Recipient parameter, and KMS returns the plaintext encrypted to the public
    key inside that document. The key policy condition
    kms:RecipientAttestation:PCR0 is what makes this refuse for any other image.

    Credentials come from the parent (instance role via IMDSv2) -- the enclave
    cannot reach IMDS itself.
    """
    if DEV_MODE:
        # Laptop path. Deterministic key so you can develop without AWS.
        log("DEV_MODE: skipping KMS, using a fixed test key")
        return b"\x00" * 32

    cmd = [
        "/app/kmstool_enclave_cli", "decrypt",
        "--region", REGION,
        "--proxy-port", KMS_PROXY_PORT,
        "--aws-access-key-id", creds["AccessKeyId"],
        "--aws-secret-access-key", creds["SecretAccessKey"],
        "--aws-session-token", creds["Token"],
        "--ciphertext", ciphertext_b64,
    ]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(f"KMS decrypt failed: {out.stderr.strip()}")
    for line in out.stdout.splitlines():
        if line.startswith("PLAINTEXT: "):
            return base64.b64decode(line.split("PLAINTEXT: ", 1)[1])
    raise RuntimeError(f"unexpected kmstool output: {out.stdout[:200]}")


# --------------------------------------------------------------------------- #
# request loop
# --------------------------------------------------------------------------- #
def serve_connection(conn: socket.socket) -> None:
    """One long-lived connection, many requests. Reconnecting per request adds
    a full vsock handshake to every measurement -- don't."""
    try:
        while True:
            req = recv_frame(conn)
            t0 = time.perf_counter()

            if req.get("op") == "init":
                key = kms_decrypt(req["wrapped_key"], req.get("creds", {}))
                _state["data_key"] = key
                _state["boot_ms"]["kms_unwrap"] = (time.perf_counter() - t0) * 1000
                send_frame(conn, {
                    "ok": True,
                    "kms_unwrap_ms": round(_state["boot_ms"]["kms_unwrap"], 2),
                })
                log(f"data key unwrapped in "
                    f"{_state['boot_ms']['kms_unwrap']:.1f} ms")
                continue

            if _state["data_key"] is None:
                send_frame(conn, {"ok": False, "error": "not initialized"})
                continue

            resp = handle(_state["data_key"], req)
            # Server-side service time, excluding transport. Subtract this from
            # the client-observed number to isolate vsock cost.
            resp["service_us"] = round((time.perf_counter() - t0) * 1e6, 1)
            send_frame(conn, resp)
    except (ConnectionError, OSError):
        pass
    finally:
        conn.close()


def main() -> None:
    log(f"starting, pid={os.getpid()}")
    srv = listen_socket()
    log("listening on vsock" if not DEV_MODE else "listening on tcp (dev)")
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=serve_connection, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
