-- Optional daily planning email summaries. Run after planning-notifications.sql.
-- Add the sending-only Resend key to Supabase Vault as cobridey_resend_api_key.
begin;
alter table public.cb_planning_preferences add column if not exists email_opt_in boolean not null default false;
alter table public.cb_planning_preferences add column if not exists email_opted_at timestamptz;
create table if not exists public.cb_planning_email_settings(
 singleton boolean primary key default true check(singleton), enabled boolean not null default true,
 sender text not null default 'hello@mail.cobridey.com', daily_limit integer not null default 50 check(daily_limit between 1 and 10000),
 monthly_limit integer not null default 1500 check(monthly_limit between 1 and 300000), pause_until timestamptz,
 last_error text
);
insert into public.cb_planning_email_settings(singleton) values(true) on conflict do nothing;
create table if not exists public.cb_planning_email_jobs(
 id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users on delete cascade,
 local_day date not null,state text not null default 'queued' check(state in ('queued','inflight','accepted','failed','cancelled','uncertain')),
 notice_through timestamptz not null,created_at timestamptz not null default now(),
 first_attempt_at timestamptz,last_attempt_at timestamptz,next_attempt_at timestamptz not null default now(),
 attempts integer not null default 0,request_id bigint,payload jsonb,provider_id text,last_error text,accepted_at timestamptz,
 unique(user_id,local_day)
);
create index if not exists cb_planning_email_ready on public.cb_planning_email_jobs(state,next_attempt_at);
alter table public.cb_planning_email_settings enable row level security;
alter table public.cb_planning_email_jobs enable row level security;
revoke all on public.cb_planning_email_settings,public.cb_planning_email_jobs from public,anon,authenticated;

create or replace function public.cb_planning_email_ready() returns boolean language plpgsql security definer set search_path='' as $$
declare present boolean;
begin
 if to_regclass('vault.decrypted_secrets') is null or to_regclass('net._http_response') is null then return false;end if;
 select exists(select 1 from vault.decrypted_secrets where name='cobridey_resend_api_key' and length(decrypted_secret)>10) into present;
 return present and exists(select 1 from public.cb_planning_email_settings where enabled);
end; $$;
create or replace function public.cb_planning_email_status() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 return jsonb_build_object('available',public.cb_planning_email_ready(),'enabled',coalesce((select email_opt_in from public.cb_planning_preferences where user_id=auth.uid()),false),
 'last', (select jsonb_build_object('state',state,'at',coalesce(accepted_at,last_attempt_at,created_at)) from public.cb_planning_email_jobs where user_id=auth.uid() order by created_at desc limit 1));
end; $$;
create or replace function public.cb_set_planning_delivery(p_categories text[],p_time_zone text,p_email boolean)
returns public.cb_planning_preferences language plpgsql security definer set search_path='' as $$
declare result public.cb_planning_preferences;
begin
 if p_email is null then raise exception 'Choose an email preference';end if;
 if p_email and not public.cb_planning_email_ready() and not exists(select 1 from public.cb_planning_preferences where user_id=auth.uid() and email_opt_in) then raise exception 'Email summaries are unavailable right now. In-app updates are still available.';end if;
 perform public.cb_set_planning_preferences(p_categories,p_time_zone);
 update public.cb_planning_preferences set email_opted_at=case when p_email and not email_opt_in then now() else email_opted_at end,email_opt_in=p_email,updated_at=now() where user_id=auth.uid() returning * into result;
 if not p_email then update public.cb_planning_email_jobs set state='cancelled',last_error='Email summaries turned off' where user_id=auth.uid() and state='queued';end if;
 return result;
end; $$;
-- Use explicit recipients: cron has no user's JWT. No titles, emails or private fields are returned to browsers.
create or replace function public.cb_planning_digest_items(p_user uuid,p_since timestamptz,p_until timestamptz)
returns table(quantity bigint,latest timestamptz) language sql stable security definer set search_path='' as $$
 select count(*),max(n.created_at) from public.cb_planning_notifications n
 join public.cb_planning_preferences pref on pref.user_id=n.user_id and pref.email_opt_in and n.category=any(pref.categories)
 join auth.users u on u.id=n.user_id and u.email_confirmed_at is not null
 where n.user_id=p_user and n.read_at is null and n.created_at>p_since and n.created_at<=p_until
 and public.cb_planning_can_view(p_user,n.project_id,n.source_kind,n.source_id)
 and (n.category<>'deadlines'
 or (n.source_kind='task' and exists(select 1 from public.cb_tasks t where t.id=n.source_id and not t.done and t.due_date=n.source_date))
 or (n.source_kind='event' and exists(select 1 from public.cb_project_events e where e.id=n.source_id and e.details->>'date'=n.source_date::text and coalesce(e.details->>'status','') not in ('Completed','Complete'))))
 and (n.kind<>'approval_requested' or exists(select 1 from public.cb_tasks t where t.id=n.source_id and not t.done and t.approval_required and t.approved_by is null and lower(t.approver_email)=lower(u.email)))
 and (n.kind<>'assigned' or exists(select 1 from public.cb_tasks t where t.id=n.source_id and lower(t.assignee_email)=lower(u.email)));
