#!/usr/bin/env bash
# At-scale load test for pg_partition_magician.
#
# Builds a multi-table DB with one giant time-series table (bench.events),
# generates the bulk DATA SERVER-SIDE (nothing crosses the wire), then drives a
# steady index-supported OLTP workload while pg_partition_magician converts the
# giant table to partitioned ONLINE. Captures latency/throughput/health before,
# during, and after the conversion so the impact is measurable.
#
# Everything is parameterised by env vars (see bench/README.md). The connection
# string is read from PGHOST/PGUSER/... or a single BENCH_DSN; it is NEVER echoed.
set -euo pipefail

# ---- config (override via env) ---------------------------------------------
PSQL="${PSQL:-psql}"
PGBENCH="${PGBENCH:-pgbench}"
BENCH_DSN="${BENCH_DSN:-}"                  # libpq conninfo/URI; if empty, use PG* env
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BENCH_DIR="$REPO_ROOT/bench"
RESULTS="${RESULTS:-$BENCH_DIR/results}"

BENCH_ROWS="${BENCH_ROWS:-300000000}"       # target rows in bench.events (~120GB at ~400B/row)
BENCH_MONTHS="${BENCH_MONTHS:-12}"          # spread history across this many months
BENCH_CHUNK="${BENCH_CHUNK:-2000000}"       # generator commit chunk
BENCH_GEN_JOBS="${BENCH_GEN_JOBS:-1}"       # parallel generator sessions (one INSERT..SELECT is single-core; fan out to use all cores)
BENCH_INTERVAL="${BENCH_INTERVAL:-1 month}" # partition width
BENCH_PREMAKE="${BENCH_PREMAKE:-3}"

BENCH_CLIENTS="${BENCH_CLIENTS:-16}"        # pgbench concurrent clients
BENCH_JOBS="${BENCH_JOBS:-4}"               # pgbench worker threads
BENCH_OPS="${BENCH_OPS:-50}"                # server-side ops per workload_step call
BENCH_PHASE_SECS="${BENCH_PHASE_SECS:-120}" # per-phase load duration (baseline/post)
BENCH_ADOPT_WARM="${BENCH_ADOPT_WARM:-15}"  # load lead-in before firing adopt

BENCH_DRAIN_BATCH="${BENCH_DRAIN_BATCH:-20000}"  # rows per drain_step
BENCH_DRAIN_SLEEP="${BENCH_DRAIN_SLEEP:-0}"      # pause between drain steps (s); 0 = full speed
BENCH_DRAIN_MAX_SECS="${BENCH_DRAIN_MAX_SECS:-3600}"  # safety cap on the drain window

BENCH_PGFR="${BENCH_PGFR:-0}"               # 1 = wire in pg_flight_recorder
BENCH_PGFR_SQL="${BENCH_PGFR_SQL:-}"        # path to pg_flight_recorder install SQL (if BENCH_PGFR=1)
BENCH_SKIP_GENERATE="${BENCH_SKIP_GENERATE:-0}"  # 1 = data already loaded, skip 00/10

mkdir -p "$RESULTS"

# Always reap background load drivers, even on error/interrupt -- an orphaned
# pgbench keeps holding locks and corrupts the next run.
BG_PIDS=()
cleanup() { local p; for p in "${BG_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT INT TERM

# ---- psql helpers (DSN passed positionally, never logged) ------------------
conn_args() { if [ -n "$BENCH_DSN" ]; then printf '%s' "$BENCH_DSN"; fi; }
q()  { if [ -n "$BENCH_DSN" ]; then "$PSQL" "$BENCH_DSN" -v ON_ERROR_STOP=1 -tAqc "$1"; else "$PSQL" -v ON_ERROR_STOP=1 -tAqc "$1"; fi; }
qf() { if [ -n "$BENCH_DSN" ]; then "$PSQL" "$BENCH_DSN" -v ON_ERROR_STOP=1 -f "$1"; else "$PSQL" -v ON_ERROR_STOP=1 -f "$1"; fi; }
say() { printf '\n\033[1;36m== %s ==\033[0m %s\n' "$1" "$(q "select to_char(now(),'HH24:MI:SS')")"; }

have_ext() { [ "$(q "select count(*) from pg_extension where extname='$1'")" = "1" ]; }
have_pgss=0

pgss_reset() { [ "$have_pgss" = "1" ] && q "select pg_stat_statements_reset()" >/dev/null || true; }
# snapshot the workload statements (server-side, WAN-free timing) for a phase
pgss_snapshot() {
  [ "$have_pgss" = "1" ] || return 0
  local label="$1"
  q "copy (
       select '$label' as phase, calls,
              round(total_exec_time::numeric,1) as total_ms,
              round(mean_exec_time::numeric,4)  as mean_ms,
              round(stddev_exec_time::numeric,4) as stddev_ms,
              rows, left(regexp_replace(query,'\s+',' ','g'),80) as query
       from pg_stat_statements
       where query ilike '%bench.%' and query not ilike '%pg_stat_statements%'
       order by total_exec_time desc limit 15
     ) to stdout with (format csv, header true)" > "$RESULTS/$label.pgss.csv"
}

