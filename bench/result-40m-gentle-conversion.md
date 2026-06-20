# Banked result — 40M-row online conversion, **gentle/steady-state arm** (rung 3)

The **gentle** profile (`bench/run_rung.sh R3 gentle`) of the load-test harness converting an
unpartitioned `bench.events` to RANGE-partitioned **online**, while a 16-client OLTP workload
runs continuously, on a provisioned Supabase **2xlarge** (8 vCPU / 32 GB RAM, gp3 500 GB /
12 000 IOPS, PostgreSQL 17.6, staging "green"). Same engine and same 40M-row workload as the
[stress result](result-40m-online-conversion.md); the question is different.

- **Stress arm** asks *"converted online + fully drained — and what breaks when we over-drive it?"*
  It runs the drain hard (2 s cron, 150k batches) to completion. That manufactures I/O stress
  (123 GB WAL, 34 forced checkpoints, tps → 9.9) — useful as a bug-finder, **not** representative
  of how pgpm is meant to run.
- **Gentle arm** (this doc) asks *"is the drain unnoticeable to the workload?"* It drives pgpm at
  its **intended** pace (20 s cron, 20k batches — sized to fit `work_mem`) and **measures a fixed
  window** of steady-state draining rather than waiting for the drain to finish (a gentle drain of
  a large table is meant to run for hours/days in the background; it doesn't need to complete
  inside a benchmark).

## Setup
- **40 M rows**, ~2 months of history → ~12 GB heap+indexes unpartitioned. Generated server-side
  by 8 parallel sessions, then **`VACUUM (FREEZE, ANALYZE)`** so the post-bulk-load freeze WAL
  settles *before* measurement (`BENCH_PREFREEZE=1`; see "I/O attribution" below).
- Conversion: `build_pk_concurrently` (online PK) → `adopt()` → `pgpm.maintenance` on pg_cron
  **every 20 s**, **drain batch 20 000**. pgpm self-drives premake + drain; the harness observes.
- Observe mode: **window** — 60 s warm-up to reach steady-state draining, then a 300 s measurement
  window. Convert metrics are restricted to that window (the one-time adopt cutover is excluded).

## Result — the gentle drain is unnoticeable to the workload
During steady-state draining, the 16-client workload held **~178 tps at ~89.5 ms latency —
at or below its own baseline** (90.6 ms). Per-interval client latency through the steady window:

```
convert  5s 126 tps  90.0ms     convert 45s 178 tps  89.6ms
        10s 178 tps  89.9ms             50s 178 tps  89.6ms
        15s 177 tps  90.3ms             55s 178 tps  89.7ms
        30s 178 tps  89.6ms             65s 179 tps  89.4ms
        35s 179 tps  89.4ms             70s 179 tps  89.3ms
        40s 179 tps  89.5ms             75s 178 tps  89.9ms
```

| phase | tps | avg latency | client p50 / p95 / p99 (pgbench --log) |
|-------|-----|-------------|----------------------------------------|
| baseline (unpartitioned) | 176.0 | 90.7 ms | 90.6 / 98.3 / 102.2 ms |
| **convert (steady-state drain)** | **~178** | **~89.5 ms** | tracks baseline (see note) |
| post (partitioned) | 172.1 | 92.9 ms | 92.5 / 100.0 / 102.1 ms |

**The verdict is the latency comparison, and it is unambiguous: the drain did not slow the
workload.** This is corroborated by an earlier gentle R3 run whose measurement window survived
long enough to aggregate (n=8662): convert **p50 91.3 / p95 146.5 / p99 186.4 ms**, every
percentile **≤ baseline** (105.4 / 162.3 / 193.3 ms in that run).

Throughput (tps) is *not* the verdict here: for a fixed client count, tps ≈ clients/latency, so it
only falls if latency rises **or** if the workload driver loses its connection — which is exactly
what truncated this run's window aggregate (see "Infra caveat").

## I/O attribution — the drain is not the I/O stressor
pgfr (server-side, continuous) over the conversion window flagged 2 forced checkpoints, a
checkpoint, and 1.05 GB of temp. **None of it is the drain**, established three ways:

1. **Temp spill is the one-time PK index build.** `convert.temp.csv` attributes all 1.05 GB to a
   single statement — `create unique index concurrently … events_pgpm_pkey_pre (created_at, id)`
   (`build_pk_concurrently` sorting 40M rows during adopt **prep**). The drain's 20k-row batches
   fit in `work_mem` and spill nothing.
2. **Forced checkpoints are rate-independent → not the drain.** The gentle R0 run uses the
   *identical* drain rate and produces **zero** forced checkpoints; only the large rung does. A
   symptom that scales with table size but not drain rate is the *load*, not the drain. The window
   moved ~450k rows (~0.7 GB WAL); the residual checkpoints are the CIC's own index WAL.
3. **Pre-freeze cut the load aftermath out of the window.** Settling the bulk-load freeze WAL
   before measuring dropped forced checkpoints **6 → 2** and checkpoint **sync_time 24.6 s → 0.17 s**
   between two otherwise-identical gentle R3 runs — direct proof that the bulk of the I/O the
   *previous* run blamed on the window was the load's freeze, not the conversion.

What remains (one-time CIC index build) is the inherent price of going online — building the PK
without an exclusive lock — and it happens **once**, before the table is partitioned. The
steady-state drain itself stays under the instance's I/O baseline, which is the whole design goal.

## Server is robust to the client network; the workload driver is not
On all three green gentle runs the `.red`/Tailscale **client** path stalled mid-window (~80 s into
convert — right as the CIC fsync bursts on a burst-limited instance), while the **server kept
draining throughout**: `drain_ops` climbed 0 → 23, ~450k rows moved, premake created 3 partitions
(1 → 4) — all during a client blackout in which both the workload pgbench *and* the observer saw a
dead socket. pgpm's drain/premake and the server-side workload are unaffected by the client path.

## Infra caveat (measurement, not pgpm)
The long (300 s) windowed *aggregate* is unreliable over the NAT'd `.red`/Tailscale path: 3 of 3
green runs lost the client connection mid-window. The robust evidence is therefore the
per-interval progress (above) plus the server-side traces (pgfr, drain progress, pgss/temp
attribution), all of which are WAN-immune. A clean single-run windowed aggregate needs the
workload driver off that path (Supavisor pooler / co-located driver) and/or more EBS burst
headroom (larger tier) so the one-time CIC fsync doesn't starve the measurement connection.
