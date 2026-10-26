-- Private vendor submissions and immutable review decisions, separate from financial documents.
begin;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('cb-vendor-deliverables','cb-vendor-deliverables',false,20971520,array['application/pdf','image/jpeg','image/png','image/webp','text/plain','text/csv','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet']) on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
-- Extend the installed quota and cleanup functions without resetting later migrations.
do $storage$
declare signature text;definition text;
begin
 foreach signature in array array['public.cb_storage_status()','public.cb_reserve_file(text,text,bigint)','public.cb_claim_unused_files()','public.cb_save_workspace(text,jsonb,bigint)','public.cb_touch_record_files(jsonb,boolean)'] loop
 if to_regprocedure(signature) is not null then select pg_get_functiondef(to_regprocedure(signature)) into definition;
 if strpos(definition,'''cb-vendor-deliverables''')=0 then definition=replace(definition,'''cb-memories''','''cb-memories'',''cb-vendor-deliverables''');execute definition;end if;
 end if;
 end loop;
end;$storage$;
drop policy if exists cb_vendor_deliverable_owner_read on storage.objects;
create policy cb_vendor_deliverable_owner_read on storage.objects for select to authenticated using(bucket_id='cb-vendor-deliverables' and split_part(name,'/',1)=auth.uid()::text);
create table if not exists public.cb_vendor_submissions(
 id uuid primary key default gen_random_uuid(),work_id uuid not null references public.cb_vendor_work on delete cascade,version bigint not null,
 uploaded_by uuid not null references auth.users,bucket text not null default 'cb-vendor-deliverables' check(bucket='cb-vendor-deliverables'),path text not null,name text not null,note text not null default '',
 status text not null default 'Pending' check(status in ('Pending','Approved','Changes requested')),review_note text not null default '',reviewed_by uuid references auth.users,reviewed_at timestamptz,revision bigint not null default 1,created_at timestamptz not null default now(),unique(work_id,version)
);
create table if not exists public.cb_vendor_submission_writes(user_id uuid not null references auth.users,client_id uuid not null,payload jsonb not null,response jsonb not null,primary key(user_id,client_id));
alter table public.cb_vendor_submissions enable row level security;alter table public.cb_vendor_submission_writes enable row level security;
revoke all on public.cb_vendor_submissions,public.cb_vendor_submission_writes from public,anon,authenticated;
create or replace function public.cb_vendor_work_access(p_work uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_vendor_work w join public.cb_shared_vendors v on v.id=w.vendor_id where w.id=p_work and public.cb_shared_vendor_access(v.id) and (public.cb_project_access(v.project_id,'owner') or public.cb_project_access(v.project_id,'write') or w.assigned_to=auth.uid()));
$$;
create or replace function public.cb_vendor_submission_file_access(p_bucket text,p_path text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_vendor_submissions s where s.bucket=p_bucket and s.path=p_path and public.cb_vendor_work_access(s.work_id));
$$;
drop policy if exists cb_vendor_submission_read on storage.objects;
create policy cb_vendor_submission_read on storage.objects for select to authenticated using(public.cb_vendor_submission_file_access(bucket_id,name));
create or replace function public.cb_vendor_deliverables(p_work uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare w public.cb_vendor_work;v public.cb_shared_vendors;active boolean;latest bigint;
begin
 if not public.cb_vendor_work_access(p_work) then raise exception 'Assigned work access required' using errcode='42501';end if;
 select * into w from public.cb_vendor_work where id=p_work;select * into v from public.cb_shared_vendors where id=w.vendor_id;
 active=not v.archived and w.status<>'Cancelled' and exists(select 1 from public.cb_projects where id=v.project_id and archived_at is null);
 select coalesce(max(version),0) into latest from public.cb_vendor_submissions where work_id=w.id;
 return jsonb_build_object('project',v.project_id,'title',w.title,'work_revision',w.revision,'can_submit',active and (public.cb_project_access(v.project_id,'write') or w.assigned_to=auth.uid()),'can_review',active and public.cb_project_access(v.project_id,'write'),'latest',latest,
 'submissions',(select coalesce(jsonb_agg(to_jsonb(s) order by version desc),'[]') from public.cb_vendor_submissions s where work_id=w.id));
end;$$;
create or replace function public.cb_submit_vendor_deliverable(p_work uuid,p_work_revision bigint,p_client uuid,p_path text,p_name text,p_note text) returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.cb_vendor_work;v public.cb_shared_vendors;s public.cb_vendor_submissions;prev public.cb_vendor_submission_writes;payload jsonb;result jsonb;meta jsonb;latest bigint;
begin
 select v2.* into v from public.cb_vendor_work w2 join public.cb_shared_vendors v2 on v2.id=w2.vendor_id where w2.id=p_work;perform 1 from public.cb_projects where id=v.project_id for update;
 if not coalesce(public.cb_vendor_work_access(p_work) and not v.archived and exists(select 1 from public.cb_projects where id=v.project_id and archived_at is null),false) then raise exception 'Assigned work access required' using errcode='42501';end if;
 select * into w from public.cb_vendor_work where id=p_work;
 if w.status='Cancelled' or not (public.cb_project_access(v.project_id,'write') or w.assigned_to=auth.uid()) then raise exception 'This work is not accepting submissions' using errcode='42501';end if;
 payload=jsonb_build_object('kind','submit','work',p_work,'work_revision',p_work_revision,'path',p_path,'name',p_name,'note',p_note);
 if p_client is null then raise exception 'Save request ID required';end if;select * into prev from public.cb_vendor_submission_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Submission changed during retry' using errcode='PT409';end if;return prev.response;end if;
 if w.revision is distinct from p_work_revision then raise exception 'Work instructions changed. Refresh before submitting.' using errcode='PT409';end if;
 if length(btrim(coalesce(p_name,''))) not between 1 and 200 or length(coalesce(p_note,''))>3000 or p_path is null or split_part(p_path,'/',1)<>auth.uid()::text or p_path !~ '^[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+$' then raise exception 'Upload your own file and check its name and note';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':files',0));
 select metadata into meta from storage.objects where bucket_id='cb-vendor-deliverables' and name=p_path;
 if not found or coalesce(meta->>'mimetype','') not in ('application/pdf','image/jpeg','image/png','image/webp','text/plain','text/csv','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet') then raise exception 'Upload a supported vendor deliverable first';end if;
 if exists(select 1 from public.cb_file_reservations where bucket='cb-vendor-deliverables' and path=p_path and deleting) then raise exception 'File cleanup is in progress. Upload again.';end if;
 select coalesce(max(version),0) into latest from public.cb_vendor_submissions where work_id=w.id;if latest>=50 then raise exception 'This work item has reached fifty submission versions';end if;
 insert into public.cb_vendor_submissions(work_id,version,uploaded_by,path,name,note) values(w.id,latest+1,auth.uid(),p_path,btrim(p_name),coalesce(p_note,'')) returning * into s;
 result=to_jsonb(s);insert into public.cb_vendor_submission_writes values(auth.uid(),p_client,payload,result);insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(v.project_id,auth.uid(),'Vendor deliverable submitted',array['vendor']);return result;
