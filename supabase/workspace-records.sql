-- CoBrides record-based saving. Run after storage-recovery.sql. Rerunnable.
-- Existing workspace payloads stay intact until a complete record save commits.
begin;
create table if not exists public.cb_workspace_records (
 user_id uuid not null references auth.users on delete cascade, workspace text not null,
 record_key text not null check(octet_length(record_key)<=4096),
 from_revision bigint not null, to_revision bigint, closed_at timestamptz,
 body jsonb not null check(jsonb_typeof(body)='object' and octet_length(body::text)<=550000),
 primary key(user_id,workspace,record_key,from_revision),
 check(to_revision is null or to_revision>from_revision)
);
create unique index if not exists cb_records_current on public.cb_workspace_records(user_id,workspace,record_key) where to_revision is null;
create index if not exists cb_records_history on public.cb_workspace_records(user_id,workspace,from_revision,to_revision);
create table if not exists public.cb_record_uploads (
 user_id uuid not null references auth.users on delete cascade, batch uuid not null,
 workspace text not null, base_revision bigint not null, expected_count integer not null check(expected_count>=0),
 fingerprint text not null, replace_all boolean not null, committed_revision bigint,
 created_at timestamptz not null default now(), primary key(user_id,batch)
);
create table if not exists public.cb_record_changes (
 user_id uuid not null, batch uuid not null, record_key text not null,
 body jsonb, deleted boolean not null default false,
 primary key(user_id,batch,record_key),foreign key(user_id,batch) references public.cb_record_uploads on delete cascade
);
alter table public.cb_workspace_records enable row level security;
alter table public.cb_record_uploads enable row level security;
alter table public.cb_record_changes enable row level security;
revoke all on public.cb_workspace_records,public.cb_record_uploads,public.cb_record_changes from public,anon,authenticated;
grant select on public.cb_workspace_records to authenticated;
drop policy if exists cb_records_owner on public.cb_workspace_records;
create policy cb_records_owner on public.cb_workspace_records for select to authenticated using(user_id=auth.uid());

-- SQL version of the browser codec, used to restore legacy recovery snapshots.
create or replace function public.cb_flatten_workspace(p_value jsonb,p_path jsonb default '[]'::jsonb)
returns table(record_key text,body jsonb) language plpgsql set search_path='' as $$
declare field record; item jsonb; pos bigint:=0; item_id text; k text;
begin
 if jsonb_typeof(p_value)='object' then
  record_key:=p_path::text||':object:';body:=jsonb_build_object('path',p_path,'kind','object');return next;
  for field in select * from jsonb_each(p_value) loop return query select * from public.cb_flatten_workspace(field.value,p_path||jsonb_build_array(field.key)); end loop;
 elsif jsonb_typeof(p_value)='array' then
  record_key:=p_path::text||':array:';body:=jsonb_build_object('path',p_path,'kind','array');return next;
  for item in select value from jsonb_array_elements(p_value) loop
   item_id:=case when jsonb_typeof(item->'id')='string' and item->>'id'<>'' and (select count(*) from jsonb_array_elements(p_value) e where e->>'id'=item->>'id')=1 then 'id:'||(item->>'id') else 'index:'||pos end;
   record_key:=p_path::text||':item:'||item_id;body:=jsonb_build_object('path',p_path,'kind','item','id',item_id,'position',pos,'value',item);return next;pos:=pos+1;
  end loop;
 else record_key:=p_path::text||':value:';body:=jsonb_build_object('path',p_path,'kind','value','value',p_value);return next;
 end if;
end; $$;

create or replace function public.cb_begin_record_save(p_workspace text,p_batch uuid,p_revision bigint,p_count integer,p_fingerprint text,p_replace boolean)
returns boolean language plpgsql security definer set search_path='' as $$
declare prior public.cb_record_uploads; current_revision bigint;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 if p_workspace not in ('bride','planner','partner','bridal-party','family','vendor','merchant','venue','guest') or p_revision<0 or p_count<0 or p_count>1000000 or p_fingerprint !~ '^[0-9a-f]{64}$' then raise exception 'Invalid record save'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':files',0));
 select * into prior from public.cb_record_uploads where user_id=auth.uid() and batch=p_batch;
 if found then
  if prior.workspace<>p_workspace or prior.base_revision<>p_revision or prior.expected_count<>p_count or prior.fingerprint<>p_fingerprint or prior.replace_all<>p_replace then raise exception 'Save retry does not match'; end if;
  return true;
 end if;
 select revision into current_revision from public.cb_workspace_states where user_id=auth.uid() and workspace=p_workspace;
 if coalesce(current_revision,0)<>p_revision then raise exception 'CB_SYNC_CONFLICT' using errcode='PT409'; end if;
 -- Staging expires after seven days; committed retry tokens remain for 30 days.
 delete from public.cb_record_uploads where user_id=auth.uid() and created_at<now()-case when committed_revision is null then interval '7 days' else interval '30 days' end;
 insert into public.cb_record_uploads(user_id,batch,workspace,base_revision,expected_count,fingerprint,replace_all) values(auth.uid(),p_batch,p_workspace,p_revision,p_count,p_fingerprint,p_replace);
 return true;
