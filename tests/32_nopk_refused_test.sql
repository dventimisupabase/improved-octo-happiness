-- Regression test for issue #89. pgpm does not support no-PK tables. transmute must REFUSE a table
-- with no primary key up front (before the rename), with a pgpm-prefixed message that names the
-- requirement -- never proceeding into the old no-PK path, whose `SET NOT NULL` on a nullable control
-- column scanned the whole (renamed) default under ACCESS EXCLUSIVE (an O(rows) blocking cost that
-- contradicted the "always metadata-only" contract). Requiring the control column to be part of the
-- primary key also guarantees it is NOT NULL, so that SET NOT NULL is now a metadata no-op.
create extension if not exists pgtap;

begin;
select plan(3);

create table public.nopk_t (created_at timestamptz not null, body text);
insert into public.nopk_t (created_at, body)
  select now() - (g || ' days')::interval, 'x' from generate_series(1, 50) g;

select throws_ok(
  $$ select pgpm.transmute('public.nopk_t', 'created_at', interval '1 month') $$,
  NULL, NULL,
  'transmute refuses a table with no primary key');

select throws_like(
  $$ select pgpm.transmute('public.nopk_t', 'created_at', interval '1 month') $$,
  'pg_partition_magician:%primary key%',
  'the refusal is a pgpm guard that names the missing primary key');

-- the refusal is up front: the table is untouched, still a plain table (not renamed/partitioned)
select is(
  (select relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'nopk_t'),
  'r',
  'the original table is left intact (refused before the cutover, no blocking scan)');

select * from finish();
rollback;
