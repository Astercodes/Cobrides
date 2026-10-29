-- Home moving, delivery, installation and utility appointment coordination.
-- Run after shared-home.sql and home-properties.sql. No supplier booking or receipt is inferred.
begin;
create table if not exists public.cb_home_appointments(id uuid primary key default gen_random_uuid(),home_id uuid not null references public.cb_home_plans on delete cascade,item_id uuid not null references public.cb_home_items on delete restrict,coordinator uuid references auth.users,data jsonb not null,start_at timestamptz not null,end_at timestamptz not null,revision bigint not null default 1,updated_at timestamptz not null default now(),check(end_at>start_at));
create index if not exists cb_home_appointment_window on public.cb_home_appointments(home_id,start_at,end_at);
alter table public.cb_home_appointments enable row level security;revoke all on public.cb_home_appointments from public,anon,authenticated;
create or replace function public.cb_home_schedule(p_home uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare detail jsonb;begin
 if not public.cb_home_access(p_home,false) then raise exception 'Home access required' using errcode='42501';end if;
 detail=public.cb_home_detail(p_home);
 return detail||jsonb_build_object('appointments',(select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'item',a.item_id,'coordinator',a.coordinator,'data',a.data,'start_at',a.start_at,'end_at',a.end_at,'revision',a.revision,'viewing_conflicts',(select count(*) from public.cb_home_viewings v join public.cb_home_properties p on p.id=v.property_id where p.home_id=p_home and v.data->>'status' in ('Scheduled','Confirmed') and a.data->>'status' in ('Planned','Confirmed') and v.start_at<a.end_at and v.end_at>a.start_at)) order by a.start_at,a.id),'[]') from public.cb_home_appointments a where a.home_id=p_home));end;$$;
