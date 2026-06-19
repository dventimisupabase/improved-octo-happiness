-- Server-side workload. One call performs p_ops index-supported operations, so a
-- single client round-trip drives many ops -- the SERVER is the bottleneck, not
-- the network (essential when the driver isn't co-located with the DB). Latency
-- per operation = call latency / p_ops; pg_stat_statements records server-side
-- timing WAN-free. References bench.events by name, so it's identical before and
-- after adoption.
--
-- Every query is the kind you'd actually run against a time-partitioned events
-- table: it filters by user_id (the lookup index) AND a recent created_at window,
-- so post-conversion the planner prunes to the newest partition(s). The cost is
-- therefore ~stable before and after -- which is the point: it lets adopt()/drain
-- degradation show up as the signal instead of being masked by partition fan-out.
-- (A bare "WHERE id = ?" lookup is deliberately avoided: id is not the partition
-- key, so post-conversion it would fan out across every partition and dominate.)
--
-- Mix:
--   40%  head insert (created_at = now())            + companion upsert
--   40%  a user's recent activity, last 7 days, newest 20  (index + pruning)
--   20%  a user's activity count, last 30 days              (index + pruning)
create or replace function bench.workload_step(p_ops int default 50)
returns void language plpgsql as $$
declare
  v_users int;
  r       double precision;
  uid     int;
  newid   bigint;
  i       int;
begin
  select count(*) into v_users from bench.users;
  for i in 1 .. p_ops loop
    r   := random();
    uid := 1 + floor(random() * v_users)::int;
    if r < 0.40 then
      insert into bench.events (created_at, user_id, kind, payload)
      values (now(), uid, floor(random() * 8)::smallint,
              substr(md5(random()::text) || md5(random()::text) || md5(random()::text), 1, 200))
      returning id into newid;
      insert into bench.user_seen (user_id, last_event, seen_at) values (uid, newid, now())
      on conflict (user_id) do update set last_event = excluded.last_event, seen_at = excluded.seen_at;
    elsif r < 0.80 then
      perform count(*) from (
        select id from bench.events
        where user_id = uid and created_at >= now() - interval '7 days'
        order by created_at desc limit 20
      ) s;
    else
      perform count(*) from bench.events
      where user_id = uid and created_at >= now() - interval '30 days';
    end if;
  end loop;
end;
$$;
