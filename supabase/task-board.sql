-- Run after shared-planning.sql. No personal records are published automatically.
begin;
alter table public.cb_tasks add column if not exists plan jsonb not null default '{}' check(jsonb_typeof(plan)='object');
alter table public.cb_tasks add column if not exists approval_required boolean not null default false;
alter table public.cb_tasks add column if not exists approver_email text not null default '';
alter table public.cb_tasks add column if not exists approved_by uuid references auth.users;
create or replace function public.cb_task_visible(p_task uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_tasks t where t.id=p_task and public.cb_project_access(t.project_id,'read') and (public.cb_task_manager(t.project_id) or lower(t.assignee_email)=lower(coalesce(auth.jwt()->>'email','')) or (t.approval_required and lower(t.approver_email)=lower(coalesce(auth.jwt()->>'email','')))));
$$;
drop policy if exists tasks_read on public.cb_tasks;
create policy tasks_read on public.cb_tasks for select to authenticated using(public.cb_task_visible(id));
create table if not exists public.cb_task_comments(id uuid primary key default gen_random_uuid(),task_id uuid not null references public.cb_tasks on delete cascade,author_id uuid not null references auth.users,body text not null check(length(trim(body)) between 1 and 3000),created_at timestamptz not null default now());
alter table public.cb_task_comments enable row level security;
revoke all on public.cb_task_comments from public,anon,authenticated;
grant select on public.cb_task_comments to authenticated;
drop policy if exists task_comments_read on public.cb_task_comments;
create policy task_comments_read on public.cb_task_comments for select to authenticated using(public.cb_task_visible(task_id));
create or replace function public.cb_save_task_plan(p_task uuid,p_revision bigint,p_plan jsonb,p_approval boolean,p_approver text) returns public.cb_tasks language plpgsql security definer set search_path='' as $$
declare t public.cb_tasks; pid uuid; dep uuid; st jsonb; clean_subtasks jsonb:='[]'; dependencies jsonb; safe jsonb;
begin
 select project_id into pid from public.cb_tasks where id=p_task;
 perform 1 from public.cb_projects where id=pid for update;
 select * into t from public.cb_tasks where id=p_task for update;
 if not public.cb_project_access(pid,'write') then raise exception 'Task editing access denied';end if;
 if t.revision<>p_revision then raise exception 'CB_TASK_CONFLICT: Refresh this task before saving.' using errcode='40001';end if;
 if t.done then raise exception 'Reopen this task before changing its plan';end if;
 if jsonb_typeof(p_plan) is distinct from 'object' or octet_length(p_plan::text)>30000 then raise exception 'Enter a valid task plan';end if;
 dependencies=coalesce(p_plan->'dependencies','[]');
 if jsonb_typeof(dependencies)<>'array' or jsonb_array_length(dependencies)>30 or jsonb_typeof(coalesce(p_plan->'subtasks','[]'))<>'array' or jsonb_array_length(coalesce(p_plan->'subtasks','[]'))>50 then raise exception 'Keep up to 30 prerequisites and 50 subtasks';end if;
 for dep in select value::uuid from jsonb_array_elements_text(dependencies) loop
  if dep=p_task or not exists(select 1 from public.cb_tasks where id=dep and project_id=pid) then raise exception 'Choose a prerequisite in this wedding';end if;
  if exists(with recursive chain(id,path) as (select dep,array[dep] union all select d.value::uuid,c.path||d.value::uuid from chain c join public.cb_tasks x on x.id=c.id cross join lateral jsonb_array_elements_text(coalesce(x.plan->'dependencies','[]')) d where not d.value::uuid=any(c.path)) select 1 from chain where id=p_task) then raise exception 'Task dependencies cannot form a cycle';end if;
 end loop;
 for st in select value from jsonb_array_elements(coalesce(p_plan->'subtasks','[]')) loop
  if length(coalesce(st->>'id','')) not between 1 and 100 or length(trim(coalesce(st->>'title',''))) not between 1 and 300 or jsonb_typeof(st->'done') is distinct from 'boolean' then raise exception 'Enter valid subtasks';end if;
  if exists(select 1 from jsonb_array_elements(clean_subtasks) s where s->>'id'=st->>'id') then raise exception 'Subtask IDs must be unique';end if;
  clean_subtasks=clean_subtasks||jsonb_build_array(jsonb_build_object('id',st->>'id','title',trim(st->>'title'),'done',(st->>'done')::boolean));
 end loop;
 if coalesce(p_plan->>'priority','Normal') not in ('Low','Normal','High','Urgent') or coalesce(p_plan->>'status','To do') not in ('To do','In progress','Waiting') then raise exception 'Choose an available task status and priority';end if;
 if p_approval and not exists(select 1 from auth.users u where lower(u.email)=lower(trim(p_approver)) and (exists(select 1 from public.cb_projects where id=pid and owner_id=u.id) or exists(select 1 from public.cb_members where project_id=pid and user_id=u.id))) then raise exception 'Choose an accepted team member as approver';end if;
 safe=jsonb_build_object('subtasks',clean_subtasks,'dependencies',dependencies,'priority',coalesce(p_plan->>'priority','Normal'),'status',coalesce(p_plan->>'status','To do'),'category',left(coalesce(p_plan->>'category','Planning'),100),'phase',left(coalesce(p_plan->>'phase','Prepare'),100));
 update public.cb_tasks set plan=safe,approval_required=coalesce(p_approval,false),approver_email=case when p_approval then lower(trim(p_approver)) else '' end,approved_by=null,revision=revision+1,updated_at=now() where id=p_task returning * into t;
 insert into public.cb_project_activity(project_id,actor_id,action) values(pid,auth.uid(),'Task plan updated');return t;
