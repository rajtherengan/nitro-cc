# Latency reruns for the 3ICT2026 revision (paper 1571355379)

Reviewer 1: "Only five independent runs for latency experiments; statistical
evidence could be stronger." These scripts rerun the steady-state latency
experiment as 25 paired runs with randomised order and produce the updated
latency table and Fig. 1.

## Files

| File | What it does |
|---|---|
| `scripts/35_bench_paired.sh` | Starts the pinned baseline server, records the environment, runs the pairs |
| `bench/paired_runs.py` | One pair = one enclave run + one baseline run, back to back, order randomised (seeded). Same procedure as `latency.py`. Writes a row per run and size, flushed as it goes |
| `bench/analyze_paired.py` | Paired differences, bootstrap and t 95% intervals, Wilcoxon test, ratio intervals, service-time split, order check; writes `table_latency.tex` and `fig1_latency.pdf` |

## On the instance

```bash
# 1. Same build as the paper's latency runs (KMS call stubbed), not debug mode
./scripts/20_run_enclave.sh            # leave running in its own terminal

# 2. In a second terminal
export DATA_KEY_B64=$(cat kms/plaintext_key.b64)
PAIRS=25 ./scripts/35_bench_paired.sh  # ~45-60 min on m5.xlarge

# 3. Analyse (on the instance or your laptop; needs numpy + matplotlib, scipy optional)
python3 bench/analyze_paired.py bench/paired_YYYYMMDD_HHMM.csv
```

Keep the instance otherwise idle while it runs. If a session is interrupted,
the CSV keeps every finished run; rerun with a new output file and concatenate
(renumber `run` in the second file so pairs stay distinct).

Send back: `bench/paired_*.csv`, `bench/paired_*.env.txt` and the
`*_analysis/` folder.

## Sanity check

Running the analysis on the original data
(`python3 bench/analyze_paired.py bench/controlled_20260915_0032.csv`)
reproduces the paper's Table III/IV means and SDs exactly. In those original
runs the enclave was always measured first, so the order check is empty; the
new runs randomise the order.
