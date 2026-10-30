-- Private spiritual counseling/class attendance. No counselor or team access is introduced.
begin;
create table if not exists public.cb_faith_classes(user_id uuid not null references auth.users on delete cascade,scope text not null,project_ref text not null,record_ref text not null,schedule text not null,definition jsonb not null,legacy_checkins jsonb not null default '[]',primary key(user_id,scope,project_ref,record_ref,schedule));
create table if not exists public.cb_faith_attendance(user_id uuid not null,scope text not null,project_ref text not null,record_ref text not null,schedule text not null,session integer not null check(session between 1 and 12),completed boolean not null,revision bigint not null default 1,primary key(user_id,scope,project_ref,record_ref,schedule,session),foreign key(user_id,scope,project_ref,record_ref,schedule) references public.cb_faith_classes on delete cascade);
create table if not exists public.cb_faith_attendance_writes(user_id uuid not null references auth.users on delete cascade,client uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client));
create table if not exists public.cb_faith_attendance_history(user_id uuid not null references auth.users on delete cascade,scope text not null,project_ref text not null,record_ref text not null,schedule text not null,session integer not null,revision bigint not null,snapshot jsonb not null,at timestamptz not null default now(),primary key(user_id,scope,project_ref,record_ref,schedule,session,revision));
alter table public.cb_faith_classes enable row level security;alter table public.cb_faith_attendance enable row level security;alter table public.cb_faith_attendance_writes enable row level security;alter table public.cb_faith_attendance_history enable row level security;
revoke all on public.cb_faith_classes,public.cb_faith_attendance,public.cb_faith_attendance_writes,public.cb_faith_attendance_history from public,anon,authenticated;
create or replace function public.cb_faith_class_definition(r jsonb) returns jsonb language plpgsql immutable set search_path='' as $$
declare d date;t time;every integer;begin
 if coalesce(r->>'date','')!~'^\d{4}-\d{2}-\d{2}$' or coalesce(r->>'time','')<>'' and r->>'time'!~'^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(r->>'interval','0')!~'^[0-9]{1,3}$' then return null;end if;
 begin d=(r->>'date')::date;t=nullif(r->>'time','')::time;every=coalesce(r->>'interval','0')::integer;exception when datetime_field_overflow or invalid_datetime_format then return null;end;
 if every>365 then return null;end if;return jsonb_build_object('date',d,'time',coalesce(r->>'time',''),'interval',every);end;$$;
create or replace function public.cb_prepare_faith_classes(p_scope text,p_project text,p_zone text) returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;def jsonb;sig text;legacy jsonb;results jsonb='[]';sessions jsonb;n integer;day date;row public.cb_faith_attendance;begin
 if auth.uid() is null or p_scope is null or p_scope not in ('personal','demo') then raise exception 'Sign in to open private classes' using errcode='42501';end if;
 if length(coalesce(p_project,'')) not between 1 and 200 or not exists(select 1 from pg_timezone_names where name=p_zone) then raise exception 'Choose a project and valid time zone';end if;
 perform 1 from public.cb_workspace_states where user_id=auth.uid() and workspace='bride' for update;
 for r in select x.value from (select distinct on (body->'value'->>'id') body->'value' value from public.cb_workspace_records where user_id=auth.uid() and workspace='bride' and to_revision is null and body->>'kind'='item' and (body->'path'=jsonb_build_array(p_scope,'faithRecords') or p_scope='personal' and body->'path'=jsonb_build_array('faithRecords')) order by body->'value'->>'id',jsonb_array_length(body->'path') desc) x where x.value->>'projectId'=p_project and x.value->>'kind'='Counseling & classes' loop
 def=public.cb_faith_class_definition(r);if def is null then results=results||jsonb_build_array(jsonb_build_object('record',r->>'id','error','Choose a valid start date, time and repeat interval to track this class.','sessions','[]'::jsonb));continue;end if;sig=md5(def::text);
 if not exists(select 1 from public.cb_faith_classes where user_id=auth.uid() and scope=p_scope and project_ref=p_project and record_ref=r->>'id' and schedule=sig) then
 legacy=case when exists(select 1 from public.cb_faith_classes where user_id=auth.uid() and scope=p_scope and project_ref=p_project and record_ref=r->>'id') then '[]'::jsonb when jsonb_typeof(r->'checkins')='array' then r->'checkins' else '[]'::jsonb end;
 insert into public.cb_faith_classes values(auth.uid(),p_scope,p_project,r->>'id',sig,def,legacy);
 for n in 1..(case when (def->>'interval')::integer>0 then 12 else 1 end) loop
 day=(def->>'date')::date+(n-1)*(def->>'interval')::integer;
 if legacy @> jsonb_build_array(day::text) and day+coalesce(nullif(def->>'time','')::time,time '00:00') <=now() at time zone p_zone then
 insert into public.cb_faith_attendance values(auth.uid(),p_scope,p_project,r->>'id',sig,n,true,1) returning * into row;
 insert into public.cb_faith_attendance_history values(auth.uid(),p_scope,p_project,r->>'id',sig,n,1,jsonb_build_object('completed',true,'origin','Previous attendance'),now());end if;end loop;end if;
 select coalesce(jsonb_agg(jsonb_build_object('number',series.n,'date',(def->>'date')::date+(series.n-1)*(def->>'interval')::integer,'time',def->>'time','completed',coalesce(a.completed,false),'revision',coalesce(a.revision,0)) order by series.n),'[]') into sessions from generate_series(1,case when (def->>'interval')::integer>0 then 12 else 1 end) series(n) left join public.cb_faith_attendance a on a.user_id=auth.uid() and a.scope=p_scope and a.project_ref=p_project and a.record_ref=r->>'id' and a.schedule=sig and a.session=series.n;
 results=results||jsonb_build_array(jsonb_build_object('record',r->>'id','schedule',sig,'editable',not coalesce((r->>'archived')::boolean,false) and coalesce(r->>'status','Planned') not in ('Complete','Cancelled','Paused'),'sessions',sessions));
 end loop;return jsonb_build_object('scope',p_scope,'project',p_project,'classes',results);end;$$;
