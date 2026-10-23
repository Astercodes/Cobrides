-- CoBrides storage allowance, safe cleanup and recovery. Rerunnable.
-- Run after cloud-storage.sql and file-storage.sql. No existing records are deleted.
begin;
create table if not exists public.cb_file_reservations (
 user_id uuid not null references auth.users on delete cascade,
 bucket text not null, path text not null, bytes bigint not null check(bytes between 1 and 20971520),
 touched_at timestamptz not null default now(), deleting boolean not null default false,
 primary key(bucket,path)
);
create table if not exists public.cb_workspace_backups (
 user_id uuid not null references auth.users on delete cascade, workspace text not null,
 revision bigint not null, payload jsonb not null, created_at timestamptz not null default now(),
 primary key(user_id,workspace,revision)
);
alter table public.cb_file_reservations enable row level security;
alter table public.cb_workspace_backups enable row level security;
revoke all on public.cb_file_reservations,public.cb_workspace_backups from public,anon,authenticated;
grant select on public.cb_workspace_backups to authenticated;
drop policy if exists cb_backup_owner on public.cb_workspace_backups;
create policy cb_backup_owner on public.cb_workspace_backups for select to authenticated using(user_id=auth.uid());

create or replace function public.cb_storage_status() returns jsonb
language plpgsql security definer set search_path='' as $$
declare used bigint; reserved bigint;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select coalesce(sum((metadata->>'size')::bigint),0) into used from storage.objects
 where bucket_id in ('cb-inspiration','cb-documents','cb-memories') and split_part(name,'/',1)=auth.uid()::text;
 select coalesce(sum(r.bytes),0) into reserved from public.cb_file_reservations r
 where r.user_id=auth.uid() and r.touched_at>now()-interval '1 hour' and not r.deleting
 and not exists(select 1 from storage.objects o where o.bucket_id=r.bucket and o.name=r.path);
 return jsonb_build_object('used',used,'reserved',reserved,'limit',524288000);
end; $$;

create or replace function public.cb_reserve_file(p_bucket text,p_path text,p_bytes bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare stats jsonb; existing bigint;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':files',0));
 if p_bucket not in ('cb-inspiration','cb-documents','cb-memories') or split_part(p_path,'/',1)<>auth.uid()::text
 or p_path !~ '^[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+$' or p_bytes is null or p_bytes<1 or p_bytes>20971520 then raise exception 'Invalid upload'; end if;
 delete from public.cb_file_reservations r where r.user_id=auth.uid() and r.bucket=p_bucket and r.path=p_path and r.deleting
 and not exists(select 1 from storage.objects o where o.bucket_id=r.bucket and o.name=r.path);
 if exists(select 1 from public.cb_file_reservations where bucket=p_bucket and path=p_path and deleting) then raise exception 'File cleanup is in progress. Retry shortly.'; end if;
 stats:=public.cb_storage_status();
 select (metadata->>'size')::bigint into existing from storage.objects where bucket_id=p_bucket and name=p_path;
 if existing is null then
  -- A repeated reservation does not consume the allowance twice.
  if (stats->>'used')::bigint+(stats->>'reserved')::bigint+p_bytes-coalesce((select bytes from public.cb_file_reservations where bucket=p_bucket and path=p_path and touched_at>now()-interval '1 hour'),0)>524288000 then
   raise exception 'Your 500 MB file allowance is full. Contact CoBrides support before uploading more.';
  end if;
 elsif existing<>p_bytes then raise exception 'File size does not match the saved upload'; end if;
 insert into public.cb_file_reservations(user_id,bucket,path,bytes) values(auth.uid(),p_bucket,p_path,p_bytes)
 on conflict(bucket,path) do update set touched_at=now(),bytes=excluded.bytes;
 return public.cb_storage_status();
end; $$;

