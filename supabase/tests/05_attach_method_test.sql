-- Verifies the default-scan-skip optimization: closed windows attach via the
-- exclusion-CHECK path, the open/current window uses a plain attach, and the
-- temporary exclusion constraints are cleaned up afterward.
create extension if not exists pgtap;

begin;
select plan(4);

-- precondition: at least one closed window exists to exercise the skip path
select cmp_ok(
  (select count(*) from partition_migration.windows where window_end <= current_date)::int,
  '>', 0,
  'there is at least one closed window to attach via check_skip'
);

-- drive the full drain
select partition_migration.drain_all(5000);

select is(
  (select count(*) from partition_migration.windows
    where window_end <= current_date
      and attach_method is distinct from 'check_skip')::int,
  0,
  'every CLOSED window attached via the scan-skipping check_skip path'
);

select is(
  (select count(*) from partition_migration.windows
    where window_end > current_date
      and attach_method is distinct from 'plain')::int,
  0,
  'the OPEN (current/future) window attached via a plain (write-safe) attach'
);

-- the temporary exclusion constraints must not linger on the default
select is(
  (select count(*) from pg_constraint
    where conrelid = 'public.messages_default'::regclass
      and conname ~ '_excl$')::int,
  0,
  'temporary exclusion CHECK constraints were dropped after attach'
);

select * from finish();
rollback;
