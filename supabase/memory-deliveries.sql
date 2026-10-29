-- Connect approved photographer/video deliveries to shared memory albums without copying files.
-- Run after shared-memories.sql and vendor-deliverables.sql.
begin;
alter table public.cb_memory_items add column if not exists file_bucket text not null default 'cb-memories' check(file_bucket in ('cb-memories','cb-vendor-deliverables'));
alter table public.cb_memory_items add column if not exists source_submission uuid references public.cb_vendor_submissions on delete set null;
alter table public.cb_memory_items add column if not exists source_version bigint;
create unique index if not exists cb_memory_source_album on public.cb_memory_items(album_id,source_submission) where source_submission is not null;
update storage.buckets set allowed_mime_types=(select array_agg(distinct m) from unnest(allowed_mime_types||array['video/mp4','video/webm']) m) where id='cb-vendor-deliverables';
-- Preserve existing submission/review controls and allow short video deliverables.
do $video$ declare body text;begin body=pg_get_functiondef('public.cb_submit_vendor_deliverable(uuid,bigint,uuid,text,text,text)'::regprocedure);if strpos(body,'''video/mp4''')=0 then body=replace(body,'''image/webp'',''text/plain''','''image/webp'',''video/mp4'',''video/webm'',''text/plain''');execute body;end if;end;$video$;
create or replace function public.cb_memory_shared_file_access(p_bucket text,p_path text) returns boolean language sql stable security definer set search_path='' as $$select auth.uid() is not null and p_bucket in ('cb-memories','cb-vendor-deliverables') and exists(select 1 from public.cb_memory_items m where m.file_bucket=p_bucket and m.file_path=p_path and public.cb_memory_can_read(m.id))$$;
create or replace function public.cb_memory_file_access(p_path text) returns boolean language sql stable security definer set search_path='' as $$select public.cb_memory_shared_file_access('cb-memories',p_path)$$;
drop policy if exists cb_memory_reviewed_read on storage.objects;
create policy cb_memory_reviewed_read on storage.objects for select to authenticated using(public.cb_memory_shared_file_access(bucket_id,name));
-- Retain the full existing record/vendor cleanup chain, then protect linked album versions.
do $references$ begin if to_regprocedure('public.cb_file_referenced_before_memory_deliveries(text,text)') is null then alter function public.cb_file_referenced(text,text) rename to cb_file_referenced_before_memory_deliveries;end if;end;$references$;
create or replace function public.cb_file_referenced(p_bucket text,p_path text) returns boolean language sql security definer set search_path='' as $$select public.cb_file_referenced_before_memory_deliveries(p_bucket,p_path) or exists(select 1 from public.cb_memory_items where file_bucket=p_bucket and file_path=p_path) or exists(select 1 from public.cb_memory_history where coalesce(snapshot->>'file_bucket','cb-memories')=p_bucket and snapshot->>'file_path'=p_path)$$;
-- Return provenance without vendor notes or commercial details. Existing page cursors are retained.
do $album$ declare body text;begin body=pg_get_functiondef('public.cb_memory_album(uuid,jsonb)'::regprocedure);if strpos(body,'''file_bucket'',m.file_bucket')=0 then body=replace(body,'''file_path'',m.file_path,','''file_path'',m.file_path,''file_bucket'',m.file_bucket,''source_submission'',m.source_submission,''source_version'',m.source_version,');execute body;end if;end;$album$;
-- An owner-uploaded replacement always becomes a regular private account file and needs review again.
do $item$ declare body text;begin body=pg_get_functiondef('public.cb_save_memory_item(uuid,uuid,bigint,uuid,text,text,text,text)'::regprocedure);body=replace(body,'set title=btrim(p_title),caption=p_caption,file_path=p_path,mime=','set title=btrim(p_title),caption=p_caption,file_bucket=''cb-memories'',source_submission=null,source_version=null,file_path=p_path,mime=');
 body=replace(body,'perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||'':files'',0));','');body=replace(body,'perform 1 from public.cb_projects where id=a.project_id for update;','perform 1 from public.cb_projects where id=a.project_id for update; perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||'':files'',0));');execute body;end;$item$;
create or replace function public.cb_memory_vendor_deliveries(p_project uuid,p_before jsonb default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(public.cb_project_access(p_project,'write'),false) then raise exception 'Wedding manager access required' using errcode='42501';end if;
 return jsonb_build_object('project',p_project,'owner',public.cb_project_access(p_project,'owner'),'items',(select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at desc,d.id desc),'[]') from (
 select s.id,s.work_id,w.vendor_id,w.title as work_title,v.name as vendor_name,s.name,s.version,s.status,s.revision,s.created_at,w.status as work_status,w.due_date,
 o.metadata->>'mimetype' as mime,
 public.cb_project_access(p_project,'owner') and s.status='Approved' and not v.archived and w.status<>'Cancelled' and s.version=(select max(version) from public.cb_vendor_submissions where work_id=w.id) as can_import
 from public.cb_vendor_submissions s join public.cb_vendor_work w on w.id=s.work_id join public.cb_shared_vendors v on v.id=w.vendor_id join storage.objects o on o.bucket_id=s.bucket and o.name=s.path
 where v.project_id=p_project and public.cb_vendor_work_access(w.id) and o.metadata->>'mimetype' in ('image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm') and (p_before is null or (s.created_at,s.id)<((p_before->>'at')::timestamptz,(p_before->>'id')::uuid)) order by s.created_at desc,s.id desc limit 101) d));
