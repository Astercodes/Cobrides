-- Shared Wedding Memories: reviewed albums and signed-in guest contributions.
-- Run after wedding-projects.sql, storage-recovery.sql and private file storage.
begin;
create table if not exists public.cb_memory_albums(id uuid primary key default gen_random_uuid(),project_id uuid not null references public.cb_projects on delete cascade,created_by uuid not null references auth.users,event_id uuid references public.cb_project_events,title text not null,description text not null default '',guest_visible boolean not null default false,uploads_open boolean not null default false,archived boolean not null default false,revision bigint not null default 1,updated_at timestamptz not null default now());
create table if not exists public.cb_memory_links(album_id uuid primary key references public.cb_memory_albums on delete cascade,token text not null unique default replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-',''),generation bigint not null default 1);
create table if not exists public.cb_memory_guests(album_id uuid not null references public.cb_memory_albums on delete cascade,user_id uuid not null references auth.users on delete cascade,generation bigint not null,joined_at timestamptz not null default now(),primary key(album_id,user_id));
create table if not exists public.cb_memory_items(id uuid primary key default gen_random_uuid(),album_id uuid not null references public.cb_memory_albums on delete cascade,created_by uuid not null references auth.users,local_ref text not null,title text not null,caption text not null default '',file_path text not null,mime text not null,bytes bigint not null,status text not null default 'Pending review' check(status in ('Pending review','Approved','Hidden','Archived')),revision bigint not null default 1,reviewed_by uuid references auth.users,reviewed_at timestamptz,updated_at timestamptz not null default now(),unique(album_id,created_by,local_ref));
create table if not exists public.cb_memory_history(item_id uuid not null references public.cb_memory_items on delete cascade,revision bigint not null,actor_id uuid not null,kind text not null,snapshot jsonb not null,at timestamptz not null default now(),primary key(item_id,revision));
create table if not exists public.cb_memory_writes(user_id uuid not null references auth.users on delete cascade,client uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client));
alter table public.cb_memory_albums enable row level security;alter table public.cb_memory_links enable row level security;alter table public.cb_memory_guests enable row level security;alter table public.cb_memory_items enable row level security;alter table public.cb_memory_history enable row level security;alter table public.cb_memory_writes enable row level security;
revoke all on public.cb_memory_albums,public.cb_memory_links,public.cb_memory_guests,public.cb_memory_items,public.cb_memory_history,public.cb_memory_writes from public,anon,authenticated;
create index if not exists cb_memory_project on public.cb_memory_albums(project_id);
create index if not exists cb_memory_album_items on public.cb_memory_items(album_id,updated_at desc);
create or replace function public.cb_memory_manager(p_album uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.cb_memory_albums a where a.id=p_album and public.cb_project_access(a.project_id,'write') and (a.event_id is null or public.cb_project_event_access(a.event_id)))$$;
create or replace function public.cb_memory_guest(p_album uuid) returns boolean language sql stable security definer set search_path='' as $$select auth.uid() is not null and exists(select 1 from public.cb_memory_guests g join public.cb_memory_links l on l.album_id=g.album_id and l.generation=g.generation join public.cb_memory_albums a on a.id=g.album_id join public.cb_projects p on p.id=a.project_id where g.album_id=p_album and g.user_id=auth.uid() and not a.archived and p.archived_at is null)$$;
create or replace function public.cb_memory_can_read(p_item uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.cb_memory_items m join public.cb_memory_albums a on a.id=m.album_id where m.id=p_item and (public.cb_memory_manager(a.id) or public.cb_memory_guest(a.id) and (m.created_by=auth.uid() or a.guest_visible and m.status='Approved')))$$;
create or replace function public.cb_memory_file_access(p_path text) returns boolean language sql stable security definer set search_path='' as $$select auth.uid() is not null and exists(select 1 from public.cb_memory_items m where m.file_path=p_path and public.cb_memory_can_read(m.id))$$;
drop policy if exists cb_memory_reviewed_read on storage.objects;
create policy cb_memory_reviewed_read on storage.objects for select to authenticated using(bucket_id='cb-memories' and public.cb_memory_file_access(name));
-- Shared files and previous reviewed versions are protected from unused-file cleanup.
do $reference$ begin if to_regprocedure('public.cb_file_referenced_before_memories(text,text)') is null then alter function public.cb_file_referenced(text,text) rename to cb_file_referenced_before_memories;end if;end;$reference$;
create or replace function public.cb_file_referenced(p_bucket text,p_path text) returns boolean language sql security definer set search_path='' as $$select public.cb_file_referenced_before_memories(p_bucket,p_path) or p_bucket='cb-memories' and (exists(select 1 from public.cb_memory_items where file_path=p_path) or exists(select 1 from public.cb_memory_history where snapshot->>'file_path'=p_path))$$;
create or replace function public.cb_save_memory_album(p_project uuid,p_id uuid,p_revision bigint,p_client uuid,p_event uuid,p_title text,p_description text,p_visible boolean,p_uploads boolean,p_archived boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.cb_memory_albums;w public.cb_memory_writes;payload jsonb;result jsonb;is_owner boolean;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not coalesce(public.cb_project_access(p_project,'write'),false) then raise exception 'Wedding manager access required' using errcode='42501';end if;
 is_owner=public.cb_project_access(p_project,'owner');
 if p_event is not null and not exists(select 1 from public.cb_project_events where id=p_event and project_id=p_project and public.cb_project_event_access(id)) then raise exception 'Choose an accessible celebration';end if;
 payload=jsonb_build_object('action','album','project',p_project,'id',p_id,'revision',p_revision,'event',p_event,'title',p_title,'description',p_description,'visible',p_visible,'uploads',p_uploads,'archived',p_archived);
 if p_client is null then raise exception 'Request ID required';end if;
 select * into w from public.cb_memory_writes where user_id=auth.uid() and client=p_client;if found then if w.payload is distinct from payload then raise exception 'Retry the same album details' using errcode='PT409';end if;return w.response;end if;
 if p_title is null or length(btrim(p_title)) not between 1 and 160 or p_description is null or length(p_description)>2000 or p_visible is null or p_uploads is null or p_archived is null then raise exception 'Review album details';end if;
 if p_id is null then
  if p_revision is distinct from 0::bigint then raise exception 'Refresh before creating an album' using errcode='PT409';end if;
  if not is_owner and (p_visible or p_uploads) then raise exception 'Only the wedding owner can open guest sharing';end if;
  if (select count(*) from public.cb_memory_albums where project_id=p_project)>=500 then raise exception 'Album allowance reached';end if;
  insert into public.cb_memory_albums(project_id,created_by,event_id,title,description,guest_visible,uploads_open,archived) values(p_project,auth.uid(),p_event,btrim(p_title),p_description,p_visible,p_uploads,p_archived) returning * into a;
  insert into public.cb_memory_links(album_id) values(a.id);
 else
  select * into a from public.cb_memory_albums where id=p_id and project_id=p_project for update;
  if not found or not public.cb_memory_manager(a.id) then raise exception 'Album unavailable' using errcode='42501';end if;
  if a.revision is distinct from p_revision then raise exception 'Album changed. Refresh first.' using errcode='PT409';end if;
  if not is_owner and (a.guest_visible,a.uploads_open,a.archived) is distinct from (p_visible,p_uploads,p_archived) then raise exception 'Only the wedding owner can change album sharing';end if;
  update public.cb_memory_albums set event_id=p_event,title=btrim(p_title),description=p_description,guest_visible=p_visible,uploads_open=p_uploads,archived=p_archived,revision=revision+1,updated_at=now() where id=a.id returning * into a;
 end if;
 result=to_jsonb(a);insert into public.cb_memory_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
create or replace function public.cb_memory_workspace(p_project uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(public.cb_project_access(p_project,'write'),false) then raise exception 'Wedding manager access required' using errcode='42501';end if;
 return jsonb_build_object('project',p_project,'owner',public.cb_project_access(p_project,'owner'),'events',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title) order by title),'[]') from public.cb_project_events where project_id=p_project and public.cb_project_event_access(id)),'albums',(select coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('token',case when public.cb_project_access(p_project,'owner') then l.token end) order by a.archived,a.updated_at desc),'[]') from public.cb_memory_albums a join public.cb_memory_links l on l.album_id=a.id where a.project_id=p_project and public.cb_memory_manager(a.id)));