# total size of bench.events INCLUDING all partitions (a partitioned parent has no
# heap of its own, so pg_total_relation_size(parent) alone reads 0 post-conversion)
EVENTS_SIZE_SUB="(select pg_size_pretty(coalesce((select sum(pg_total_relation_size(c.oid)) from pg_class c
        where c.oid='bench.events'::regclass
           or c.oid in (select inhrelid from pg_inherits where inhparent='bench.events'::regclass)),0)))"

# health gauge: default size, dead tuples, live partition count, lag-ish counters
health_snapshot() {
  local label="$1"
  q "copy (
       select '$label' as phase,
              $EVENTS_SIZE_SUB as events_total_size,
              (select count(*) from pg_inherits where inhparent='bench.events'::regclass) as partitions,
              (select n_dead_tup from pg_stat_user_tables where relid='bench.events'::regclass) as parent_dead_tup,
              (select coalesce(sum(n_dead_tup),0) from pg_stat_user_tables
                 where schemaname='bench') as bench_dead_tup,
              (select count(*) from pg_stat_activity where state='active' and datname=current_database()) as active_backends
     ) to stdout with (format csv, header true)" > "$RESULTS/$label.health.csv"
}

# percentiles (µs -> ms) from pgbench --log files for a label
pctiles() {
  local label="$1" files
  # pgbench --log-prefix=X writes "X.<pid>" and "X.<pid>.<thread>" (no .log suffix)
  files=$(ls "$RESULTS/pgb_$label".* 2>/dev/null || true)
  [ -n "$files" ] || { echo "n/a"; return 0; }
  # shellcheck disable=SC2086
  awk '{print $3}' $files | sort -n | awk '
    function pct(p,   i){ i=int(p*n); if(i>=n)i=n-1; return a[i]/1000.0 }
    { a[n++]=$1 }
    END {
      if (n==0) { print "n/a"; exit }
      printf "n=%d p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms", n, pct(0.50), pct(0.95), pct(0.99), a[n-1]/1000.0
    }'
}

# run a fixed-duration load phase; capture pgbench summary + percentiles + pgss + health
run_phase() {
  local label="$1" secs="$2"
  say "load phase: $label (${secs}s, ${BENCH_CLIENTS} clients)"
  pgss_reset
  local args=( -n -c "$BENCH_CLIENTS" -j "$BENCH_JOBS" -T "$secs" -P 5
               -D "ops=$BENCH_OPS" -f "$BENCH_DIR/workload.pgbench"
               --log "--log-prefix=$RESULTS/pgb_$label" )
  rm -f "$RESULTS/pgb_$label".*
  if [ -n "$BENCH_DSN" ]; then "$PGBENCH" "$BENCH_DSN" "${args[@]}"; else "$PGBENCH" "${args[@]}"; fi \
    | tee "$RESULTS/$label.pgbench.txt"
  pgss_snapshot "$label"
  health_snapshot "$label"
  printf '%s\n' "$(pctiles "$label")" > "$RESULTS/$label.pctiles.txt"
  echo "  latency: $(cat "$RESULTS/$label.pctiles.txt")"
}