end; $$;

create or replace function public.cb_stage_record_save(p_batch uuid,p_changes jsonb) returns boolean
language plpgsql security definer set search_path='' as $$
declare upload public.cb_record_uploads; change jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select * into upload from public.cb_record_uploads where user_id=auth.uid() and batch=p_batch for update;
 if not found then raise exception 'Save session expired. Retry saving.'; end if;
 if upload.committed_revision is not null then return true; end if;
 if jsonb_typeof(p_changes)<>'array' or jsonb_array_length(p_changes)>200 or octet_length(p_changes::text)>700000 then raise exception 'Save batch is too large'; end if;
 for change in select value from jsonb_array_elements(p_changes) loop
  if jsonb_typeof(change->'key')<>'string' or octet_length(change->>'key')>4096 or
  (not coalesce((change->>'deleted')::boolean,false) and (jsonb_typeof(change->'body')<>'object' or jsonb_typeof(change->'body'->'path')<>'array' or change->'body'->>'kind' not in ('object','array','item','value') or octet_length((change->'body')::text)>550000)) then raise exception 'Invalid planning record'; end if;
  if not coalesce((change->>'deleted')::boolean,false) and (change->>'key'<>(change->'body'->'path')::text||':'||(change->'body'->>'kind')||':'||coalesce(change->'body'->>'id','')
   or jsonb_path_exists(change->'body'->'path','$[*] ? (@.type() != "string")')) then raise exception 'Invalid record identity'; end if;
  insert into public.cb_record_changes(user_id,batch,record_key,body,deleted) values(auth.uid(),p_batch,change->>'key',change->'body',coalesce((change->>'deleted')::boolean,false))
  on conflict(user_id,batch,record_key) do update set body=excluded.body,deleted=excluded.deleted;
 end loop;
 if (select count(*) from public.cb_record_changes where user_id=auth.uid() and batch=p_batch)>upload.expected_count then raise exception 'Save batch does not match'; end if;
 return true;
end; $$;

create or replace function public.cb_touch_record_files(p_body jsonb,p_validate boolean) returns void
language plpgsql security definer set search_path='' as $$
declare ref text; file_bucket text; file_path text;
begin
 for ref in select distinct value #>> '{}' from jsonb_path_query(p_body,'$.** ? (@.type() == "string")') value where value #>> '{}' like 'cb-file:v1:%'
 loop
  file_bucket:=split_part(substr(ref,12),'/',1);file_path:=substr(substr(ref,12),length(file_bucket)+2);
  if p_validate and (file_bucket not in ('cb-inspiration','cb-documents','cb-memories') or split_part(file_path,'/',1)<>auth.uid()::text or
  not exists(select 1 from storage.objects where bucket_id=file_bucket and name=file_path) or exists(select 1 from public.cb_file_reservations where bucket=file_bucket and path=file_path and deleting)) then raise exception 'A referenced file is unavailable. Keep your changes and upload that file again.'; end if;
  insert into public.cb_file_reservations(user_id,bucket,path,bytes,touched_at)
  select auth.uid(),bucket_id,name,greatest(1,least(20971520,(metadata->>'size')::bigint)),now() from storage.objects
  where bucket_id=file_bucket and name=file_path and split_part(name,'/',1)=auth.uid()::text
  on conflict(bucket,path) do update set touched_at=now();
 end loop;
end; $$;

