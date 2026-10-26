-- Shared vendor deliverables and operational updates; no commercial terms are exposed.
begin;
create table if not exists public.cb_vendor_work(
 id uuid primary key default gen_random_uuid(),vendor_id uuid not null references public.cb_shared_vendors on delete cascade,
 title text not null,kind text not null,assigned_to uuid references auth.users,due_date date,time_window text not null default '',location text not null default '',instructions text not null default '',
 status text not null default 'To do',progress_note text not null default '',revision bigint not null default 1,created_by uuid not null references auth.users,created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.cb_vendor_work_writes(user_id uuid not null references auth.users,client_id uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client_id));
create table if not exists public.cb_vendor_work_versions(work_id uuid not null references public.cb_vendor_work on delete cascade,revision bigint not null,actor_id uuid not null references auth.users,snapshot jsonb not null,at timestamptz not null default now(),primary key(work_id,revision));
alter table public.cb_vendor_work enable row level security;alter table public.cb_vendor_work_writes enable row level security;alter table public.cb_vendor_work_versions enable row level security;
revoke all on public.cb_vendor_work,public.cb_vendor_work_writes,public.cb_vendor_work_versions from public,anon,authenticated;
create index if not exists cb_vendor_work_vendor on public.cb_vendor_work(vendor_id,due_date);
create or replace function public.cb_vendor_coordination(p_vendor uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v public.cb_shared_vendors;manager boolean;
begin
 if not public.cb_shared_vendor_access(p_vendor) then raise exception 'Vendor access denied' using errcode='42501';end if;
 select * into v from public.cb_shared_vendors where id=p_vendor;manager=public.cb_project_access(v.project_id,'owner') or public.cb_project_access(v.project_id,'write');
 return jsonb_build_object('project',v.project_id,'vendor',v.name,'manager',manager,'editable',not v.archived and public.cb_project_access(v.project_id,'write'),
 'active',not v.archived and exists(select 1 from public.cb_projects where id=v.project_id and archived_at is null),
 'people',case when manager then (select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'name',coalesce(nullif(p.full_name,''),u.email))),'[]') from auth.users u left join public.cb_profiles p on p.user_id=u.id where public.cb_collab_user_access(u.id,v.project_id,'read') and (u.id=any(v.readers) or public.cb_collab_user_access(u.id,v.project_id,'write') or public.cb_collab_user_access(u.id,v.project_id,'owner'))) else '[]'::jsonb end,
 'items',(select coalesce(jsonb_agg(to_jsonb(w)||jsonb_build_object('can_update',not v.archived and exists(select 1 from public.cb_projects where id=v.project_id and archived_at is null) and (public.cb_project_access(v.project_id,'write') or w.assigned_to=auth.uid() and w.status not in ('Complete','Cancelled')),
 'history',(select coalesce(jsonb_agg(jsonb_build_object('revision',h.revision,'status',h.snapshot->>'status','note',h.snapshot->>'progress_note','at',h.at) order by h.revision desc),'[]') from public.cb_vendor_work_versions h where h.work_id=w.id)) order by w.due_date nulls last,w.created_at,w.id),'[]') from public.cb_vendor_work w where w.vendor_id=v.id and (manager or w.assigned_to=auth.uid())));
