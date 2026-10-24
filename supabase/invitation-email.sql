-- Direct wedding invitations. Run after planning-delivery.sql and team-invitation-roles.sql.
begin;
create table if not exists public.cb_invitation_email_jobs(
 id uuid primary key default gen_random_uuid(),invite_id uuid not null unique references public.cb_invites on delete cascade,
 requested_by uuid not null references auth.users,created_at timestamptz not null default now(),
 state text not null default 'queued' check(state in ('queued','inflight','accepted','failed','cancelled','uncertain')),
 payload jsonb not null,attempts integer not null default 0,request_id bigint,provider_id text,
 first_attempt_at timestamptz,last_attempt_at timestamptz,next_attempt_at timestamptz not null default now(),last_error text
);
alter table public.cb_invitation_email_jobs enable row level security;
revoke all on public.cb_invitation_email_jobs from public,anon,authenticated;
create index if not exists cb_invitation_email_provider on public.cb_invitation_email_jobs(provider_id);
create or replace function public.cb_invitation_email_blocked(p_email text) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_planning_delivery_events e
 where e.kind in ('email.bounced','email.complained','email.suppressed') and (
 exists(select 1 from public.cb_invitation_email_jobs j where j.provider_id=e.provider_id and lower(j.payload->'to'->>0)=lower(p_email))
 or exists(select 1 from public.cb_planning_email_jobs j where j.provider_id=e.provider_id and lower(j.payload->'to'->>0)=lower(p_email))));
$$;
create or replace function public.cb_send_invitation_email(p_invite uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare invitation public.cb_invites; project public.cb_projects; title text; link text; body jsonb; job public.cb_invitation_email_jobs;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 perform pg_advisory_xact_lock(hashtextextended('cb-invitation-email-queue',0));
 select * into invitation from public.cb_invites where id=p_invite for update;
 if not found or not public.cb_project_access(invitation.project_id,'invite') then raise exception 'Invitation access denied' using errcode='42501';end if;
 if invitation.revoked or invitation.accepted_at is not null or invitation.expires_at<=now() then raise exception 'This invitation is no longer pending';end if;
 if not exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null) then raise exception 'Verify your email first';end if;
 select * into job from public.cb_invitation_email_jobs where invite_id=p_invite;
 if found then return jsonb_build_object('state',job.state);end if;
 if not public.cb_planning_email_ready() then raise exception 'Email delivery is unavailable. You can still share the invitation link.';end if;
 if length(invitation.email)>254 or invitation.email !~ '^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+\.[^[:space:]<>@,;]+$' then raise exception 'Enter a valid email address';end if;
 if public.cb_invitation_email_blocked(invitation.email) then raise exception 'Email delivery is unavailable for this address. Share the invitation link instead.';end if;
 if (select count(*) from public.cb_invitation_email_jobs where requested_by=auth.uid() and created_at>now()-interval '1 day')>=10 then raise exception 'Daily invitation email limit reached. You can still share links.';end if;
 if (select count(*) from public.cb_invitation_email_jobs where lower(payload->'to'->>0)=lower(invitation.email) and created_at>now()-interval '1 day')>=3 then raise exception 'This address has already received several invitations today. Share the existing link.';end if;
 select * into project from public.cb_projects where id=invitation.project_id;
 title=replace(replace(replace(replace(left(project.title,200),'&','&amp;'),'<','&lt;'),'>','&gt;'),'"','&quot;');
 link='https://www.cobridey.com/collaborate.html#invite='||invitation.token;
 body=jsonb_build_object('from','Cobridey <hello@mail.cobridey.com>','to',jsonb_build_array(invitation.email),
 'subject','You are invited to a wedding on Cobridey',
 'text','You have been invited to join '||project.title||' on Cobridey as '||invitation.role||'. Sign in or create an account using this email address. Review and accept your invitation: '||link||chr(10)||'Expires: '||invitation.expires_at::date||chr(10)||'If this invitation is unexpected, you can ignore it. Access is granted only after you accept.'||chr(10)||'Cobridey · Your Bridal Journey Companion',
 'html','<!doctype html><html lang="en"><body style="margin:0;padding:32px 16px;background:#faf7f5;color:#111;font-family:Arial,sans-serif"><main style="max-width:540px;margin:auto;background:white;border-radius:22px;overflow:hidden;border-top:7px solid #c60063"><div style="padding:34px"><p style="font-size:26px;font-weight:bold">Cobridey<span style="color:#c60063">.</span></p><p style="color:#9c0050;letter-spacing:2px;font-size:11px;font-weight:bold">A PLACE IN THE CELEBRATION</p><h1 style="font-size:30px;line-height:1.2">You are part of the picture.</h1><p style="font-size:16px;line-height:1.8">You have been invited to join <strong>'||title||'</strong> as <strong>'||invitation.role||'</strong>.</p><p style="line-height:1.8">Sign in or create your account using the email address that received this invitation, then review and accept your access.</p><a href="'||link||'" style="display:inline-block;padding:16px 24px;background:#c60063;background:linear-gradient(110deg,#c60063,#7220a2);color:white;border-radius:12px;text-decoration:none;font-weight:bold">View invitation</a><p style="font-size:13px;line-height:1.8;margin-top:28px">Expires '||invitation.expires_at::date||'. Access is granted only after you accept. If this invitation is unexpected, you can ignore it.</p><p style="font-size:12px">Cobridey · Your Bridal Journey Companion</p></div></main></body></html>');
 insert into public.cb_invitation_email_jobs(invite_id,requested_by,payload) values(p_invite,auth.uid(),body);
 return '{"state":"queued"}';