end; $$;
create or replace function public.cb_task_step(p_task uuid,p_revision bigint,p_subtask text,p_done boolean,p_approve boolean default false) returns public.cb_tasks language plpgsql security definer set search_path='' as $$
declare t public.cb_tasks; pid uuid; updated_subtasks jsonb;
begin
 select project_id into pid from public.cb_tasks where id=p_task;
 perform 1 from public.cb_projects where id=pid for update;
 select * into t from public.cb_tasks where id=p_task for update;
 if not public.cb_task_visible(p_task) or exists(select 1 from public.cb_projects where id=pid and archived_at is not null) then raise exception 'Task access denied';end if;
 if t.revision<>p_revision then raise exception 'CB_TASK_CONFLICT: Refresh this task before saving.' using errcode='40001';end if;
 if t.done then raise exception 'Reopen this task before changing it';end if;
 if p_approve then
  if not t.approval_required or lower(t.approver_email)<>lower(coalesce(auth.jwt()->>'email','')) then raise exception 'Only the designated approver can approve';end if;
  update public.cb_tasks set approved_by=case when p_done then auth.uid() else null end,revision=revision+1,updated_at=now() where id=p_task returning * into t;
 else
  if not (public.cb_task_manager(pid) or lower(t.assignee_email)=lower(coalesce(auth.jwt()->>'email',''))) then raise exception 'Assignment access denied';end if;
  if not exists(select 1 from jsonb_array_elements(coalesce(t.plan->'subtasks','[]')) s where s->>'id'=p_subtask) then raise exception 'Subtask not found';end if;
  select jsonb_agg(case when s->>'id'=p_subtask then s||jsonb_build_object('done',p_done) else s end order by ord) into updated_subtasks from jsonb_array_elements(t.plan->'subtasks') with ordinality x(s,ord);
  update public.cb_tasks set plan=jsonb_set(plan,'{subtasks}',updated_subtasks),approved_by=null,revision=revision+1,updated_at=now() where id=p_task returning * into t;
 end if;
 insert into public.cb_project_activity(project_id,actor_id,action) values(pid,auth.uid(),case when p_approve then 'Task approval updated' else 'Subtask updated' end);return t;
end; $$;
create or replace function public.cb_add_task_comment(p_task uuid,p_body text) returns public.cb_task_comments language plpgsql security definer set search_path='' as $$
declare row public.cb_task_comments; pid uuid;
begin
 select project_id into pid from public.cb_tasks where id=p_task;
 perform 1 from public.cb_projects where id=pid for update;
 if not public.cb_task_visible(p_task) or exists(select 1 from public.cb_projects where id=pid and archived_at is not null) then raise exception 'Task access denied';end if;
 insert into public.cb_task_comments(task_id,author_id,body) values(p_task,auth.uid(),trim(p_body)) returning * into row;return row;