create or replace function public.cb_commit_record_save(p_batch uuid) returns bigint
language plpgsql security definer set search_path='' as $$
declare upload public.cb_record_uploads; head public.cb_workspace_states; next_revision bigint; item record;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':files',0));
 select * into upload from public.cb_record_uploads where user_id=auth.uid() and batch=p_batch for update;
 if not found then raise exception 'Save session expired. Retry saving.'; end if;
 if upload.committed_revision is not null then return upload.committed_revision; end if;
 select * into head from public.cb_workspace_states where user_id=auth.uid() and workspace=upload.workspace for update;
 if coalesce(head.revision,0)<>upload.base_revision then raise exception 'CB_SYNC_CONFLICT' using errcode='PT409'; end if;
 if (select count(*) from public.cb_record_changes where user_id=auth.uid() and batch=p_batch)<>upload.expected_count then raise exception 'Save is incomplete. Retry saving.'; end if;
 if coalesce(head.payload->>'cbRecordStore','0')<>'1' and not upload.replace_all then raise exception 'A complete first save is required'; end if;
 next_revision:=upload.base_revision+1;
 for item in select body from public.cb_record_changes where user_id=auth.uid() and batch=p_batch and not deleted loop perform public.cb_touch_record_files(item.body,true); end loop;
 for item in select r.body from public.cb_workspace_records r where r.user_id=auth.uid() and r.workspace=upload.workspace and r.to_revision is null and
 (upload.replace_all or exists(select 1 from public.cb_record_changes c where c.user_id=auth.uid() and c.batch=p_batch and c.record_key=r.record_key)) loop perform public.cb_touch_record_files(item.body,false); end loop;
 -- Legacy file references also receive a removal grace period during migration.
 if head.payload is not null and coalesce(head.payload->>'cbRecordStore','0')<>'1' then perform public.cb_touch_record_files(head.payload,false); end if;
 update public.cb_workspace_records r set to_revision=next_revision,closed_at=now()
 where r.user_id=auth.uid() and r.workspace=upload.workspace and r.to_revision is null and
 ((upload.replace_all and not exists(select 1 from public.cb_record_changes c where c.user_id=auth.uid() and c.batch=p_batch and c.record_key=r.record_key and not deleted)) or
 exists(select 1 from public.cb_record_changes c where c.user_id=auth.uid() and c.batch=p_batch and c.record_key=r.record_key and (c.deleted or c.body is distinct from r.body)));
 insert into public.cb_workspace_records(user_id,workspace,record_key,from_revision,body)
 select auth.uid(),upload.workspace,c.record_key,next_revision,c.body from public.cb_record_changes c
 where c.user_id=auth.uid() and c.batch=p_batch and not c.deleted and not exists(select 1 from public.cb_workspace_records r where r.user_id=auth.uid() and r.workspace=upload.workspace and r.record_key=c.record_key and r.to_revision is null);
 if not exists(select 1 from public.cb_workspace_records where user_id=auth.uid() and workspace=upload.workspace and record_key='[]:object:' and to_revision is null) then raise exception 'Workspace structure is incomplete'; end if;
 if upload.base_revision=0 then
  insert into public.cb_workspace_states(user_id,workspace,payload,revision) values(auth.uid(),upload.workspace,'{"cbRecordStore":1}',next_revision);
 else update public.cb_workspace_states set payload='{"cbRecordStore":1}',revision=next_revision,updated_at=now() where user_id=auth.uid() and workspace=upload.workspace; end if;
 update public.cb_record_uploads set committed_revision=next_revision where user_id=auth.uid() and batch=p_batch;
 -- Only retry metadata is needed after commit; staged record copies can be discarded.
 delete from public.cb_record_changes where user_id=auth.uid() and batch=p_batch;
 return next_revision;
end; $$;

-- Keep the legacy RPC for old sessions until their workspace has migrated.
do $$ begin if to_regprocedure('public.cb_save_workspace_legacy(text,jsonb,bigint)') is null then alter function public.cb_save_workspace(text,jsonb,bigint) rename to cb_save_workspace_legacy; end if; end $$;
create or replace function public.cb_save_workspace(p_workspace text,p_payload jsonb,p_revision bigint) returns bigint
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.cb_workspace_states where user_id=auth.uid() and workspace=p_workspace and payload->>'cbRecordStore'='1') then raise exception 'This workspace has been upgraded. Refresh CoBrides before saving.'; end if;
 return public.cb_save_workspace_legacy(p_workspace,p_payload,p_revision);
end; $$;

