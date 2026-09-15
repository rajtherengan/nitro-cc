"""
Shared between the parent instance and the enclave.

Transport is length-prefixed JSON. Framing matters for the latency numbers: if
you use newline-delimited JSON you end up doing a read per byte on the slow
path, and you will measure your parser instead of the enclave.

One switch controls everything: TRANSPORT=vsock on AWS, TRANSPORT=tcp on your
laptop. Identical code either way, so you debug locally and deploy unchanged.
"""

from __future__ import annotations

import json
import os
import socket
import struct

TRANSPORT = os.environ.get("TRANSPORT", "vsock")
PORT = int(os.environ.get("ENCLAVE_PORT", "5005"))
ENCLAVE_CID = int(os.environ.get("ENCLAVE_CID", "16"))

_HDR = struct.Struct("!I")
MAX_FRAME = 32 * 1024 * 1024


# --------------------------------------------------------------------------- #
# framing
# --------------------------------------------------------------------------- #
def send_frame(sock: socket.socket, obj: dict) -> None:
    body = json.dumps(obj).encode()
    sock.sendall(_HDR.pack(len(body)) + body)


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray(n)
    view = memoryview(buf)
    got = 0
    while got < n:
        k = sock.recv_into(view[got:], n - got)
        if k == 0:
            raise ConnectionError("peer closed mid-frame")
        got += k
    return bytes(buf)


def recv_frame(sock: socket.socket) -> dict:
    (length,) = _HDR.unpack(_recv_exact(sock, _HDR.size))
    if length > MAX_FRAME:
        raise ValueError(f"frame too large: {length}")
    return json.loads(_recv_exact(sock, length))


# --------------------------------------------------------------------------- #
# sockets
# --------------------------------------------------------------------------- #
def listen_socket() -> socket.socket:
    """Enclave side."""
    if TRANSPORT == "vsock":
        s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        s.bind((socket.VMADDR_CID_ANY, PORT))
    else:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", PORT))
    s.listen(128)
    return s


def connect_socket(timeout: float = 10.0) -> socket.socket:
    """Parent side. Parent CID is always 3; the enclave CID you pick at launch."""
    if TRANSPORT == "vsock":
        s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((ENCLAVE_CID, PORT))
    else:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(("127.0.0.1", PORT))
        # Without this, Nagle batches small frames and your p50 picks up ~40ms
        # of pure artifact. vsock has no equivalent knob and no equivalent bug.
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s
