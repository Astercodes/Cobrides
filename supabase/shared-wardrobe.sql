-- Opt-in outfit sharing and wardrobe appointments. Personal measurements are never copied.
begin;
create table if not exists public.cb_shared_looks(
 id uuid primary key default gen_random_uuid(),project_id uuid not null references public.cb_projects on delete cascade,
 created_by uuid not null references auth.users,local_ref text not null,event_id uuid references public.cb_project_events on delete restrict,
 wearer_id uuid references auth.users,coordinator_id uuid references auth.users,vendor_id uuid references public.cb_shared_vendors on delete set null,
 readers uuid[] not null default '{}',shopping_ids uuid[] not null default '{}',data jsonb not null,status text not null default 'Planning',progress_note text not null default '',archived boolean not null default false,
 revision bigint not null default 1,updated_at timestamptz not null default now(),unique(project_id,created_by,local_ref)
);
create table if not exists public.cb_wardrobe_appointments(
 id uuid primary key default gen_random_uuid(),look_id uuid not null references public.cb_shared_looks on delete cascade,
 data jsonb not null,start_at timestamptz not null,end_at timestamptz not null,status text not null default 'Planned',progress_note text not null default '',
 revision bigint not null default 1,created_by uuid not null references auth.users,updated_at timestamptz not null default now(),check(end_at>start_at)
);
create table if not exists public.cb_wardrobe_writes(user_id uuid not null references auth.users,client_id uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client_id));
create table if not exists public.cb_wardrobe_versions(kind text not null,target_id uuid not null,revision bigint not null,actor_id uuid not null references auth.users,snapshot jsonb not null,at timestamptz not null default now(),primary key(kind,target_id,revision));
alter table public.cb_shared_looks enable row level security;alter table public.cb_wardrobe_appointments enable row level security;alter table public.cb_wardrobe_writes enable row level security;alter table public.cb_wardrobe_versions enable row level security;
revoke all on public.cb_shared_looks,public.cb_wardrobe_appointments,public.cb_wardrobe_writes,public.cb_wardrobe_versions from public,anon,authenticated;
create index if not exists cb_shared_looks_project on public.cb_shared_looks(project_id);
create index if not exists cb_wardrobe_appointments_look on public.cb_wardrobe_appointments(look_id,start_at);
create or replace function public.cb_wardrobe_event_access(p_user uuid,p_event uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_project_events e where e.id=p_event and public.cb_collab_user_access(p_user,e.project_id,'read') and public.cb_collab_user_access(p_user,e.project_id,'events') and
 (public.cb_collab_user_access(p_user,e.project_id,'write') or e.visibility='team' and exists(select 1 from public.cb_members m where m.project_id=e.project_id and m.user_id=p_user and m.role in ('family','sibling','friend','bridal-party')) or exists(select 1 from public.cb_project_event_members where event_id=e.id and user_id=p_user)));
