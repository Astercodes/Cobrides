-- Private beauty routine check-ins. Existing appointment/routine records remain in owner workspace storage.
begin;
create table if not exists public.cb_care_days(user_id uuid not null references auth.users on delete cascade,scope text not null check(scope in ('personal','demo')),project_ref text not null,routine_ref text not null,day date not null,steps jsonb not null,completed boolean not null,revision bigint not null default 1,updated_at timestamptz not null default now(),primary key(user_id,scope,project_ref,routine_ref,day));
create table if not exists public.cb_care_writes(user_id uuid not null,client uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client));
create table if not exists public.cb_care_history(user_id uuid not null,scope text not null,project_ref text not null,routine_ref text not null,day date not null,revision bigint not null,snapshot jsonb not null,at timestamptz not null default now(),primary key(user_id,scope,project_ref,routine_ref,day,revision));
alter table public.cb_care_days enable row level security;alter table public.cb_care_writes enable row level security;alter table public.cb_care_history enable row level security;
revoke all on public.cb_care_days,public.cb_care_writes,public.cb_care_history from public,anon,authenticated;
create or replace function public.cb_care_record(p_scope text,p_collection text,p_ref text) returns jsonb language sql stable security definer set search_path='' as $$
 select body->'value' from public.cb_workspace_records where user_id=auth.uid() and workspace='bride' and to_revision is null and body->>'kind'='item' and body->'value'->>'id'=p_ref and (body->'path'=jsonb_build_array(p_scope,p_collection) or p_scope='personal' and body->'path'=jsonb_build_array(p_collection)) order by jsonb_array_length(body->'path') desc limit 1;
$$;
create or replace function public.cb_private_care_days(p_scope text,p_project text) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or p_scope not in ('personal','demo') or p_scope is null then raise exception 'Sign in to open your routines' using errcode='42501';end if;
 return jsonb_build_object('project',p_project,'scope',p_scope,'days',(select coalesce(jsonb_agg(to_jsonb(d)-'user_id' order by d.day,d.routine_ref),'[]') from public.cb_care_days d where user_id=auth.uid() and scope=p_scope and project_ref=p_project and day>=current_date-91 and public.cb_care_record(p_scope,'preparationRecords',routine_ref)->>'projectId'=p_project));
end;$$;
create or replace function public.cb_save_care_day(p_scope text,p_project text,p_routine text,p_day date,p_zone text,p_steps jsonb,p_definition jsonb,p_completed boolean,p_revision bigint,p_client uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;anchor jsonb;old public.cb_care_writes;d public.cb_care_days;payload jsonb;result jsonb;today date;start_date date;step jsonb;all_steps jsonb;
begin
 if auth.uid() is null or p_scope not in ('personal','demo') or p_scope is null then raise exception 'Sign in to save your routine' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':'||p_scope||':'||p_project||':'||p_routine,0));
 perform 1 from public.cb_workspace_states where user_id=auth.uid() and workspace='bride' for update;
 if not exists(select 1 from pg_timezone_names where name=p_zone) then raise exception 'Choose a valid time zone';end if;
 today=(now() at time zone p_zone)::date;
 if p_client is null or p_day is null or p_day>today or p_day<today-366 or p_revision is null or p_revision<0 or p_completed is null then raise exception 'Use today or a recent past date';end if;
 r=public.cb_care_record(p_scope,'preparationRecords',p_routine);
 if r is null or r->>'projectId' is distinct from p_project or r->>'space' is distinct from 'beauty' or r->>'kind' is distinct from 'Routine' or coalesce((r->>'archived')::boolean,false) or r->>'status' in ('Completed','Cancelled') then raise exception 'Save an active private routine first' using errcode='42501';end if;
 payload=jsonb_build_object('scope',p_scope,'project',p_project,'routine',p_routine,'day',p_day,'zone',p_zone,'steps',p_steps,'definition',p_definition,'completed',p_completed,'revision',p_revision);
 select * into old from public.cb_care_writes where user_id=auth.uid() and client=p_client;if found then if old.payload is distinct from payload then raise exception 'Retry the same check-in' using errcode='PT409';end if;return old.response;end if;
 if jsonb_typeof(p_steps) is distinct from 'array' or jsonb_array_length(p_steps)>30 or coalesce(r->'routineSteps','[]') is distinct from p_definition then raise exception 'Your routine changed. Reload it before checking in.' using errcode='PT409';end if;
 all_steps=coalesce((select jsonb_agg(value->>'id') from jsonb_array_elements(coalesce(r->'routineSteps','[]'))),'[]');
 if (select count(*)<>count(distinct value) from jsonb_array_elements(p_steps)) then raise exception 'Each step can only be selected once';end if;
 for step in select value from jsonb_array_elements(p_steps) loop if jsonb_typeof(step)<>'string' or not all_steps @> jsonb_build_array(step) then raise exception 'Choose steps from this routine';end if;end loop;
 if p_completed and jsonb_array_length(p_steps)<>jsonb_array_length(all_steps) then raise exception 'Complete every routine step before checking in';end if;
 if r->>'scheduleMode'='Relative' then
  anchor=public.cb_care_record(p_scope,case when coalesce(r->>'eventId','')<>'' then 'events' else 'projects' end,coalesce(nullif(r->>'eventId',''),p_project));
  if anchor is null or (coalesce(r->>'eventId','')<>'' and anchor->>'projectId' is distinct from p_project) then raise exception 'Set your routine start date first';end if;
  if coalesce(anchor->>'date','')<>'' then start_date=(anchor->>'date')::date-coalesce((r->>'daysBefore')::integer,0);end if;
 else if coalesce(r->>'date','')<>'' then start_date=(r->>'date')::date;end if;end if;
 if start_date is not null and p_day<start_date then raise exception 'This routine has not started on that date';end if;
 select * into d from public.cb_care_days where user_id=auth.uid() and scope=p_scope and project_ref=p_project and routine_ref=p_routine and day=p_day for update;
 if coalesce(d.revision,0)<>p_revision then raise exception 'Another device updated this routine. Refresh before changing it.' using errcode='PT409';end if;
 insert into public.cb_care_days(user_id,scope,project_ref,routine_ref,day,steps,completed) values(auth.uid(),p_scope,p_project,p_routine,p_day,p_steps,p_completed) on conflict(user_id,scope,project_ref,routine_ref,day) do update set steps=excluded.steps,completed=excluded.completed,revision=cb_care_days.revision+1,updated_at=now() returning * into d;
 result=to_jsonb(d)-'user_id';insert into public.cb_care_writes values(auth.uid(),p_client,payload,result);insert into public.cb_care_history values(auth.uid(),p_scope,p_project,p_routine,p_day,d.revision,result,now());return result;
end;$$;
revoke all on function public.cb_care_record(text,text,text),public.cb_private_care_days(text,text),public.cb_save_care_day(text,text,text,date,text,jsonb,jsonb,boolean,bigint,uuid) from public,anon,authenticated;
grant execute on function public.cb_private_care_days(text,text),public.cb_save_care_day(text,text,text,date,text,jsonb,jsonb,boolean,bigint,uuid) to authenticated;
notify pgrst,'reload schema';commit;