# ---- 0. preflight ----------------------------------------------------------
say "preflight"
q "select version()" | sed 's/^/  /'
if ! have_ext pg_cron; then
  echo "  NOTE: pg_cron not installed; pgpm install needs it. Attempting create extension..."
  q "create extension if not exists pg_cron" || { echo "  ERROR: pg_cron required"; exit 1; }
fi
# pg_stat_statements is only usable if it's in shared_preload_libraries; CREATE
# EXTENSION can succeed yet the functions still error, so verify with a reset.
if q "create extension if not exists pg_stat_statements" >/dev/null 2>&1 \
   && q "select pg_stat_statements_reset()" >/dev/null 2>&1; then
  have_pgss=1; echo "  pg_stat_statements: on (server-side latency capture enabled)"
else
  echo "  pg_stat_statements: unavailable (not preloaded; relying on pgbench --log timing)"
fi

# ---- 1. install pgpm (+ optional pg_flight_recorder) -----------------------
say "install pg_partition_magician"
qf "$REPO_ROOT/sql/pg_partition_magician.sql" >/dev/null
echo "  pgpm installed: $(q "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='pgpm'") functions"
if [ "$BENCH_PGFR" = "1" ]; then
  if [ -n "$BENCH_PGFR_SQL" ] && [ -f "$BENCH_PGFR_SQL" ]; then
    say "install pg_flight_recorder"
    qf "$BENCH_PGFR_SQL" >/dev/null && echo "  pg_flight_recorder installed"
  else
    echo "  WARNING: BENCH_PGFR=1 but BENCH_PGFR_SQL not set/found; skipping pgfr"
  fi
fi

# ---- 2. schema + data (server-side generation) -----------------------------
if [ "$BENCH_SKIP_GENERATE" = "1" ]; then
  say "skip generate (BENCH_SKIP_GENERATE=1)"
else
  say "build schema + generate data SERVER-SIDE"
  qf "$BENCH_DIR/sql/00_schema.sql" >/dev/null
  qf "$BENCH_DIR/sql/10_generate.sql" >/dev/null
  if [ "$BENCH_GEN_JOBS" -le 1 ]; then
    echo "  generating $BENCH_ROWS rows across $BENCH_MONTHS months (1 session, in-database, nothing on the wire)..."
    q "call bench.generate_events($BENCH_ROWS, $BENCH_MONTHS, $BENCH_CHUNK)"
  else
    # one INSERT..SELECT is single-core-bound; split the target across N sessions
    # that all append to bench.events concurrently (the identity sequence keeps ids
    # unique). They each spread rows over the same month span, so the distribution
    # is unchanged.
    echo "  generating $BENCH_ROWS rows across $BENCH_MONTHS months via $BENCH_GEN_JOBS parallel sessions..."
    gen_base=$(( BENCH_ROWS / BENCH_GEN_JOBS ))
    gen_rem=$(( BENCH_ROWS - gen_base * BENCH_GEN_JOBS ))
    gen_pids=()
    for j in $(seq 1 "$BENCH_GEN_JOBS"); do
      rows_j=$gen_base
      [ "$j" -eq 1 ] && rows_j=$(( gen_base + gen_rem ))   # job 1 absorbs the remainder
      ( q "call bench.generate_events($rows_j, $BENCH_MONTHS, $BENCH_CHUNK)" \
          > "$RESULTS/generate_job_$j.log" 2>&1 ) &
      pid=$!; gen_pids+=("$pid"); BG_PIDS+=("$pid")
      echo "    job $j: $rows_j rows (pid $pid)"
    done
    gen_fail=0
    for pid in "${gen_pids[@]}"; do wait "$pid" || gen_fail=1; done
    [ "$gen_fail" = "0" ] || { echo "  ERROR: a generator session failed; see $RESULTS/generate_job_*.log"; exit 1; }
    q "analyze bench.events" >/dev/null   # one fresh analyze after all sessions finish
  fi
fi
qf "$BENCH_DIR/sql/20_workload.sql" >/dev/null
echo "  events: $(q "select count(*) from bench.events") rows, $(q "select pg_size_pretty(pg_total_relation_size('bench.events'))")"