$$;
create or replace function public.cb_wardrobe_access(p_look uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_shared_looks w where w.id=p_look and public.cb_project_access(w.project_id,'read') and (w.event_id is null or public.cb_project_event_access(w.event_id)) and (public.cb_project_access(w.project_id,'owner') or public.cb_project_access(w.project_id,'write') or auth.uid()=w.wearer_id or auth.uid()=w.coordinator_id or auth.uid()=any(w.readers)));
$$;
create or replace function public.cb_wardrobe_workspace(p_project uuid,p_look uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare manager boolean;chosen uuid;
begin
 if not public.cb_project_access(p_project,'read') then raise exception 'Wedding wardrobe access required' using errcode='42501';end if;manager=public.cb_project_access(p_project,'write');
 if p_look is not null and not exists(select 1 from public.cb_shared_looks where id=p_look and project_id=p_project and public.cb_wardrobe_access(id)) then raise exception 'Outfit access required' using errcode='42501';end if;
 chosen=coalesce(p_look,(select id from public.cb_shared_looks where project_id=p_project and public.cb_wardrobe_access(id) order by archived,updated_at desc,id limit 1));
 return jsonb_build_object('project',p_project,'selected',chosen,'editable',manager,'active',exists(select 1 from public.cb_projects where id=p_project and archived_at is null),
 'events',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'title',e.title) order by title),'[]') from public.cb_project_events e where e.project_id=p_project and public.cb_project_event_access(e.id)),
 'people',case when manager then (select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'name',coalesce(nullif(p.full_name,''),u.email),'events',(select coalesce(jsonb_agg(e.id),'[]') from public.cb_project_events e where e.project_id=p_project and public.cb_project_event_access(e.id) and public.cb_wardrobe_event_access(u.id,e.id)))),'[]') from auth.users u left join public.cb_profiles p on p.user_id=u.id where u.id in (select owner_id from public.cb_projects where id=p_project union select user_id from public.cb_members where project_id=p_project) and public.cb_collab_user_access(u.id,p_project,'read')) else '[]'::jsonb end,
 'vendors',case when manager then (select coalesce(jsonb_agg(jsonb_build_object('id',v.id,'name',v.name)),'[]') from public.cb_shared_vendors v where v.project_id=p_project and not v.archived and public.cb_shared_vendor_access(v.id)) else '[]'::jsonb end,
 'shopping',case when manager then (select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'title',i.data->>'title','list',l.title)),'[]') from public.cb_shopping_items i join public.cb_shopping_lists l on l.id=i.list_id where l.project_id=p_project and not l.archived and i.status<>'Cancelled' and public.cb_shopping_access(l.id)) else '[]'::jsonb end,
 'looks',(select coalesce(jsonb_agg((to_jsonb(w)-'shopping_ids'-'local_ref')||case when manager then jsonb_build_object('shopping_ids',w.shopping_ids,'local_ref',w.local_ref) else '{}'::jsonb end||jsonb_build_object(
 'event_title',(select title from public.cb_project_events where id=w.event_id),
 'collection_due',case when w.data->>'dateMode'='Before celebration' then (select nullif(details->>'date','')::date-(w.data->>'daysBefore')::integer from public.cb_project_events where id=w.event_id) else nullif(w.data->>'collectionDate','')::date end,
 'vendor_name',(select name from public.cb_shared_vendors where id=w.vendor_id and public.cb_shared_vendor_access(id)),
 'can_update',not w.archived and exists(select 1 from public.cb_projects where id=p_project and archived_at is null) and (manager or auth.uid() in (w.wearer_id,w.coordinator_id) and w.status<>'Collected'),
 'history',(select coalesce(jsonb_agg(jsonb_build_object('revision',h.revision,'status',h.snapshot->>'status','note',h.snapshot->>'progress_note','at',h.at) order by h.revision desc),'[]') from public.cb_wardrobe_versions h where h.kind='look' and h.target_id=w.id)) order by w.archived,w.updated_at desc,w.id),'[]') from public.cb_shared_looks w where project_id=p_project and public.cb_wardrobe_access(w.id)),
 'pieces',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'title',i.data->>'title','category',i.data->>'category','image',i.data->>'image','url',i.data->>'url','status',i.status)),'[]') from public.cb_shopping_items i join public.cb_shopping_lists l on l.id=i.list_id where i.id=any(coalesce((select shopping_ids from public.cb_shared_looks where id=chosen),array[]::uuid[])) and not l.archived and l.project_id=p_project and public.cb_shopping_access(l.id)),
 'appointments',(select coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('can_update',not w.archived and exists(select 1 from public.cb_projects where id=p_project and archived_at is null) and (manager or auth.uid() in (w.wearer_id,w.coordinator_id) and a.status not in ('Completed','Cancelled')),'history',(select coalesce(jsonb_agg(jsonb_build_object('revision',h.revision,'status',h.snapshot->>'status','note',h.snapshot->>'progress_note','at',h.at) order by h.revision desc),'[]') from public.cb_wardrobe_versions h where h.kind='appointment' and h.target_id=a.id)) order by a.start_at,a.id),'[]') from public.cb_wardrobe_appointments a join public.cb_shared_looks w on w.id=a.look_id where w.id=chosen and public.cb_wardrobe_access(w.id)));