$$;

create or replace function public.cb_process_planning_email() returns jsonb language plpgsql security definer set search_path='' as $$
declare settings public.cb_planning_email_settings; job public.cb_planning_email_jobs; response record; recipient record; summary record;
 api_key text; local_date date; since_at timestamptz; request bigint; body jsonb; html text; text_body text; used_day integer; used_month integer; earliest timestamptz;
begin
 if not pg_try_advisory_xact_lock(hashtextextended('cb-planning-email-worker',0)) then return '{"status":"busy"}';end if;
 if not public.cb_planning_email_ready() then return '{"status":"not_configured"}';end if;
 select * into settings from public.cb_planning_email_settings where singleton for update;
 -- Reconcile responses before dispatching new work. Provider acceptance is not proof of inbox delivery.
 for job in select * from public.cb_planning_email_jobs where state='inflight' for update loop
  select * into response from net._http_response where id=job.request_id;
  if found and response.status_code between 200 and 299 and coalesce(response.error_msg,'')='' and not coalesce(response.timed_out,false) then
   begin body=response.content::jsonb;exception when others then body='{}';end;
   update public.cb_planning_email_jobs set state='accepted',accepted_at=now(),provider_id=body->>'id',last_error=null where id=job.id;
  elsif found or job.last_attempt_at<now()-interval '15 minutes' then
   if job.attempts>=5 or job.first_attempt_at<now()-interval '20 hours' then
    update public.cb_planning_email_jobs set state='uncertain',last_error='Delivery could not be confirmed; automatic retries stopped.' where id=job.id;
   elsif found and response.status_code between 400 and 499 and response.status_code not in (408,409,429) then
    update public.cb_planning_email_jobs set state='failed',last_error='Email provider rejected this request.' where id=job.id;
    if response.status_code in (401,403) then update public.cb_planning_email_settings set enabled=false,last_error='Check the sending key and verified domain.' where singleton;return '{"status":"provider_configuration_error"}';end if;
   else
    update public.cb_planning_email_jobs set state='queued',next_attempt_at=now()+make_interval(mins=>least(60,power(2,job.attempts)::integer)),last_error='Provider response delayed or temporarily unavailable.' where id=job.id;
    if found and response.status_code=429 then update public.cb_planning_email_settings set pause_until=now()+interval '15 minutes',last_error='Provider sending limit reached.' where singleton;end if;
   end if;
  end if;
 end loop;
 -- One new summary per recipient's local calendar day, after 09:00.
 for recipient in select pref.*,u.email from public.cb_planning_preferences pref join auth.users u on u.id=pref.user_id
 where pref.email_opt_in and pref.email_opted_at is not null and u.email_confirmed_at is not null and u.email is not null loop
  if (now() at time zone recipient.time_zone)::time<time '09:00' then continue;end if;
  local_date=(now() at time zone recipient.time_zone)::date;
  select greatest(recipient.email_opted_at,coalesce(max(notice_through),recipient.email_opted_at)) into since_at
  from public.cb_planning_email_jobs where user_id=recipient.user_id and state in ('accepted','inflight','uncertain');
  select * into summary from public.cb_planning_digest_items(recipient.user_id,since_at,now());
  if summary.quantity>0 then
   insert into public.cb_planning_email_jobs(user_id,local_day,notice_through) values(recipient.user_id,local_date,summary.latest) on conflict(user_id,local_day) do nothing;
  end if;
 end loop;
 select count(*) into used_day from public.cb_planning_email_jobs where first_attempt_at>=(date_trunc('day',now() at time zone 'UTC') at time zone 'UTC');
 select count(*) into used_month from public.cb_planning_email_jobs where first_attempt_at>=(date_trunc('month',now() at time zone 'UTC') at time zone 'UTC');
 select min(last_attempt_at) into earliest from public.cb_planning_email_jobs where last_attempt_at>now()-interval '55 seconds';
 if earliest is not null then return '{"status":"paced"}';end if;
 select pause_until into settings.pause_until from public.cb_planning_email_settings where singleton;
 if settings.pause_until>now() then return '{"status":"provider_paused"}';end if;
 select decrypted_secret into api_key from vault.decrypted_secrets where name='cobridey_resend_api_key' limit 1;
 for job in select * from public.cb_planning_email_jobs where state='queued' and next_attempt_at<=now() order by created_at,id for update skip locked loop
  select pref.*,u.email,u.email_confirmed_at into recipient from public.cb_planning_preferences pref join auth.users u on u.id=pref.user_id where pref.user_id=job.user_id;
  if not found or not recipient.email_opt_in or recipient.email_confirmed_at is null or (now() at time zone recipient.time_zone)::date<>job.local_day then
   update public.cb_planning_email_jobs set state='cancelled',last_error='Preferences changed or summary date passed.' where id=job.id;continue;
  end if;
  if (now() at time zone recipient.time_zone)::time<time '09:00' then continue;end if;
  if job.first_attempt_at is not null and (job.attempts>=5 or job.first_attempt_at<now()-interval '20 hours') then
   update public.cb_planning_email_jobs set state='uncertain',last_error='Retry window closed.' where id=job.id;continue;
  end if;
  select * into summary from public.cb_planning_digest_items(job.user_id,recipient.email_opted_at,job.notice_through);
  if summary.quantity=0 or (job.payload is not null and job.payload->'to'->>0 is distinct from recipient.email) then
   update public.cb_planning_email_jobs set state='cancelled',last_error='Updates are read, no longer available, or the email address changed.' where id=job.id;continue;
  end if;
  if job.first_attempt_at is null and (used_day>=settings.daily_limit or used_month>=settings.monthly_limit) then return '{"status":"application_allowance_reached"}';end if;
  if job.payload is null then
   text_body='A little clarity for your day.'||chr(10)||chr(10)||'You have '||summary.quantity||' new unread updates in your shared wedding plans. Sign in to review your assignments, approvals and upcoming dates.'||chr(10)||chr(10)||'Open your updates: https://www.cobridey.com/login.html?next=%2Fcollaborate.html%3Fnotifications%3D1'||chr(10)||'Manage email preferences: https://www.cobridey.com/login.html?next=%2Fcollaborate.html%3Fnotification_preferences%3D1'||chr(10)||chr(10)||'Cobridey · Your Bridal Journey Companion';
   html='<html lang="en"><body style="margin:0;padding:32px 16px;background:#faf7f5;color:#111;font-family:Arial,sans-serif"><div style="max-width:540px;margin:auto;background:#fff;border-radius:22px;overflow:hidden;border-top:7px solid #c60063"><div style="padding:34px"><p style="font-size:25px;font-weight:bold;margin:0 0 30px">Cobridey<span style="color:#c60063">.</span></p><p style="color:#9c0050;font-size:11px;font-weight:bold;letter-spacing:2px">YOUR DAILY PLANNING SUMMARY</p><h1 style="font-size:30px;line-height:1.2;letter-spacing:-1px">A little clarity for your day.</h1><p style="font-size:16px;line-height:1.8">You have <strong>'||summary.quantity||' new unread updates</strong> in your shared wedding plans. Your assignments, approvals and upcoming dates are waiting in your inbox.</p><a href="https://www.cobridey.com/login.html?next=%2Fcollaborate.html%3Fnotifications%3D1" style="display:inline-block;padding:16px 22px;background:#c60063;color:#fff;text-decoration:none;border-radius:12px;font-weight:bold">Open my updates</a><p style="font-size:13px;line-height:1.8;margin-top:28px">Your wedding details stay inside your account. Sign in to see the latest information.</p><p style="font-size:12px;line-height:1.8">Cobridey · Your Bridal Journey Companion<br>You enabled daily planning summaries in Cobridey.<br><a href="https://www.cobridey.com/login.html?next=%2Fcollaborate.html%3Fnotification_preferences%3D1" style="color:#9c0050">Manage email preferences</a></p></div></div></body></html>';
   body=jsonb_build_object('from','Cobridey <'||settings.sender||'>','to',jsonb_build_array(recipient.email),'subject','Your Cobridey planning summary','html',html,'text',text_body);
  else body=job.payload;end if;
  request=net.http_post(url:='https://api.resend.com/emails',body:=body,headers:=jsonb_build_object('Authorization','Bearer '||api_key,'Content-Type','application/json','Idempotency-Key','cobridey-planning/'||job.id),timeout_milliseconds:=10000);
  update public.cb_planning_email_jobs set state='inflight',payload=body,request_id=request,first_attempt_at=coalesce(first_attempt_at,now()),last_attempt_at=now(),attempts=attempts+1 where id=job.id;
  return jsonb_build_object('status','submitted','job_id',job.id);
 end loop;
 return '{"status":"idle"}';
end; $$;
revoke all on function public.cb_planning_email_ready(),public.cb_planning_email_status(),public.cb_set_planning_delivery(text[],text,boolean),
 public.cb_planning_digest_items(uuid,timestamptz,timestamptz),public.cb_process_planning_email() from public,anon,authenticated;
grant execute on function public.cb_planning_email_status(),public.cb_set_planning_delivery(text[],text,boolean) to authenticated;
do $setup$
begin
 if exists(select 1 from pg_available_extensions where name='pg_net') then create extension if not exists pg_net;end if;
 if exists(select 1 from pg_extension where extname='pg_cron') then
  perform cron.schedule('cb-planning-email','* * * * *','select public.cb_process_planning_email();');
 end if;
end; $setup$;
notify pgrst,'reload schema';
commit;
