-- Server-side bulk generator for bench.events. Runs entirely on the server (no
-- data crosses the wire) and commits per chunk so WAL/memory stay bounded and a
-- long run is restartable. created_at is spread across the last p_months months,
-- so the table arrives with many full monthly partitions to drain; the load
-- phase then appends at the head (now()).
create or replace procedure bench.generate_events(
  p_target_rows bigint,
  p_months      int    default 12,
  p_chunk       int    default 2000000
)
language plpgsql as $$
declare
  v_done  bigint := 0;
  v_n     int;
  v_users int;
  v_start timestamptz := now() - make_interval(months => p_months);
  v_span  double precision := extract(epoch from (now() - (now() - make_interval(months => p_months))));
begin
  select count(*) into v_users from bench.users;
  while v_done < p_target_rows loop
    v_n := least(p_chunk, p_target_rows - v_done)::int;
    insert into bench.events (created_at, user_id, kind, payload)
    select
      v_start + make_interval(secs => (random() * v_span)),
      1 + floor(random() * v_users)::int,
      floor(random() * 8)::smallint,
      -- ~360 incompressible bytes so the heap reaches the target size
      substr(md5(random()::text) || md5(random()::text) || md5(random()::text)
           || md5(random()::text) || md5(random()::text) || md5(random()::text), 1, 360)
    from generate_series(1, v_n);
    v_done := v_done + v_n;
    commit;
    raise notice 'bench.generate_events: % / % rows', v_done, p_target_rows;
  end loop;
  analyze bench.events;
end;
$$;
