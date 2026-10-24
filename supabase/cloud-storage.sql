-- Run once after collaboration.sql and accounts.sql.
begin;
create table public.cb_workspace_states (
 user_id uuid not null references auth.users on delete cascade,
 workspace text not null check(workspace in ('bride','planner','partner','bridal-party','family','vendor','merchant','venue','guest')),
 payload jsonb not null check(jsonb_typeof(payload)='object' and octet_length(payload::text)<=20000000),
 revision bigint not null default 1,
 updated_at timestamptz not null default now(),
 primary key(user_id,workspace)
);
alter table public.cb_workspace_states enable row level security;
create policy workspace_owner_read on public.cb_workspace_states for select to authenticated using(user_id=auth.uid());
revoke all on public.cb_workspace_states from anon,authenticated;
grant select on public.cb_workspace_states to authenticated;

-- Compare-and-swap prevents stale devices from overwriting newer records.
create function public.cb_save_workspace(p_workspace text,p_payload jsonb,p_revision bigint)
returns bigint language plpgsql security definer set search_path='' as $$
declare next_revision bigint;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 if p_revision=0 then
  insert into public.cb_workspace_states(user_id,workspace,payload)
  values(auth.uid(),p_workspace,p_payload) on conflict do nothing returning revision into next_revision;
 else
  update public.cb_workspace_states set payload=p_payload,revision=revision+1,updated_at=now()
  where user_id=auth.uid() and workspace=p_workspace and revision=p_revision
  returning revision into next_revision;
 end if;
 if next_revision is null then raise exception 'CB_SYNC_CONFLICT' using errcode='PT409'; end if;
 return next_revision;
end; $$;
revoke all on function public.cb_save_workspace(text,jsonb,bigint) from public,anon;
grant execute on function public.cb_save_workspace(text,jsonb,bigint) to authenticated;

-- Only the verified owner's account receives the requested populated journey.
create function public.cb_can_seed_demo() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null and lower(email)='ayenaiayomide5@gmail.com');
$$;
revoke all on function public.cb_can_seed_demo() from public,anon;
grant execute on function public.cb_can_seed_demo() to authenticated;
commit;