end;$$;
create or replace function public.cb_save_shared_look(p_project uuid,p_id uuid,p_ref text,p_revision bigint,p_client uuid,p_event uuid,p_wearer uuid,p_coordinator uuid,p_vendor uuid,p_readers uuid[],p_items uuid[],p_data jsonb,p_archived boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.cb_shared_looks;prev public.cb_wardrobe_writes;payload jsonb;result jsonb;k text;v text;person uuid;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not public.cb_project_access(p_project,'write') then raise exception 'Wardrobe planning access required' using errcode='42501';end if;
 if p_event is not null and not exists(select 1 from public.cb_project_events where id=p_event and project_id=p_project and public.cb_project_event_access(id)) then raise exception 'Choose an accessible celebration in this wedding' using errcode='42501';end if;
 payload=jsonb_build_object('kind','look','project',p_project,'id',p_id,'ref',p_ref,'revision',p_revision,'event',p_event,'wearer',p_wearer,'coordinator',p_coordinator,'vendor',p_vendor,'readers',p_readers,'items',p_items,'data',p_data,'archived',p_archived);
 if p_client is null then raise exception 'Save request ID required';end if;select * into prev from public.cb_wardrobe_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 if jsonb_typeof(p_data) is distinct from 'object' or octet_length(p_data::text)>12000 or p_data-array['title','wearerLabel','occasion','style','accessories','care','collectionDate','dateMode','daysBefore','notes']::text[]<>'{}' then raise exception 'Check outfit fields; measurements and financial fields are private';end if;
 for k,v in select key,value #>> '{}' from jsonb_each(p_data) loop if jsonb_typeof(p_data->k)<>'string' or length(v)>(case when k in ('style','accessories','care','notes') then 2000 else 200 end) then raise exception 'Check outfit text limits';end if;end loop;
 if length(btrim(coalesce(p_data->>'title',''))) not between 1 and 160 or coalesce(p_data->>'dateMode','Manual') not in ('Manual','Before celebration') or coalesce(p_data->>'daysBefore','0') !~ '^\d{1,4}$' or (coalesce(p_data->>'daysBefore','0'))::integer>3650 then raise exception 'Check the outfit name and collection-date rule';end if;
 if p_data->>'dateMode'='Before celebration' and p_event is null then raise exception 'Choose a celebration for the relative collection date';end if;
 v=coalesce(p_data->>'collectionDate','');if v<>'' then if v !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Choose a valid collection date';end if;perform v::date;end if;
 if p_readers is null or cardinality(p_readers)>100 or p_items is null or cardinality(p_items)>50 or p_archived is null then raise exception 'Review the outfit audience and pieces';end if;
 foreach person in array p_readers||array[p_wearer,p_coordinator] loop if person is not null and (not public.cb_collab_user_access(person,p_project,'read') or p_event is not null and not public.cb_wardrobe_event_access(person,p_event)) then raise exception 'Choose accepted teammates with access to this celebration';end if;end loop;
 if p_vendor is not null and not exists(select 1 from public.cb_shared_vendors where id=p_vendor and project_id=p_project and not archived and public.cb_shared_vendor_access(id)) then raise exception 'Choose a team vendor in this wedding';end if;
 foreach person in array p_items loop if person is null or not exists(select 1 from public.cb_shopping_items i join public.cb_shopping_lists l on l.id=i.list_id where i.id=person and l.project_id=p_project and not l.archived and i.status<>'Cancelled' and public.cb_shopping_access(l.id)) then raise exception 'Choose available shared shopping pieces in this wedding';end if;end loop;
 if p_id is null then
 if length(coalesce(p_ref,'')) not between 1 and 250 or p_revision is distinct from 0::bigint then raise exception 'Use a new outfit reference and refresh before creating';end if;
 if exists(select 1 from public.cb_shared_looks where project_id=p_project and created_by=auth.uid() and local_ref=p_ref) then raise exception 'This outfit is already shared. Open its existing plan.' using errcode='PT409';end if;
 if (select count(*) from public.cb_shared_looks where project_id=p_project)>=200 then raise exception 'This wedding has reached its shared outfit allowance';end if;
 insert into public.cb_shared_looks(project_id,created_by,local_ref,event_id,wearer_id,coordinator_id,vendor_id,readers,shopping_ids,data,archived) values(p_project,auth.uid(),p_ref,p_event,p_wearer,p_coordinator,p_vendor,p_readers,p_items,p_data,p_archived) returning * into w;
 else
 select * into w from public.cb_shared_looks where id=p_id and project_id=p_project;
 if not found or not public.cb_wardrobe_access(w.id) then raise exception 'Outfit access required' using errcode='42501';end if;
 if w.revision is distinct from p_revision then raise exception 'Outfit changed. Refresh before editing.' using errcode='PT409';end if;
 update public.cb_shared_looks set event_id=p_event,wearer_id=p_wearer,coordinator_id=p_coordinator,vendor_id=p_vendor,readers=p_readers,shopping_ids=p_items,data=p_data,archived=p_archived,revision=revision+1,updated_at=now() where id=w.id returning * into w;
 end if;
 if not w.archived and exists(select 1 from public.cb_wardrobe_appointments a join public.cb_wardrobe_appointments x on x.id<>a.id and x.start_at<a.end_at and x.end_at>a.start_at join public.cb_shared_looks other on other.id=x.look_id where a.look_id=w.id and a.status in ('Planned','Confirmed') and x.status in ('Planned','Confirmed') and other.project_id=p_project and not other.archived and (other.id=w.id or other.wearer_id in (w.wearer_id,w.coordinator_id) or other.coordinator_id in (w.wearer_id,w.coordinator_id))) then raise exception 'This assignment overlaps another wardrobe commitment';end if;
 result=to_jsonb(w);insert into public.cb_wardrobe_versions values('look',w.id,w.revision,auth.uid(),result,now());insert into public.cb_wardrobe_writes values(auth.uid(),p_client,payload,result);insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(p_project,auth.uid(),'Shared outfit plan reviewed',array['wardrobe']);return result;
end;$$;
create or replace function public.cb_save_wardrobe_appointment(p_look uuid,p_id uuid,p_revision bigint,p_client uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.cb_shared_looks;a public.cb_wardrobe_appointments;prev public.cb_wardrobe_writes;payload jsonb;result jsonb;k text;v text;starts timestamptz;ends timestamptz;
begin
 select * into w from public.cb_shared_looks where id=p_look;perform 1 from public.cb_projects where id=w.project_id for update;select * into w from public.cb_shared_looks where id=p_look;
 if not coalesce(public.cb_project_access(w.project_id,'write') and public.cb_wardrobe_access(w.id) and not w.archived,false) then raise exception 'Wardrobe planning access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind','appointment','look',p_look,'id',p_id,'revision',p_revision,'data',p_data);if p_client is null then raise exception 'Save request ID required';end if;select * into prev from public.cb_wardrobe_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 if jsonb_typeof(p_data) is distinct from 'object' or octet_length(p_data::text)>8000 or p_data-array['title','type','start','end','timeZone','location','notes','status']::text[]<>'{}' then raise exception 'Check appointment fields';end if;
 for k,v in select key,value #>> '{}' from jsonb_each(p_data) loop if jsonb_typeof(p_data->k)<>'string' or length(v)>(case when k='notes' then 2000 else 300 end) then raise exception 'Check appointment text limits';end if;end loop;
 if length(btrim(coalesce(p_data->>'title',''))) not between 1 and 160 or coalesce(p_data->>'type','') not in ('Fitting','Alteration','Collection','Garment care') or coalesce(p_data->>'status','') not in ('Planned','Confirmed','Completed','Cancelled') then raise exception 'Check the appointment name, type and status';end if;
 foreach k in array array['start','end'] loop if coalesce(p_data->>k,'') !~ '^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d$' then raise exception 'Choose valid local appointment dates and times';end if;end loop;
 if not exists(select 1 from pg_timezone_names where name=p_data->>'timeZone') then raise exception 'Choose a valid appointment time zone';end if;
 starts=(p_data->>'start')::timestamp at time zone (p_data->>'timeZone');ends=(p_data->>'end')::timestamp at time zone (p_data->>'timeZone');if ends<=starts then raise exception 'Appointment end must follow its start';end if;
 if p_data->>'status' in ('Completed','Cancelled') and length(btrim(coalesce(p_data->>'notes','')))=0 then raise exception 'Add a completion or cancellation note';end if;
 if p_data->>'status' in ('Planned','Confirmed') and exists(select 1 from public.cb_wardrobe_appointments x join public.cb_shared_looks other on other.id=x.look_id where other.project_id=w.project_id and not other.archived and x.status in ('Planned','Confirmed') and x.start_at<ends and x.end_at>starts and (p_id is null or x.id<>p_id) and (other.id=w.id or other.wearer_id in (w.wearer_id,w.coordinator_id) or other.coordinator_id in (w.wearer_id,w.coordinator_id))) then raise exception 'This appointment overlaps another wardrobe commitment for the wearer or coordinator';end if;
 if p_id is null then
 if p_revision is distinct from 0::bigint then raise exception 'Refresh before creating an appointment' using errcode='PT409';end if;
 if (select count(*) from public.cb_wardrobe_appointments where look_id=w.id)>=50 then raise exception 'This outfit has reached its appointment allowance';end if;
 insert into public.cb_wardrobe_appointments(look_id,data,start_at,end_at,status,created_by) values(w.id,p_data-'status',starts,ends,p_data->>'status',auth.uid()) returning * into a;
 else
 select * into a from public.cb_wardrobe_appointments where id=p_id and look_id=w.id;if not found then raise exception 'Appointment access required' using errcode='42501';end if;
 if a.revision is distinct from p_revision then raise exception 'Appointment changed. Refresh before editing.' using errcode='PT409';end if;
 update public.cb_wardrobe_appointments set data=p_data-'status',start_at=starts,end_at=ends,status=p_data->>'status',revision=revision+1,updated_at=now() where id=a.id returning * into a;
 end if;
 result=to_jsonb(a);insert into public.cb_wardrobe_versions values('appointment',a.id,a.revision,auth.uid(),result,now());insert into public.cb_wardrobe_writes values(auth.uid(),p_client,payload,result);insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(w.project_id,auth.uid(),'Wardrobe appointment reviewed',array['wardrobe']);return result;
end;$$;
create or replace function public.cb_update_wardrobe_progress(p_kind text,p_id uuid,p_revision bigint,p_client uuid,p_status text,p_note text) returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.cb_shared_looks;a public.cb_wardrobe_appointments;pid uuid;prev public.cb_wardrobe_writes;payload jsonb;result jsonb;manager boolean;current_status text;
begin
 if p_kind='look' then select project_id into pid from public.cb_shared_looks where id=p_id;elsif p_kind='appointment' then select w2.project_id into pid from public.cb_wardrobe_appointments a2 join public.cb_shared_looks w2 on w2.id=a2.look_id where a2.id=p_id;else raise exception 'Choose an outfit or appointment';end if;
 perform 1 from public.cb_projects where id=pid for update;
 if p_kind='look' then select * into w from public.cb_shared_looks where id=p_id;current_status=w.status;else select * into a from public.cb_wardrobe_appointments where id=p_id;select * into w from public.cb_shared_looks where id=a.look_id;current_status=a.status;end if;
 manager=public.cb_project_access(pid,'write');
 if not coalesce(public.cb_wardrobe_access(w.id) and not w.archived and exists(select 1 from public.cb_projects where id=pid and archived_at is null) and (manager or auth.uid() in (w.wearer_id,w.coordinator_id)),false) then raise exception 'Assigned wardrobe access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind',p_kind||'-progress','id',p_id,'revision',p_revision,'status',p_status,'note',p_note);if p_client is null then raise exception 'Save request ID required';end if;select * into prev from public.cb_wardrobe_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 if (case when p_kind='look' then w.revision else a.revision end) is distinct from p_revision then raise exception 'Wardrobe record changed. Refresh before updating.' using errcode='PT409';end if;
 if p_note is null or length(btrim(p_note)) not between 1 and 2000 then raise exception 'Add a wardrobe progress note';end if;
 if p_kind='look' then
 if coalesce(p_status,'') not in ('Planning','Selected','In alterations','Ready','Collected') then raise exception 'Choose a valid outfit status';end if;
 if not manager and not (case current_status when 'Planning' then p_status='Selected' when 'Selected' then p_status in ('In alterations','Ready') when 'In alterations' then p_status='Ready' when 'Ready' then p_status='Collected' else false end) then raise exception 'Ask a wedding manager to correct or reopen this outfit';end if;
 update public.cb_shared_looks set status=p_status,progress_note=btrim(p_note),revision=revision+1,updated_at=now() where id=w.id returning * into w;result=to_jsonb(w);
 else
 if coalesce(p_status,'') not in ('Planned','Confirmed','Completed','Cancelled') then raise exception 'Choose a valid appointment status';end if;
 if not manager and not (current_status in ('Planned','Confirmed') and p_status in ('Confirmed','Completed')) then raise exception 'Ask a wedding manager to reschedule or reopen this appointment';end if;
 if p_status in ('Planned','Confirmed') and exists(select 1 from public.cb_wardrobe_appointments x join public.cb_shared_looks other on other.id=x.look_id where other.project_id=pid and not other.archived and x.status in ('Planned','Confirmed') and x.id<>a.id and x.start_at<a.end_at and x.end_at>a.start_at and (other.id=w.id or other.wearer_id in (w.wearer_id,w.coordinator_id) or other.coordinator_id in (w.wearer_id,w.coordinator_id))) then raise exception 'This appointment overlaps another wardrobe commitment';end if;
 update public.cb_wardrobe_appointments set status=p_status,progress_note=btrim(p_note),revision=revision+1,updated_at=now() where id=a.id returning * into a;result=to_jsonb(a);
 end if;
 insert into public.cb_wardrobe_versions values(p_kind,p_id,(result->>'revision')::bigint,auth.uid(),result,now());insert into public.cb_wardrobe_writes values(auth.uid(),p_client,payload,result);insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(pid,auth.uid(),'Wardrobe progress updated',array['wardrobe']);return result;
end;$$;
revoke all on function public.cb_wardrobe_event_access(uuid,uuid),public.cb_wardrobe_access(uuid),public.cb_wardrobe_workspace(uuid,uuid),public.cb_save_shared_look(uuid,uuid,text,bigint,uuid,uuid,uuid,uuid,uuid,uuid[],uuid[],jsonb,boolean),public.cb_save_wardrobe_appointment(uuid,uuid,bigint,uuid,jsonb),public.cb_update_wardrobe_progress(text,uuid,bigint,uuid,text,text) from public,anon,authenticated;
grant execute on function public.cb_wardrobe_workspace(uuid,uuid),public.cb_save_shared_look(uuid,uuid,text,bigint,uuid,uuid,uuid,uuid,uuid,uuid[],uuid[],jsonb,boolean),public.cb_save_wardrobe_appointment(uuid,uuid,bigint,uuid,jsonb),public.cb_update_wardrobe_progress(text,uuid,bigint,uuid,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
