-- Shared venue profiles, celebration arrangements and viewing appointments.
begin;
create table if not exists public.cb_venue_records(
 id uuid primary key default gen_random_uuid(),vendor_id uuid not null references public.cb_shared_vendors on delete cascade,
 event_id uuid references public.cb_project_events on delete restrict,kind text not null check(kind in ('Profile','Celebration','Viewing')),
 data jsonb not null,revision bigint not null default 1,created_by uuid not null references auth.users,updated_at timestamptz not null default now()
);
create unique index if not exists cb_venue_profile_unique on public.cb_venue_records(vendor_id) where kind='Profile';
create unique index if not exists cb_venue_event_unique on public.cb_venue_records(vendor_id,event_id) where kind='Celebration';
create index if not exists cb_venue_vendor_index on public.cb_venue_records(vendor_id);
create table if not exists public.cb_venue_writes(user_id uuid not null references auth.users,client_id uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client_id));
create table if not exists public.cb_venue_versions(record_id uuid not null references public.cb_venue_records on delete cascade,revision bigint not null,actor_id uuid not null references auth.users,snapshot jsonb not null,at timestamptz not null default now(),primary key(record_id,revision));
alter table public.cb_venue_records enable row level security;alter table public.cb_venue_writes enable row level security;alter table public.cb_venue_versions enable row level security;
revoke all on public.cb_venue_records,public.cb_venue_writes,public.cb_venue_versions from public,anon,authenticated;
create or replace function public.cb_venue_workspace(p_vendor uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v public.cb_shared_vendors;
begin
 if not public.cb_shared_vendor_access(p_vendor) then raise exception 'Venue access denied' using errcode='42501';end if;
 select * into v from public.cb_shared_vendors where id=p_vendor;
 return jsonb_build_object('project',v.project_id,'vendor',v.name,'editable',not v.archived and public.cb_project_access(v.project_id,'write') and exists(select 1 from public.cb_projects where id=v.project_id and archived_at is null),
 'bookings',(select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'title',b.title,'status',b.status)),'[]') from public.cb_vendor_bookings b where b.vendor_id=v.id),
 'events',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'title',e.title) order by e.title),'[]') from public.cb_project_events e where e.project_id=v.project_id and public.cb_project_event_access(e.id)),
 'items',(select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('event_title',(select title from public.cb_project_events where id=r.event_id),'history',(select coalesce(jsonb_agg(jsonb_build_object('revision',h.revision,'at',h.at) order by h.revision desc),'[]') from public.cb_venue_versions h where h.record_id=r.id)) order by r.updated_at desc,r.id),'[]') from public.cb_venue_records r where r.vendor_id=v.id and (r.event_id is null or public.cb_project_event_access(r.event_id))));
