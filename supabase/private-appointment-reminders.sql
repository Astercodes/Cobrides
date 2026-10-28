-- Private appointment reminders. Run after private-appointments.sql and shopping-notifications.sql.
-- Uses the existing Resend sender, shared sending allowance and signed delivery webhook.
begin;
create table if not exists public.cb_care_reminder_settings(
 id uuid not null unique default gen_random_uuid(),user_id uuid not null references auth.users on delete cascade,
 scope text not null check(scope in ('personal','demo')),project_ref text not null,appointment_ref text not null,
 minutes integer not null default 1440 check(minutes in (15,30,60,180,1440,2880,10080)),
 in_app boolean not null default false,email boolean not null default false,revision bigint not null default 1,
 updated_at timestamptz not null default now(),primary key(user_id,scope,project_ref,appointment_ref));
create table if not exists public.cb_care_reminder_writes(user_id uuid not null references auth.users on delete cascade,client uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client));
alter table public.cb_care_reminder_settings enable row level security;alter table public.cb_care_reminder_writes enable row level security;
revoke all on public.cb_care_reminder_settings,public.cb_care_reminder_writes from public,anon,authenticated;
-- Explicit owner lookup for scheduled workers, never callable by a client.
create or replace function public.cb_care_owner_record(p_user uuid,p_scope text,p_collection text,p_ref text) returns jsonb language sql stable security definer set search_path='' as $$
 select body->'value' from public.cb_workspace_records where user_id=p_user and workspace='bride' and to_revision is null and body->>'kind'='item' and body->'value'->>'id'=p_ref and (body->'path'=jsonb_build_array(p_scope,p_collection) or p_scope='personal' and body->'path'=jsonb_build_array(p_collection)) order by jsonb_array_length(body->'path') desc limit 1;
