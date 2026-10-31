-- Explicit service-file sharing; uploaded originals remain immutable and private.
begin;
create table if not exists public.cb_experience_files(id uuid primary key default gen_random_uuid(),item_id uuid not null references public.cb_experience_items on delete cascade,uploaded_by uuid not null references auth.users,bucket text not null default 'cb-documents' check(bucket='cb-documents'),path text not null,name text not null,mime text not null,bytes bigint not null,revision bigint not null default 1,created_at timestamptz not null default now(),removed_at timestamptz,removed_by uuid references auth.users,unique(item_id,bucket,path));
create table if not exists public.cb_experience_file_writes(user_id uuid not null references auth.users on delete cascade,client uuid not null,payload jsonb not null,response jsonb not null,at timestamptz not null default now(),primary key(user_id,client));
alter table public.cb_experience_files enable row level security;alter table public.cb_experience_file_writes enable row level security;
revoke all on public.cb_experience_files,public.cb_experience_file_writes from public,anon,authenticated;
create index if not exists cb_experience_file_item on public.cb_experience_files(item_id);
create or replace function public.cb_experience_file_access(p_bucket text,p_path text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_experience_files f join public.cb_experience_items i on i.id=f.item_id where f.bucket=p_bucket and f.path=p_path and f.removed_at is null and public.cb_experience_member(i.event_id,auth.uid()));
$$;
drop policy if exists cb_experience_file_read on storage.objects;
create policy cb_experience_file_read on storage.objects for select to authenticated using(public.cb_experience_file_access(bucket_id,name));
create or replace function public.cb_experience_files(p_item uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare i public.cb_experience_items;e public.cb_project_events;
begin
 select * into i from public.cb_experience_items where id=p_item;select * into e from public.cb_project_events where id=i.event_id;
 if i.id is null or not coalesce(public.cb_experience_member(e.id,auth.uid()),false) then raise exception 'Celebration service access required' using errcode='42501';end if;
 return jsonb_build_object('item',i.id,'item_revision',i.revision,'event',e.id,'event_revision',e.revision,'title',i.data->>'title','can_edit',public.cb_project_access(e.project_id,'write'),'files',(select coalesce(jsonb_agg(to_jsonb(f)-'uploaded_by'-'removed_by' order by f.created_at,f.id),'[]') from public.cb_experience_files f where f.item_id=i.id and f.removed_at is null));
end;$$;
create or replace function public.cb_link_experience_file(p_item uuid,p_item_revision bigint,p_event_revision bigint,p_client uuid,p_path text,p_name text,p_confirm boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare i public.cb_experience_items;e public.cb_project_events;f public.cb_experience_files;w public.cb_experience_file_writes;payload jsonb;result jsonb;meta jsonb;
begin
 select * into i from public.cb_experience_items where id=p_item;select * into e from public.cb_project_events where id=i.event_id;perform 1 from public.cb_projects where id=e.project_id for update;
 select * into i from public.cb_experience_items where id=p_item;select * into e from public.cb_project_events where id=i.event_id;
 if i.id is null or not coalesce(public.cb_experience_member(e.id,auth.uid()) and public.cb_project_access(e.project_id,'write'),false) then raise exception 'Celebration planning access required' using errcode='42501';end if;
 payload=jsonb_build_object('action','Link','item',p_item,'item_revision',p_item_revision,'event_revision',p_event_revision,'path',p_path,'name',p_name,'confirm',p_confirm);
 if p_client is null then raise exception 'Request ID required';end if;select * into w from public.cb_experience_file_writes where user_id=auth.uid() and client=p_client;
 if found then if w.payload is distinct from payload then raise exception 'Retry the original file request';end if;return w.response;end if;
 if p_confirm is distinct from true then raise exception 'Confirm sharing this file with the celebration team';end if;
 if i.revision is distinct from p_item_revision or e.revision is distinct from p_event_revision then raise exception 'The service or celebration changed. Reopen files before sharing.' using errcode='PT409';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':files',0));
 if p_path is null or split_part(p_path,'/',1)<>auth.uid()::text or p_path!~'^[-a-zA-Z0-9_/\.]+$' or p_path like '%..%' then raise exception 'Upload your own file before sharing';end if;
 if length(btrim(coalesce(p_name,''))) not between 1 and 200 then raise exception 'Choose a file name up to 200 characters';end if;
 select metadata into meta from storage.objects where bucket_id='cb-documents' and name=p_path;
 if not found then raise exception 'Upload your own file before sharing';end if;
 if coalesce(meta->>'mimetype','') not in ('image/jpeg','image/png','image/webp','image/gif','application/pdf','text/plain','text/csv','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','audio/mpeg','audio/ogg','audio/wav','audio/webm','audio/x-wav','video/mp4','video/webm') then raise exception 'Choose a supported image, document, audio or video file';end if;
 if coalesce(meta->>'size','')!~'^[0-9]{1,10}$' then raise exception 'File size could not be verified';end if;
 if (meta->>'size')::bigint not between 1 and 20971520 then raise exception 'Choose a file up to 20 MB';end if;
 if exists(select 1 from public.cb_file_reservations where bucket='cb-documents' and path=p_path and deleting) then raise exception 'File cleanup is in progress. Upload again.';end if;
 select * into f from public.cb_experience_files where item_id=i.id and bucket='cb-documents' and path=p_path;
 if f.id is not null and f.name<>btrim(p_name) then raise exception 'This file is already attached with a different name' using errcode='PT409';end if;
 if f.id is null or f.removed_at is not null then
  if (select count(*) from public.cb_experience_files where item_id=i.id and removed_at is null)>=20 then raise exception 'Keep up to twenty files per service';end if;
  insert into public.cb_experience_files(item_id,uploaded_by,path,name,mime,bytes) values(i.id,auth.uid(),p_path,btrim(p_name),meta->>'mimetype',(meta->>'size')::bigint) on conflict(item_id,bucket,path) do update set removed_at=null,removed_by=null,revision=cb_experience_files.revision+1 returning * into f;
 end if;
 result=jsonb_build_object('id',f.id,'revision',f.revision,'saved',true);insert into public.cb_experience_file_writes(user_id,client,payload,response) values(auth.uid(),p_client,payload,result);return result;
