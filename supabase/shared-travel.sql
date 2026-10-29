-- Explicitly shared honeymoon plans and time-zone-aware itinerary/reservation records.
-- Run after wedding-projects.sql and collaboration access setup. No bookings or messages are sent.
begin;
create table if not exists public.cb_travel_plans(id uuid primary key default gen_random_uuid(),project_id uuid not null references public.cb_projects on delete cascade,owner_id uuid not null references auth.users,data jsonb not null,readers uuid[] not null default '{}',editors uuid[] not null default '{}',archived boolean not null default false,revision bigint not null default 1,updated_at timestamptz not null default now());
create table if not exists public.cb_travel_items(id uuid primary key default gen_random_uuid(),trip_id uuid not null references public.cb_travel_plans on delete cascade,created_by uuid not null references auth.users,data jsonb not null,start_at timestamptz not null,end_at timestamptz not null,revision bigint not null default 1,updated_at timestamptz not null default now(),check(end_at>start_at));
create table if not exists public.cb_travel_writes(user_id uuid not null references auth.users on delete cascade,client uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client));
create table if not exists public.cb_travel_history(kind text not null,target_id uuid not null,revision bigint not null,actor_id uuid not null,snapshot jsonb not null,at timestamptz not null default now(),primary key(kind,target_id,revision));
alter table public.cb_travel_plans enable row level security;alter table public.cb_travel_items enable row level security;alter table public.cb_travel_writes enable row level security;alter table public.cb_travel_history enable row level security;
revoke all on public.cb_travel_plans,public.cb_travel_items,public.cb_travel_writes,public.cb_travel_history from public,anon,authenticated;
create index if not exists cb_travel_project on public.cb_travel_plans(project_id);
create index if not exists cb_travel_item_time on public.cb_travel_items(trip_id,start_at);
create or replace function public.cb_travel_access(p_trip uuid,p_write boolean default false) returns boolean language sql stable security definer set search_path='' as $$select auth.uid() is not null and exists(select 1 from public.cb_travel_plans t where t.id=p_trip and public.cb_project_access(t.project_id,'read') and (t.owner_id=auth.uid() or not t.archived and (auth.uid()=any(t.editors) or not p_write and auth.uid()=any(t.readers))))$$;
create or replace function public.cb_travel_people(p_project uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(public.cb_project_access(p_project,'write') or exists(select 1 from public.cb_travel_plans where project_id=p_project and owner_id=auth.uid() and public.cb_project_access(p_project,'read')),false) then raise exception 'Trip sharing access required' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'name',coalesce(p.full_name,'Wedding collaborator'),'role',u.role) order by coalesce(p.full_name,''),u.id),'[]') from (select owner_id id,'Wedding owner' role from public.cb_projects where id=p_project union select user_id,role from public.cb_members where project_id=p_project and user_id<>(select owner_id from public.cb_projects where id=p_project)) u left join public.cb_profiles p on p.user_id=u.id where u.id<>auth.uid());
end;$$;
create or replace function public.cb_travel_summary(p_trip uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t public.cb_travel_plans;
begin
 if not public.cb_travel_access(p_trip,false) then raise exception 'This trip is private or no longer shared with you' using errcode='42501';end if;
 select * into t from public.cb_travel_plans where id=p_trip;
 return jsonb_build_object('id',t.id,'project',t.project_id,'data',t.data,'revision',t.revision,'archived',t.archived,'owner',t.owner_id=auth.uid(),'can_edit',public.cb_travel_access(t.id,true),'readers',case when t.owner_id=auth.uid() then to_jsonb(t.readers) else '[]' end,'editors',case when t.owner_id=auth.uid() then to_jsonb(t.editors) else '[]' end);
end;$$;
create or replace function public.cb_travel_workspace(p_project uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(public.cb_project_access(p_project,'read'),false) then raise exception 'Wedding access required' using errcode='42501';end if;
 return jsonb_build_object('project',p_project,'can_create',public.cb_project_access(p_project,'write'),'trips',(select coalesce(jsonb_agg(public.cb_travel_summary(t.id) order by t.archived,t.updated_at desc,t.id),'[]') from public.cb_travel_plans t where t.project_id=p_project and public.cb_travel_access(t.id,false)));
end;$$;
create or replace function public.cb_save_travel_plan(p_project uuid,p_id uuid,p_revision bigint,p_client uuid,p_data jsonb,p_readers uuid[],p_editors uuid[],p_archived boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.cb_travel_plans;w public.cb_travel_writes;payload jsonb;result jsonb;k text;v uuid;r uuid[];e uuid[];start_day date;end_day date;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if p_id is null then if not coalesce(public.cb_project_access(p_project,'write'),false) then raise exception 'Planning access required to create a trip' using errcode='42501';end if;
 else select * into t from public.cb_travel_plans where id=p_id and project_id=p_project for update;if t.id is null or not public.cb_travel_access(t.id,true) then raise exception 'Trip editing access required' using errcode='42501';end if;end if;
 payload=jsonb_build_object('action','trip','project',p_project,'id',p_id,'revision',p_revision,'data',p_data,'readers',p_readers,'editors',p_editors,'archived',p_archived);if p_client is null then raise exception 'Request ID required';end if;
 select * into w from public.cb_travel_writes where user_id=auth.uid() and client=p_client;if found then if w.payload is distinct from payload then raise exception 'Retry the original trip details' using errcode='PT409';end if;return w.response;end if;
 if jsonb_typeof(p_data) is distinct from 'object' or p_data-array['title','destination','start','end','zone','notes']::text[]<>'{}' or p_archived is null then raise exception 'Review trip details';end if;
 foreach k in array array['title','destination','start','end','zone','notes'] loop if jsonb_typeof(p_data->k) is distinct from 'string' or length(p_data->>k)>(case k when 'notes' then 2000 when 'destination' then 250 when 'title' then 160 else 100 end) then raise exception 'Review trip text limits';end if;end loop;
 if length(btrim(p_data->>'title'))<1 or not exists(select 1 from pg_timezone_names where name=p_data->>'zone') then raise exception 'Add a trip title and a valid time zone';end if;
 if (p_data->>'start'='') is distinct from (p_data->>'end'='') then raise exception 'Choose both departure and return dates';end if;
 if p_data->>'start'<>'' then
 if p_data->>'start'!~'^\d{4}-\d{2}-\d{2}$' or p_data->>'end'!~'^\d{4}-\d{2}-\d{2}$' then raise exception 'Choose valid travel dates';end if;
 start_day=(p_data->>'start')::date;end_day=(p_data->>'end')::date;if end_day<start_day or end_day-start_day>366 then raise exception 'Return must follow departure, within one year';end if;
 end if;
 if t.id is null or t.owner_id=auth.uid() then
 r=coalesce(p_readers,'{}');e=coalesce(p_editors,'{}');if cardinality(r)>100 or cardinality(e)>100 or array_position(r,null) is not null or array_position(e,null) is not null then raise exception 'Choose up to 100 accepted collaborators per access level';end if;
 foreach v in array r||e loop if v=auth.uid() or not exists(select 1 from public.cb_projects where id=p_project and owner_id=v union all select 1 from public.cb_members where project_id=p_project and user_id=v) then raise exception 'Choose accepted members of this wedding';end if;end loop;
 select coalesce(array_agg(distinct x order by x),'{}') into r from unnest(r) x;select coalesce(array_agg(distinct x order by x),'{}') into e from unnest(e) x;
 else if p_readers is not null or p_editors is not null or p_archived is distinct from t.archived then raise exception 'Only the trip creator controls sharing and archival' using errcode='42501';end if;r=t.readers;e=t.editors;end if;
 if t.id is null then
 if p_revision is distinct from 0::bigint then raise exception 'Refresh before creating a trip' using errcode='PT409';end if;
 if (select count(*) from public.cb_travel_plans where project_id=p_project and owner_id=auth.uid())>=100 then raise exception 'Trip allowance reached';end if;
 insert into public.cb_travel_plans(project_id,owner_id,data,readers,editors,archived) values(p_project,auth.uid(),p_data,r,e,p_archived) returning * into t;
 else
 if t.revision is distinct from p_revision then raise exception 'Another device updated this trip. Refresh first.' using errcode='PT409';end if;
 if exists(select 1 from public.cb_travel_items i where i.trip_id=t.id and i.data->>'status'<>'Cancelled' and start_day is not null and ((i.data->>'start')::date<start_day or (i.data->>'end')::date>end_day or (i.data->>'start')::date>end_day or (i.data->>'end')::date<start_day)) then raise exception 'Update itinerary activities before narrowing the trip dates';end if;
 update public.cb_travel_plans set data=p_data,readers=r,editors=e,archived=p_archived,revision=revision+1,updated_at=now() where id=t.id returning * into t;
 end if;
 result=public.cb_travel_summary(t.id);insert into public.cb_travel_history values('trip',t.id,t.revision,auth.uid(),to_jsonb(t),now());insert into public.cb_travel_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
create or replace function public.cb_travel_itinerary(p_trip uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.cb_travel_access(p_trip,false) then raise exception 'Trip access required' using errcode='42501';end if;
 return jsonb_build_object('trip',public.cb_travel_summary(p_trip),'items',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'data',i.data,'start_at',i.start_at,'end_at',i.end_at,'revision',i.revision,'conflicts',(select count(*) from public.cb_travel_items j where j.trip_id=p_trip and j.id<>i.id and (j.data->>'blocks')::boolean and (i.data->>'blocks')::boolean and j.data->>'status'<>'Cancelled' and i.data->>'status'<>'Cancelled' and j.start_at<i.end_at and j.end_at>i.start_at)) order by i.start_at,i.id),'[]') from public.cb_travel_items i where i.trip_id=p_trip));
