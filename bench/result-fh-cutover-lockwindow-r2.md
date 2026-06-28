# Banked result: from_hypertable cutover lock window, drained vs undrained (R2, #170/#176)

The #173 cutover-lock-window bench arm run at scale on Supabase **green**, to confirm the online
pre-drain (#170 tracking delta, #176 append-only tail) actually shortens the cutover's
`ACCESS EXCLUSIVE` window. Four arms = {tracking, append-only} x {drained, undrained}, each on its
**own fresh 2XL PG15 + TimescaleDB 2.16.1** project (one arm per instance, run in parallel), us-east-1,
100 GB gp3 / 12 000 IOPS.

## Setup

- Rung R2: **10 M rows**, 6 months, chunk interval 3 days; 16-client OLTP workload runs throughout the
  online copy, so a change backlog (tracking) / append tail (append-only) accumulates during the copy.
- `BENCH_DRAIN_BATCH=5000` (the pre-drain's micro-batch and residual threshold), `BENCH_REFINE=0` (the
  lock window is at cutover, before any refine).
- Lock window timed by the harness's `pg_locks` probe (brackets the source `AccessExclusiveLock`); the
  at-lock residual is the backlog the under-lock pass applies (undrained = the whole backlog; drained =
  bounded by the threshold).

## Result: the pre-drain ~halves the lock window on both paths

| Path | Arm | backlog at entry | at-lock residual | **ACCESS EXCLUSIVE window** | whole cutover call |
|------|-----|------------------|------------------|------------------------------|--------------------|
| tracking (#170)    | undrained | 31 470 | 31 470  | **1.162 s** | 17.8 s |
| tracking (#170)    | drained   | 32 276 | <= 5 000 | **0.611 s** | 25.8 s |
| append-only (#176) | undrained | 7 715  | 7 715   | **0.433 s** | 20.1 s |
| append-only (#176) | drained   | 9 121  | <= 5 000 | **0.223 s** | 20.9 s |

- **Drained's blocking window is ~2x shorter** than undrained on both paths, and the at-lock residual is
  bounded by the threshold instead of the whole backlog. Conservation held on all four arms (the immutable
  cohort survived the online migration unchanged).
- The *whole* cutover call is **longer** when drained (e.g. tracking 25.8 s vs 17.8 s) -- that is the
  mechanism working: the pre-drain does the reconcile/copy work **online, off the lock**, leaving only a
  tiny residual for the brief locked window.

## Reading it

The contrast is real but **modest at R2** because the accumulated backlog is small (~8 k-32 k) relative to
the per-key work, so even the undrained lock window is already sub-1.2 s. The benefit scales with the
backlog, which scales with copy duration: at R3 (40 M, a multi-minute copy) the undrained window grows
while the drained window stays bounded by the threshold, so the gap is expected to be far starker. R2 here
confirms the **mechanism** (drained < undrained, residual bounded, work moved off the lock) end to end on
real Apache TimescaleDB for both the tracking and append-only paths.

## Notes

- Append-only (`p_track_changes => false`) initially crashed the harness: `run_fh.sh` read the backlog
  from `bench.events_pgpm_delta`, which does not exist on the non-tracking path. Fixed to read the
  append tail (`control > max(dest)`) instead; that fix ships with this result.
- Each arm ran on a fresh instance (fresh-instance-per-arm); all four torn down via the API after.