end;$$;
create or replace function public.cb_remove_experience_file(p_file uuid,p_revision bigint,p_client uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare f public.cb_experience_files;e public.cb_project_events;w public.cb_experience_file_writes;payload jsonb;result jsonb;
begin
 select e0.* into e from public.cb_experience_files x join public.cb_experience_items i on i.id=x.item_id join public.cb_project_events e0 on e0.id=i.event_id where x.id=p_file;perform 1 from public.cb_projects where id=e.project_id for update;
 if e.id is null or not coalesce(public.cb_experience_member(e.id,auth.uid()) and public.cb_project_access(e.project_id,'write'),false) then raise exception 'Celebration planning access required' using errcode='42501';end if;
 payload=jsonb_build_object('action','Remove','file',p_file,'revision',p_revision);if p_client is null then raise exception 'Request ID required';end if;select * into w from public.cb_experience_file_writes where user_id=auth.uid() and client=p_client;
 if found then if w.payload is distinct from payload then raise exception 'Retry the original file request';end if;return w.response;end if;
 select * into f from public.cb_experience_files where id=p_file for update;
 if f.revision is distinct from p_revision then raise exception 'This attachment changed. Refresh files first.' using errcode='PT409';end if;
 if f.removed_at is null then update public.cb_experience_files set removed_at=now(),removed_by=auth.uid(),revision=revision+1 where id=f.id returning * into f;end if;
 result=jsonb_build_object('id',f.id,'revision',f.revision,'removed',true);insert into public.cb_experience_file_writes(user_id,client,payload,response) values(auth.uid(),p_client,payload,result);return result;
end;$$;
do $wrap$ begin if to_regprocedure('public.cb_file_referenced_before_experience(text,text)') is null then alter function public.cb_file_referenced(text,text) rename to cb_file_referenced_before_experience;end if;end;$wrap$;
create or replace function public.cb_file_referenced(p_bucket text,p_path text) returns boolean language sql security definer set search_path='' as $$select public.cb_file_referenced_before_experience(p_bucket,p_path) or exists(select 1 from public.cb_experience_files where bucket=p_bucket and path=p_path and (removed_at is null or removed_at>now()-interval '30 days'))$$;
revoke all on function public.cb_experience_file_access(text,text),public.cb_experience_files(uuid),public.cb_link_experience_file(uuid,bigint,bigint,uuid,text,text,boolean),public.cb_remove_experience_file(uuid,bigint,uuid),public.cb_file_referenced_before_experience(text,text),public.cb_file_referenced(text,text) from public,anon,authenticated;
grant execute on function public.cb_experience_file_access(text,text),public.cb_experience_files(uuid),public.cb_link_experience_file(uuid,bigint,bigint,uuid,text,text,boolean),public.cb_remove_experience_file(uuid,bigint,uuid),public.cb_file_referenced(text,text) to authenticated;
do $refresh$ declare sig text;body text;begin foreach sig in array array['public.cb_claim_unused_files()','public.cb_file_delete_allowed(text,text)'] loop if to_regprocedure(sig) is not null then body=pg_get_functiondef(to_regprocedure(sig));execute body;end if;end loop;end;$refresh$;
notify pgrst,'reload schema';commit;