end;$$;
create or replace function public.cb_import_memory_delivery(p_album uuid,p_album_revision bigint,p_submission uuid,p_submission_revision bigint,p_client uuid,p_title text,p_caption text) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.cb_memory_albums;s public.cb_vendor_submissions;w public.cb_vendor_work;v public.cb_shared_vendors;m public.cb_memory_items;old public.cb_memory_writes;payload jsonb;result jsonb;meta jsonb;
begin
 select * into a from public.cb_memory_albums where id=p_album;
 perform 1 from public.cb_projects where id=a.project_id for update;
 if a.id is null or not coalesce(public.cb_project_access(a.project_id,'owner'),false) then raise exception 'Only the wedding owner can add professional deliveries to albums' using errcode='42501';end if;
 payload=jsonb_build_object('action','delivery-import','album',p_album,'album_revision',p_album_revision,'submission',p_submission,'submission_revision',p_submission_revision,'title',p_title,'caption',p_caption);if p_client is null then raise exception 'Request ID required';end if;
 select * into old from public.cb_memory_writes where user_id=auth.uid() and client=p_client;if found then if old.payload is distinct from payload then raise exception 'Retry the same delivery selection' using errcode='PT409';end if;return old.response;end if;
 select * into a from public.cb_memory_albums where id=p_album for share;
 if a.archived or a.revision is distinct from p_album_revision then raise exception 'Album changed. Refresh before importing.' using errcode='PT409';end if;
 select * into s from public.cb_vendor_submissions where id=p_submission for share;
 select * into w from public.cb_vendor_work where id=s.work_id;select * into v from public.cb_shared_vendors where id=w.vendor_id;
 if s.id is null or v.project_id is distinct from a.project_id or not coalesce(public.cb_vendor_work_access(w.id),false) or v.archived or w.status='Cancelled' then raise exception 'This delivery is unavailable for this wedding' using errcode='42501';end if;
 if s.revision is distinct from p_submission_revision or s.status<>'Approved' or exists(select 1 from public.cb_vendor_submissions where work_id=w.id and version>s.version) then raise exception 'Review the latest delivery version before adding it' using errcode='PT409';end if;
 if p_title is null or length(btrim(p_title)) not between 1 and 160 or p_caption is null or length(p_caption)>2000 then raise exception 'Review the memory title and caption';end if;
 perform pg_advisory_xact_lock(hashtextextended(s.uploaded_by::text||':files',0));
 if exists(select 1 from public.cb_file_reservations where bucket=s.bucket and path=s.path and deleting) then raise exception 'This file is being cleaned up. Ask for a new delivery.';end if;
 select metadata into meta from storage.objects where bucket_id=s.bucket and name=s.path;
 if meta is null or s.bucket<>'cb-vendor-deliverables' or coalesce(meta->>'mimetype','') not in ('image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm') or coalesce((meta->>'size')::bigint,0) not between 1 and 20971520 then raise exception 'Choose a delivered photo or short video up to 20 MB';end if;
 select * into m from public.cb_memory_items where album_id=p_album and source_submission=s.id;
 if m.id is not null then raise exception 'This delivery is already in that album. Open the existing memory.' using errcode='PT409';end if;
 if (select count(*) from public.cb_memory_items where album_id=p_album)>=10000 then raise exception 'This album has reached its allowance';end if;
 insert into public.cb_memory_items(album_id,created_by,local_ref,title,caption,file_path,file_bucket,mime,bytes,source_submission,source_version) values(p_album,auth.uid(),'vendor:'||s.id,btrim(p_title),p_caption,s.path,s.bucket,meta->>'mimetype',(meta->>'size')::bigint,s.id,s.version) returning * into m;
 result=to_jsonb(m);insert into public.cb_memory_history values(m.id,m.revision,auth.uid(),'Professional delivery added',result,now());insert into public.cb_memory_writes values(auth.uid(),p_client,payload,result);return result;
end;$$;
revoke all on function public.cb_memory_shared_file_access(text,text),public.cb_memory_vendor_deliveries(uuid,jsonb),public.cb_import_memory_delivery(uuid,bigint,uuid,bigint,uuid,text,text),public.cb_file_referenced(text,text),public.cb_file_referenced_before_memory_deliveries(text,text) from public,anon,authenticated;
grant execute on function public.cb_memory_shared_file_access(text,text),public.cb_memory_vendor_deliveries(uuid,jsonb),public.cb_import_memory_delivery(uuid,bigint,uuid,bigint,uuid,text,text) to authenticated;
do $rebind$ declare signature text;body text;begin foreach signature in array array['public.cb_claim_unused_files()','public.cb_file_delete_allowed(text,text)'] loop if to_regprocedure(signature) is not null then body=pg_get_functiondef(to_regprocedure(signature));execute body;end if;end loop;end;$rebind$;
notify pgrst,'reload schema';commit;
