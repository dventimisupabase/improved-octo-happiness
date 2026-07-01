-- observe track :: PGFR ABSENT
-- The observe module must install on a database with no pg_flight_recorder, the
-- pure-pgpm window summary must still work, and the PGFR-delegating functions must
-- refuse with a clear pgpm-prefixed error (the "optional, never required" contract).
begin;
select plan(6);

create table public.t (id bigint);

-- A small synthetic operation log: a transmute, one drain, two adaptive ticks (one
-- a 'probe' = no congestion, one a 'wal' backoff), a regrain, and a retention drop.
insert into pgpm.log (parent_table, action, rows, method, at) values
  ('public.t'::regclass, 'transmute',    null, null,             now() - interval '5 min'),
  ('public.t'::regclass, 'drain_move',   1000, null,             now() - interval '4 min'),
  ('public.t'::regclass, 'drain_budget', 5000, 'probe',          now() - interval '4 min'),
  ('public.t'::regclass, 'drain_budget', 2500, 'wal',            now() - interval '3 min'),
  ('public.t'::regclass, 'regrain',          1, 'copy_swap_drop', now() - interval '2 min'),
  ('public.t'::regclass, 'retain_drop',  null, null,             now() - interval '1 min');

select is( pgpm._observe_has_pgfr(), false,
           'PGFR absent: _observe_has_pgfr() is false' );

-- observe_window is pure pgpm.log and works with no PGFR.
select is( (select drains   from pgpm.observe_window('public.t'::regclass)), 1::bigint,
           'observe_window: one drain_move counted' );
select is( (select adaptive_ticks from pgpm.observe_window('public.t'::regclass)), 2::bigint,
           'observe_window: both drain_budget ticks counted' );
select is( (select backoffs from pgpm.observe_window('public.t'::regclass)), 1::bigint,
           'observe_window: only the non-probe tick counts as a backoff' );

-- The PGFR-delegating functions refuse cleanly (raise, SQLSTATE P0001).
select throws_ok( $$ select pgpm.impact_report('public.t'::regclass) $$, 'P0001',
                  null, 'impact_report refuses without PGFR' );
select throws_ok( $$ select * from pgpm.feathering_validation('public.t'::regclass) $$, 'P0001',
                  null, 'feathering_validation refuses without PGFR' );

select * from finish();
rollback;
