-- Delivery events for planning summaries. Run after planning-email.sql.
-- Put the Resend webhook signing secret in Vault as cobridey_resend_webhook_secret
-- and in Vercel as RESEND_WEBHOOK_SECRET. Never expose it in a public config.
begin;
alter table public.cb_planning_preferences add column if not exists suppressed_email text;
alter table public.cb_planning_preferences add column if not exists suppression_reason text;
alter table public.cb_planning_email_jobs add column if not exists delivery_state text;
alter table public.cb_planning_email_jobs add column if not exists delivery_updated_at timestamptz;
create index if not exists cb_planning_provider_id on public.cb_planning_email_jobs(provider_id) where provider_id is not null;
create table if not exists public.cb_planning_delivery_events(
 event_id text primary key,provider_id text not null,kind text not null check(kind in ('email.delivered','email.bounced','email.complained','email.failed','email.delivery_delayed','email.suppressed')),
 occurred_at timestamptz not null,received_at timestamptz not null default now(),processed_at timestamptz
);
create index if not exists cb_planning_delivery_pending on public.cb_planning_delivery_events(provider_id) where processed_at is null;
alter table public.cb_planning_delivery_events enable row level security;
revoke all on public.cb_planning_delivery_events from public,anon,authenticated;
create or replace function public.cb_delivery_priority(p_kind text) returns integer language sql immutable set search_path='' as $$
 select case p_kind when 'email.delivery_delayed' then 1 when 'email.delivered' then 2 when 'email.failed' then 3 when 'email.suppressed' then 4 when 'email.bounced' then 5 when 'email.complained' then 6 else 0 end;
$$;
create or replace function public.cb_apply_planning_delivery(p_event text) returns boolean language plpgsql security definer set search_path='' as $$
declare job public.cb_planning_email_jobs; event public.cb_planning_delivery_events; address text;
begin
 select j.* into job from public.cb_planning_email_jobs j join public.cb_planning_delivery_events e on e.provider_id=j.provider_id where e.event_id=p_event;
 if not found then return false;end if;
 -- Match the preference-before-job lock order used by opt-out; skip busy rows and retry later.
 perform 1 from public.cb_planning_preferences where user_id=job.user_id for update skip locked;
 if not found then return false;end if;
 select * into job from public.cb_planning_email_jobs where id=job.id for update skip locked;
 if not found then return false;end if;
 select * into event from public.cb_planning_delivery_events where event_id=p_event and processed_at is null for update skip locked;
 if not found then return false;end if;
 if public.cb_delivery_priority(event.kind)>public.cb_delivery_priority(job.delivery_state) or (event.kind=job.delivery_state and (job.delivery_updated_at is null or event.occurred_at>job.delivery_updated_at)) then
  update public.cb_planning_email_jobs set delivery_state=event.kind,delivery_updated_at=event.occurred_at where id=job.id;
 end if;
 if event.kind in ('email.bounced','email.complained','email.suppressed') then
  address=lower(job.payload->'to'->>0);
  if address is not null then
   update public.cb_planning_preferences pref set suppressed_email=address,suppression_reason=event.kind,
    email_opt_in=case when exists(select 1 from auth.users u where u.id=pref.user_id and lower(u.email)=address) then false else email_opt_in end,
    updated_at=now() where pref.user_id=job.user_id;
   update public.cb_planning_email_jobs set state='cancelled',last_error='Email paused after recipient rejection.' where user_id=job.user_id and state='queued' and (lower(payload->'to'->>0)=address or (payload is null and exists(select 1 from auth.users u where u.id=job.user_id and lower(u.email)=address)));
  end if;
 end if;
 update public.cb_planning_delivery_events set processed_at=now() where event_id=event.event_id;
 return true;
end; $$;
create or replace function public.cb_reconcile_planning_delivery() returns integer language plpgsql security definer set search_path='' as $$
declare e record;n integer:=0;
begin
 for e in select event_id from public.cb_planning_delivery_events d where processed_at is null and exists(select 1 from public.cb_planning_email_jobs j where j.provider_id=d.provider_id) order by received_at limit 100 loop
  if public.cb_apply_planning_delivery(e.event_id) then n=n+1;end if;
 end loop;return n;
end; $$;
create or replace function public.cb_planning_delivery_after_provider() returns trigger language plpgsql security definer set search_path='' as $$
declare e record;
begin
 if new.provider_id is not null and old.provider_id is distinct from new.provider_id then
  for e in select event_id from public.cb_planning_delivery_events where provider_id=new.provider_id and processed_at is null loop perform public.cb_apply_planning_delivery(e.event_id);end loop;
 end if;
 return new;
end; $$;
drop trigger if exists cb_planning_provider_linked on public.cb_planning_email_jobs;
create trigger cb_planning_provider_linked after update of provider_id on public.cb_planning_email_jobs for each row execute function public.cb_planning_delivery_after_provider();

