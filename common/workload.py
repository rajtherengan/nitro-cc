"""
The actual work, kept identical on both paths so the benchmark is honest.

If the enclave version and the baseline version differ by even a JSON parse,
your measured "enclave overhead" is partly just different code. Both servers
import this module.
"""

from __future__ import annotations

import base64
import json
import os

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


# --------------------------------------------------------------------------- #
# payload crypto (client -> server), symmetric under a KMS-managed data key
# --------------------------------------------------------------------------- #
def seal(data_key: bytes, records: list[dict]) -> dict:
    nonce = os.urandom(12)
    ct = AESGCM(data_key).encrypt(nonce, json.dumps(records).encode(), None)
    return {
        "nonce": base64.b64encode(nonce).decode(),
        "ct": base64.b64encode(ct).decode(),
    }


def unseal(data_key: bytes, envelope: dict) -> list[dict]:
    return json.loads(
        AESGCM(data_key).decrypt(
            base64.b64decode(envelope["nonce"]),
            base64.b64decode(envelope["ct"]),
            None,
        )
    )


# --------------------------------------------------------------------------- #
# the computation
# --------------------------------------------------------------------------- #
RELEASE_FIELDS = ("n", "mean_hba1c", "pct_above_6_5")


def aggregate(records: list[dict]) -> dict:
    values = [r["hba1c"] for r in records]
    n = len(values)
    if n == 0:
        return {"n": 0, "mean_hba1c": None, "pct_above_6_5": None}
    return {
        "n": n,
        "mean_hba1c": round(sum(values) / n, 4),
        "pct_above_6_5": round(100 * sum(v > 6.5 for v in values) / n, 2),
    }


def handle(data_key: bytes, request: dict) -> dict:
    """One request: unseal -> compute -> release only allowlisted fields."""
    if request.get("op") == "ping":
        return {"ok": True, "op": "ping"}
    records = unseal(data_key, request["envelope"])
    result = aggregate(records)
    return {"ok": True, **{k: result[k] for k in RELEASE_FIELDS}}


def synthetic_records(n: int) -> list[dict]:
    return [
        {"patient": f"P-{i:06d}", "hba1c": 4.0 + (i % 55) / 10, "age": 30 + i % 50}
        for i in range(n)
    ]
