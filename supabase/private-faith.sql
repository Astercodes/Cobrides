-- Owner-only prayer, devotional and scripture check-ins. No team access or public activity.
-- Run after workspace-records.sql. Existing notes, prayers and vows stay in private account storage.
begin;
create table if not exists public.cb_faith_plan_states(user_id uuid not null references auth.users on delete cascade,scope text not null check(scope in ('personal','demo')),project_ref text not null,plan_ref text not null,plan_start date not null,plan_type text not null check(plan_type in ('Prayer','Devotional','Bible')),legacy_checkins jsonb not null default '[]',created_at timestamptz not null default now(),primary key(user_id,scope,project_ref,plan_ref,plan_start,plan_type));
create table if not exists public.cb_faith_days(user_id uuid not null,scope text not null,project_ref text not null,plan_ref text not null,plan_start date not null,plan_type text not null,day_index integer not null check(day_index between 1 and 90),completed boolean not null,revision bigint not null default 1,updated_at timestamptz not null default now(),primary key(user_id,scope,project_ref,plan_ref,plan_start,plan_type,day_index),foreign key(user_id,scope,project_ref,plan_ref,plan_start,plan_type) references public.cb_faith_plan_states on delete cascade);
create table if not exists public.cb_faith_writes(user_id uuid not null references auth.users on delete cascade,client uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client));
create table if not exists public.cb_faith_day_history(user_id uuid not null references auth.users on delete cascade,scope text not null,project_ref text not null,plan_ref text not null,plan_start date not null,plan_type text not null,day_index integer not null,revision bigint not null,snapshot jsonb not null,at timestamptz not null default now(),primary key(user_id,scope,project_ref,plan_ref,plan_start,plan_type,day_index,revision));
alter table public.cb_faith_plan_states enable row level security;alter table public.cb_faith_days enable row level security;alter table public.cb_faith_writes enable row level security;alter table public.cb_faith_day_history enable row level security;
revoke all on public.cb_faith_plan_states,public.cb_faith_days,public.cb_faith_writes,public.cb_faith_day_history from public,anon,authenticated;
create or replace function public.cb_faith_source(p_scope text,p_project text,p_plan text,p_start date,p_type text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;begin
 if auth.uid() is null or p_scope is null or p_scope not in ('personal','demo') then raise exception 'Sign in to open your private plan' using errcode='42501';end if;
 if length(coalesce(p_project,'')) not between 1 and 200 or length(coalesce(p_plan,'')) not between 1 and 200 or p_start is null or p_type is null or p_type not in ('Prayer','Devotional','Bible') then raise exception 'Choose a saved daily plan and valid start date';end if;
 select body->'value' into r from public.cb_workspace_records where user_id=auth.uid() and workspace='bride' and to_revision is null and body->>'kind'='item' and body->'value'->>'id'=p_plan and (body->'path'=jsonb_build_array(p_scope,'faithRecords') or p_scope='personal' and body->'path'=jsonb_build_array('faithRecords')) order by jsonb_array_length(body->'path') desc limit 1;
 if r is null or r->>'projectId' is distinct from p_project or r->>'dailyPlanType' is distinct from p_type or r->>'kind' is distinct from (case when p_type='Bible' then 'Scripture & reading' else 'Prayer & devotional plan' end) then raise exception 'Save this private daily plan first' using errcode='42501';end if;
 if r->>'date' is distinct from p_start::text then raise exception 'The plan start date changed on another device. Refresh your workspace first.' using errcode='PT409';end if;
 return r;end;$$;
create or replace function public.cb_faith_plan_progress(p_scope text,p_project text,p_plan text,p_start date,p_type text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;begin
 r=public.cb_faith_source(p_scope,p_project,p_plan,p_start,p_type);
 return jsonb_build_object('scope',p_scope,'project',p_project,'plan',p_plan,'start',p_start,'type',p_type,'editable',not coalesce((r->>'archived')::boolean,false) and coalesce(r->>'status','Planned') not in ('Complete','Cancelled','Paused'),'days',(select coalesce(jsonb_agg(jsonb_build_object('day',d.day_index,'date',d.plan_start+d.day_index-1,'completed',d.completed,'revision',d.revision) order by d.day_index),'[]') from public.cb_faith_days d where d.user_id=auth.uid() and d.scope=p_scope and d.project_ref=p_project and d.plan_ref=p_plan and d.plan_start=p_start and d.plan_type=p_type));end;$$;
create or replace function public.cb_prepare_faith_plan(p_scope text,p_project text,p_plan text,p_start date,p_type text,p_zone text) returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;legacy jsonb;v jsonb;d date;n integer;today date;lim integer;row public.cb_faith_days;begin
 if auth.uid() is null then raise exception 'Sign in to open your private plan' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':'||p_scope||':'||p_project||':'||p_plan,0));perform 1 from public.cb_workspace_states where user_id=auth.uid() and workspace='bride' for update;
 r=public.cb_faith_source(p_scope,p_project,p_plan,p_start,p_type);
 if p_zone is null or not exists(select 1 from pg_timezone_names where name=p_zone) then raise exception 'Choose a valid time zone';end if;today=(now() at time zone p_zone)::date;lim=case when p_type='Devotional' then 30 else 90 end;
 if not exists(select 1 from public.cb_faith_plan_states where user_id=auth.uid() and scope=p_scope and project_ref=p_project and plan_ref=p_plan and plan_start=p_start and plan_type=p_type) then
 legacy=case when exists(select 1 from public.cb_faith_plan_states where user_id=auth.uid() and scope=p_scope and project_ref=p_project and plan_ref=p_plan and plan_type=p_type) then '[]'::jsonb when jsonb_typeof(r->'checkins')='array' then r->'checkins' else '[]'::jsonb end;
 insert into public.cb_faith_plan_states(user_id,scope,project_ref,plan_ref,plan_start,plan_type,legacy_checkins) values(auth.uid(),p_scope,p_project,p_plan,p_start,p_type,legacy);
 for v in select distinct value from jsonb_array_elements(legacy) loop
 if jsonb_typeof(v)='string' and v #>> '{}' ~ '^\d{4}-\d{2}-\d{2}$' then
 begin d=(v #>> '{}')::date;exception when datetime_field_overflow or invalid_datetime_format then continue;end;
 n=d-p_start+1;if n between 1 and lim and d<=today then
 insert into public.cb_faith_days(user_id,scope,project_ref,plan_ref,plan_start,plan_type,day_index,completed) values(auth.uid(),p_scope,p_project,p_plan,p_start,p_type,n,true) returning * into row;
 insert into public.cb_faith_day_history values(auth.uid(),p_scope,p_project,p_plan,p_start,p_type,n,row.revision,jsonb_build_object('origin','Previous progress','completed',true),now());
 end if;end if;end loop;
 end if;
 return public.cb_faith_plan_progress(p_scope,p_project,p_plan,p_start,p_type);end;$$;
create or replace function public.cb_save_faith_day(p_scope text,p_project text,p_plan text,p_start date,p_type text,p_day integer,p_zone text,p_completed boolean,p_revision bigint,p_client uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;prepared jsonb;old public.cb_faith_writes;d public.cb_faith_days;payload jsonb;result jsonb;today date;begin
 if auth.uid() is null then raise exception 'Sign in to save your private progress' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':'||p_scope||':'||p_project||':'||p_plan,0));perform 1 from public.cb_workspace_states where user_id=auth.uid() and workspace='bride' for update;
 r=public.cb_faith_source(p_scope,p_project,p_plan,p_start,p_type);
 if coalesce((r->>'archived')::boolean,false) or coalesce(r->>'status','Planned') in ('Complete','Cancelled','Paused') then raise exception 'Resume your private plan before changing progress' using errcode='42501';end if;
 payload=jsonb_build_object('scope',p_scope,'project',p_project,'plan',p_plan,'start',p_start,'type',p_type,'day',p_day,'zone',p_zone,'completed',p_completed,'revision',p_revision);
 if p_client is null then raise exception 'Request ID required';end if;
 select * into old from public.cb_faith_writes where user_id=auth.uid() and client=p_client;if found then if old.payload is distinct from payload then raise exception 'Retry the same daily check-in' using errcode='PT409';end if;return old.response;end if;
 if p_zone is null or not exists(select 1 from pg_timezone_names where name=p_zone) then raise exception 'Choose a valid time zone';end if;today=(now() at time zone p_zone)::date;
 if p_day is null or p_day<1 or p_day>(case when p_type='Devotional' then 30 else 90 end) or p_start+p_day-1>today or p_completed is null or p_revision is null or p_revision<0 then raise exception 'Choose today or a past day within this plan';end if;
 prepared=public.cb_prepare_faith_plan(p_scope,p_project,p_plan,p_start,p_type,p_zone);
 select * into d from public.cb_faith_days where user_id=auth.uid() and scope=p_scope and project_ref=p_project and plan_ref=p_plan and plan_start=p_start and plan_type=p_type and day_index=p_day for update;
 if coalesce(d.revision,0)<>p_revision then raise exception 'Another device updated this day. Refresh before changing it.' using errcode='PT409';end if;
 insert into public.cb_faith_days(user_id,scope,project_ref,plan_ref,plan_start,plan_type,day_index,completed) values(auth.uid(),p_scope,p_project,p_plan,p_start,p_type,p_day,p_completed) on conflict(user_id,scope,project_ref,plan_ref,plan_start,plan_type,day_index) do update set completed=excluded.completed,revision=cb_faith_days.revision+1,updated_at=now() returning * into d;
 result=jsonb_build_object('day',p_day,'date',p_start+p_day-1,'completed',d.completed,'revision',d.revision);insert into public.cb_faith_writes values(auth.uid(),p_client,payload,result);insert into public.cb_faith_day_history values(auth.uid(),p_scope,p_project,p_plan,p_start,p_type,p_day,d.revision,result,now());return result;
end;$$;
revoke all on function public.cb_faith_source(text,text,text,date,text),public.cb_faith_plan_progress(text,text,text,date,text),public.cb_prepare_faith_plan(text,text,text,date,text,text),public.cb_save_faith_day(text,text,text,date,text,integer,text,boolean,bigint,uuid) from public,anon,authenticated;
grant execute on function public.cb_prepare_faith_plan(text,text,text,date,text,text),public.cb_save_faith_day(text,text,text,date,text,integer,text,boolean,bigint,uuid) to authenticated;
notify pgrst,'reload schema';commit;