create or replace function public.cb_record_planning_delivery(p_secret text,p_event_id text,p_email_id text,p_kind text,p_occurred timestamptz)
returns jsonb language plpgsql security definer set search_path='' as $$
declare expected text; saved public.cb_planning_delivery_events;
begin
 if to_regclass('vault.decrypted_secrets') is null then raise exception 'Delivery receiver is unavailable' using errcode='42501';end if;
 select decrypted_secret into expected from vault.decrypted_secrets where name='cobridey_resend_webhook_secret' limit 1;
 if expected is null or length(expected)<20 or length(coalesce(p_secret,''))>256 or md5(coalesce(p_secret,'')) is distinct from md5(expected) then raise exception 'Delivery access denied' using errcode='42501';end if;
 if p_event_id is null or p_event_id !~ '^[A-Za-z0-9_-]{1,200}$' or p_email_id is null or p_email_id !~ '^[A-Za-z0-9_-]{1,160}$'
 or p_kind is null or public.cb_delivery_priority(p_kind)=0 or p_occurred is null or p_occurred>now()+interval '5 minutes' or p_occurred<timestamptz '2000-01-01' then raise exception 'Invalid delivery event';end if;
 insert into public.cb_planning_delivery_events(event_id,provider_id,kind,occurred_at) values(p_event_id,p_email_id,p_kind,p_occurred) on conflict do nothing;
 select * into saved from public.cb_planning_delivery_events where event_id=p_event_id;
 if saved.provider_id<>p_email_id or saved.kind<>p_kind or saved.occurred_at<>p_occurred then raise exception 'Event ID already recorded';end if;
 return jsonb_build_object('received',true,'processed',public.cb_apply_planning_delivery(p_event_id));
end; $$;
create or replace function public.cb_planning_email_status() returns jsonb language plpgsql security definer set search_path='' as $$
declare blocked boolean;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 select exists(select 1 from public.cb_planning_preferences p join auth.users u on u.id=p.user_id where p.user_id=auth.uid() and lower(p.suppressed_email)=lower(u.email)) into blocked;
 return jsonb_build_object('available',public.cb_planning_email_ready(),'enabled',coalesce((select email_opt_in from public.cb_planning_preferences where user_id=auth.uid()),false),'suppressed',blocked,
 'last',(select jsonb_build_object('state',coalesce(delivery_state,state),'at',coalesce(delivery_updated_at,accepted_at,last_attempt_at,created_at)) from public.cb_planning_email_jobs where user_id=auth.uid() order by created_at desc limit 1));
end; $$;
create or replace function public.cb_set_planning_delivery(p_categories text[],p_time_zone text,p_email boolean)
returns public.cb_planning_preferences language plpgsql security definer set search_path='' as $$
declare result public.cb_planning_preferences;
begin
 if p_email is null then raise exception 'Choose an email preference';end if;
 if p_email and exists(select 1 from public.cb_planning_preferences p join auth.users u on u.id=p.user_id where p.user_id=auth.uid() and lower(p.suppressed_email)=lower(u.email)) then raise exception 'Email summaries are paused for this address after a delivery problem. Contact support to review this address.';end if;
 if p_email and not public.cb_planning_email_ready() and not exists(select 1 from public.cb_planning_preferences where user_id=auth.uid() and email_opt_in) then raise exception 'Email summaries are unavailable right now. In-app updates are still available.';end if;
 perform public.cb_set_planning_preferences(p_categories,p_time_zone);
 update public.cb_planning_preferences set email_opted_at=case when p_email and not email_opt_in then now() else email_opted_at end,email_opt_in=p_email,updated_at=now() where user_id=auth.uid() returning * into result;
 if not p_email then update public.cb_planning_email_jobs set state='cancelled',last_error='Email summaries turned off' where user_id=auth.uid() and state='queued';end if;
 return result;
end; $$;
revoke all on function public.cb_delivery_priority(text),public.cb_apply_planning_delivery(text),public.cb_reconcile_planning_delivery(),
 public.cb_planning_delivery_after_provider(),public.cb_record_planning_delivery(text,text,text,text,timestamptz),
 public.cb_planning_email_status(),public.cb_set_planning_delivery(text[],text,boolean) from public,anon,authenticated;
grant execute on function public.cb_record_planning_delivery(text,text,text,text,timestamptz) to anon,authenticated;
grant execute on function public.cb_planning_email_status(),public.cb_set_planning_delivery(text[],text,boolean) to authenticated;
do $setup$
begin
 if exists(select 1 from pg_extension where extname='pg_cron') then perform cron.schedule('cb-planning-delivery','* * * * *','select public.cb_reconcile_planning_delivery();');end if;
end; $setup$;
notify pgrst,'reload schema';
commit;
