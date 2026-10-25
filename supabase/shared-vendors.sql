-- Shared vendor directory. Selected personal fields are shared only through explicit review.
begin;
create table if not exists public.cb_shared_vendors(
 id uuid primary key default gen_random_uuid(),seq bigint generated always as identity unique,
 project_id uuid not null references public.cb_projects on delete cascade,created_by uuid not null references auth.users,
 local_ref text not null,name text not null check(length(btrim(name)) between 1 and 160),details jsonb not null default '{}',
 readers uuid[] not null default '{}',archived boolean not null default false,revision bigint not null default 1,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(project_id,created_by,local_ref)
);
create table if not exists public.cb_vendor_writes(user_id uuid not null references auth.users,client_id uuid not null,vendor_id uuid not null references public.cb_shared_vendors on delete cascade,payload jsonb not null,response jsonb not null,primary key(user_id,client_id));
create table if not exists public.cb_vendor_versions(vendor_id uuid references public.cb_shared_vendors on delete cascade,revision bigint not null,actor_id uuid not null references auth.users,snapshot jsonb not null,at timestamptz not null default now(),primary key(vendor_id,revision));
alter table public.cb_shared_vendors enable row level security;
alter table public.cb_vendor_writes enable row level security;
alter table public.cb_vendor_versions enable row level security;
revoke all on public.cb_shared_vendors,public.cb_vendor_writes,public.cb_vendor_versions from public,anon,authenticated;
create or replace function public.cb_shared_vendor_access(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_shared_vendors v where v.id=p_id and public.cb_project_access(v.project_id,'read') and (public.cb_project_access(v.project_id,'owner') or public.cb_project_access(v.project_id,'write') or auth.uid()=any(v.readers)));
$$;
create or replace function public.cb_list_shared_vendors(p_project uuid,p_query text default '',p_before bigint default null) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.cb_project_access(p_project,'read') then raise exception 'Wedding access denied' using errcode='42501';end if;
 if length(coalesce(p_query,''))>100 then raise exception 'Search using up to 100 characters';end if;
 return (select coalesce(jsonb_agg(row order by seq desc),'[]') from (select seq,(to_jsonb(v)-'local_ref')||jsonb_build_object('seq',v.seq::text,'editable',public.cb_project_access(p_project,'write')) row from public.cb_shared_vendors v where project_id=p_project and public.cb_shared_vendor_access(id) and (p_before is null or seq<p_before) and strpos(lower(name||' '||coalesce(details->>'category','')),lower(coalesce(p_query,'')))>0 order by seq desc limit 50) records);