end;$$;
create or replace function public.cb_save_travel_item(p_trip uuid,p_trip_revision bigint,p_id uuid,p_revision bigint,p_client uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.cb_travel_plans;i public.cb_travel_items;w public.cb_travel_writes;payload jsonb;result jsonb;k text;a timestamptz;b timestamptz;sa timestamp;sb timestamp;
begin
 select * into t from public.cb_travel_plans where id=p_trip;perform 1 from public.cb_projects where id=t.project_id for update;select * into t from public.cb_travel_plans where id=p_trip for update;
 if not public.cb_travel_access(p_trip,true) or t.archived then raise exception 'Trip editing access required' using errcode='42501';end if;
 payload=jsonb_build_object('action','item','trip',p_trip,'trip_revision',p_trip_revision,'id',p_id,'revision',p_revision,'data',p_data);if p_client is null then raise exception 'Request ID required';end if;
 select * into w from public.cb_travel_writes where user_id=auth.uid() and client=p_client;if found then if w.payload is distinct from payload then raise exception 'Retry the same itinerary details' using errcode='PT409';end if;return w.response;end if;
 if t.revision is distinct from p_trip_revision then raise exception 'Trip details changed. Refresh the itinerary first.' using errcode='PT409';end if;
 if jsonb_typeof(p_data) is distinct from 'object' or p_data-array['title','kind','start','end','startZone','endZone','location','provider','reference','url','notes','status','blocks']::text[]<>'{}' or jsonb_typeof(p_data->'blocks') is distinct from 'boolean' then raise exception 'Review itinerary details';end if;
 foreach k in array array['title','kind','start','end','startZone','endZone','location','provider','reference','url','notes','status'] loop if jsonb_typeof(p_data->k) is distinct from 'string' or length(p_data->>k)>(case k when 'notes' then 2000 when 'url' then 2000 when 'location' then 250 when 'title' then 160 else 120 end) then raise exception 'Review itinerary text limits';end if;end loop;
 if length(btrim(p_data->>'title'))<1 or p_data->>'kind' not in ('Flight','Stay','Transfer','Experience','Meal','Travel task') or p_data->>'status' not in ('Planned','Booked externally','Confirmed externally','Complete','Cancelled') then raise exception 'Choose an itinerary title, category and status';end if;
 if p_data->>'url'<>'' and (p_data->>'url' !~ '^https://[^[:space:]]+$' or p_data->>'url' ~ '^https://[^/]*@') then raise exception 'Use a secure provider link';end if;
 if p_data->>'start'!~'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$' or p_data->>'end'!~'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$' or not exists(select 1 from pg_timezone_names where name=p_data->>'startZone') or not exists(select 1 from pg_timezone_names where name=p_data->>'endZone') then raise exception 'Choose local start/end times and valid time zones';end if;
 sa=(p_data->>'start')::timestamp;sb=(p_data->>'end')::timestamp;a=sa at time zone (p_data->>'startZone');b=sb at time zone (p_data->>'endZone');
 if to_char(a at time zone (p_data->>'startZone'),'YYYY-MM-DD"T"HH24:MI')<>p_data->>'start' or to_char(b at time zone (p_data->>'endZone'),'YYYY-MM-DD"T"HH24:MI')<>p_data->>'end' then raise exception 'A local time does not exist because of a clock change. Choose another time.';end if;
 if p_data->>'status'='Complete' and p_data->>'kind'<>'Travel task' and a>now() then raise exception 'Mark the activity complete after it begins';end if;
 if b<=a or b-a>interval '366 days' then raise exception 'End time must follow start time, within one year';end if;
 if t.data->>'start'<>'' and p_data->>'status'<>'Cancelled' and (sa::date<(t.data->>'start')::date or sb::date>(t.data->>'end')::date or sa::date>(t.data->>'end')::date or sb::date<(t.data->>'start')::date) then raise exception 'Keep the activity inside the trip dates';end if;
 if p_id is not null then select * into i from public.cb_travel_items where id=p_id and trip_id=p_trip for update;if i.id is null then raise exception 'Itinerary item unavailable' using errcode='42501';end if;end if;
 if coalesce(i.revision,0) is distinct from p_revision then raise exception 'Another device updated this activity. Refresh first.' using errcode='PT409';end if;
 if (p_data->>'blocks')::boolean and p_data->>'status' in ('Booked externally','Confirmed externally') and exists(select 1 from public.cb_travel_items x where x.trip_id=p_trip and (p_id is null or x.id<>p_id) and (x.data->>'blocks')::boolean and x.data->>'status' in ('Booked externally','Confirmed externally') and x.start_at<b and x.end_at>a) then raise exception 'This overlaps another confirmed activity. Review the times or mark a parallel plan as not reserving this time.' using errcode='PT409';end if;
 if p_id is null then if (select count(*) from public.cb_travel_items where trip_id=p_trip)>=2000 then raise exception 'Itinerary allowance reached';end if;insert into public.cb_travel_items(trip_id,created_by,data,start_at,end_at) values(p_trip,auth.uid(),p_data,a,b) returning * into i;
 else update public.cb_travel_items set data=p_data,start_at=a,end_at=b,revision=revision+1,updated_at=now() where id=i.id returning * into i;end if;
 result=to_jsonb(i);insert into public.cb_travel_history values('item',i.id,i.revision,auth.uid(),result,now());insert into public.cb_travel_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
revoke all on function public.cb_travel_access(uuid,boolean),public.cb_travel_people(uuid),public.cb_travel_summary(uuid),public.cb_travel_workspace(uuid),public.cb_save_travel_plan(uuid,uuid,bigint,uuid,jsonb,uuid[],uuid[],boolean),public.cb_travel_itinerary(uuid),public.cb_save_travel_item(uuid,bigint,uuid,bigint,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.cb_travel_people(uuid),public.cb_travel_workspace(uuid),public.cb_save_travel_plan(uuid,uuid,bigint,uuid,jsonb,uuid[],uuid[],boolean),public.cb_travel_itinerary(uuid),public.cb_save_travel_item(uuid,bigint,uuid,bigint,uuid,jsonb) to authenticated;
notify pgrst,'reload schema';commit;
