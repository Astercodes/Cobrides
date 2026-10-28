-- Private appointment scheduling. Run after private-care.sql. No provider bookings or messages are sent.
begin;
create table if not exists public.cb_care_appointments(user_id uuid not null references auth.users on delete cascade,scope text not null,project_ref text not null,appointment_ref text not null,data jsonb not null,source jsonb not null,starts_at timestamptz,ends_at timestamptz,revision bigint not null default 1,updated_at timestamptz not null default now(),primary key(user_id,scope,project_ref,appointment_ref));
create table if not exists public.cb_care_appointment_writes(user_id uuid not null,client uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client));
create table if not exists public.cb_care_appointment_history(user_id uuid not null,scope text not null,project_ref text not null,appointment_ref text not null,revision bigint not null,snapshot jsonb not null,at timestamptz not null default now(),primary key(user_id,scope,project_ref,appointment_ref,revision));
alter table public.cb_care_appointments enable row level security;alter table public.cb_care_appointment_writes enable row level security;alter table public.cb_care_appointment_history enable row level security;
revoke all on public.cb_care_appointments,public.cb_care_appointment_writes,public.cb_care_appointment_history from public,anon,authenticated;
create or replace function public.cb_care_appointment_source(p_scope text,p_project text,p_ref text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;anchor jsonb;date_value text;begin
 r=public.cb_care_record(p_scope,'preparationRecords',p_ref);
 if r is null or r->>'projectId' is distinct from p_project or r->>'space' is distinct from 'beauty' or r->>'kind' is distinct from 'Appointment' or coalesce((r->>'archived')::boolean,false) or r->>'status'='Cancelled' then return null;end if;
 date_value=coalesce(r->>'date','');
 if r->>'scheduleMode'='Relative' then
  anchor=public.cb_care_record(p_scope,case when coalesce(r->>'eventId','')<>'' then 'events' else 'projects' end,coalesce(nullif(r->>'eventId',''),p_project));
  if coalesce(anchor->>'date','')<>'' and (coalesce(r->>'eventId','')='' or anchor->>'projectId'=p_project) then date_value=((anchor->>'date')::date-coalesce((r->>'daysBefore')::integer,0))::text;else date_value='';end if;
 end if;
 return jsonb_build_object('title',coalesce(r->>'title',''),'date',date_value,'time',coalesce(r->>'time',''),'provider',coalesce(r->>'providerId',''),'location',coalesce(r->>'location',''));
end;$$;
create or replace function public.cb_private_appointments(p_scope text,p_project text) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or p_scope not in ('personal','demo') or p_scope is null then raise exception 'Sign in to open appointments' using errcode='42501';end if;
 return jsonb_build_object('project',p_project,'scope',p_scope,'appointments',(select coalesce(jsonb_agg(to_jsonb(a)-'user_id'||jsonb_build_object('needs_review',public.cb_care_appointment_source(p_scope,p_project,a.appointment_ref) is distinct from a.source) order by a.starts_at nulls last,a.appointment_ref),'[]') from public.cb_care_appointments a where user_id=auth.uid() and scope=p_scope and project_ref=p_project));
end;$$;
create or replace function public.cb_save_private_appointment(p_scope text,p_project text,p_ref text,p_revision bigint,p_client uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare src jsonb;old public.cb_care_appointment_writes;a public.cb_care_appointments;payload jsonb;result jsonb;start_time timestamptz;end_time timestamptz;duration integer;zone text;status text;
begin
 if auth.uid() is null or p_scope not in ('personal','demo') or p_scope is null then raise exception 'Sign in to save appointments' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':care-appointments',0));
 perform 1 from public.cb_workspace_states where user_id=auth.uid() and workspace='bride' for update;
 src=public.cb_care_appointment_source(p_scope,p_project,p_ref);
 -- A cancelled source can still have its existing calendar booking cancelled.
 if src is null and not coalesce((p_data->>'status'='Cancelled' and public.cb_care_record(p_scope,'preparationRecords',p_ref)->>'projectId'=p_project),false) then raise exception 'Save an active beauty appointment first' using errcode='42501';end if;
 if p_client is null or p_revision is null or p_revision<0 then raise exception 'Review appointment details';end if;
 payload=jsonb_build_object('scope',p_scope,'project',p_project,'ref',p_ref,'revision',p_revision,'data',p_data);
 select * into old from public.cb_care_appointment_writes where user_id=auth.uid() and client=p_client;if found then if old.payload is distinct from payload then raise exception 'Retry the original appointment details' using errcode='PT409';end if;return old.response;end if;
 if jsonb_typeof(p_data) is distinct from 'object' or p_data-array['minutes','zone','status','reference']::text[]<>'{}' or coalesce(p_data->>'minutes','')!~'^[0-9]{1,3}$' or jsonb_typeof(p_data->'reference') is distinct from 'string' or length(p_data->>'reference')>250 then raise exception 'Review appointment duration and booking reference';end if;
 duration=(p_data->>'minutes')::integer;zone=p_data->>'zone';status=p_data->>'status';
 if duration not between 15 and 480 or status not in ('Draft','Confirmed','Attended','Cancelled') or status is null or not exists(select 1 from pg_timezone_names where name=zone) then raise exception 'Choose a valid duration, time zone and status';end if;
 select * into a from public.cb_care_appointments where user_id=auth.uid() and scope=p_scope and project_ref=p_project and appointment_ref=p_ref for update;
 if coalesce(a.revision,0)<>p_revision then raise exception 'Another device updated this appointment. Refresh first.' using errcode='PT409';end if;
 if src is null then if a.revision is null then raise exception 'Appointment unavailable' using errcode='42501';end if;src=a.source;end if;
 if coalesce(src->>'date','')<>'' and coalesce(src->>'time','')~'^([01][0-9]|2[0-3]):[0-5][0-9]$' then
  start_time=((src->>'date')||' '||(src->>'time'))::timestamp at time zone zone;
  if to_char(start_time at time zone zone,'YYYY-MM-DD HH24:MI')<>(src->>'date')||' '||(src->>'time') then raise exception 'That local time does not exist because of a clock change. Choose another time.';end if;
  end_time=start_time+duration*interval '1 minute';
 elsif status in ('Confirmed','Attended') then raise exception 'Add a date and time to your appointment first';end if;
 if status='Attended' and start_time>now() then raise exception 'Mark attendance after the appointment has started';end if;
 if status='Confirmed' and exists(select 1 from public.cb_care_appointments x where x.user_id=auth.uid() and x.scope=p_scope and not (x.project_ref=p_project and x.appointment_ref=p_ref) and x.data->>'status'='Confirmed' and x.source is not distinct from public.cb_care_appointment_source(x.scope,x.project_ref,x.appointment_ref) and x.starts_at<end_time and x.ends_at>start_time) then raise exception 'This overlaps another confirmed personal appointment. Choose another time.' using errcode='PT409';end if;
 insert into public.cb_care_appointments(user_id,scope,project_ref,appointment_ref,data,source,starts_at,ends_at) values(auth.uid(),p_scope,p_project,p_ref,p_data,src,start_time,end_time) on conflict(user_id,scope,project_ref,appointment_ref) do update set data=excluded.data,source=excluded.source,starts_at=excluded.starts_at,ends_at=excluded.ends_at,revision=cb_care_appointments.revision+1,updated_at=now() returning * into a;
 result=to_jsonb(a)-'user_id';insert into public.cb_care_appointment_writes values(auth.uid(),p_client,payload,result);insert into public.cb_care_appointment_history values(auth.uid(),p_scope,p_project,p_ref,a.revision,result,now());return result;
end;$$;
revoke all on function public.cb_care_appointment_source(text,text,text),public.cb_private_appointments(text,text),public.cb_save_private_appointment(text,text,text,bigint,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.cb_private_appointments(text,text),public.cb_save_private_appointment(text,text,text,bigint,uuid,jsonb) to authenticated;
notify pgrst,'reload schema';commit;
