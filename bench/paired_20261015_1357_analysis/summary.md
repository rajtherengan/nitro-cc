# Paired latency analysis

Source: `bench/paired_20261015_1357.csv`  
Pairs per size: 25  
Bootstrap: 20000 resamples of pairs, seed 1

## Run medians (ms)

| Records | Payload | Baseline mean ± SD | Enclave mean ± SD | Δ mean | Δ 95% CI (bootstrap) | Δ 95% CI (t) | Wilcoxon p | Ratio | Ratio 95% CI |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 160 B | 1.225 ± 0.009 | 1.355 ± 0.016 | 0.130 | [0.123, 0.137] | [0.123, 0.138] | 5.96e-08 | 1.106 | [1.101, 1.112] |
| 10 | 760 B | 1.281 ± 0.011 | 1.363 ± 0.010 | 0.082 | [0.076, 0.088] | [0.076, 0.088] | 5.96e-08 | 1.064 | [1.059, 1.069] |
| 100 | 6.8 kB | 1.649 ± 0.012 | 1.517 ± 0.017 | -0.132 | [-0.140, -0.122] | [-0.143, -0.122] | 5.96e-08 | 0.920 | [0.915, 0.926] |
| 1000 | 67 kB | 5.169 ± 0.017 | 5.115 ± 0.019 | -0.054 | [-0.065, -0.043] | [-0.066, -0.042] | 1.19e-07 | 0.990 | [0.987, 0.992] |
| 10000 | 667 kB | 46.68 ± 0.493 | 47.02 ± 0.296 | 0.348 | [0.165, 0.546] | [0.144, 0.552] | 0.000912 | 1.007 | [1.004, 1.012] |

## Where the time goes (means of run medians, ms)

Server-side service time is measured inside the server; the rest is client-observed
median minus service median (loopback HTTP, gateway and, for the enclave, the vsock
crossing). Medians are not additive, so treat the split as approximate.

| Records | Baseline service | Baseline rest | Enclave service | Enclave rest |
|---|---|---|---|---|
| 1 | 0.492 | 0.733 | 0.042 | 1.313 |
| 10 | 0.528 | 0.753 | 0.059 | 1.304 |
| 100 | 0.747 | 0.903 | 0.215 | 1.302 |
| 1000 | 2.470 | 2.699 | 1.034 | 4.081 |
| 10000 | 27.178 | 19.499 | 11.972 | 35.053 |

## Order check (mean p50 by position in the pair, ms)

| Records | Baseline 1st | Baseline 2nd | Enclave 1st | Enclave 2nd |
|---|---|---|---|---|
| 1 | 1.226 (n=8) | 1.225 (n=17) | 1.352 (n=17) | 1.361 (n=8) |
| 10 | 1.286 (n=8) | 1.278 (n=17) | 1.366 (n=17) | 1.357 (n=8) |
| 100 | 1.653 (n=8) | 1.648 (n=17) | 1.518 (n=17) | 1.515 (n=8) |
| 1000 | 5.166 (n=8) | 5.171 (n=17) | 5.116 (n=17) | 5.115 (n=8) |
| 10000 | 46.824 (n=8) | 46.607 (n=17) | 47.040 (n=17) | 46.992 (n=8) |