create or replace function public.cb_save_home_appointment(p_home uuid,p_home_revision bigint,p_item uuid,p_item_revision bigint,p_id uuid,p_revision bigint,p_client uuid,p_data jsonb,p_coordinator uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare h public.cb_home_plans;i public.cb_home_items;r public.cb_home_appointments;w public.cb_home_writes;payload jsonb;result jsonb;k text;a timestamptz;b timestamptz;sa timestamp;sb timestamp;begin
 select * into h from public.cb_home_plans where id=p_home;perform 1 from public.cb_projects where id=h.project_id for update;select * into h from public.cb_home_plans where id=p_home for update;
 if not public.cb_home_access(p_home,true) or h.archived then raise exception 'Home editing access required' using errcode='42501';end if;
 payload=jsonb_build_object('action','home-appointment','home',p_home,'home_revision',p_home_revision,'item',p_item,'item_revision',p_item_revision,'id',p_id,'revision',p_revision,'data',p_data,'coordinator',p_coordinator);
 if p_client is null then raise exception 'Request ID required';end if;
 select * into w from public.cb_home_writes where user_id=auth.uid() and client=p_client;if found then if w.payload is distinct from payload then raise exception 'Retry the same arrival-window details' using errcode='PT409';end if;return w.response;end if;
 if h.revision is distinct from p_home_revision then raise exception 'Home sharing or details changed. Refresh first.' using errcode='PT409';end if;
 select * into i from public.cb_home_items where id=p_item and home_id=p_home for update;if i.id is null then raise exception 'Choose an item from this home plan' using errcode='42501';end if;
 if i.revision is distinct from p_item_revision then raise exception 'Household item changed. Review it again.' using errcode='PT409';end if;
 if p_id is not null then select * into r from public.cb_home_appointments where id=p_id and home_id=p_home and item_id=i.id for update;if r.id is null then raise exception 'Appointment unavailable' using errcode='42501';end if;end if;
 if coalesce(r.revision,0) is distinct from p_revision then raise exception 'Another device updated this appointment. Refresh first.' using errcode='PT409';end if;
 if jsonb_typeof(p_data) is distinct from 'object' or p_data-array['title','kind','start','end','zone','status','contact','address','notes']::text[]<>'{}' then raise exception 'Review appointment fields';end if;
 foreach k in array array['title','kind','start','end','zone','status','contact','address','notes'] loop if jsonb_typeof(p_data->k) is distinct from 'string' or length(p_data->>k)>(case when k='notes' then 2000 when k in ('contact','address') then 250 else 160 end) then raise exception 'Review appointment text limits';end if;end loop;
 if length(btrim(p_data->>'title'))<1 or p_data->>'kind' not in ('Moving','Delivery','Installation','Utility visit','Maintenance') or p_data->>'status' not in ('Planned','Confirmed','Completed','Cancelled') then raise exception 'Choose appointment title, type and status';end if;
 if i.data->>'status'='Cancelled' and p_data->>'status' in ('Planned','Confirmed') then raise exception 'Reopen this household item before scheduling a visit';end if;
 if p_coordinator is not null and (not exists(select 1 from public.cb_projects where id=h.project_id and owner_id=p_coordinator union all select 1 from public.cb_members where project_id=h.project_id and user_id=p_coordinator) or not (p_coordinator=h.owner_id or p_coordinator=any(h.readers||h.editors))) then raise exception 'Choose an accepted coordinator with access to this home';end if;
 if p_data->>'start'!~'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$' or p_data->>'end'!~'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$' or not exists(select 1 from pg_timezone_names where name=p_data->>'zone') then raise exception 'Choose local arrival times and a valid time zone';end if;
 sa=(p_data->>'start')::timestamp;sb=(p_data->>'end')::timestamp;a=sa at time zone (p_data->>'zone');b=sb at time zone (p_data->>'zone');
 if to_char(a at time zone (p_data->>'zone'),'YYYY-MM-DD"T"HH24:MI')<>p_data->>'start' or to_char(b at time zone (p_data->>'zone'),'YYYY-MM-DD"T"HH24:MI')<>p_data->>'end' then raise exception 'This local time does not exist because of a clock change';end if;
 if b<=a or b-a>interval '24 hours' then raise exception 'Arrival-window end must follow its start, within 24 hours';end if;
 if p_data->>'status'='Completed' and a>now() then raise exception 'Complete the appointment after it begins';end if;
 if p_data->>'status' in ('Planned','Confirmed') and exists(select 1 from public.cb_home_appointments x where x.home_id=p_home and (p_id is null or x.id<>p_id) and x.data->>'status' in ('Planned','Confirmed') and x.start_at<b and x.end_at>a and (x.item_id=i.id or p_coordinator is not null and x.coordinator=p_coordinator)) then raise exception 'This item or coordinator already has an overlapping appointment in this home plan.' using errcode='PT409';end if;
 if r.id is null then if (select count(*) from public.cb_home_appointments where home_id=p_home)>=2000 then raise exception 'Home appointment allowance reached';end if;insert into public.cb_home_appointments(home_id,item_id,coordinator,data,start_at,end_at) values(p_home,i.id,p_coordinator,p_data,a,b) returning * into r;
 else update public.cb_home_appointments set data=p_data,coordinator=p_coordinator,start_at=a,end_at=b,revision=revision+1,updated_at=now() where id=r.id returning * into r;end if;
 result=jsonb_build_object('id',r.id,'item',r.item_id,'coordinator',r.coordinator,'data',r.data,'start_at',r.start_at,'end_at',r.end_at,'revision',r.revision);insert into public.cb_home_history values('appointment',r.id,r.revision,auth.uid(),to_jsonb(r),now());insert into public.cb_home_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
revoke all on function public.cb_home_schedule(uuid),public.cb_save_home_appointment(uuid,bigint,uuid,bigint,uuid,bigint,uuid,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.cb_home_schedule(uuid),public.cb_save_home_appointment(uuid,bigint,uuid,bigint,uuid,bigint,uuid,jsonb,uuid) to authenticated;
notify pgrst,'reload schema';commit;