# ---- 3. baseline (unpartitioned, under load) -------------------------------
run_phase baseline "$BENCH_PHASE_SECS"

# ---- 4. adopt under load ---------------------------------------------------
say "adopt under load"
pgss_reset
rm -f "$RESULTS/pgb_adopt".*   # drop any prior-run logs so pctiles is fresh
adopt_bg_secs=$(( BENCH_ADOPT_WARM + 30 ))
( if [ -n "$BENCH_DSN" ]; then \
    "$PGBENCH" "$BENCH_DSN" -n -c "$BENCH_CLIENTS" -j "$BENCH_JOBS" -T "$adopt_bg_secs" -P 5 \
      -D "ops=$BENCH_OPS" -f "$BENCH_DIR/workload.pgbench" \
      --log "--log-prefix=$RESULTS/pgb_adopt"; \
  else \
    "$PGBENCH" -n -c "$BENCH_CLIENTS" -j "$BENCH_JOBS" -T "$adopt_bg_secs" -P 5 \
      -D "ops=$BENCH_OPS" -f "$BENCH_DIR/workload.pgbench" \
      --log "--log-prefix=$RESULTS/pgb_adopt"; \
  fi > "$RESULTS/adopt.pgbench.txt" 2>&1 ) &
load_pid=$!; BG_PIDS+=("$load_pid")
sleep "$BENCH_ADOPT_WARM"
echo "  firing pgpm.adopt('bench.events','created_at','$BENCH_INTERVAL') under live load..."
adopt_start=$(q "select extract(epoch from clock_timestamp())")
q "select pgpm.adopt('bench.events','created_at', interval '$BENCH_INTERVAL', $BENCH_PREMAKE)" >/dev/null
adopt_end=$(q "select extract(epoch from clock_timestamp())")
awk -v a="$adopt_start" -v b="$adopt_end" 'BEGIN{printf "  adopt() returned in %.3fs (metadata-only; table is now partitioned)\n", b-a}'
wait "$load_pid" || true
pgss_snapshot adopt
health_snapshot adopt
printf '%s\n' "$(pctiles adopt)" > "$RESULTS/adopt.pctiles.txt"
echo "  default holds: $(q "select default_rows from pgpm.check_default('bench.events')") rows to drain"

# ---- 5. drain under load ---------------------------------------------------
say "drain under load"
pgss_reset
rm -f "$RESULTS/pgb_drain".*   # drop any prior-run logs so pctiles is fresh
( if [ -n "$BENCH_DSN" ]; then \
    "$PGBENCH" "$BENCH_DSN" -n -c "$BENCH_CLIENTS" -j "$BENCH_JOBS" -T "$BENCH_DRAIN_MAX_SECS" -P 5 \
      -D "ops=$BENCH_OPS" -f "$BENCH_DIR/workload.pgbench" \
      --log "--log-prefix=$RESULTS/pgb_drain"; \
  else \
    "$PGBENCH" -n -c "$BENCH_CLIENTS" -j "$BENCH_JOBS" -T "$BENCH_DRAIN_MAX_SECS" -P 5 \
      -D "ops=$BENCH_OPS" -f "$BENCH_DIR/workload.pgbench" \
      --log "--log-prefix=$RESULTS/pgb_drain"; \
  fi > "$RESULTS/drain.pgbench.txt" 2>&1 ) &