create or replace function public.cb_file_referenced(p_bucket text,p_path text) returns boolean
language sql security definer set search_path='' as $$
 select exists(select 1 from public.cb_workspace_states where user_id=auth.uid() and strpos(payload::text,p_bucket||'/'||p_path)>0)
 or exists(select 1 from public.cb_workspace_backups where user_id=auth.uid() and strpos(payload::text,p_bucket||'/'||p_path)>0)
 or exists(select 1 from public.cb_workspace_records where user_id=auth.uid() and strpos(body::text,p_bucket||'/'||p_path)>0);
$$;

create or replace function public.cb_restore_workspace(p_workspace text,p_backup_revision bigint,p_revision bigint) returns bigint
language plpgsql security definer set search_path='' as $$
declare saved jsonb; batch_id uuid:=gen_random_uuid(); total integer;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':files',0));
 select payload into saved from public.cb_workspace_backups where user_id=auth.uid() and workspace=p_workspace and revision=p_backup_revision and created_at>=now()-interval '30 days';
 if saved is null then raise exception 'Recovery version not found'; end if;
 if coalesce((select revision from public.cb_workspace_states where user_id=auth.uid() and workspace=p_workspace),0)<>p_revision then raise exception 'CB_SYNC_CONFLICT' using errcode='PT409'; end if;
 if saved->>'cbRecordStore'='1' then
  select count(*) into total from public.cb_workspace_records where user_id=auth.uid() and workspace=p_workspace and from_revision<=p_backup_revision and (to_revision is null or to_revision>p_backup_revision);
 else select count(*) into total from public.cb_flatten_workspace(saved); end if;
 if total=0 then raise exception 'Recovery records are unavailable'; end if;
 perform public.cb_begin_record_save(p_workspace,batch_id,p_revision,total,repeat('0',64),true);
 if saved->>'cbRecordStore'='1' then
  insert into public.cb_record_changes(user_id,batch,record_key,body)
  select auth.uid(),batch_id,record_key,body from public.cb_workspace_records where user_id=auth.uid() and workspace=p_workspace and from_revision<=p_backup_revision and (to_revision is null or to_revision>p_backup_revision);
 else insert into public.cb_record_changes(user_id,batch,record_key,body) select auth.uid(),batch_id,record_key,body from public.cb_flatten_workspace(saved); end if;
 insert into public.cb_workspace_backups(user_id,workspace,revision,payload) select user_id,workspace,revision,payload from public.cb_workspace_states where user_id=auth.uid() and workspace=p_workspace on conflict do nothing;
 return public.cb_commit_record_save(batch_id);
end; $$;

create or replace function public.cb_prune_record_history() returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':files',0));
 delete from public.cb_workspace_backups where user_id=auth.uid() and created_at<now()-interval '30 days';
 delete from public.cb_workspace_records r where r.user_id=auth.uid() and r.to_revision is not null and r.closed_at<now()-interval '30 days'
 and not exists(select 1 from public.cb_workspace_backups b where b.user_id=r.user_id and b.workspace=r.workspace and b.payload->>'cbRecordStore'='1' and b.revision>=r.from_revision and b.revision<r.to_revision);
end; $$;
do $$ begin if to_regprocedure('public.cb_claim_unused_files_legacy()') is null then alter function public.cb_claim_unused_files() rename to cb_claim_unused_files_legacy; end if; end $$;
create or replace function public.cb_claim_unused_files() returns table(bucket text,path text) language plpgsql security definer set search_path='' as $$
begin perform public.cb_prune_record_history();return query select * from public.cb_claim_unused_files_legacy();end; $$;

revoke all on function public.cb_save_workspace_legacy(text,jsonb,bigint),public.cb_claim_unused_files_legacy(),public.cb_touch_record_files(jsonb,boolean),public.cb_flatten_workspace(jsonb,jsonb) from public,anon,authenticated;
revoke all on function public.cb_begin_record_save(text,uuid,bigint,integer,text,boolean),public.cb_stage_record_save(uuid,jsonb),public.cb_commit_record_save(uuid),public.cb_prune_record_history(),public.cb_restore_workspace(text,bigint,bigint),public.cb_save_workspace(text,jsonb,bigint),public.cb_claim_unused_files() from public,anon;
grant execute on function public.cb_begin_record_save(text,uuid,bigint,integer,text,boolean),public.cb_stage_record_save(uuid,jsonb),public.cb_commit_record_save(uuid),public.cb_prune_record_history(),public.cb_restore_workspace(text,bigint,bigint),public.cb_save_workspace(text,jsonb,bigint),public.cb_claim_unused_files() to authenticated;
commit;
