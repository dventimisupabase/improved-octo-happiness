-- =============================================================================
-- pg_partition_magician :: observe  --  optional observability that correlates
-- pgpm's own operation log against pg_flight_recorder (PGFR) samples.
--
-- OPTIONAL add-on, loaded ON TOP of the core (pgpm_core/install.sql). PGFR is
-- NEVER a dependency: this module installs anywhere, and the PGFR-delegating
-- functions raise a clear, catchable error when the pgfr_analyze extension is
-- absent. pgpm's only runtime dependency stays pg_cron.
--
-- The integration is strictly READ-ONLY and ONE-DIRECTIONAL: pgpm writes
-- nothing into PGFR and PGFR needs zero changes. pgpm already records every
-- obtain/drain/retain/refine/cutover in pgpm.log (with the per-tick adaptive
-- feathering decision), but keeps no history of what the database as a whole
-- was doing during those operations. PGFR is the mirror image: it samples wait
-- events, locks, checkpoints, WAL, I/O, and query latency continuously, but does
-- not know which spikes were pgpm's doing. pgpm.log.at windows bridge the two.
--
-- Surface (all in the pgpm schema):
--   pgpm.observe_window(parent, since)        pure pgpm.log: the time window pgpm
--                                             was active on a table + what it did.
--                                             Works WITHOUT PGFR.
--   pgpm.impact_report(parent, since)         text: what the conversion did to the
--                                             workload (forced checkpoints, WAL,
--                                             temp, top waits, top queries) over
--                                             that window. Requires pgfr_analyze.
--   pgpm.feathering_validation(parent, since) per-backoff-tick cross-check: did PGFR
--                                             independently confirm the pressure the
--                                             adaptive feathering backed off on?
--                                             Requires pgfr_analyze.
-- =============================================================================

-- _observe_has_pgfr: is pg_flight_recorder's analysis layer present? The
-- report/validation functions gate on this so they fail with a pgpm-prefixed
-- message instead of a raw "function pgfr_analyze.* does not exist". Gates on the
-- pgfr_analyze SCHEMA, not pg_extension: PGFR's script install (the common path)
-- creates the schema and its objects without CREATE EXTENSION; only the dbdev/TLE
-- channel registers an extension. The schema is present either way.
create or replace function pgpm._observe_has_pgfr()
returns boolean language sql stable as $$
  select exists (select 1 from pg_namespace where nspname = 'pgfr_analyze');
$$;

-- observe_window: the span pgpm was active on p_parent within the last p_since,
-- plus a summary of what it did (rows moved, drain/refine/retain counts, and the
-- adaptive-feathering backoff breakdown by signal). PURE pgpm.log -- no PGFR
-- dependency, so it is useful and testable on its own. Always returns exactly one
-- row; when there is no activity, the window bounds are null and the counts are 0.
--
-- "Operation" actions move data or change structure; the drain_budget rows are the
-- per-tick adaptive decision (method is the OR'd backoff reason: 'probe' = no
-- congestion, else some combination of 'wal'/'lock'/'io').
create or replace function pgpm.observe_window(
  p_parent regclass, p_since interval default '7 days'
) returns table (
  parent_table   regclass,
  window_start   timestamptz,
  window_end     timestamptz,
  duration       interval,
  log_rows       bigint,
  rows_moved     bigint,
  drains         bigint,
  refines        bigint,
  retains        bigint,
  adaptive_ticks bigint,
  backoffs       bigint,
  wal_backoffs   bigint,
  lock_backoffs  bigint,
  io_backoffs    bigint
) language sql stable as $$
  select
    p_parent,
    min(l.at),
    max(l.at),
    max(l.at) - min(l.at),
    count(*),
    coalesce(sum(l.rows) filter (where l.action in ('drain_move','refine_copy')), 0),
    count(*) filter (where l.action = 'drain_move'),
    count(*) filter (where l.action = 'refine'),
    count(*) filter (where l.action = 'retain_drop'),
    count(*) filter (where l.action = 'drain_budget'),
    count(*) filter (where l.action = 'drain_budget' and l.method <> 'probe'),
    count(*) filter (where l.action = 'drain_budget' and l.method like '%wal%'),
    count(*) filter (where l.action = 'drain_budget' and l.method like '%lock%'),
    count(*) filter (where l.action = 'drain_budget' and l.method like '%io%')
  from pgpm.log l
  where l.parent_table = p_parent
    and l.at >= now() - p_since;
