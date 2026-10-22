-- CoBrides private account file storage. Safe to run more than once.
-- Run in Supabase SQL Editor. Does not modify existing wedding records.
begin;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
select id,id,false,20971520,array['image/jpeg','image/png','image/webp','image/gif','application/pdf','text/plain','text/csv','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','audio/mpeg','audio/ogg','audio/wav','audio/webm','audio/x-wav','video/mp4','video/webm']
from unnest(array['cb-inspiration','cb-documents','cb-memories']) as id
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists cb_files_owner_read on storage.objects;
create policy cb_files_owner_read on storage.objects for select to authenticated
using(bucket_id in ('cb-inspiration','cb-documents','cb-memories') and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists cb_files_owner_insert on storage.objects;
create policy cb_files_owner_insert on storage.objects for insert to authenticated
with check(bucket_id in ('cb-inspiration','cb-documents','cb-memories') and (storage.foldername(name))[1]=auth.uid()::text);
-- Immutable content-addressed files: deliberately no update or delete policy.
-- Removing a planning record does not destroy a file needed by a saved revision.
commit;
