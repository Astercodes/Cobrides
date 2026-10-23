-- CoBrides authenticated import budgets. Safe to run repeatedly.
begin;
create table if not exists public.cb_import_usage (
 user_id uuid not null references auth.users(id) on delete cascade,
 action text not null check(action in ('preview','image','collection')),
 window_start timestamptz not null,
 window_seconds integer not null check(window_seconds in (60,3600,86400)),
 requests integer not null default 0 check(requests>=0),
 primary key(user_id,action,window_seconds,window_start)
);
alter table public.cb_import_usage enable row level security;
revoke all on public.cb_import_usage from public,anon,authenticated;
create or replace function public.cb_consume_import_budget(p_action text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); limits integer[]; seconds integer[]:=array[60,3600,86400]; i integer; stamp timestamptz; used integer; retry integer;
begin
 if uid is null or not exists(select 1 from auth.users where id=uid and email_confirmed_at is not null) then raise exception 'CB_IMPORT_SIGN_IN_REQUIRED' using errcode='28000'; end if;
 case p_action when 'preview' then limits:=array[20,150,1000]; when 'image' then limits:=array[180,1500,6000]; when 'collection' then limits:=array[3,15,50]; else raise exception 'CB_IMPORT_INVALID_ACTION'; end case;
 -- Serialize each account/action so minute/hour/day limits are enforced together.
 perform pg_advisory_xact_lock(hashtextextended(uid::text||':'||p_action,0));
 for i in 1..3 loop
  stamp:=to_timestamp(floor(extract(epoch from now())/seconds[i])*seconds[i]);
  select requests into used from public.cb_import_usage where user_id=uid and action=p_action and window_seconds=seconds[i] and window_start=stamp;
  if coalesce(used,0)>=limits[i] then
   retry:=greatest(1,ceil(extract(epoch from stamp+make_interval(secs=>seconds[i])-now()))::integer);
   return jsonb_build_object('allowed',false,'retryAfter',retry);
  end if;
 end loop;
 for i in 1..3 loop
  stamp:=to_timestamp(floor(extract(epoch from now())/seconds[i])*seconds[i]);
  insert into public.cb_import_usage(user_id,action,window_start,window_seconds,requests) values(uid,p_action,stamp,seconds[i],1)
  on conflict(user_id,action,window_seconds,window_start) do update set requests=cb_import_usage.requests+1;
 end loop;
 -- Bound retained counters without touching other accounts.
 delete from public.cb_import_usage where user_id=uid and window_start<now()-interval '2 days';
 return jsonb_build_object('allowed',true,'userId',uid);
end;
$$;
revoke all on function public.cb_consume_import_budget(text) from public,anon;
grant execute on function public.cb_consume_import_budget(text) to authenticated;
commit;