end;$$;
create or replace function public.cb_join_memory_album(p_token text) returns uuid language plpgsql security definer set search_path='' as $$
declare a public.cb_memory_albums;l public.cb_memory_links;
begin
 if auth.uid() is null then raise exception 'Sign in to open this album' using errcode='42501';end if;
 if p_token is null or p_token!~'^[a-f0-9]{64}$' then raise exception 'This album invitation is unavailable' using errcode='42501';end if;
 select * into l from public.cb_memory_links where token=p_token for share;
 select * into a from public.cb_memory_albums where id=l.album_id for share;
 if a.id is null or a.archived or not(a.guest_visible or a.uploads_open) or not exists(select 1 from public.cb_projects where id=a.project_id and archived_at is null) then raise exception 'This album invitation is closed' using errcode='42501';end if;
 insert into public.cb_memory_guests values(a.id,auth.uid(),l.generation,now()) on conflict(album_id,user_id) do update set generation=excluded.generation,joined_at=excluded.joined_at;return a.id;
end;$$;
create or replace function public.cb_memory_album(p_album uuid,p_before jsonb default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.cb_memory_albums;manager boolean;
begin
 select * into a from public.cb_memory_albums where id=p_album;manager=public.cb_memory_manager(p_album);
 if a.id is null or not(manager or public.cb_memory_guest(p_album)) then raise exception 'Album access required' using errcode='42501';end if;
 return jsonb_build_object('album',jsonb_build_object('id',a.id,'title',a.title,'description',a.description,'archived',a.archived,'guest_visible',a.guest_visible,'uploads_open',a.uploads_open,'revision',a.revision),'manager',manager,'owner',public.cb_project_access(a.project_id,'owner'),'can_upload',not a.archived and (manager or a.uploads_open and public.cb_memory_guest(a.id)),
 'items',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'album',m.album_id,'mine',m.created_by=auth.uid(),'title',m.title,'caption',m.caption,'file_path',m.file_path,'mime',m.mime,'bytes',m.bytes,'status',m.status,'revision',m.revision,'updated_at',m.updated_at) order by m.updated_at desc,m.id desc),'[]') from (select m.* from public.cb_memory_items m where m.album_id=a.id and public.cb_memory_can_read(m.id) and (manager or m.status<>'Archived') and (p_before is null or (m.updated_at,m.id)<((p_before->>'at')::timestamptz,(p_before->>'id')::uuid)) order by m.updated_at desc,m.id desc limit 101) m));
