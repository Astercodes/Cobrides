-- Private-by-default household plans. Run after shared shopping and registry follow-through.
-- Run after wedding-projects.sql and collaboration access setup. No bookings or messages are sent.
begin;
create table if not exists public.cb_home_plans(id uuid primary key default gen_random_uuid(),project_id uuid not null references public.cb_projects on delete cascade,owner_id uuid not null references auth.users,data jsonb not null,readers uuid[] not null default '{}',editors uuid[] not null default '{}',archived boolean not null default false,revision bigint not null default 1,updated_at timestamptz not null default now());
create table if not exists public.cb_home_writes(user_id uuid not null references auth.users on delete cascade,client uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client));
create table if not exists public.cb_home_history(kind text not null,target_id uuid not null,revision bigint not null,actor_id uuid not null,snapshot jsonb not null,at timestamptz not null default now(),primary key(kind,target_id,revision));
alter table public.cb_home_plans enable row level security;alter table public.cb_home_writes enable row level security;alter table public.cb_home_history enable row level security;
revoke all on public.cb_home_plans,public.cb_home_writes,public.cb_home_history from public,anon,authenticated;
create index if not exists cb_home_project on public.cb_home_plans(project_id);
create or replace function public.cb_home_access(p_home uuid,p_write boolean default false) returns boolean language sql stable security definer set search_path='' as $$select auth.uid() is not null and exists(select 1 from public.cb_home_plans t where t.id=p_home and public.cb_project_access(t.project_id,'read') and (t.owner_id=auth.uid() or not t.archived and (auth.uid()=any(t.editors) or not p_write and auth.uid()=any(t.readers))))$$;
create or replace function public.cb_home_people(p_project uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(public.cb_project_access(p_project,'write') or exists(select 1 from public.cb_home_plans where project_id=p_project and owner_id=auth.uid() and public.cb_project_access(p_project,'read')),false) then raise exception 'Home sharing access required' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'name',coalesce(p.full_name,'Wedding collaborator'),'role',u.role) order by coalesce(p.full_name,''),u.id),'[]') from (select owner_id id,'Wedding owner' role from public.cb_projects where id=p_project union select user_id,role from public.cb_members where project_id=p_project and user_id<>(select owner_id from public.cb_projects where id=p_project)) u left join public.cb_profiles p on p.user_id=u.id where u.id<>auth.uid());
end;$$;
create or replace function public.cb_home_summary(p_home uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t public.cb_home_plans;
begin
 if not public.cb_home_access(p_home,false) then raise exception 'This home is private or no longer shared with you' using errcode='42501';end if;
 select * into t from public.cb_home_plans where id=p_home;
 return jsonb_build_object('id',t.id,'project',t.project_id,'data',t.data,'revision',t.revision,'archived',t.archived,'owner',t.owner_id=auth.uid(),'can_edit',public.cb_home_access(t.id,true),'readers',case when t.owner_id=auth.uid() then to_jsonb(t.readers) else '[]' end,'editors',case when t.owner_id=auth.uid() then to_jsonb(t.editors) else '[]' end);
end;$$;
create or replace function public.cb_home_workspace(p_project uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(public.cb_project_access(p_project,'read'),false) then raise exception 'Wedding access required' using errcode='42501';end if;
 return jsonb_build_object('project',p_project,'can_create',public.cb_project_access(p_project,'write'),'homes',(select coalesce(jsonb_agg(public.cb_home_summary(t.id) order by t.archived,t.updated_at desc,t.id),'[]') from public.cb_home_plans t where t.project_id=p_project and public.cb_home_access(t.id,false)));
end;$$;
create or replace function public.cb_save_home_plan(p_project uuid,p_id uuid,p_revision bigint,p_client uuid,p_data jsonb,p_readers uuid[],p_editors uuid[],p_archived boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.cb_home_plans;w public.cb_home_writes;payload jsonb;result jsonb;k text;v uuid;r uuid[];e uuid[];
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if p_id is null then if not coalesce(public.cb_project_access(p_project,'write'),false) then raise exception 'Planning access required to create a home' using errcode='42501';end if;
 else select * into t from public.cb_home_plans where id=p_id and project_id=p_project for update;if t.id is null or not public.cb_home_access(t.id,true) then raise exception 'Home editing access required' using errcode='42501';end if;end if;
 payload=jsonb_build_object('action','home','project',p_project,'id',p_id,'revision',p_revision,'data',p_data,'readers',p_readers,'editors',p_editors,'archived',p_archived);if p_client is null then raise exception 'Request ID required';end if;
 select * into w from public.cb_home_writes where user_id=auth.uid() and client=p_client;if found then if w.payload is distinct from payload then raise exception 'Retry the original home details' using errcode='PT409';end if;return w.response;end if;
 if jsonb_typeof(p_data) is distinct from 'object' or p_data-array['title','arrangement','moveDate','style','notes']::text[]<>'{}' or p_archived is null then raise exception 'Review home details';end if;
 foreach k in array array['title','arrangement','moveDate','style','notes'] loop if jsonb_typeof(p_data->k) is distinct from 'string' or length(p_data->>k)>(case when k='notes' then 2000 else 160 end) then raise exception 'Review home text limits';end if;end loop;
 if length(btrim(p_data->>'title'))<1 or p_data->>'arrangement' not in ('Exploring options','Renting','Buying','Existing home','Family or shared home','Other') then raise exception 'Add a home name and living arrangement';end if;
 if p_data->>'moveDate'<>'' then if p_data->>'moveDate'!~'^\d{4}-\d{2}-\d{2}$' then raise exception 'Choose a valid move-in date';end if;perform (p_data->>'moveDate')::date;end if;
 if t.id is null or t.owner_id=auth.uid() then
 r=coalesce(p_readers,'{}');e=coalesce(p_editors,'{}');if cardinality(r)>100 or cardinality(e)>100 or array_position(r,null) is not null or array_position(e,null) is not null then raise exception 'Choose up to 100 accepted collaborators per access level';end if;
 foreach v in array r||e loop if v=auth.uid() or not exists(select 1 from public.cb_projects where id=p_project and owner_id=v union all select 1 from public.cb_members where project_id=p_project and user_id=v) then raise exception 'Choose accepted members of this wedding';end if;end loop;
 select coalesce(array_agg(distinct x order by x),'{}') into r from unnest(r) x;select coalesce(array_agg(distinct x order by x),'{}') into e from unnest(e) x;
 else if p_readers is not null or p_editors is not null or p_archived is distinct from t.archived then raise exception 'Only the home creator controls sharing and archival' using errcode='42501';end if;r=t.readers;e=t.editors;end if;
 if t.id is null then
 if p_revision is distinct from 0::bigint then raise exception 'Refresh before creating a home' using errcode='PT409';end if;
 if (select count(*) from public.cb_home_plans where project_id=p_project and owner_id=auth.uid())>=100 then raise exception 'Home allowance reached';end if;
 insert into public.cb_home_plans(project_id,owner_id,data,readers,editors,archived) values(p_project,auth.uid(),p_data,r,e,p_archived) returning * into t;
 else
 if t.revision is distinct from p_revision then raise exception 'Another device updated this home. Refresh first.' using errcode='PT409';end if;
 update public.cb_home_plans set data=p_data,readers=r,editors=e,archived=p_archived,revision=revision+1,updated_at=now() where id=t.id returning * into t;
 end if;
 result=public.cb_home_summary(t.id);insert into public.cb_home_history values('home',t.id,t.revision,auth.uid(),to_jsonb(t),now());insert into public.cb_home_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
create table if not exists public.cb_home_items(id uuid primary key default gen_random_uuid(),home_id uuid not null references public.cb_home_plans on delete cascade,data jsonb not null,assignee uuid references auth.users,shopping_id uuid unique references public.cb_shopping_items,gift_id uuid unique references public.cb_registry_reservations,source_snapshot jsonb not null default '{}',revision bigint not null default 1,updated_at timestamptz not null default now(),check(shopping_id is null or gift_id is null));
alter table public.cb_home_items enable row level security;revoke all on public.cb_home_items from public,anon,authenticated;
create index if not exists cb_home_item_home on public.cb_home_items(home_id);
-- Internal projection: no donors, finance, booking or private source notes.
create or replace function public.cb_home_item_view(p_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare i public.cb_home_items;ready boolean;source_status text;begin
 select * into i from public.cb_home_items where id=p_id;
 if not public.cb_home_access(i.home_id,false) then raise exception 'Home access required' using errcode='42501';end if;
 if i.shopping_id is not null then select s.status into source_status from public.cb_shopping_items s join public.cb_shopping_lists l on l.id=s.list_id where s.id=i.shopping_id;ready=source_status='Delivered';
 elsif i.gift_id is not null then select g.status, g.status='Received' and coalesce((f.data->>'inventory')::boolean,false) into source_status,ready from public.cb_registry_reservations g left join public.cb_registry_followups f on f.gift_id=g.id where g.id=i.gift_id;
 else ready=i.data->>'status' in ('Already owned','Complete');end if;
 ready=coalesce(ready,false) and i.data->>'status'<>'Cancelled' and (not coalesce((i.data->>'requiresSetup')::boolean,false) or i.data->>'status'='Complete');
 return jsonb_build_object('id',i.id,'data',i.data,'assignee',i.assignee,'revision',i.revision,'source',i.source_snapshot,'linked',i.shopping_id is not null or i.gift_id is not null,'source_status',source_status,'ready',ready);
end;$$;
create or replace function public.cb_home_detail(p_home uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin if not public.cb_home_access(p_home,false) then raise exception 'Home access required' using errcode='42501';end if;
 return jsonb_build_object('home',public.cb_home_summary(p_home),'people',(select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'name',coalesce(p.full_name,'Home collaborator'))),'[]') from (select owner_id id from public.cb_home_plans where id=p_home union select unnest(readers||editors) from public.cb_home_plans where id=p_home) u left join public.cb_profiles p on p.user_id=u.id where exists(select 1 from public.cb_projects z where z.id=(select project_id from public.cb_home_plans where id=p_home) and z.owner_id=u.id union all select 1 from public.cb_members m where m.project_id=(select project_id from public.cb_home_plans where id=p_home) and m.user_id=u.id)),'items',(select coalesce(jsonb_agg(public.cb_home_item_view(id) order by data->>'room',data->>'title',id),'[]') from public.cb_home_items where home_id=p_home));end;$$;
create or replace function public.cb_home_sources(p_home uuid,p_search text default '') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare p uuid;begin
 if not public.cb_home_access(p_home,true) then raise exception 'Home editing access required' using errcode='42501';end if;
 select project_id into p from public.cb_home_plans where id=p_home;
 if length(coalesce(p_search,''))>160 then raise exception 'Shorten your search';end if;
 return coalesce((select jsonb_agg(x.v) from (
 select jsonb_build_object('kind','shopping','id',s.id,'revision',s.revision,'title',s.data->>'title','image',s.data->>'image','url',s.data->>'url','quantity',s.data->>'quantity','status',s.status) v from public.cb_shopping_items s join public.cb_shopping_lists l on l.id=s.list_id where l.project_id=p and not l.archived and public.cb_shopping_access(l.id) and s.data->>'title' ilike '%'||coalesce(p_search,'')||'%' and not exists(select 1 from public.cb_home_items i where i.shopping_id=s.id)
 union all select jsonb_build_object('kind','gift','id',g.id,'revision',g.revision,'follow_revision',f.revision,'title',f.inventory_item->>'title','image',f.inventory_item->>'image','url',f.inventory_item->>'url','quantity',g.quantity,'status',g.status) from public.cb_registry_reservations g join public.cb_registry_entries e on e.id=g.entry_id join public.cb_registry_followups f on f.gift_id=g.id where e.project_id=p and public.cb_project_access(p,'write') and g.status='Received' and coalesce((f.data->>'inventory')::boolean,false) and f.inventory_item->>'title' ilike '%'||coalesce(p_search,'')||'%' and not exists(select 1 from public.cb_home_items i where i.gift_id=g.id) limit 100
 ) x),'[]');end;$$;
create or replace function public.cb_save_home_item(p_home uuid,p_home_revision bigint,p_id uuid,p_revision bigint,p_client uuid,p_data jsonb,p_assignee uuid,p_source jsonb default null,p_confirm boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
declare h public.cb_home_plans;i public.cb_home_items;w public.cb_home_writes;payload jsonb;result jsonb;k text;sid uuid;gid uuid;s public.cb_shopping_items;g public.cb_registry_reservations;f public.cb_registry_followups;e public.cb_registry_entries;snap jsonb='{}';begin
 select * into h from public.cb_home_plans where id=p_home;perform 1 from public.cb_projects where id=h.project_id for update;select * into h from public.cb_home_plans where id=p_home for update;
 if not public.cb_home_access(p_home,true) or h.archived then raise exception 'Home editing access required' using errcode='42501';end if;
 payload=jsonb_build_object('action','item','home',p_home,'home_revision',p_home_revision,'id',p_id,'revision',p_revision,'data',p_data,'assignee',p_assignee,'source',p_source,'confirm',p_confirm);
 if p_client is null then raise exception 'Request ID required';end if;
 select * into w from public.cb_home_writes where user_id=auth.uid() and client=p_client;if found then if w.payload is distinct from payload then raise exception 'Retry the same home item details' using errcode='PT409';end if;return w.response;end if;
 if h.revision is distinct from p_home_revision then raise exception 'Home details changed. Refresh first.' using errcode='PT409';end if;
 if p_id is not null then select * into i from public.cb_home_items where id=p_id and home_id=p_home for update;if i.id is null then raise exception 'Home item unavailable' using errcode='42501';end if;end if;
 if coalesce(i.revision,0) is distinct from p_revision then raise exception 'Another device updated this item. Refresh first.' using errcode='PT409';end if;
 if jsonb_typeof(p_data) is distinct from 'object' or p_data-array['title','room','kind','status','due','notes','requiresSetup']::text[]<>'{}' or jsonb_typeof(p_data->'requiresSetup') is distinct from 'boolean' then raise exception 'Review home item fields';end if;
 foreach k in array array['title','room','kind','status','due','notes'] loop if jsonb_typeof(p_data->k) is distinct from 'string' or length(p_data->>k)>(case when k='notes' then 2000 when k='room' then 80 else 160 end) then raise exception 'Review item text limits';end if;end loop;
 if length(btrim(p_data->>'title'))<1 or length(btrim(p_data->>'room'))<1 or p_data->>'kind' not in ('Household need','Room task','Utility & service','Moving & delivery','Responsibility','Safety & maintenance') or p_data->>'status' not in ('Needed','Planned','In progress','Already owned','Complete','Cancelled') then raise exception 'Choose item title, room, category and status';end if;
 if p_data->>'due'<>'' then if p_data->>'due'!~'^\d{4}-\d{2}-\d{2}$' then raise exception 'Choose a valid due date';end if;perform (p_data->>'due')::date;end if;
 if p_assignee is not null and (not exists(select 1 from public.cb_projects where id=h.project_id and owner_id=p_assignee union all select 1 from public.cb_members where project_id=h.project_id and user_id=p_assignee) or not (p_assignee=h.owner_id or p_assignee=any(h.readers||h.editors))) then raise exception 'Assign an accepted person with access to this home';end if;
 p_data=jsonb_set(p_data,'{room}',to_jsonb(coalesce((select data->>'room' from public.cb_home_items where home_id=p_home and lower(data->>'room')=lower(btrim(p_data->>'room')) order by id limit 1),btrim(p_data->>'room'))));
 sid=i.shopping_id;gid=i.gift_id;snap=coalesce(i.source_snapshot,'{}');
 if p_source is not null then
 if i.id is not null or not coalesce(p_confirm,false) or p_data->>'kind'<>'Household need' or jsonb_typeof(p_source) is distinct from 'object' or p_source-array['kind','id','revision','follow_revision']::text[]<>'{}' then raise exception 'Review and confirm the product link on a new household need';end if;
 if p_source->>'kind'='shopping' then
 select x.* into s from public.cb_shopping_items x join public.cb_shopping_lists l on l.id=x.list_id where x.id=(p_source->>'id')::uuid and l.project_id=h.project_id and not l.archived and public.cb_shopping_access(l.id) for update of x;
 if s.id is null then raise exception 'Shopping source access required' using errcode='42501';end if;if s.revision is distinct from (p_source->>'revision')::bigint then raise exception 'Shopping item changed. Review it again.' using errcode='PT409';end if;
 sid=s.id;snap=jsonb_build_object('title',s.data->>'title','image',s.data->>'image','url',s.data->>'url','quantity',s.data->>'quantity');
 elsif p_source->>'kind'='gift' then
 if not coalesce(public.cb_project_access(h.project_id,'write'),false) then raise exception 'Gift inventory access required' using errcode='42501';end if;
 select * into g from public.cb_registry_reservations where id=(p_source->>'id')::uuid for update;select * into e from public.cb_registry_entries where id=g.entry_id;select * into f from public.cb_registry_followups where gift_id=g.id for update;
 if e.project_id is distinct from h.project_id or g.status is distinct from 'Received' or not coalesce((f.data->>'inventory')::boolean,false) then raise exception 'Choose a received household gift';end if;
 if g.revision is distinct from (p_source->>'revision')::bigint or f.revision is distinct from (p_source->>'follow_revision')::bigint then raise exception 'Gift inventory changed. Review it again.' using errcode='PT409';end if;
 gid=g.id;snap=jsonb_build_object('title',f.inventory_item->>'title','image',f.inventory_item->>'image','url',f.inventory_item->>'url','quantity',g.quantity);
 else raise exception 'Choose shopping or received gift inventory';end if;
 end if;
 if sid is not null or gid is not null then
 if p_data->>'kind'<>'Household need' then raise exception 'Linked goods stay under household needs';end if;
 if p_data->>'status' in ('Complete','Already owned') and not (case when sid is not null then exists(select 1 from public.cb_shopping_items where id=sid and status='Delivered') else exists(select 1 from public.cb_registry_reservations x join public.cb_registry_followups y on y.gift_id=x.id where x.id=gid and x.status='Received' and coalesce((y.data->>'inventory')::boolean,false)) end) then raise exception 'Wait until the linked item is received before completing setup';end if;
 end if;
 if i.id is null then
 if (select count(*) from public.cb_home_items where home_id=p_home)>=3000 then raise exception 'Household item allowance reached';end if;
 if exists(select 1 from public.cb_home_items where shopping_id=sid or gift_id=gid) then raise exception 'This product is already linked to a household' using errcode='PT409';end if;
 insert into public.cb_home_items(home_id,data,assignee,shopping_id,gift_id,source_snapshot) values(p_home,p_data,p_assignee,sid,gid,snap) returning * into i;
 else update public.cb_home_items set data=p_data,assignee=p_assignee,revision=revision+1,updated_at=now() where id=i.id returning * into i;end if;
 result=public.cb_home_item_view(i.id);insert into public.cb_home_history values('item',i.id,i.revision,auth.uid(),to_jsonb(i),now());insert into public.cb_home_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
revoke all on function public.cb_home_access(uuid,boolean),public.cb_home_people(uuid),public.cb_home_summary(uuid),public.cb_home_workspace(uuid),public.cb_save_home_plan(uuid,uuid,bigint,uuid,jsonb,uuid[],uuid[],boolean),public.cb_home_item_view(uuid),public.cb_home_detail(uuid),public.cb_home_sources(uuid,text),public.cb_save_home_item(uuid,bigint,uuid,bigint,uuid,jsonb,uuid,jsonb,boolean) from public,anon,authenticated;
grant execute on function public.cb_home_people(uuid),public.cb_home_workspace(uuid),public.cb_save_home_plan(uuid,uuid,bigint,uuid,jsonb,uuid[],uuid[],boolean),public.cb_home_detail(uuid),public.cb_home_sources(uuid,text),public.cb_save_home_item(uuid,bigint,uuid,bigint,uuid,jsonb,uuid,jsonb,boolean) to authenticated;
notify pgrst,'reload schema';commit;