create or replace function public.cb_file_insert_allowed(p_bucket text,p_path text,p_metadata jsonb) returns boolean
language sql security definer set search_path='' as $$
 select exists(select 1 from public.cb_file_reservations where user_id=auth.uid() and bucket=p_bucket and path=p_path
 and not deleting and touched_at>now()-interval '1 hour' and coalesce(p_metadata->>'size',p_metadata->>'contentLength')::bigint=bytes);
$$;
drop policy if exists cb_files_owner_insert on storage.objects;
create policy cb_files_owner_insert on storage.objects for insert to authenticated
with check(public.cb_file_insert_allowed(bucket_id,name,metadata));

-- Conservative reference matching also protects older URL-based snapshots.
create or replace function public.cb_file_referenced(p_bucket text,p_path text) returns boolean
language sql security definer set search_path='' as $$
 select exists(select 1 from public.cb_workspace_states where user_id=auth.uid() and strpos(payload::text,p_bucket||'/'||p_path)>0)
 or exists(select 1 from public.cb_workspace_backups where user_id=auth.uid() and strpos(payload::text,p_bucket||'/'||p_path)>0);
$$;

create or replace function public.cb_claim_unused_files() returns table(bucket text,path text)
language plpgsql security definer set search_path='' as $$
declare item record;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':files',0));
 delete from public.cb_workspace_backups where user_id=auth.uid() and created_at<now()-interval '30 days';
 delete from public.cb_file_reservations r where r.user_id=auth.uid() and r.touched_at<now()-interval '30 days'
 and not exists(select 1 from storage.objects o where o.bucket_id=r.bucket and o.name=r.path);
 for item in select o.bucket_id,o.name,greatest(1,coalesce((o.metadata->>'size')::bigint,1)) as bytes from storage.objects o
 left join public.cb_file_reservations r on r.bucket=o.bucket_id and r.path=o.name
 where o.bucket_id in ('cb-inspiration','cb-documents','cb-memories') and split_part(o.name,'/',1)=auth.uid()::text
 and greatest(o.created_at,coalesce(r.touched_at,o.created_at))<now()-interval '30 days'
 and not public.cb_file_referenced(o.bucket_id,o.name) limit 50
 loop
  insert into public.cb_file_reservations(user_id,bucket,path,bytes,deleting,touched_at)
  values(auth.uid(),item.bucket_id,item.name,least(item.bytes,20971520),true,now()-interval '31 days')
  on conflict on constraint cb_file_reservations_pkey do update set deleting=true;
  bucket:=item.bucket_id; path:=item.name; return next;
 end loop;
end; $$;
create or replace function public.cb_file_delete_allowed(p_bucket text,p_path text) returns boolean
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then return false; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':files',0));
 return exists(select 1 from public.cb_file_reservations where user_id=auth.uid() and bucket=p_bucket and path=p_path and deleting)
 and not public.cb_file_referenced(p_bucket,p_path);
end; $$;
drop policy if exists cb_files_safe_cleanup on storage.objects;
create policy cb_files_safe_cleanup on storage.objects for delete to authenticated using(public.cb_file_delete_allowed(bucket_id,name));

-- Keep up to 20 recovery points per workspace for up to 30 days.
-- Capture the prior version at most once every 15 minutes, not every keystroke.
create or replace function public.cb_capture_workspace_backup() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.cb_workspace_backups where user_id=old.user_id and workspace=old.workspace and created_at>now()-interval '15 minutes') then
  insert into public.cb_workspace_backups(user_id,workspace,revision,payload) values(old.user_id,old.workspace,old.revision,old.payload) on conflict do nothing;
 end if;
 delete from public.cb_workspace_backups where user_id=old.user_id and workspace=old.workspace and
 (created_at<now()-interval '30 days' or revision not in(select revision from public.cb_workspace_backups where user_id=old.user_id and workspace=old.workspace order by revision desc limit 20));
 return new;
end; $$;
drop trigger if exists cb_workspace_backup on public.cb_workspace_states;
create trigger cb_workspace_backup before update on public.cb_workspace_states for each row execute function public.cb_capture_workspace_backup();