end; $$;
create or replace function public.cb_invitation_email_status(p_invite uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job public.cb_invitation_email_jobs; delivery text; pid uuid;
begin
 select project_id into pid from public.cb_invites where id=p_invite;
 if pid is null or not public.cb_project_access(pid,'invite') then raise exception 'Invitation access denied' using errcode='42501';end if;
 select * into job from public.cb_invitation_email_jobs where invite_id=p_invite;
 if not found then return '{"state":"not_sent"}';end if;
 select kind into delivery from public.cb_planning_delivery_events where provider_id=job.provider_id order by public.cb_delivery_priority(kind) desc,occurred_at desc limit 1;
 return jsonb_build_object('state',job.state,'delivery',delivery);
end; $$;
create or replace function public.cb_process_invitation_email() returns jsonb
language plpgsql security definer set search_path='' as $$
declare job public.cb_invitation_email_jobs; invitation public.cb_invites; response record; data jsonb; api_key text; request bigint; settings public.cb_planning_email_settings;
begin
 if not pg_try_advisory_xact_lock(hashtextextended('cb-invitation-email-worker',0)) then return '{"status":"busy"}';end if;
 if not public.cb_planning_email_ready() then return '{"status":"not_configured"}';end if;
 -- Shared settings lock serializes invitations with daily summaries and provider pauses.
 select * into settings from public.cb_planning_email_settings where singleton for update;
 for job in select * from public.cb_invitation_email_jobs where state='inflight' for update loop
  select * into response from net._http_response where id=job.request_id;
  if found and response.status_code between 200 and 299 and coalesce(response.error_msg,'')='' and not coalesce(response.timed_out,false) then
   begin data=response.content::jsonb;exception when others then data='{}';end;
   update public.cb_invitation_email_jobs set state='accepted',provider_id=data->>'id',last_error=null where id=job.id;
  elsif found or job.last_attempt_at<now()-interval '15 minutes' then
   if job.attempts>=5 or job.first_attempt_at<now()-interval '20 hours' then
    update public.cb_invitation_email_jobs set state='uncertain',last_error='Delivery could not be confirmed' where id=job.id;
   elsif found and response.status_code between 400 and 499 and response.status_code not in (408,409,429) then
    update public.cb_invitation_email_jobs set state='failed',last_error='Email provider rejected the request' where id=job.id;
    if response.status_code in (401,403) then update public.cb_planning_email_settings set enabled=false,last_error='Check sending configuration' where singleton;return '{"status":"provider_configuration_error"}';end if;
   else
    update public.cb_invitation_email_jobs set state='queued',next_attempt_at=now()+make_interval(mins=>least(60,power(2,job.attempts)::integer)) where id=job.id;
    if found and response.status_code=429 then update public.cb_planning_email_settings set pause_until=now()+interval '15 minutes' where singleton;return '{"status":"provider_paused"}';end if;
   end if;
  end if;
 end loop;
 -- No further submission is allowed after acceptance, expiry, revocation or the sender losing access.
 update public.cb_invitation_email_jobs j set state='cancelled' where state='queued' and not exists(
 select 1 from public.cb_invites i join public.cb_projects p on p.id=i.project_id
 where i.id=j.invite_id and not coalesce(i.revoked,false) and i.accepted_at is null and i.expires_at>now() and p.archived_at is null
 and (p.owner_id=j.requested_by or exists(select 1 from public.cb_members m where m.project_id=p.id and m.user_id=j.requested_by and m.role in ('bride','planner'))));
 if settings.pause_until>now() then return '{"status":"provider_paused"}';end if;
 if (select count(*) from public.cb_invitation_email_jobs where first_attempt_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC')>=25 then return '{"status":"daily_allowance"}';end if;
 if (select count(*) from public.cb_invitation_email_jobs where first_attempt_at>=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC')>=750 then return '{"status":"monthly_allowance"}';end if;
 if exists(select 1 from public.cb_invitation_email_jobs where last_attempt_at>now()-interval '55 seconds') then return '{"status":"paced"}';end if;
 select decrypted_secret into api_key from vault.decrypted_secrets where name='cobridey_resend_api_key' limit 1;
 for job in select * from public.cb_invitation_email_jobs where state='queued' and next_attempt_at<=now() order by created_at,id for update skip locked loop
  if public.cb_invitation_email_blocked(job.payload->'to'->>0) then update public.cb_invitation_email_jobs set state='cancelled' where id=job.id;continue;end if;
  if job.first_attempt_at<now()-interval '20 hours' then update public.cb_invitation_email_jobs set state='uncertain' where id=job.id;continue;end if;
  select * into invitation from public.cb_invites where id=job.invite_id for update;
  if invitation.revoked or invitation.accepted_at is not null or invitation.expires_at<=now() then update public.cb_invitation_email_jobs set state='cancelled' where id=job.id;continue;end if;
  request=net.http_post(url:='https://api.resend.com/emails',body:=job.payload,headers:=jsonb_build_object('Authorization','Bearer '||api_key,'Content-Type','application/json','Idempotency-Key','cobridey-invitation/'||job.id),timeout_milliseconds:=10000);
  update public.cb_invitation_email_jobs set state='inflight',request_id=request,attempts=attempts+1,first_attempt_at=coalesce(first_attempt_at,now()),last_attempt_at=now() where id=job.id;
  return '{"status":"submitted"}';
 end loop;
 return '{"status":"idle"}';
end; $$;
revoke all on function public.cb_invitation_email_blocked(text),public.cb_process_invitation_email(),public.cb_send_invitation_email(uuid),public.cb_invitation_email_status(uuid) from public,anon,authenticated;
grant execute on function public.cb_send_invitation_email(uuid),public.cb_invitation_email_status(uuid) to authenticated;
do $setup$ begin
 if exists(select 1 from pg_extension where extname='pg_cron') then perform cron.schedule('cb-invitation-email','* * * * *','select public.cb_process_invitation_email();');end if;
end; $setup$;
notify pgrst,'reload schema';
commit;