$$;
create or replace function public.cb_care_owner_source(p_user uuid,p_scope text,p_project text,p_ref text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;p jsonb;anchor jsonb;d text;
begin
 p=public.cb_care_owner_record(p_user,p_scope,'projects',p_project);
 if p is null or coalesce((p->>'archived')::boolean,false) or coalesce(p->>'archiveStatus','') like 'Archived%' then return null;end if;
 r=public.cb_care_owner_record(p_user,p_scope,'preparationRecords',p_ref);
 if r is null or r->>'projectId' is distinct from p_project or r->>'space' is distinct from 'beauty' or r->>'kind' is distinct from 'Appointment' or coalesce((r->>'archived')::boolean,false) or r->>'status' in ('Cancelled','Completed','Complete') then return null;end if;
 d=coalesce(r->>'date','');
 if r->>'scheduleMode'='Relative' then
  anchor=case when coalesce(r->>'eventId','')='' then p else public.cb_care_owner_record(p_user,p_scope,'events',r->>'eventId') end;
  if coalesce(anchor->>'date','')<>'' and (coalesce(r->>'eventId','')='' or anchor->>'projectId'=p_project) then d=((anchor->>'date')::date-coalesce((r->>'daysBefore')::integer,0))::text;else d='';end if;
 end if;
 return jsonb_build_object('title',coalesce(r->>'title',''),'date',d,'time',coalesce(r->>'time',''),'provider',coalesce(r->>'providerId',''),'location',coalesce(r->>'location',''));
exception when invalid_text_representation or datetime_field_overflow or invalid_datetime_format or numeric_value_out_of_range then return null;
end;$$;
create or replace function public.cb_care_reminder_current(p_user uuid,p_id uuid,p_kind text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_care_reminder_settings s join public.cb_care_appointments a on (a.user_id,a.scope,a.project_ref,a.appointment_ref)=(s.user_id,s.scope,s.project_ref,s.appointment_ref)
 where s.user_id=p_user and s.id=p_id and (s.in_app or s.email) and a.data->>'status'='Confirmed' and a.starts_at>now()
 and a.starts_at-make_interval(mins=>s.minutes)<=now() and a.source is not distinct from public.cb_care_owner_source(s.user_id,s.scope,s.project_ref,s.appointment_ref)
 and p_kind='care:'||a.revision||':'||s.revision);
$$;
create or replace function public.cb_private_reminder_settings(p_scope text,p_project text,p_ref text) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or p_scope not in ('personal','demo') or p_scope is null or public.cb_care_record(p_scope,'preparationRecords',p_ref)->>'projectId' is distinct from p_project then raise exception 'Open your own appointment first' using errcode='42501';end if;
 return jsonb_build_object('ready',exists(select 1 from public.cb_care_appointments a where a.user_id=auth.uid() and a.scope=p_scope and a.project_ref=p_project and a.appointment_ref=p_ref and a.data->>'status'='Confirmed' and a.starts_at>now() and a.source is not distinct from public.cb_care_owner_source(auth.uid(),p_scope,p_project,p_ref)),'settings',(select to_jsonb(s)-'user_id' from public.cb_care_reminder_settings s where user_id=auth.uid() and scope=p_scope and project_ref=p_project and appointment_ref=p_ref),'email_available',public.cb_planning_email_ready(),'email_blocked',exists(select 1 from public.cb_planning_preferences p join auth.users u on u.id=p.user_id where p.user_id=auth.uid() and lower(p.suppressed_email)=lower(u.email)),'scheduled',exists(select 1 from pg_extension where extname='pg_cron'));
end;$$;
create or replace function public.cb_save_private_reminders(p_scope text,p_project text,p_ref text,p_revision bigint,p_client uuid,p_minutes integer,p_in_app boolean,p_email boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.cb_care_reminder_settings;a public.cb_care_appointments;old public.cb_care_reminder_writes;payload jsonb;result jsonb;
begin
 if auth.uid() is null or p_scope not in ('personal','demo') or p_scope is null then raise exception 'Sign in to save reminders' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':care-appointments',0));
 perform 1 from public.cb_workspace_states where user_id=auth.uid() and workspace='bride' for update;
 if p_client is null or p_revision is null or p_revision<0 or p_minutes is null or p_minutes not in (15,30,60,180,1440,2880,10080) or p_in_app is null or p_email is null then raise exception 'Review your reminder settings';end if;
 payload=jsonb_build_object('scope',p_scope,'project',p_project,'ref',p_ref,'revision',p_revision,'minutes',p_minutes,'in_app',p_in_app,'email',p_email);
 select * into old from public.cb_care_reminder_writes where user_id=auth.uid() and client=p_client;
 if found then if old.payload is distinct from payload then raise exception 'Retry the original reminder settings' using errcode='PT409';end if;return old.response;end if;
 select * into a from public.cb_care_appointments where user_id=auth.uid() and scope=p_scope and project_ref=p_project and appointment_ref=p_ref for update;
 if a.revision is null or public.cb_care_record(p_scope,'preparationRecords',p_ref)->>'projectId' is distinct from p_project then raise exception 'Save an active appointment first' using errcode='42501';end if;
 if (p_in_app or p_email) and (a.data->>'status'<>'Confirmed' or a.starts_at<=now() or a.starts_at is null or a.source is distinct from public.cb_care_owner_source(auth.uid(),p_scope,p_project,p_ref)) then raise exception 'Confirm your current appointment date, time and time zone first';end if;
 if p_email then
  if p_scope='demo' then raise exception 'Email reminders are available for your personal appointments';end if;
  if not public.cb_planning_email_ready() then raise exception 'Email reminders are unavailable right now';end if;
  if not exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null) then raise exception 'Verify your email address first';end if;
  if exists(select 1 from public.cb_planning_preferences p join auth.users u on u.id=p.user_id where p.user_id=auth.uid() and lower(p.suppressed_email)=lower(u.email)) then raise exception 'Email is paused for this address after a delivery problem';end if;
 end if;
 select * into s from public.cb_care_reminder_settings where user_id=auth.uid() and scope=p_scope and project_ref=p_project and appointment_ref=p_ref for update;
 if coalesce(s.revision,0)<>p_revision then raise exception 'Another device updated these reminders. Reopen to review.' using errcode='PT409';end if;
 insert into public.cb_planning_preferences(user_id) values(auth.uid()) on conflict do nothing;
 insert into public.cb_care_reminder_settings(user_id,scope,project_ref,appointment_ref,minutes,in_app,email) values(auth.uid(),p_scope,p_project,p_ref,p_minutes,p_in_app,p_email)
 on conflict(user_id,scope,project_ref,appointment_ref) do update set minutes=excluded.minutes,in_app=excluded.in_app,email=excluded.email,revision=cb_care_reminder_settings.revision+1,updated_at=now() returning * into s;
 result=to_jsonb(s)-'user_id';insert into public.cb_care_reminder_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
