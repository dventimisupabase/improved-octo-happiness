-- Append-only catch-up (the online guarantee). The migration copies existing chunks to a watermark while
-- the source stays live, then catches up rows that arrived after the watermark during the brief cutover.
-- This drives the two phases separately (from_hypertable_copy, then from_hypertable_cutover) and injects
-- late appends between them, asserting they land in the migrated table. Autocommit, disposable-db.
select plan(4);

select mk_plain_hypertable('hp_d1', 240, '1 day', '10 days');   -- 240 rows up to ~now

-- PHASE 1: bulk-copy the existing chunks. The source stays live (no cutover yet).
call pgpm.from_hypertable_copy('hp_d1', 'ts');

-- writes that arrive DURING the migration: 5 appends after the copy watermark (future ts, tagged device_id)
insert into hp_d1 (ts, device_id, temp)
  select now() + (g || ' hours')::interval, 1000 + g, random() * 100 from generate_series(1, 5) g;

-- PHASE 2: catch up the late appends, cut over, hand off
call pgpm.from_hypertable_cutover('hp_d1', 'ts', interval '1 month', p_paused => false);

select is(
  (select relkind::text from pg_class where oid = 'hp_d1'::regclass),
  'p', 'the table migrated to a native partitioned table');
select is((select count(*)::int from hp_d1), 245, 'all 245 rows present (240 copied + 5 late appends)');
select is(
  (select count(*)::int from hp_d1 where device_id >= 1000),
  5, 'the late appends (written between copy and cutover) were caught up');
select is(
  (select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'hp_d1'),
  0, 'the hypertable was torn down');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