end; $$;
create or replace function public.cb_set_shared_task_done(p_task uuid,p_revision bigint,p_done boolean) returns public.cb_tasks language plpgsql security definer set search_path='' as $$
declare t public.cb_tasks; pid uuid;
begin
 select project_id into pid from public.cb_tasks where id=p_task;
 perform 1 from public.cb_projects where id=pid for update;
 select * into t from public.cb_tasks where id=p_task for update;
 if not found or not public.cb_project_access(pid,'read') or not (public.cb_task_manager(pid) or lower(t.assignee_email)=lower(coalesce(auth.jwt()->>'email',''))) then raise exception 'Task access denied';end if;
 if exists(select 1 from public.cb_projects where id=pid and archived_at is not null) then raise exception 'Archived wedding: editing is paused';end if;
 if t.revision<>p_revision then raise exception 'CB_TASK_CONFLICT: This task changed. Refresh before saving.' using errcode='40001';end if;
 if p_done is null then raise exception 'Completion state is required';end if;
 if p_done then
  if exists(select 1 from jsonb_array_elements_text(coalesce(t.plan->'dependencies','[]')) d left join public.cb_tasks x on x.id=d.value::uuid where x.id is null or not x.done) then raise exception 'Complete the prerequisite tasks first';end if;
  if exists(select 1 from jsonb_array_elements(coalesce(t.plan->'subtasks','[]')) s where not coalesce((s->>'done')::boolean,false)) then raise exception 'Complete the subtasks first';end if;
  if t.approval_required and (t.approved_by is null or not exists(select 1 from auth.users u where u.id=t.approved_by and lower(u.email)=lower(t.approver_email) and (exists(select 1 from public.cb_projects where id=pid and owner_id=u.id) or exists(select 1 from public.cb_members where project_id=pid and user_id=u.id)))) then raise exception 'The designated approver must approve this task first';end if;
 else
  if exists(select 1 from public.cb_tasks d where d.project_id=pid and d.done and coalesce(d.plan->'dependencies','[]') @> jsonb_build_array(p_task::text)) then raise exception 'Reopen completed dependent tasks first';end if;
 end if;
 update public.cb_tasks set done=p_done,revision=revision+1,updated_at=now() where id=p_task returning * into t;
 insert into public.cb_project_activity(project_id,actor_id,action) values(pid,auth.uid(),case when p_done then 'Task completed' else 'Task reopened' end);return t;
end; $$;
create or replace function public.cb_task_approval_reset() returns trigger language plpgsql set search_path='' as $$
begin
 if (new.title,new.description,new.assignee_email,new.due_date,new.kind) is distinct from (old.title,old.description,old.assignee_email,old.due_date,old.kind) then if old.done then raise exception 'Reopen this task before changing its details';end if;new.approved_by=null;end if;return new;