-- Private notices have no shared-project relation. Shared notices still require a project.
alter table public.cb_planning_notifications alter column project_id drop not null;
alter table public.cb_planning_notifications drop constraint if exists cb_planning_notifications_source_kind_check;
alter table public.cb_planning_notifications add constraint cb_planning_notifications_source_kind_check check(source_kind in ('project','event','task','decision','chat','expense','contribution','vendor_work','shopping','private_care'));
alter table public.cb_planning_notifications drop constraint if exists cb_planning_private_project_check;
alter table public.cb_planning_notifications add constraint cb_planning_private_project_check check((source_kind='private_care' and project_id is null) or (source_kind<>'private_care' and project_id is not null));
alter table public.cb_planning_email_jobs add column if not exists care_notice_id uuid references public.cb_planning_notifications on delete cascade;
alter table public.cb_planning_email_jobs drop constraint if exists cb_planning_email_jobs_user_id_local_day_key;
create unique index if not exists cb_planning_digest_day on public.cb_planning_email_jobs(user_id,local_day) where care_notice_id is null;
create unique index if not exists cb_planning_care_notice on public.cb_planning_email_jobs(care_notice_id) where care_notice_id is not null;
do $wrap$ begin
 if to_regprocedure('public.cb_planning_can_view_before_private_care(uuid,uuid,text,uuid)') is null then alter function public.cb_planning_can_view(uuid,uuid,text,uuid) rename to cb_planning_can_view_before_private_care;end if;
 if to_regprocedure('public.cb_planning_notice_visible_before_private_care(uuid,text,uuid,date,text,text)') is null then alter function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) rename to cb_planning_notice_visible_before_private_care;end if;
 if to_regprocedure('public.cb_generate_planning_reminders_before_private_care(uuid)') is null then alter function public.cb_generate_planning_reminders(uuid) rename to cb_generate_planning_reminders_before_private_care;end if;