end;$$;
create or replace function public.cb_save_vendor_work(p_vendor uuid,p_id uuid,p_revision bigint,p_client uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.cb_shared_vendors;w public.cb_vendor_work;prev public.cb_vendor_work_writes;payload jsonb;result jsonb;k text;assignee uuid;
begin
 select * into v from public.cb_shared_vendors where id=p_vendor;perform 1 from public.cb_projects where id=v.project_id for update;
 if not coalesce(public.cb_project_access(v.project_id,'write') and not v.archived,false) then raise exception 'Planning access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind','work','vendor',p_vendor,'id',p_id,'revision',p_revision,'data',p_data);
 if p_client is null then raise exception 'Save request ID required';end if;select * into prev from public.cb_vendor_work_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 if jsonb_typeof(p_data) is distinct from 'object' or octet_length(p_data::text)>13000 or p_data-array['title','kind','assignedTo','due','timeWindow','location','instructions','status','progressNote']::text[]<>'{}' then raise exception 'Check work item fields';end if;
 foreach k in array array['title','kind','assignedTo','due','timeWindow','location','instructions','status','progressNote'] loop if p_data ? k and jsonb_typeof(p_data->k)<>'string' then raise exception 'Work item fields must be text';end if;end loop;
 if length(btrim(coalesce(p_data->>'title',''))) not between 1 and 200 or coalesce(p_data->>'kind','') not in ('Deliverable','Setup','Rehearsal','Logistics','Issue') or coalesce(p_data->>'status','To do') not in ('To do','In progress','Blocked','Ready','Complete','Cancelled') or length(coalesce(p_data->>'timeWindow',''))>200 or length(coalesce(p_data->>'location',''))>500 or length(coalesce(p_data->>'instructions',''))>3000 or length(coalesce(p_data->>'progressNote',''))>3000 then raise exception 'Check the title, type, status and instructions';end if;
 if p_data->>'status' in ('Blocked','Complete','Cancelled') and length(btrim(coalesce(p_data->>'progressNote','')))=0 then raise exception 'Add a progress note for blocked, completed or cancelled work';end if;
 if coalesce(p_data->>'due','')<>'' and p_data->>'due' !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Choose a valid due date';end if;
 assignee=nullif(p_data->>'assignedTo','')::uuid;
 if assignee is not null and not (public.cb_collab_user_access(assignee,v.project_id,'read') and (assignee=any(v.readers) or public.cb_collab_user_access(assignee,v.project_id,'write') or public.cb_collab_user_access(assignee,v.project_id,'owner'))) then raise exception 'Choose an accepted teammate who can access this vendor';end if;
 if p_id is null then
 insert into public.cb_vendor_work(vendor_id,title,kind,assigned_to,due_date,time_window,location,instructions,status,progress_note,created_by) values(v.id,btrim(p_data->>'title'),p_data->>'kind',assignee,nullif(p_data->>'due','')::date,coalesce(p_data->>'timeWindow',''),coalesce(p_data->>'location',''),coalesce(p_data->>'instructions',''),coalesce(p_data->>'status','To do'),coalesce(p_data->>'progressNote',''),auth.uid()) returning * into w;
 else
 select * into w from public.cb_vendor_work where id=p_id and vendor_id=v.id;
 if not found then raise exception 'Work item unavailable' using errcode='42501';end if;
 if w.revision is distinct from p_revision then raise exception 'Work item changed. Refresh before editing.' using errcode='PT409';end if;
 update public.cb_vendor_work set title=btrim(p_data->>'title'),kind=p_data->>'kind',assigned_to=assignee,due_date=nullif(p_data->>'due','')::date,time_window=coalesce(p_data->>'timeWindow',''),location=coalesce(p_data->>'location',''),instructions=coalesce(p_data->>'instructions',''),status=coalesce(p_data->>'status','To do'),progress_note=coalesce(p_data->>'progressNote',''),revision=revision+1,updated_at=now() where id=w.id returning * into w;
 end if;
 result=to_jsonb(w);insert into public.cb_vendor_work_versions values(w.id,w.revision,auth.uid(),result,now());insert into public.cb_vendor_work_writes values(auth.uid(),p_client,payload,result);insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(v.project_id,auth.uid(),'Vendor coordination item reviewed',array['vendor']);return result;
end;$$;
create or replace function public.cb_update_vendor_progress(p_work uuid,p_revision bigint,p_client uuid,p_status text,p_note text) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.cb_shared_vendors;w public.cb_vendor_work;prev public.cb_vendor_work_writes;payload jsonb;result jsonb;
begin
 select v2.* into v from public.cb_vendor_work w2 join public.cb_shared_vendors v2 on v2.id=w2.vendor_id where w2.id=p_work;perform 1 from public.cb_projects where id=v.project_id for update;
 select * into w from public.cb_vendor_work where id=p_work;
 if not coalesce(public.cb_shared_vendor_access(v.id) and not v.archived and exists(select 1 from public.cb_projects where id=v.project_id and archived_at is null) and (public.cb_project_access(v.project_id,'write') or w.assigned_to=auth.uid()),false) then raise exception 'Assigned work access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind','progress','work',p_work,'revision',p_revision,'status',p_status,'note',p_note);
 if p_client is null then raise exception 'Save request ID required';end if;select * into prev from public.cb_vendor_work_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Save changed during retry' using errcode='PT409';end if;return prev.response;end if;
 if w.revision is distinct from p_revision then raise exception 'Work item changed. Refresh before updating.' using errcode='PT409';end if;
 if not public.cb_project_access(v.project_id,'write') and w.status in ('Complete','Cancelled') then raise exception 'Ask your planner to reopen completed or cancelled work';end if;
 if coalesce(p_status,'') not in ('To do','In progress','Blocked','Ready','Complete') or length(coalesce(p_note,''))>3000 or p_status in ('Blocked','Complete') and length(btrim(coalesce(p_note,'')))=0 then raise exception 'Choose a valid status and explain blocked or completed work';end if;
 update public.cb_vendor_work set status=p_status,progress_note=coalesce(p_note,''),revision=revision+1,updated_at=now() where id=w.id returning * into w;
 result=to_jsonb(w);insert into public.cb_vendor_work_versions values(w.id,w.revision,auth.uid(),result,now());insert into public.cb_vendor_work_writes values(auth.uid(),p_client,payload,result);insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(v.project_id,auth.uid(),'Vendor readiness updated',array['vendor']);return result;
end;$$;
revoke all on function public.cb_vendor_coordination(uuid),public.cb_save_vendor_work(uuid,uuid,bigint,uuid,jsonb),public.cb_update_vendor_progress(uuid,bigint,uuid,text,text) from public,anon,authenticated;
grant execute on function public.cb_vendor_coordination(uuid),public.cb_save_vendor_work(uuid,uuid,bigint,uuid,jsonb),public.cb_update_vendor_progress(uuid,bigint,uuid,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