create or replace function public.cb_save_workspace(p_workspace text,p_payload jsonb,p_revision bigint)
returns bigint language plpgsql security definer set search_path='' as $$
declare next_revision bigint; ref text; file_bucket text; file_path text;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':files',0));
 for ref in select distinct value #>> '{}' from jsonb_path_query(p_payload,'$.** ? (@.type() == "string")') value where value #>> '{}' like 'cb-file:v1:%'
 loop
  file_bucket:=split_part(substr(ref,12),'/',1); file_path:=substr(substr(ref,12),length(file_bucket)+2);
  if file_bucket not in ('cb-inspiration','cb-documents','cb-memories') or split_part(file_path,'/',1)<>auth.uid()::text
  or not exists(select 1 from storage.objects where bucket_id=file_bucket and name=file_path)
  or exists(select 1 from public.cb_file_reservations where bucket=file_bucket and path=file_path and deleting) then
   raise exception 'A referenced file is unavailable. Keep your changes and upload that file again.';
  end if;
 end loop;
 -- Start the grace period at the last saved use, including files removed by this edit.
 insert into public.cb_file_reservations(user_id,bucket,path,bytes,touched_at)
 select auth.uid(),o.bucket_id,o.name,greatest(1,least(20971520,(o.metadata->>'size')::bigint)),now()
 from storage.objects o where o.bucket_id in ('cb-inspiration','cb-documents','cb-memories') and split_part(o.name,'/',1)=auth.uid()::text
 and (strpos(p_payload::text,o.bucket_id||'/'||o.name)>0 or exists(select 1 from public.cb_workspace_states w where w.user_id=auth.uid() and w.workspace=p_workspace and strpos(w.payload::text,o.bucket_id||'/'||o.name)>0))
 on conflict(bucket,path) do update set touched_at=now();
 if p_revision=0 then
  insert into public.cb_workspace_states(user_id,workspace,payload) values(auth.uid(),p_workspace,p_payload) on conflict do nothing returning revision into next_revision;
 else
  update public.cb_workspace_states set payload=p_payload,revision=revision+1,updated_at=now() where user_id=auth.uid() and workspace=p_workspace and revision=p_revision returning revision into next_revision;
 end if;
 if next_revision is null then raise exception 'CB_SYNC_CONFLICT' using errcode='40001'; end if;
 return next_revision;
end; $$;
create or replace function public.cb_restore_workspace(p_workspace text,p_backup_revision bigint,p_revision bigint) returns bigint
language plpgsql security definer set search_path='' as $$
declare saved jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select payload into saved from public.cb_workspace_backups where user_id=auth.uid() and workspace=p_workspace and revision=p_backup_revision and created_at>=now()-interval '30 days';
 if saved is null then raise exception 'Recovery version not found'; end if;
 -- Preserve the current version before restoration, even inside the 15-minute window.
 insert into public.cb_workspace_backups(user_id,workspace,revision,payload)
 select user_id,workspace,revision,payload from public.cb_workspace_states where user_id=auth.uid() and workspace=p_workspace and revision=p_revision on conflict do nothing;
 return public.cb_save_workspace(p_workspace,saved,p_revision);
end; $$;
revoke all on function public.cb_capture_workspace_backup() from public,anon,authenticated;
revoke all on function public.cb_storage_status(),public.cb_reserve_file(text,text,bigint),public.cb_file_insert_allowed(text,text,jsonb),public.cb_file_referenced(text,text),public.cb_claim_unused_files(),public.cb_file_delete_allowed(text,text),public.cb_save_workspace(text,jsonb,bigint),public.cb_restore_workspace(text,bigint,bigint) from public,anon;
grant execute on function public.cb_storage_status(),public.cb_reserve_file(text,text,bigint),public.cb_file_insert_allowed(text,text,jsonb),public.cb_file_referenced(text,text),public.cb_claim_unused_files(),public.cb_file_delete_allowed(text,text),public.cb_save_workspace(text,jsonb,bigint),public.cb_restore_workspace(text,bigint,bigint) to authenticated;
commit;