end;$$;
create or replace function public.cb_rotate_memory_link(p_album uuid,p_revision bigint,p_client uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.cb_memory_albums;w public.cb_memory_writes;payload jsonb;result jsonb;
begin
 select * into a from public.cb_memory_albums where id=p_album;
 perform 1 from public.cb_projects where id=a.project_id for update;
 if not coalesce(public.cb_project_access(a.project_id,'owner'),false) then raise exception 'Only the wedding owner can revoke album links' using errcode='42501';end if;
 payload=jsonb_build_object('action','rotate','album',p_album,'revision',p_revision);if p_client is null then raise exception 'Request ID required';end if;
 select * into w from public.cb_memory_writes where user_id=auth.uid() and client=p_client;if found then if w.payload is distinct from payload then raise exception 'Retry the original request' using errcode='PT409';end if;return w.response;end if;
 select * into a from public.cb_memory_albums where id=p_album for update;
 if a.revision is distinct from p_revision then raise exception 'Album changed. Refresh first.' using errcode='PT409';end if;
 update public.cb_memory_links set token=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-',''),generation=generation+1 where album_id=p_album;
 update public.cb_memory_albums set revision=revision+1,updated_at=now() where id=p_album;
 result=jsonb_build_object('token',(select token from public.cb_memory_links where album_id=p_album));insert into public.cb_memory_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
create or replace function public.cb_save_memory_item(p_album uuid,p_id uuid,p_revision bigint,p_client uuid,p_ref text,p_title text,p_caption text,p_path text) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.cb_memory_albums;m public.cb_memory_items;w public.cb_memory_writes;payload jsonb;result jsonb;meta jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in to add memories' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':files',0));
 select * into a from public.cb_memory_albums where id=p_album;
 perform 1 from public.cb_projects where id=a.project_id for update;
 select * into a from public.cb_memory_albums where id=p_album for share;
 if a.id is null or a.archived or not(public.cb_memory_manager(a.id) or a.uploads_open and public.cb_memory_guest(a.id)) then raise exception 'This album is closed for uploads' using errcode='42501';end if;
 payload=jsonb_build_object('action','media','album',p_album,'id',p_id,'revision',p_revision,'ref',p_ref,'title',p_title,'caption',p_caption,'path',p_path);if p_client is null then raise exception 'Request ID required';end if;
 select * into w from public.cb_memory_writes where user_id=auth.uid() and client=p_client;if found then if w.payload is distinct from payload then raise exception 'Retry the same memory' using errcode='PT409';end if;return w.response;end if;
 if p_title is null or length(btrim(p_title)) not between 1 and 160 or p_caption is null or length(p_caption)>2000 or p_path is null or p_path !~ '^[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+$' or split_part(p_path,'/',1)<>auth.uid()::text then raise exception 'Choose your own uploaded photograph or video';end if;
 if exists(select 1 from public.cb_file_reservations where bucket='cb-memories' and path=p_path and deleting) then raise exception 'File cleanup is in progress. Upload this file again.';end if;
 select metadata into meta from storage.objects where bucket_id='cb-memories' and name=p_path;
 if meta is null or coalesce(meta->>'mimetype','') not in ('image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm') or coalesce((meta->>'size')::bigint,0) not between 1 and 20971520 then raise exception 'Upload a supported photo or video up to 20 MB first';end if;
 if p_id is null then
  if p_revision is distinct from 0::bigint or length(coalesce(p_ref,'')) not between 1 and 160 then raise exception 'Refresh before adding a memory' using errcode='PT409';end if;
  if (select count(*) from public.cb_memory_items where album_id=p_album)>=10000 or (select count(*) from public.cb_memory_items where album_id=p_album and created_by=auth.uid() and updated_at>now()-interval '1 hour')>=100 then raise exception 'Upload allowance reached. Please try later.' using errcode='PT429';end if;
  insert into public.cb_memory_items(album_id,created_by,local_ref,title,caption,file_path,mime,bytes) values(p_album,auth.uid(),p_ref,btrim(p_title),p_caption,p_path,meta->>'mimetype',(meta->>'size')::bigint) returning * into m;
 else
  select * into m from public.cb_memory_items where id=p_id and album_id=p_album for update;
  if m.id is null or m.created_by<>auth.uid() then raise exception 'Only the contributor can replace this memory' using errcode='42501';end if;
  if m.revision is distinct from p_revision then raise exception 'Memory changed. Refresh first.' using errcode='PT409';end if;
  update public.cb_memory_items set title=btrim(p_title),caption=p_caption,file_path=p_path,mime=meta->>'mimetype',bytes=(meta->>'size')::bigint,status='Pending review',reviewed_by=null,reviewed_at=null,revision=revision+1,updated_at=now() where id=m.id returning * into m;
 end if;
 result=to_jsonb(m);insert into public.cb_memory_history values(m.id,m.revision,auth.uid(),'Submitted',result,now());insert into public.cb_memory_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
create or replace function public.cb_review_memory_item(p_item uuid,p_revision bigint,p_client uuid,p_status text) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.cb_memory_albums;m public.cb_memory_items;w public.cb_memory_writes;payload jsonb;result jsonb;
begin
 select * into m from public.cb_memory_items where id=p_item;select * into a from public.cb_memory_albums where id=m.album_id;
 perform 1 from public.cb_projects where id=a.project_id for update;
 if not coalesce(public.cb_project_access(a.project_id,'owner'),false) then raise exception 'Only the wedding owner can approve or hide memories' using errcode='42501';end if;
 payload=jsonb_build_object('action','review','item',p_item,'revision',p_revision,'status',p_status);if p_client is null or p_status is null or p_status not in ('Pending review','Approved','Hidden','Archived') then raise exception 'Choose a review status';end if;
 select * into w from public.cb_memory_writes where user_id=auth.uid() and client=p_client;if found then if w.payload is distinct from payload then raise exception 'Retry the same review' using errcode='PT409';end if;return w.response;end if;
 select * into m from public.cb_memory_items where id=p_item for update;
 if m.revision is distinct from p_revision then raise exception 'Memory changed. Refresh before reviewing.' using errcode='PT409';end if;
 if a.archived and p_status='Approved' then raise exception 'Restore the album before approving';end if;
 update public.cb_memory_items set status=p_status,reviewed_by=auth.uid(),reviewed_at=now(),revision=revision+1,updated_at=now() where id=m.id returning * into m;
 result=to_jsonb(m);insert into public.cb_memory_history values(m.id,m.revision,auth.uid(),'Review',result,now());insert into public.cb_memory_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
revoke all on function public.cb_memory_manager(uuid),public.cb_memory_guest(uuid),public.cb_memory_can_read(uuid),public.cb_memory_file_access(text),public.cb_file_referenced_before_memories(text,text),public.cb_file_referenced(text,text),public.cb_save_memory_album(uuid,uuid,bigint,uuid,uuid,text,text,boolean,boolean,boolean),public.cb_memory_workspace(uuid),public.cb_join_memory_album(text),public.cb_memory_album(uuid,jsonb),public.cb_rotate_memory_link(uuid,bigint,uuid),public.cb_save_memory_item(uuid,uuid,bigint,uuid,text,text,text,text),public.cb_review_memory_item(uuid,bigint,uuid,text) from public,anon,authenticated;
grant execute on function public.cb_memory_file_access(text),public.cb_save_memory_album(uuid,uuid,bigint,uuid,uuid,text,text,boolean,boolean,boolean),public.cb_memory_workspace(uuid),public.cb_join_memory_album(text),public.cb_memory_album(uuid,jsonb),public.cb_rotate_memory_link(uuid,bigint,uuid),public.cb_save_memory_item(uuid,uuid,bigint,uuid,text,text,text,text),public.cb_review_memory_item(uuid,bigint,uuid,text) to authenticated;
do $rebind$ declare signature text;body text;begin foreach signature in array array['public.cb_claim_unused_files()','public.cb_file_delete_allowed(text,text)'] loop if to_regprocedure(signature) is not null then body=pg_get_functiondef(to_regprocedure(signature));execute body;end if;end loop;end;$rebind$;
notify pgrst,'reload schema';commit;