end;$wrap$;
create or replace function public.cb_planning_can_view(p_user uuid,p_project uuid,p_kind text,p_source uuid) returns boolean language sql stable security definer set search_path='' as $$select case when p_kind='private_care' then exists(select 1 from public.cb_care_reminder_settings s join public.cb_care_appointments a on (a.user_id,a.scope,a.project_ref,a.appointment_ref)=(s.user_id,s.scope,s.project_ref,s.appointment_ref) where s.id=p_source and s.user_id=p_user) else public.cb_planning_can_view_before_private_care(p_user,p_project,p_kind,p_source) end$$;
create or replace function public.cb_planning_notice_visible(p_project uuid,p_kind text,p_source uuid,p_date date,p_category text,p_notice_kind text) returns boolean language sql stable security definer set search_path='' as $$select case when p_kind='private_care' then public.cb_care_reminder_current(auth.uid(),p_source,p_notice_kind) and exists(select 1 from public.cb_care_reminder_settings where id=p_source and user_id=auth.uid() and in_app) else public.cb_planning_notice_visible_before_private_care(p_project,p_kind,p_source,p_date,p_category,p_notice_kind) end$$;
drop policy if exists planning_inbox_own on public.cb_planning_notifications;
create policy planning_inbox_own on public.cb_planning_notifications for select to authenticated using(user_id=auth.uid() and public.cb_planning_notice_visible(project_id,source_kind,source_id,source_date,category,kind));
create or replace function public.cb_generate_care_reminders(p_user uuid default null) returns integer language plpgsql security definer set search_path='' as $$
declare s record;nid uuid;n integer:=0;
begin
 for s in select pref.*,a.starts_at,a.data->>'zone' zone,'care:'||a.revision||':'||pref.revision token from public.cb_care_reminder_settings pref join public.cb_care_appointments a on (a.user_id,a.scope,a.project_ref,a.appointment_ref)=(pref.user_id,pref.scope,pref.project_ref,pref.appointment_ref)
 where (p_user is null or pref.user_id=p_user) and (pref.in_app or pref.email) and a.data->>'status'='Confirmed' and a.starts_at>now() and a.starts_at-make_interval(mins=>pref.minutes)<=now() and a.source is not distinct from public.cb_care_owner_source(pref.user_id,pref.scope,pref.project_ref,pref.appointment_ref) loop
  insert into public.cb_planning_notifications(user_id,project_id,category,kind,source_kind,source_id,source_date,title,body,dedupe_key)
  values(s.user_id,null,'schedule',s.token,'private_care',s.id,(s.starts_at at time zone s.zone)::date,'Your private appointment is coming up','Open your personal preparation space to review the time and details.','private-care:'||s.id||':'||s.token)
  on conflict(user_id,dedupe_key) do nothing;
  n=n+1;
  select id into nid from public.cb_planning_notifications where user_id=s.user_id and dedupe_key='private-care:'||s.id||':'||s.token;
  if s.email and s.scope='personal' then insert into public.cb_planning_email_jobs(user_id,local_day,notice_through,care_notice_id) values(s.user_id,(s.starts_at at time zone s.zone)::date,now(),nid) on conflict(care_notice_id) where care_notice_id is not null do nothing;end if;
 end loop;return n;