end;$$;
create or replace function public.cb_review_vendor_deliverable(p_submission uuid,p_revision bigint,p_client uuid,p_decision text,p_note text) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.cb_vendor_submissions;v public.cb_shared_vendors;prev public.cb_vendor_submission_writes;payload jsonb;result jsonb;
begin
 select v2.* into v from public.cb_vendor_submissions s2 join public.cb_vendor_work w on w.id=s2.work_id join public.cb_shared_vendors v2 on v2.id=w.vendor_id where s2.id=p_submission;perform 1 from public.cb_projects where id=v.project_id for update;
 if not coalesce(public.cb_project_access(v.project_id,'write') and not v.archived,false) then raise exception 'Planning review access required' using errcode='42501';end if;
 payload=jsonb_build_object('kind','review','submission',p_submission,'revision',p_revision,'decision',p_decision,'note',p_note);
 if p_client is null then raise exception 'Save request ID required';end if;select * into prev from public.cb_vendor_submission_writes where user_id=auth.uid() and client_id=p_client;
 if found then if prev.payload is distinct from payload then raise exception 'Review changed during retry' using errcode='PT409';end if;return prev.response;end if;
 select * into s from public.cb_vendor_submissions where id=p_submission;
 if s.revision is distinct from p_revision then raise exception 'Submission review changed. Refresh before reviewing.' using errcode='PT409';end if;
 if s.status<>'Pending' then raise exception 'This version has already been reviewed. Request a new submission.';end if;
 if exists(select 1 from public.cb_vendor_submissions where work_id=s.work_id and version>s.version) then raise exception 'A newer submission exists. Review its latest version.' using errcode='PT409';end if;
 if exists(select 1 from public.cb_vendor_work where id=s.work_id and status='Cancelled') then raise exception 'Cancelled work cannot be reviewed';end if;
 if coalesce(p_decision,'') not in ('Approved','Changes requested') or length(coalesce(p_note,''))>3000 or p_decision='Changes requested' and length(btrim(coalesce(p_note,'')))=0 then raise exception 'Choose a review decision and explain requested changes';end if;
 update public.cb_vendor_submissions set status=p_decision,review_note=coalesce(p_note,''),reviewed_by=auth.uid(),reviewed_at=now(),revision=revision+1 where id=s.id returning * into s;
 result=to_jsonb(s);insert into public.cb_vendor_submission_writes values(auth.uid(),p_client,payload,result);insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(v.project_id,auth.uid(),'Vendor deliverable reviewed',array['vendor']);return result;
end;$$;
do $migration$ begin
 if to_regprocedure('public.cb_file_referenced_before_vendor_submissions(text,text)') is null then alter function public.cb_file_referenced(text,text) rename to cb_file_referenced_before_vendor_submissions;end if;
end;$migration$;
create or replace function public.cb_file_referenced(p_bucket text,p_path text) returns boolean language sql security definer set search_path='' as $$select public.cb_file_referenced_before_vendor_submissions(p_bucket,p_path) or exists(select 1 from public.cb_vendor_submissions where bucket=p_bucket and path=p_path)$$;
revoke all on function public.cb_vendor_work_access(uuid),public.cb_vendor_submission_file_access(text,text),public.cb_vendor_deliverables(uuid),public.cb_submit_vendor_deliverable(uuid,bigint,uuid,text,text,text),public.cb_review_vendor_deliverable(uuid,bigint,uuid,text,text),public.cb_file_referenced(text,text),public.cb_file_referenced_before_vendor_submissions(text,text) from public,anon,authenticated;
grant execute on function public.cb_vendor_submission_file_access(text,text),public.cb_vendor_deliverables(uuid),public.cb_submit_vendor_deliverable(uuid,bigint,uuid,text,text,text),public.cb_review_vendor_deliverable(uuid,bigint,uuid,text,text),public.cb_file_referenced(text,text) to authenticated;
do $refresh$ declare signature text;definition text;begin foreach signature in array array['public.cb_claim_unused_files()','public.cb_file_delete_allowed(text,text)'] loop if to_regprocedure(signature) is not null then select pg_get_functiondef(to_regprocedure(signature)) into definition;execute definition;end if;end loop;end;$refresh$;
notify pgrst,'reload schema';
commit;