end; $$;
drop trigger if exists cb_task_approval_reset on public.cb_tasks;
create trigger cb_task_approval_reset before update on public.cb_tasks for each row execute function public.cb_task_approval_reset();
revoke all on function public.cb_task_visible(uuid),public.cb_save_task_plan(uuid,bigint,jsonb,boolean,text),public.cb_task_step(uuid,bigint,text,boolean,boolean),public.cb_add_task_comment(uuid,text) from public,anon;
grant execute on function public.cb_task_visible(uuid),public.cb_save_task_plan(uuid,bigint,jsonb,boolean,text),public.cb_task_step(uuid,bigint,text,boolean,boolean),public.cb_add_task_comment(uuid,text) to authenticated;
create table if not exists public.cb_task_attachments(id uuid primary key default gen_random_uuid(),task_id uuid not null references public.cb_tasks on delete cascade,uploaded_by uuid not null references auth.users,bucket text not null check(bucket='cb-documents'),path text not null,name text not null check(length(name) between 1 and 200),created_at timestamptz not null default now(),unique(task_id,bucket,path));
alter table public.cb_task_attachments enable row level security;
revoke all on public.cb_task_attachments from public,anon,authenticated;
grant select on public.cb_task_attachments to authenticated;
drop policy if exists task_attachments_read on public.cb_task_attachments;
create policy task_attachments_read on public.cb_task_attachments for select to authenticated using(public.cb_task_visible(task_id));
create or replace function public.cb_task_file_access(p_bucket text,p_path text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_task_attachments a where a.bucket=p_bucket and a.path=p_path and public.cb_task_visible(a.task_id));
$$;
drop policy if exists cb_shared_task_file_read on storage.objects;
create policy cb_shared_task_file_read on storage.objects for select to authenticated using(public.cb_task_file_access(bucket_id,name));
create or replace function public.cb_link_task_file(p_task uuid,p_bucket text,p_path text,p_name text) returns public.cb_task_attachments language plpgsql security definer set search_path='' as $$
declare row public.cb_task_attachments;pid uuid;
begin
 select project_id into pid from public.cb_tasks where id=p_task;
 perform 1 from public.cb_projects where id=pid for update;
 if not public.cb_task_visible(p_task) or exists(select 1 from public.cb_projects where id=pid and archived_at is not null) then raise exception 'Task access denied';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':files',0));
 if p_bucket<>'cb-documents' or split_part(p_path,'/',1)<>auth.uid()::text or not exists(select 1 from storage.objects where bucket_id=p_bucket and name=p_path) then raise exception 'Upload your own document before sharing it';end if;
 if exists(select 1 from public.cb_file_reservations where bucket=p_bucket and path=p_path and deleting) then raise exception 'File cleanup is in progress. Upload again.';end if;
 if (select count(*) from public.cb_task_attachments where task_id=p_task)>=10 and not exists(select 1 from public.cb_task_attachments where task_id=p_task and bucket=p_bucket and path=p_path) then raise exception 'Keep up to ten attachments per task';end if;
 insert into public.cb_task_attachments(task_id,uploaded_by,bucket,path,name) values(p_task,auth.uid(),p_bucket,p_path,left(p_name,200)) on conflict(task_id,bucket,path) do update set name=excluded.name returning * into row;return row;
end; $$;
create or replace function public.cb_unlink_task_file(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare a public.cb_task_attachments;pid uuid;
begin
 select t.project_id into pid from public.cb_task_attachments x join public.cb_tasks t on t.id=x.task_id where x.id=p_id;
 perform 1 from public.cb_projects where id=pid for update;
 select * into a from public.cb_task_attachments where id=p_id for update;
 if not public.cb_task_visible(a.task_id) or not (a.uploaded_by=auth.uid() or public.cb_task_manager(pid)) or exists(select 1 from public.cb_projects where id=pid and archived_at is not null) then raise exception 'Attachment access denied';end if;
 delete from public.cb_task_attachments where id=p_id;
end; $$;
-- Preserve the installed record-store cleanup checks, adding shared-file protection.
do $$begin
 if to_regprocedure('public.cb_file_referenced_before_tasks(text,text)') is null then alter function public.cb_file_referenced(text,text) rename to cb_file_referenced_before_tasks;end if;
end$$;
create or replace function public.cb_file_referenced(p_bucket text,p_path text) returns boolean language sql security definer set search_path='' as $$
 select public.cb_file_referenced_before_tasks(p_bucket,p_path) or exists(select 1 from public.cb_task_attachments where bucket=p_bucket and path=p_path);
$$;
revoke all on function public.cb_task_file_access(text,text),public.cb_link_task_file(uuid,text,text,text),public.cb_unlink_task_file(uuid),public.cb_file_referenced(text,text) from public,anon;
grant execute on function public.cb_task_file_access(text,text),public.cb_link_task_file(uuid,text,text,text),public.cb_unlink_task_file(uuid),public.cb_file_referenced(text,text) to authenticated;
create or replace function public.cb_save_board_task(p_project uuid,p_ref text,p_revision bigint,p_title text,p_assignee text,p_due date,p_kind text,p_description text,p_plan jsonb,p_approval boolean,p_approver text) returns public.cb_tasks language plpgsql security definer set search_path='' as $$
declare t public.cb_tasks;
begin
 select * into t from public.cb_save_shared_task(p_project,p_ref,p_revision,p_title,p_assignee,p_due,p_kind,p_description);
 select * into t from public.cb_save_task_plan(t.id,t.revision,p_plan,p_approval,p_approver);return t;
end; $$;
revoke all on function public.cb_save_board_task(uuid,text,bigint,text,text,date,text,text,jsonb,boolean,text) from public,anon;
grant execute on function public.cb_save_board_task(uuid,text,bigint,text,text,date,text,text,jsonb,boolean,text) to authenticated;
notify pgrst,'reload schema';
commit;