end; $$;
create or replace function public.cb_shared_vendor_detail(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.cb_shared_vendor_access(p_id) then raise exception 'Vendor access denied' using errcode='42501';end if;
 return (select (to_jsonb(v)-'local_ref')||jsonb_build_object('seq',v.seq::text,'editable',public.cb_project_access(project_id,'write'),'conversations',public.cb_chat_record_sources('vendor',id),'history',case when public.cb_project_access(project_id,'write') then (select coalesce(jsonb_agg(jsonb_build_object('revision',revision,'at',at,'name',snapshot->>'name') order by revision desc),'[]') from (select * from public.cb_vendor_versions where vendor_id=v.id order by revision desc limit 20) versions) else '[]'::jsonb end) from public.cb_shared_vendors v where id=p_id);
end; $$;
create or replace function public.cb_save_shared_vendor(p_project uuid,p_id uuid,p_client uuid,p_ref text,p_revision bigint,p_name text,p_details jsonb,p_readers uuid[],p_archived boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.cb_shared_vendors;previous public.cb_vendor_writes;payload jsonb;person uuid;part record;result jsonb;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not public.cb_project_access(p_project,'write') then raise exception 'Vendor editing access denied' using errcode='42501';end if;
 if p_client is null then raise exception 'A save request ID is required';end if;
 payload=jsonb_build_object('project',p_project,'id',p_id,'ref',p_ref,'revision',p_revision,'name',p_name,'details',p_details,'readers',p_readers,'archived',p_archived);
 select * into previous from public.cb_vendor_writes where user_id=auth.uid() and client_id=p_client;
 if found then if previous.payload is distinct from payload then raise exception 'Vendor changed during retry. Reload before saving.' using errcode='PT409';end if;return previous.response;end if;
 if length(btrim(coalesce(p_name,''))) not between 1 and 160 or p_archived is null or jsonb_typeof(p_details) is distinct from 'object' or octet_length(p_details::text)>12000 or p_details-array['category','location','services','email','phone','portfolio','stage']::text[]<>'{}' then raise exception 'Enter valid vendor details';end if;
 for part in select * from jsonb_each(p_details) loop if jsonb_typeof(part.value)<>'string' or length(part.value#>>'{}')>2000 then raise exception 'Vendor fields must be text, up to 2000 characters';end if;end loop;
 if coalesce(p_details->>'portfolio','')<>'' and ((p_details->>'portfolio') !~ '^https://[^/@[:space:]]+\.[^/[:space:]]+' or (p_details->>'portfolio') ~ '^https://[^/]*@' or length(p_details->>'portfolio')>2000) then raise exception 'Use a complete HTTPS portfolio link without credentials';end if;
 if coalesce(p_details->>'email','')<>'' and ((p_details->>'email') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or length(p_details->>'email')>254) then raise exception 'Use a valid vendor email';end if;
 if p_readers is null or cardinality(p_readers)>100 or array_position(p_readers,null) is not null or cardinality(p_readers)<>(select count(distinct x) from unnest(p_readers) x) then raise exception 'Choose up to 100 teammates';end if;
 foreach person in array p_readers loop if not public.cb_collab_user_access(person,p_project,'read') then raise exception 'Choose active accepted teammates';end if;end loop;
 if p_id is null then
  if p_revision<>0 or length(coalesce(p_ref,'')) not between 1 and 240 then raise exception 'Use a new vendor reference';end if;
  if exists(select 1 from public.cb_shared_vendors where project_id=p_project and created_by=auth.uid() and local_ref=p_ref) then raise exception 'This vendor is already shared. Open its shared record.' using errcode='PT409';end if;
  insert into public.cb_shared_vendors(project_id,created_by,local_ref,name,details,readers,archived) values(p_project,auth.uid(),p_ref,btrim(p_name),p_details,p_readers,p_archived) returning * into v;
 else
  update public.cb_shared_vendors set name=btrim(p_name),details=p_details,readers=p_readers,archived=p_archived,revision=revision+1,updated_at=now() where id=p_id and project_id=p_project and revision=p_revision returning * into v;
  if not found then raise exception 'Vendor changed. Reload before saving.' using errcode='PT409';end if;
 end if;
 insert into public.cb_vendor_versions(vendor_id,revision,actor_id,snapshot) values(v.id,v.revision,auth.uid(),to_jsonb(v)-'local_ref');
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(p_project,auth.uid(),'Shared vendor updated',array['vendor']);
 result=(to_jsonb(v)-'local_ref')||jsonb_build_object('seq',v.seq::text,'editable',true);
 insert into public.cb_vendor_writes(user_id,client_id,vendor_id,payload,response) values(auth.uid(),p_client,v.id,payload,result);
 return result;
end; $$;
-- Extend existing record links; every read still checks the target's own permissions.
alter table public.cb_chat_record_links drop constraint if exists cb_chat_record_links_kind_check;
alter table public.cb_chat_record_links add constraint cb_chat_record_links_kind_check check(kind in ('task','decision','event','vendor'));
do $migration$ begin
 if to_regprocedure('public.cb_chat_record_project_before_vendors(text,uuid)') is null then alter function public.cb_chat_record_project(text,uuid) rename to cb_chat_record_project_before_vendors;end if;
 if to_regprocedure('public.cb_chat_record_context_before_vendors(uuid,bigint,text,text)') is null then alter function public.cb_chat_record_context(uuid,bigint,text,text) rename to cb_chat_record_context_before_vendors;end if;
 if to_regprocedure('public.cb_chat_record_detail_before_vendors(text,uuid)') is null then alter function public.cb_chat_record_detail(text,uuid) rename to cb_chat_record_detail_before_vendors;end if;
end; $migration$;
create or replace function public.cb_chat_record_project(p_kind text,p_target uuid) returns uuid language sql stable security definer set search_path='' as $$select case when p_kind='vendor' then (select project_id from public.cb_shared_vendors where id=p_target and public.cb_shared_vendor_access(id)) else public.cb_chat_record_project_before_vendors(p_kind,p_target) end$$;
create or replace function public.cb_chat_record_context(p_thread uuid,p_message bigint,p_kind text,p_query text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare pid uuid;
begin
 if p_kind<>'vendor' or p_kind is null then return public.cb_chat_record_context_before_vendors(p_thread,p_message,p_kind,p_query);end if;
 select project_id into pid from public.cb_chat_threads where id=p_thread;
 if not public.cb_chat_access(p_thread) or not public.cb_project_access(pid,'write') then raise exception 'Record linking access denied' using errcode='42501';end if;
 if not exists(select 1 from public.cb_chat_messages where id=p_message and thread_id=p_thread) then raise exception 'Message is not in this conversation';end if;
 if length(coalesce(p_query,''))>100 then raise exception 'Search using up to 100 characters';end if;
 return (select coalesce(jsonb_agg(row order by name,id),'[]') from (select name,id,jsonb_build_object('id',id,'title',name,'detail',details->>'category') row from public.cb_shared_vendors where project_id=pid and not archived and public.cb_shared_vendor_access(id) and strpos(lower(name),lower(coalesce(p_query,'')))>0 order by name,id limit 50) records);
end; $$;
create or replace function public.cb_chat_record_detail(p_kind text,p_target uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb;
begin
 if p_kind<>'vendor' or p_kind is null then return public.cb_chat_record_detail_before_vendors(p_kind,p_target);end if;
 v=public.cb_shared_vendor_detail(p_target);
 return jsonb_build_object('kind','vendor','project',v->>'project_id','record',jsonb_build_object('id',v->>'id','title',v->>'name','notes',v->'details'->>'services','category',v->'details'->>'category','location',v->'details'->>'location','stage',v->'details'->>'stage','archived',v->'archived'),'conversations',v->'conversations');
end; $$;
revoke all on function public.cb_shared_vendor_access(uuid),public.cb_list_shared_vendors(uuid,text,bigint),public.cb_shared_vendor_detail(uuid),public.cb_save_shared_vendor(uuid,uuid,uuid,text,bigint,text,jsonb,uuid[],boolean),public.cb_chat_record_project_before_vendors(text,uuid),public.cb_chat_record_context_before_vendors(uuid,bigint,text,text),public.cb_chat_record_detail_before_vendors(text,uuid),public.cb_chat_record_project(text,uuid),public.cb_chat_record_context(uuid,bigint,text,text),public.cb_chat_record_detail(text,uuid) from public,anon,authenticated;
grant execute on function public.cb_list_shared_vendors(uuid,text,bigint),public.cb_shared_vendor_detail(uuid),public.cb_save_shared_vendor(uuid,uuid,uuid,text,bigint,text,jsonb,uuid[],boolean),public.cb_chat_record_context(uuid,bigint,text,text),public.cb_chat_record_detail(text,uuid) to authenticated;
create or replace function public.cb_chat_history(p_thread uuid,p_before bigint default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;rows jsonb;pid uuid;
begin
 result=public.cb_chat_history_before_record_links(p_thread,p_before);select project_id into pid from public.cb_chat_threads where id=p_thread;
 select coalesce(jsonb_agg(m||jsonb_build_object('record_links',(select coalesce(jsonb_agg(jsonb_build_object('kind',l.kind,'id',l.target_id,'project',pid,'title',case l.kind when 'vendor' then (select name from public.cb_shared_vendors where id=l.target_id) when 'task' then (select title from public.cb_tasks where id=l.target_id) when 'decision' then (select title from public.cb_decisions where id=l.target_id) else (select title from public.cb_project_events where id=l.target_id) end)),'[]') from public.cb_chat_record_links l where l.message_id=(m->>'id')::bigint and public.cb_chat_record_project(l.kind,l.target_id)=pid)) order by (m->>'id')::bigint),'[]') into rows from jsonb_array_elements(result->'messages') m;
 return jsonb_set(result,'{messages}',rows);
end; $$;

revoke all on function public.cb_chat_history(uuid,bigint) from public,anon,authenticated;
grant execute on function public.cb_chat_history(uuid,bigint) to authenticated;
create or replace function public.cb_shared_vendor_signal() returns trigger language plpgsql security definer set search_path='' as $$
declare r record;begin
 for r in select distinct x.user_id from public.cb_chat_record_links l join public.cb_chat_messages m on m.id=l.message_id join public.cb_chat_participants x on x.thread_id=m.thread_id where l.kind='vendor' and l.target_id=new.id order by x.user_id loop perform public.cb_chat_signal_user(r.user_id);end loop;return new;end; $$;
drop trigger if exists cb_shared_vendor_updates on public.cb_shared_vendors;
create trigger cb_shared_vendor_updates after update on public.cb_shared_vendors for each row execute function public.cb_shared_vendor_signal();
create or replace function public.cb_shared_vendor_deleted() returns trigger language plpgsql security definer set search_path='' as $$begin delete from public.cb_chat_record_links where kind='vendor' and target_id=old.id;return old;end; $$;
drop trigger if exists cb_shared_vendor_cleanup on public.cb_shared_vendors;
create trigger cb_shared_vendor_cleanup after delete on public.cb_shared_vendors for each row execute function public.cb_shared_vendor_deleted();
revoke all on function public.cb_shared_vendor_signal(),public.cb_shared_vendor_deleted() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
