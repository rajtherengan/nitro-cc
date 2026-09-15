# Confidential computing on AWS Nitro Enclaves, with response-time measurement

Real deployment of the hospital-aggregation workload from the simulation, plus a
harness that measures what the protection actually costs in milliseconds.

Two servers run the **identical** workload code (`common/workload.py`):

| | Where the plaintext lives | Who can read it |
|---|---|---|
| `parent/baseline_server.py` | parent instance RAM | anyone with root on the box |
| `enclave/app.py` | inside the Nitro Enclave | nobody — no shell, no network, no host memory mapping |

The delta between them is the number you're after.

---

## Develop locally first

The whole thing runs on a laptop with vsock swapped for TCP loopback. Same code
paths, so you debug on your machine and deploy unchanged.

```bash
pip install cryptography

DEV_MODE=1 TRANSPORT=tcp python3 enclave/app.py &
DEV_MODE=1 TRANSPORT=tcp python3 parent/gateway.py &
python3 parent/baseline_server.py &

python3 bench/latency.py --compare http://localhost:8080 http://localhost:8081
```

Verified output from the dev path — the *shape* is what matters, not the
absolute values:

```
  DELTA
   records    p50 abs   p50 rel    p99 abs   p99 rel
  --------------------------------------------------
         1    +0.286ms     1.30x    +0.199ms     1.08x
        10    +0.400ms     1.39x    +0.051ms     1.02x
       100    +0.556ms     1.41x    -0.128ms     0.96x
      1000    +0.089ms     1.02x   +21.006ms     3.45x
```

Read it as: a roughly fixed sub-millisecond hop cost that looks catastrophic in
percentage terms on tiny requests and vanishes on large ones. **This is why a
single payload size is useless** — pick 1 record and report 1.30x, pick 1000 and
report 1.02x, and both are technically true.

---

## The AWS runbook

```bash
./scripts/00_setup_host.sh     # nitro-cli, docker, CPU/memory allocator
./scripts/10_build_enclave.sh  # docker build -> EIF, prints PCR0
# paste PCR0 into kms/enclave-key-policy.json, create the KMS key
./scripts/20_run_enclave.sh    # run-enclave + vsock-proxy + gateway
./scripts/30_bench.sh          # steady-state latency, both paths
./scripts/40_measure_boot.sh   # cold start, measured separately
```

**Instance:** `m5.xlarge` or larger, launched with `--enclave-options
Enabled=true`. That flag is set at launch only — get it wrong and you relaunch.
Not t-family; enclaves aren't supported there. You need ≥4 vCPUs because the
allocator permanently hands 2 to the enclave, and a starved parent poisons your
baseline.

**Cost:** Nitro Enclaves itself is free. You pay for the instance —
`m5.xlarge` is about $0.19/hr on-demand, so a full afternoon of benchmarking is
under a dollar. KMS is $1/month per key plus $0.03 per 10k requests.

### Three things that will cost you an hour each

1. **`--debug-mode` zeroes all PCRs.** It's the only way to get
   `nitro-cli console` output, and it makes your KMS policy reject the enclave.
   Debug and attest are mutually exclusive; you'll toggle between them.
2. **Any Dockerfile change moves PCR0**, and KMS starts returning AccessDenied
   with nothing in the message about measurements. Pin base images by digest.
3. **The enclave has no network at all.** vsock is the only channel. If your
   code calls `boto3` directly it hangs until timeout — every AWS call has to go
   through `vsock-proxy` on the parent.

---

## Measuring response time properly

`bench/latency.py` is built around the failure modes, not just the timing loop.

**Report these three numbers separately. Folding them together is the most
common way to publish a wrong result:**

| Phase | Magnitude | Frequency |
|---|---|---|
| Enclave cold start (EIF load + kernel boot) | 4–12 s, scales with image size | once per deployment |
| KMS attested `Decrypt` of the data key | 40–150 ms | once per enclave lifetime — cache it |
| Steady-state request serving | sub-ms to low ms | every request ← **the benchmark** |

**What the harness does and why:**

- **Discards warmup.** First requests pay interpreter startup, page faults, and
  CPU frequency ramp. Include them and you're measuring Python, not vsock.
- **Keep-alive connections, pooled.** A fresh vsock connection per request adds
  handshake cost to every sample that no real deployment would pay.
- **p50/p90/p99, never the mean.** TEE overhead lives in the tail — scheduling
  across the parent/enclave boundary, memory pressure. A mean erases exactly the
  thing you're looking for.
- **Sweeps payload size** from 1 to 10,000 records, for the reason above.
- **Reports server-side `service_us` next to client-observed latency.** The gap
  between them *is* the transport cost, isolated from the compute.
- **Disables Nagle on both servers.** During development every single latency
  pinned to exactly 43.98 ms regardless of payload — headers and body went out
  as two writes, Nagle held the second waiting for an ACK, and the peer's
  delayed-ACK timer held the ACK for 40 ms. If you ever see suspiciously round,
  suspiciously flat latencies, this is it. It is not your enclave.