$$;

-- impact_report: "what did my conversion do to the workload?" Derives the active
-- window from pgpm.log (observe_window) and asks pgfr_analyze what the database
-- was doing during it. Sections degrade independently: a section whose PGFR call
-- has too little data (e.g. fewer than two snapshots, or pg_stat_statements reset)
-- reports that rather than failing the whole report.
create or replace function pgpm.impact_report(
  p_parent regclass, p_since interval default '7 days'
) returns text language plpgsql stable as $$
declare
  w        record;
  cmp      record;
  ln       text[] := '{}';
  sect     text;
begin
  if not pgpm._observe_has_pgfr() then
    raise exception 'pg_partition_magician: impact_report requires pg_flight_recorder (the pgfr_analyze extension). Install it to correlate pgpm operations against database telemetry, or use pgpm.observe_window() for the pgpm-only summary.';
  end if;

  select * into w from pgpm.observe_window(p_parent, p_since);
  if w.window_start is null then
    return format('pg_partition_magician impact report: no pgpm activity for %s in the last %s.', p_parent, p_since);
  end if;

  ln := ln || format('pg_partition_magician :: impact report for %s', p_parent);
  ln := ln || format('  window:   %s  ->  %s  (%s)', w.window_start, w.window_end, w.duration);
  ln := ln || format('  pgpm did: %s log rows, %s rows moved; %s drains, %s refines, %s retains',
                     w.log_rows, w.rows_moved, w.drains, w.refines, w.retains);
  ln := ln || format('  feathering: %s adaptive ticks, %s backed off (wal=%s lock=%s io=%s)',
                     w.adaptive_ticks, w.backoffs, w.wal_backoffs, w.lock_backoffs, w.io_backoffs);
  ln := ln || ''::text;

  -- Checkpoints / WAL / temp / I/O over the window (pgfr_analyze.compare brackets
  -- the window with the nearest snapshots and returns the deltas).
  begin
    select * into cmp from pgfr_analyze.compare(w.window_start, w.window_end);
    if not found then   -- FOUND, not "cmp is null": a record with any null field is neither IS NULL nor IS NOT NULL
      ln := ln || '  database impact: insufficient snapshots in the window (need at least two).'::text;
    else
      ln := ln || format('  forced checkpoints: %s (timed: %s)', cmp.ckpt_requested_delta, cmp.ckpt_timed_delta);
      ln := ln || format('  WAL generated:      %s', cmp.wal_bytes_pretty);
      ln := ln || format('  temp spilled:       %s', cmp.temp_bytes_pretty);
      ln := ln || format('  client read time:   %s ms', round(coalesce(cmp.io_client_read_time_ms, 0), 1));
    end if;
  exception when others then
    ln := ln || format('  database impact: unavailable (%s)', left(sqlerrm, 120));
  end;
  ln := ln || ''::text;

  -- Top wait events in the window.
  begin
    sect := '';
    for cmp in
      select wait_event_type, wait_event, total_waiters, pct_of_samples
        from pgfr_analyze.wait_summary(w.window_start, w.window_end)
       where wait_event is not null
       order by total_waiters desc nulls last
       limit 5
    loop
      sect := sect || format('    %-28s waiters=%s  (%s%% of samples)' || chr(10),
                             cmp.wait_event_type || '/' || cmp.wait_event, cmp.total_waiters, round(cmp.pct_of_samples, 1));
    end loop;
    ln := ln || 'top wait events:'::text;
    ln := ln || coalesce(nullif(rtrim(sect, chr(10)), ''), '    (none sampled)');
  exception when others then
    ln := ln || format('top wait events: unavailable (%s)', left(sqlerrm, 120));
  end;
  ln := ln || ''::text;

  -- Top queries by execution-time delta in the window.
  begin
    sect := '';
    for cmp in
      select queryid, calls_delta, round(total_exec_time_delta_ms::numeric, 1) as exec_ms
        from pgfr_analyze.statement_activity_v2(w.window_start, w.window_end, 5)
       order by total_exec_time_delta_ms desc nulls last
    loop
      sect := sect || format('    queryid=%-22s calls=%s  exec=%s ms' || chr(10), cmp.queryid, cmp.calls_delta, cmp.exec_ms);
    end loop;
    ln := ln || 'top queries by exec-time:'::text;
    ln := ln || coalesce(nullif(rtrim(sect, chr(10)), ''), '    (none; pg_stat_statements may be absent)');
  exception when others then
    ln := ln || format('top queries by exec-time: unavailable (%s)', left(sqlerrm, 120));
  end;

  return array_to_string(ln, chr(10));