load_pid=$!; BG_PIDS+=("$load_pid")
drain_start=$(q "select extract(epoch from clock_timestamp())")
: > "$RESULTS/drain.progress.csv"
echo "elapsed_s,default_rows,partitions,status" >> "$RESULTS/drain.progress.csv"
steps=0
while :; do
  status=$(q "select pgpm.drain_step('bench.events', $BENCH_DRAIN_BATCH)")
  steps=$((steps + 1))
  if [ $((steps % 10)) -eq 0 ] || [ "${status%%:*}" = "attached" ]; then
    now_s=$(q "select extract(epoch from clock_timestamp())")
    elapsed=$(awk -v a="$drain_start" -v b="$now_s" 'BEGIN{printf "%.0f", b-a}')
    drows=$(q "select default_rows from pgpm.check_default('bench.events')")
    nparts=$(q "select count(*) from pg_inherits where inhparent='bench.events'::regclass")
    printf '%s,%s,%s,%s\n' "$elapsed" "$drows" "$nparts" "$status" >> "$RESULTS/drain.progress.csv"
    printf '\r  drain: %ss elapsed, default=%s rows, %s partitions, last=%s   ' \
      "$elapsed" "$drows" "$nparts" "$status"
  fi
  [ "$status" = "idle" ] && break
  now_s=$(q "select extract(epoch from clock_timestamp())")
  if awk -v a="$drain_start" -v b="$now_s" -v m="$BENCH_DRAIN_MAX_SECS" 'BEGIN{exit !(b-a > m)}'; then
    echo; echo "  drain hit BENCH_DRAIN_MAX_SECS cap; stopping"; break
  fi
  [ "$BENCH_DRAIN_SLEEP" != "0" ] && sleep "$BENCH_DRAIN_SLEEP" || true
done
drain_end=$(q "select extract(epoch from clock_timestamp())")
echo
awk -v a="$drain_start" -v b="$drain_end" -v s="$steps" \
  'BEGIN{printf "  drain complete: %d steps in %.1fs (closed history fully partitioned)\n", s, b-a}'
kill "$load_pid" 2>/dev/null || true
wait "$load_pid" 2>/dev/null || true
pgss_snapshot drain
health_snapshot drain
printf '%s\n' "$(pctiles drain)" > "$RESULTS/drain.pctiles.txt"

# ---- 6. post (partitioned, under load) -------------------------------------
# Reclaim the dead tuples the drain left in the default before measuring: "after
# conversion" steady state has a vacuumed default, not the drain's transient bloat.
say "vacuum + analyze before post (settle the conversion)"
q "vacuum (analyze) bench.events" >/dev/null
run_phase post "$BENCH_PHASE_SECS"

# ---- 7. report -------------------------------------------------------------
say "report"
{
  echo "# pg_partition_magician — at-scale load test"
  echo
  echo "- rows: $(q "select count(*) from bench.events")"
  echo "- events size: $(q "select $EVENTS_SIZE_SUB")"
  echo "- partitions: $(q "select count(*) from pg_inherits where inhparent='bench.events'::regclass")"
  echo "- clients: $BENCH_CLIENTS, ops/call: $BENCH_OPS, drain batch: $BENCH_DRAIN_BATCH"
  echo
  echo "## throughput / latency by phase"
  echo
  echo "| phase | pgbench tps | pgbench avg latency | server-side latency (pgbench --log) |"
  echo "|-------|-------------|---------------------|--------------------------------------|"
  for ph in baseline adopt drain post; do
    tps=$(grep -h 'tps =' "$RESULTS/$ph.pgbench.txt" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//' || echo "n/a")
    lat=$(grep -h 'latency average' "$RESULTS/$ph.pgbench.txt" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//' || echo "n/a")
    pct=$(cat "$RESULTS/$ph.pctiles.txt" 2>/dev/null || echo "n/a")
    printf '| %s | %s | %s | %s |\n' "$ph" "${tps:-n/a}" "${lat:-n/a}" "$pct"
  done
  echo
  echo "## health by phase"
  echo
  if [ -f "$RESULTS/baseline.health.csv" ]; then
    head -1 "$RESULTS/baseline.health.csv" | sed 's/,/ | /g; s/^/| /; s/$/ |/'
    head -1 "$RESULTS/baseline.health.csv" | sed 's/[^,]*/---/g; s/,/ | /g; s/^/| /; s/$/ |/'
    for ph in baseline adopt drain post; do
      [ -f "$RESULTS/$ph.health.csv" ] && tail -1 "$RESULTS/$ph.health.csv" | sed 's/,/ | /g; s/^/| /; s/$/ |/'
    done
  fi
  echo
  echo "## drain progress"
  echo
  echo "See \`drain.progress.csv\` (default_rows draining to ~current-month residue under load)."
  echo
  echo "Per-statement server-side timing per phase: \`*.pgss.csv\`."
} > "$RESULTS/report.md"
cat "$RESULTS/report.md"
echo
echo "Full artifacts in $RESULTS/"