end;$$;
create or replace function public.cb_save_venue_record(p_vendor uuid,p_id uuid,p_event uuid,p_kind text,p_revision bigint,p_client uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.cb_shared_vendors;r public.cb_venue_records;prior public.cb_venue_writes;payload jsonb;result jsonb;k text;val text;start_at timestamp;end_at timestamp;
begin
 select * into v from public.cb_shared_vendors where id=p_vendor;perform 1 from public.cb_projects where id=v.project_id for update;
 if not coalesce(public.cb_shared_vendor_access(v.id) and public.cb_project_access(v.project_id,'write') and not v.archived and exists(select 1 from public.cb_projects where id=v.project_id and archived_at is null),false) then raise exception 'Venue planning access required' using errcode='42501';end if;
 if p_event is not null and not exists(select 1 from public.cb_project_events where id=p_event and project_id=v.project_id and public.cb_project_event_access(id)) then raise exception 'Choose an accessible celebration from this wedding' using errcode='42501';end if;
 payload=jsonb_build_object('vendor',p_vendor,'id',p_id,'event',p_event,'kind',p_kind,'revision',p_revision,'data',p_data);
 if p_client is null then raise exception 'Save request ID required';end if;
 select * into prior from public.cb_venue_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prior.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prior.response;end if;
 if p_kind is null or p_kind not in ('Profile','Celebration','Viewing') or (p_kind='Celebration' and p_event is null) or (p_kind='Profile' and p_event is not null) then raise exception 'Choose a valid venue record and celebration';end if;
 if jsonb_typeof(p_data) is distinct from 'object' or octet_length(p_data::text)>18000 or p_data-array['title','capacity','expectedGuests','layout','facilities','accessibility','address','requirements','availability','verification','date','start','end','timeZone','contact','notes','bookingId']::text[]<>'{}' then raise exception 'Check venue fields';end if;
 for k,val in select key,value #>> '{}' from jsonb_each(p_data) loop
 if jsonb_typeof(p_data->k)<>'string' or length(val)>(case when k in ('requirements','notes','facilities','accessibility') then 3000 else 500 end) then raise exception 'Venue fields must be text within their limits';end if;
 end loop;
 if length(btrim(coalesce(p_data->>'title',''))) not between 1 and 160 then raise exception 'Add a venue record title';end if;
 foreach k in array array['capacity','expectedGuests'] loop
 val=coalesce(p_data->>k,'');if val<>'' and (val !~ '^\d{1,6}$' or val::integer>100000) then raise exception 'Guest counts must be whole numbers up to 100000';end if;
 end loop;
 if coalesce(p_data->>'availability','Unknown') not in ('Unknown','Inquiry sent','Available','Hold','Booked','Unavailable','Requested','Confirmed','Completed','Cancelled') then raise exception 'Choose a valid recorded status';end if;
 foreach k in array array['date','verification'] loop val=coalesce(p_data->>k,'');if val<>'' then if val !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Choose valid dates';end if;perform val::date;end if;end loop;
 foreach k in array array['start','end'] loop val=coalesce(p_data->>k,'');if val<>'' then if val !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$' then raise exception 'Choose valid local date and time';end if;perform val::timestamp;end if;end loop;
 start_at=nullif(p_data->>'start','')::timestamp;end_at=nullif(p_data->>'end','')::timestamp;
 if (start_at is null)<>(end_at is null) or end_at<=start_at then raise exception 'End time must follow start time';end if;
 if p_kind='Viewing' and start_at is null then raise exception 'Choose the viewing start and end';end if;
 if start_at is not null and not exists(select 1 from pg_timezone_names where name=p_data->>'timeZone') then raise exception 'Choose a valid time zone';end if;
 if coalesce(p_data->>'bookingId','')<>'' and not exists(select 1 from public.cb_vendor_bookings b where b.id=(p_data->>'bookingId')::uuid and b.vendor_id=v.id) then raise exception 'Choose a booking from this venue';end if;
 if p_id is null then
 if (select count(*) from public.cb_venue_records where vendor_id=v.id)>=200 then raise exception 'This venue has reached its record allowance';end if;
 if p_revision is distinct from 0::bigint then raise exception 'Refresh before creating a venue record' using errcode='PT409';end if;
 if exists(select 1 from public.cb_venue_records where vendor_id=v.id and (p_kind='Profile' and kind='Profile' or p_kind='Celebration' and kind='Celebration' and event_id=p_event)) then raise exception 'This venue plan already exists. Refresh before editing.' using errcode='PT409';end if;
 insert into public.cb_venue_records(vendor_id,event_id,kind,data,created_by) values(v.id,p_event,p_kind,p_data,auth.uid()) returning * into r;
 else
 select * into r from public.cb_venue_records where id=p_id and vendor_id=v.id;
 if not found or r.kind<>p_kind or r.event_id is distinct from p_event then raise exception 'Venue record unavailable or celebration changed' using errcode='42501';end if;
 if r.revision is distinct from p_revision then raise exception 'Venue record changed. Refresh before editing.' using errcode='PT409';end if;
 update public.cb_venue_records set data=p_data,revision=revision+1,updated_at=now() where id=r.id returning * into r;
 end if;
 result=to_jsonb(r);insert into public.cb_venue_versions values(r.id,r.revision,auth.uid(),result,now());insert into public.cb_venue_writes values(auth.uid(),p_client,payload,result);
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(v.project_id,auth.uid(),'Venue plan reviewed',array['venue']);return result;
end;$$;
revoke all on function public.cb_venue_workspace(uuid),public.cb_save_venue_record(uuid,uuid,uuid,text,bigint,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.cb_venue_workspace(uuid),public.cb_save_venue_record(uuid,uuid,uuid,text,bigint,uuid,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