end $$;

-- feathering_validation: ground-truth check on the adaptive feathering. pgpm backs
-- off on its OWN instantaneous reads of WAL rate / lock waiters / I/O latency and
-- discards the raw values. PGFR sampled the same signals independently. For each
-- backoff tick (a drain_budget row whose reason is not 'probe'), this asks PGFR
-- whether real pressure was present in the lead-up window, so you can tell whether
-- the feathering fires for real reasons or phantoms -- ground truth for tuning
-- drain_batch / drain_wal_high_water / the ambient factors.
--
-- Corroboration is the strongest signal PGFR can supply per dimension:
--   wal  -> a forced checkpoint actually occurred in the lead-up (ckpt_requested_delta > 0)
--   lock -> PGFR sampled a Lock wait_event with waiters in the lead-up
--   io   -> client read time was non-zero in the lead-up (null where pg_stat_io is
--           unavailable, e.g. PG15)
-- p_lead is how far back from each tick to look (the backoff is a leading signal, so
-- the pressure precedes the tick). NOTE the lock dimension relies on PGFR's activity
-- ring buffer (~2h retention by default), so lock corroboration is only meaningful
-- for ticks within that window; wal/io come from the 30-day snapshot tier.
create or replace function pgpm.feathering_validation(
  p_parent regclass, p_since interval default '7 days', p_lead interval default '2 minutes'
) returns table (
  tick_at              timestamptz,
  reason               text,
  wal_signal_confirmed boolean,
  lock_signal_confirmed boolean,
  io_signal_confirmed  boolean,
  note                 text
) language plpgsql stable as $$
declare
  r           record;
  cmp         record;
  lk          bigint;
  v_have_cmp  boolean;
begin
  if not pgpm._observe_has_pgfr() then
    raise exception 'pg_partition_magician: feathering_validation requires pg_flight_recorder (the pgfr_analyze extension).';
  end if;

  for r in
    select l.at as tick_at, l.method as reason
      from pgpm.log l
     where l.parent_table = p_parent
       and l.action = 'drain_budget'
       and l.method <> 'probe'
       and l.at >= now() - p_since
     order by l.at
  loop
    -- checkpoints / WAL / I/O in the lead-up window
    begin
      select * into cmp from pgfr_analyze.compare(r.tick_at - p_lead, r.tick_at);
      v_have_cmp := found;          -- FOUND, not "cmp is null": compare's record has null fields (e.g. io_* on PG15)
    exception when others then v_have_cmp := false;
    end;
    -- a Lock wait sampled with waiters in the lead-up window
    begin
      select coalesce(sum(total_waiters), 0) into lk
        from pgfr_analyze.wait_summary(r.tick_at - p_lead, r.tick_at)
       where wait_event_type = 'Lock';
    exception when others then lk := null;
    end;

    tick_at               := r.tick_at;
    reason                := r.reason;
    wal_signal_confirmed  := case when not v_have_cmp then null else coalesce(cmp.ckpt_requested_delta, 0) > 0 end;
    lock_signal_confirmed := case when lk is null then null else lk > 0 end;
    io_signal_confirmed   := case when not v_have_cmp or cmp.io_client_read_time_ms is null then null
                                  else cmp.io_client_read_time_ms > 0 end;
    note := concat_ws('; ',
              case when v_have_cmp then format('ckpt_req=%s wal=%s io_ms=%s',
                     cmp.ckpt_requested_delta, cmp.wal_bytes_pretty, round(coalesce(cmp.io_client_read_time_ms,0),1)) end,
              case when lk is not null then format('lock_waiters=%s', lk) end);
    return next;
  end loop;
end $$;