end;$$;
create or replace function public.cb_generate_planning_reminders(p_user uuid default null) returns integer language plpgsql security definer set search_path='' as $$begin return public.cb_generate_planning_reminders_before_private_care(p_user)+public.cb_generate_care_reminders(p_user);end;$$;
create or replace function public.cb_care_email_valid(p_user uuid,p_notice uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_planning_notifications n join public.cb_care_reminder_settings s on s.id=n.source_id join auth.users u on u.id=n.user_id left join public.cb_planning_preferences p on p.user_id=u.id where n.id=p_notice and n.user_id=p_user and n.source_kind='private_care' and s.user_id=p_user and s.email and s.scope='personal' and u.email_confirmed_at is not null and u.email is not null and lower(coalesce(p.suppressed_email,''))<>lower(u.email) and public.cb_care_reminder_current(p_user,s.id,n.kind));
$$;
create or replace function public.cb_care_notice_target(p_notice uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare s public.cb_care_reminder_settings;
begin
 select pref.* into s from public.cb_care_reminder_settings pref join public.cb_planning_notifications n on n.source_id=pref.id where n.id=p_notice and n.user_id=auth.uid() and pref.user_id=auth.uid() and n.source_kind='private_care' and public.cb_care_reminder_current(auth.uid(),pref.id,n.kind);
 if not found then raise exception 'This reminder is no longer current' using errcode='42501';end if;
 return jsonb_build_object('project',s.project_ref,'scope',s.scope,'appointment',s.appointment_ref);
end;$$;
-- Private reminders have their own opted-in email jobs, never enter shared digests.
do $digest$ declare body text;begin body=pg_get_functiondef('public.cb_planning_digest_items(uuid,timestamptz,timestamptz)'::regprocedure);if strpos(body,'n.source_kind<>''private_care''')=0 then body=replace(body,'where n.user_id=p_user','where n.source_kind<>''private_care'' and n.user_id=p_user');execute body;end if;end;$digest$;

-- Reuses the existing paced, quota-controlled sender and signed delivery receipts.
create or replace function public.cb_process_planning_email() returns jsonb language plpgsql security definer set search_path='' as $$
declare settings public.cb_planning_email_settings; job public.cb_planning_email_jobs; response record; recipient record; summary record;
 api_key text; local_date date; since_at timestamptz; request bigint; body jsonb; html text; text_body text; used_day integer; used_month integer; earliest timestamptz;
begin
 if not pg_try_advisory_xact_lock(hashtextextended('cb-planning-email-worker',0)) then return '{"status":"busy"}';end if;
 perform public.cb_generate_care_reminders();
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
  from public.cb_planning_email_jobs where user_id=recipient.user_id and care_notice_id is null and state in ('accepted','inflight','uncertain');
  select * into summary from public.cb_planning_digest_items(recipient.user_id,since_at,now());
  if summary.quantity>0 then
   insert into public.cb_planning_email_jobs(user_id,local_day,notice_through) values(recipient.user_id,local_date,summary.latest) on conflict(user_id,local_day) where care_notice_id is null do nothing;
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
  if job.care_notice_id is not null then
   perform pg_advisory_xact_lock(hashtextextended(job.user_id::text||':care-appointments',0));
   perform 1 from public.cb_workspace_states where user_id=job.user_id and workspace='bride' for update;
   perform 1 from public.cb_care_appointments a join public.cb_care_reminder_settings s on (a.user_id,a.scope,a.project_ref,a.appointment_ref)=(s.user_id,s.scope,s.project_ref,s.appointment_ref) join public.cb_planning_notifications n on n.source_id=s.id where n.id=job.care_notice_id and a.user_id=job.user_id for update of a,s;
  end if;
  select pref.*,u.email,u.email_confirmed_at into recipient from public.cb_planning_preferences pref join auth.users u on u.id=pref.user_id where pref.user_id=job.user_id;
  if not found or recipient.email_confirmed_at is null or lower(coalesce(recipient.suppressed_email,''))=lower(recipient.email) or (job.care_notice_id is null and (not recipient.email_opt_in or (now() at time zone recipient.time_zone)::date<>job.local_day)) or (job.care_notice_id is not null and not public.cb_care_email_valid(job.user_id,job.care_notice_id)) then
   update public.cb_planning_email_jobs set state='cancelled',last_error='Preferences changed or summary date passed.' where id=job.id;continue;
  end if;
  if job.care_notice_id is null and (now() at time zone recipient.time_zone)::time<time '09:00' then continue;end if;
  if job.first_attempt_at is not null and (job.attempts>=5 or job.first_attempt_at<now()-interval '20 hours') then
   update public.cb_planning_email_jobs set state='uncertain',last_error='Retry window closed.' where id=job.id;continue;
  end if;
  if job.care_notice_id is null then select * into summary from public.cb_planning_digest_items(job.user_id,recipient.email_opted_at,job.notice_through);else select 1::bigint quantity into summary;end if;
  if summary.quantity=0 or (job.payload is not null and job.payload->'to'->>0 is distinct from recipient.email) then
   update public.cb_planning_email_jobs set state='cancelled',last_error='Updates are read, no longer available, or the email address changed.' where id=job.id;continue;
  end if;
  if job.first_attempt_at is null and (used_day>=settings.daily_limit or used_month>=settings.monthly_limit) then return '{"status":"application_allowance_reached"}';end if;
  if job.payload is null and job.care_notice_id is not null then
   text_body='Your private appointment is coming up.'||chr(10)||chr(10)||'Sign in to review its time and details: https://www.cobridey.com/journey.html?care_notice='||job.care_notice_id||'#preparation'||chr(10)||chr(10)||'Manage reminders in Beauty & Self-care > Appointment details > Reminders.'||chr(10)||'Cobridey · Your Bridal Journey Companion';
   html='<html lang="en"><body style="margin:0;padding:32px 16px;background:#faf7f5;color:#111;font-family:Arial,sans-serif"><div style="max-width:540px;margin:auto;background:#fff;border-radius:20px;border-top:6px solid #c4471c;padding:32px"><p style="font-size:26px;font-weight:bold">Cobridey</p><h1 style="font-size:28px">A little time for yourself.</h1><p style="font-size:16px;line-height:1.8">Your private appointment is coming up. Sign in to review its time and details.</p><a href="https://www.cobridey.com/journey.html?care_notice='||job.care_notice_id||'#preparation" style="display:inline-block;padding:15px 22px;background:#bf285e;border-radius:12px;color:#fff;text-decoration:none">View my appointment</a><p style="font-size:12px;line-height:1.8;margin-top:28px">You enabled this reminder. Change or turn it off in Beauty & Self-care → Appointment details → Reminders.<br>Cobridey · Your Bridal Journey Companion</p></div></body></html>';
   body=jsonb_build_object('from','Cobridey <'||settings.sender||'>','to',jsonb_build_array(recipient.email),'subject','Your private Cobridey appointment reminder','html',html,'text',text_body);
  elsif job.payload is null then
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
-- Keep the daily-summary status separate from individual appointment reminders.
do $status$ declare body text;begin body=pg_get_functiondef('public.cb_planning_email_status()'::regprocedure);body=replace(body,'where user_id=auth.uid() order by created_at','where user_id=auth.uid() and care_notice_id is null order by created_at');execute body;end;$status$;
-- Turning off daily shared summaries does not change a separately chosen private reminder.
do $delivery$ declare body text;begin body=pg_get_functiondef('public.cb_set_planning_delivery(text[],text,boolean)'::regprocedure);body=replace(body,'where user_id=auth.uid() and state=''queued'';','where user_id=auth.uid() and state=''queued'' and care_notice_id is null;');execute body;end;$delivery$;
revoke all on function public.cb_care_owner_record(uuid,text,text,text),public.cb_care_owner_source(uuid,text,text,text),public.cb_care_reminder_current(uuid,uuid,text),public.cb_generate_care_reminders(uuid),public.cb_care_email_valid(uuid,uuid),public.cb_private_reminder_settings(text,text,text),public.cb_save_private_reminders(text,text,text,bigint,uuid,integer,boolean,boolean),public.cb_care_notice_target(uuid),public.cb_planning_can_view(uuid,uuid,text,uuid),public.cb_planning_can_view_before_private_care(uuid,uuid,text,uuid),public.cb_planning_notice_visible_before_private_care(uuid,text,uuid,date,text,text),public.cb_generate_planning_reminders_before_private_care(uuid),public.cb_generate_planning_reminders(uuid),public.cb_process_planning_email() from public,anon,authenticated;
grant execute on function public.cb_private_reminder_settings(text,text,text),public.cb_save_private_reminders(text,text,text,bigint,uuid,integer,boolean,boolean),public.cb_care_notice_target(uuid) to authenticated;
revoke all on function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) from public,anon;
grant execute on function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) to authenticated;
-- Rebind callers to the current permission wrappers, preserving prior notification categories.
do $refresh$ declare signature text;body text;begin foreach signature in array array['public.cb_queue_planning_notice(uuid,uuid,text,text,text,uuid,date,text,text,text)','public.cb_planning_inbox()','public.cb_read_planning_notifications(uuid,boolean)'] loop body=pg_get_functiondef(to_regprocedure(signature));execute body;end loop;end;$refresh$;
do $cron$ begin if exists(select 1 from pg_extension where extname='pg_cron') then perform cron.schedule('cb-private-care-reminders','* * * * *','select public.cb_generate_care_reminders();');end if;end;$cron$;
notify pgrst,'reload schema';commit;