**Control for everything else:** same instance, same AZ, same run, alternating
order. The real effect is a few hundred microseconds; instance-to-instance
variance is larger than that, so a comparison across two boxes measures noise.

## What to expect on real hardware

Published and community-measured figures, so you know whether your results are
plausible:

- **vsock round trip:** roughly 50–200 µs, comparable to loopback TCP. It's
  shared-memory transport, not a network stack.
- **Steady-state overhead for compute-bound work:** low single-digit percent.
  Nitro Enclaves are full VMs on the same silicon — there's no per-instruction
  encryption tax like SGX's EPC.
- **Small-request, chatty workloads:** the fixed hop dominates and the ratio
  looks much worse. Batch aggressively.
- **Cold start:** 5–10 s for a lean image. This is the real operational cost,
  and it's why enclaves suit long-lived services rather than per-request
  isolation.

If your numbers come out wildly different, suspect methodology before hardware.

## Honest limits of this specific build

- Python's GIL caps the gateway; at high concurrency you may measure the
  gateway, not the enclave. Check `service_us` — if it's flat while client
  latency climbs, you're queueing.
- `handle()` is trivially cheap, which maximizes the *visible* relative
  overhead. A realistic ML inference workload would swamp the transport cost and
  report near-1.00x. That's a feature of the demo, not a flaw — but don't quote
  the ratio without saying what the workload was.
- `DEV_MODE` uses a fixed all-zero key. It exists so you can time things without
  AWS. Obviously never ship it.

---

## Provisioning it in AWS

Run from your machine. Needs `aws` CLI (configured) and `jq`.

```bash
./aws/provision.sh              # KMS key, IAM role, SG locked to your IP, m5.xlarge
# ~2 min for user-data bootstrap
rsync -az -e "ssh -i aws/nitro-cc-key.pem" --exclude aws --exclude '*.pem' \
    ./ ec2-user@<IP>:~/nitro-cc/
ssh -i aws/nitro-cc-key.pem ec2-user@<IP>

# on the instance
tail -f /var/log/cloud-init-output.log      # wait for BOOTSTRAP COMPLETE
cd nitro-cc
./scripts/10_build_enclave.sh               # prints PCR0

# back on your machine
./aws/tighten_key_policy.sh <PCR0>          # now only that image can decrypt

# on the instance
./scripts/05_make_data_key.sh
export DATA_KEY_B64=$(cat kms/plaintext_key.b64)
./scripts/20_run_enclave.sh &
./scripts/30_bench.sh
./scripts/40_measure_boot.sh

# when done, on your machine
./aws/teardown.sh
```

`provision.sh` writes every resource ID to `aws/.stack`; `teardown.sh` reads it
and deletes the lot. The instance is the only thing costing meaningful money.

**Prove the protection is real** before trusting any number. Once the policy is
tightened, from the parent shell:

```bash
aws kms decrypt --ciphertext-blob fileb://<(base64 -d kms/wrapped_key.b64)
```

You hold valid credentials with `kms:Decrypt` and you should still get
**AccessDenied** — your call carries no attestation document. The enclave, with
the same credentials, succeeds. If this command works, your condition didn't
apply and everything downstream is theatre.

**Ordering trap:** the key policy is created permissive, because PCR0 doesn't
exist until you've built the image. Between `provision.sh` and
`tighten_key_policy.sh` the parent can decrypt normally. Don't put anything real
through it in that window.

### What you need before provisioning

Run `./aws/preflight.sh` — it checks all of this and creates nothing.

| Requirement | How to get it |
|---|---|
| AWS account | Needs a card on file. `m5.xlarge` is not free-tier. |
| IAM user (not root) | IAM console → Users → create → **no** console access needed |
| Access key + secret | IAM → your user → Security credentials → Create access key → "CLI" |
| `aws configure` | Enter key, secret, region (`us-east-1`), output `json` |
| Permissions | `AmazonEC2FullAccess`, `IAMFullAccess`, `AWSKeyManagementServicePowerUser` for a throwaway account; scope down for anything real |
| vCPU quota ≥ 4 | Service Quotas → EC2 → "Running On-Demand Standard instances". New accounts are sometimes capped below 4. |
| `jq`, `rsync` | `brew install jq rsync` / `apt install jq rsync` |
| Budget alarm | Billing → Budgets → $5 monthly. Do this first. |

Verify with `aws sts get-caller-identity`.

**SSH:** nothing to prepare. `provision.sh` generates the key pair and writes
`aws/nitro-cc-key.pem` at mode 400. Log in as **`ec2-user`**, not `root` or
`ubuntu`:

```bash
ssh -i aws/nitro-cc-key.pem ec2-user@<IP>
```

Lose that `.pem` and the instance is unreachable — no password fallback. Tear
down and reprovision.

**No credentials go into the enclave, the image, or user-data.** The parent gets
them from the instance role via IMDSv2 at runtime and passes them over vsock.
Anything baked into the Dockerfile becomes part of PCR0 and ships to every
machine that ever runs the image.