create or replace function public.cb_save_faith_attendance(p_scope text,p_project text,p_record text,p_schedule text,p_session integer,p_zone text,p_completed boolean,p_revision bigint,p_client uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare prepared jsonb;c jsonb;s jsonb;old public.cb_faith_attendance_writes;a public.cb_faith_attendance;payload jsonb;result jsonb;begin
 prepared=public.cb_prepare_faith_classes(p_scope,p_project,p_zone);
 select value into c from jsonb_array_elements(prepared->'classes') where value->>'record'=p_record;
 if c is null or not coalesce((c->>'editable')::boolean,false) then raise exception 'Save an active private class first' using errcode='42501';end if;
 if c->>'schedule' is distinct from p_schedule then raise exception 'This class schedule changed. Refresh before recording attendance.' using errcode='PT409';end if;
 payload=jsonb_build_object('scope',p_scope,'project',p_project,'record',p_record,'schedule',p_schedule,'session',p_session,'zone',p_zone,'completed',p_completed,'revision',p_revision);if p_client is null then raise exception 'Request ID required';end if;
 select * into old from public.cb_faith_attendance_writes where user_id=auth.uid() and client=p_client;if found then if old.payload is distinct from payload then raise exception 'Retry the same attendance update' using errcode='PT409';end if;return old.response;end if;
 select value into s from jsonb_array_elements(c->'sessions') where (value->>'number')::integer=p_session;
 if s is null or p_completed is null or p_revision is null or p_revision<0 then raise exception 'Choose a session from this class';end if;
 if ((s->>'date')::date+coalesce(nullif(s->>'time','')::time,time '00:00'))>now() at time zone p_zone then raise exception 'Record attendance after the session begins';end if;
 select * into a from public.cb_faith_attendance where user_id=auth.uid() and scope=p_scope and project_ref=p_project and record_ref=p_record and schedule=p_schedule and session=p_session for update;
 if coalesce(a.revision,0)<>p_revision then raise exception 'Another device updated attendance. Refresh before changing it.' using errcode='PT409';end if;
 insert into public.cb_faith_attendance values(auth.uid(),p_scope,p_project,p_record,p_schedule,p_session,p_completed,1) on conflict(user_id,scope,project_ref,record_ref,schedule,session) do update set completed=excluded.completed,revision=cb_faith_attendance.revision+1 returning * into a;
 result=jsonb_build_object('record',p_record,'schedule',p_schedule,'number',p_session,'completed',a.completed,'revision',a.revision);insert into public.cb_faith_attendance_writes values(auth.uid(),p_client,payload,result);insert into public.cb_faith_attendance_history values(auth.uid(),p_scope,p_project,p_record,p_schedule,p_session,a.revision,result,now());return result;
end;$$;
revoke all on function public.cb_faith_class_definition(jsonb),public.cb_prepare_faith_classes(text,text,text),public.cb_save_faith_attendance(text,text,text,text,integer,text,boolean,bigint,uuid) from public,anon,authenticated;
grant execute on function public.cb_prepare_faith_classes(text,text,text),public.cb_save_faith_attendance(text,text,text,text,integer,text,boolean,bigint,uuid) to authenticated;
notify pgrst,'reload schema';commit;
