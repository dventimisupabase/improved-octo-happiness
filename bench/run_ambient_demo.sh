#!/usr/bin/env bash
# Self-calibrating ambient-signal demo on green (NOT committed -- scratch runner).
#
# Goal: the clean "quiet -> surge -> yield -> recover" arc the FIXED waiter threshold could
# never produce. A light, mostly-cached OLTP workload keeps the learned ambient baseline LOW
# and steady; the drain feathers at its ceiling; then a write-heavy surge mid-window spikes the
# IO/lock waiters far above the learned baseline, the ambient signal fires, and drain_budget
# halves -- then recovers once the surge clears. max_wal_size is raised so the WAL-rate signal
# stays quiet throughout (the surge's blocked writers make little WAL), so the backoff is
# unambiguously the ambient signal.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set -a
# shellcheck disable=SC1090
source ~/.pgpm-bench.env
set +a
: "${BENCH_DB_PASSWORD:?}" "${BENCH_PROJECT_REF:?}" "${BENCH_REGION:?}"

# ---- route through the Supavisor SESSION-mode pooler (off the flaky Tailscale path) ----
pooler_host="${BENCH_POOLER_HOST:-aws-0-${BENCH_REGION}.pooler.supabase.green}"
pw_enc="$(python3 -c 'import urllib.parse,os;print(urllib.parse.quote(os.environ["BENCH_DB_PASSWORD"],safe=""))')"
export BENCH_DSN="postgresql://postgres.${BENCH_PROJECT_REF}:${pw_enc}@${pooler_host}:5432/postgres?sslmode=require"
echo "  connection path: Supavisor session-mode pooler ($pooler_host:5432)"

# ---- data + workload (sized for the ~8GB default disk; no disk-resize API on green) ----
export BENCH_ROWS=2500000 BENCH_MONTHS=2 BENCH_GEN_JOBS=8 BENCH_CHUNK=1000000
export BENCH_CLIENTS=16 BENCH_JOBS=8 BENCH_OPS=10 BENCH_PHASE_SECS=30
export BENCH_PGFR=1 BENCH_PREFREEZE=1

# ---- gentle drain that runs THROUGH the observe window (ceiling 10k, halves visibly to the 625 floor).
#      Deliberately low WAL rate (~a few MB/s) so the WAL-rate signal and forced-checkpoint backstop stay
#      quiet at the stock 4GB max_wal_size -- any backoff during the surge is then unambiguously ambient. ----
export BENCH_DRAIN_BATCH=10000 BENCH_MAINT_INTERVAL='3 seconds' BENCH_OBSERVE_INTERVAL=5
export BENCH_OBSERVE_MODE=window BENCH_CONVERT_WARMUP_SECS=30 \
       BENCH_CONVERT_WINDOW_SECS=300 BENCH_DRAIN_MAX_SECS=900

# ---- mode 2 + the SELF-CALIBRATING ambient signal (relative surge over the learned baseline) ----
export BENCH_DRAIN_ADAPTIVE=1
export BENCH_DRAIN_AMBIENT_FACTOR=2.0 BENCH_DRAIN_AMBIENT_ALPHA=0.2 BENCH_DRAIN_AMBIENT_FLOOR=2

# ---- the surge: write-heavy burst 90s into observe, 60s long (learn baseline -> surge -> recover).
#      surge_sink growth is bounded by an external periodic TRUNCATE loop (see the wrapper), so the
#      surge can saturate writes (piling up IO/lock waiters) without filling the small disk. ----
export BENCH_SURGE_CLIENTS=24 BENCH_SURGE_AFTER_SECS=90 BENCH_SURGE_SECS=60 BENCH_SURGE_ROWS=100

export RESULTS="${RESULTS:-$DIR/results/ambient-demo}"

printf '\n==== ambient self-calibrating demo : %s rows, surge %s clients @ %ss for %ss ====\n' \
  "$BENCH_ROWS" "$BENCH_SURGE_CLIENTS" "$BENCH_SURGE_AFTER_SECS" "$BENCH_SURGE_SECS"

# ---- reset to a clean slate (idempotent) ----
pkill -f 'bench/workload.pgbench' 2>/dev/null || true
pkill -f 'bench/surge.pgbench' 2>/dev/null || true
PSQL=(psql "$BENCH_DSN" -v ON_ERROR_STOP=1 -tAq -c "set statement_timeout=0")
"${PSQL[@]}" -c "select count(pg_terminate_backend(pid)) from pg_stat_activity
  where datname=current_database() and pid<>pg_backend_pid()
    and (query ilike '%bench.%' or query ilike '%pgpm%' or query ilike '%generate_events%'
         or application_name ilike '%pgbench%')" >/dev/null || true
sleep 2
"${PSQL[@]}" -c "select count(cron.unschedule(jobid)) from cron.job
  where jobname like 'pgfr%' or jobname like 'pgpm%' or jobname like '%bench%'" >/dev/null || true
psql "$BENCH_DSN" -tAq -c "set statement_timeout=0" \
  -c "drop extension if exists pgfr_analyze cascade; drop extension if exists pgfr_record cascade;
      drop schema if exists pgfr_analyze cascade; drop schema if exists pgfr_record cascade;
      drop schema if exists bench cascade; drop schema if exists pgpm cascade" >/dev/null 2>&1 || true

mkdir -p "$RESULTS"; rm -f "$RESULTS"/* 2>/dev/null || true
exec "$DIR/run.sh"
