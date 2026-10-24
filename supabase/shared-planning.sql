-- Run after wedding-projects.sql. Existing personal tasks are never published automatically.
begin;
alter table public.cb_tasks add column if not exists revision bigint not null default 1;
alter table public.cb_tasks add column if not exists kind text not null default 'task' check(kind in ('task','milestone'));
alter table public.cb_tasks add column if not exists description text not null default '' check(length(description)<=4000);
alter table public.cb_tasks add column if not exists local_ref text;
update public.cb_tasks set local_ref='legacy:'||id::text where local_ref is null;
create unique index if not exists cb_tasks_project_ref on public.cb_tasks(project_id,local_ref) where local_ref is not null;
create or replace function public.cb_task_manager(pid uuid) returns boolean language sql stable security definer set search_path='' as $$
 select public.cb_project_access(pid,'read') and (exists(select 1 from public.cb_projects where id=pid and owner_id=auth.uid()) or exists(select 1 from public.cb_members where project_id=pid and user_id=auth.uid() and role in ('bride','planner','partner')));
$$;
drop policy if exists tasks_read on public.cb_tasks;
create policy tasks_read on public.cb_tasks for select to authenticated using(public.cb_task_manager(project_id) or (public.cb_project_access(project_id,'read') and lower(assignee_email)=lower(coalesce(auth.jwt()->>'email',''))));
-- All new writes pass through permission-checked functions.
drop policy if exists tasks_create on public.cb_tasks;
revoke insert on public.cb_tasks from authenticated;
create or replace function public.cb_save_shared_task(p_project uuid,p_ref text,p_revision bigint,p_title text,p_assignee text,p_due date,p_kind text,p_description text) returns public.cb_tasks language plpgsql security definer set search_path='' as $$
declare result public.cb_tasks; recipient uuid;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not public.cb_project_access(p_project,'write') then raise exception 'Task editing access denied'; end if;
 if length(trim(coalesce(p_ref,''))) not between 1 and 240 then raise exception 'A task reference is required'; end if;
 select u.id into recipient from auth.users u where lower(u.email)=lower(trim(p_assignee)) and (exists(select 1 from public.cb_projects p where p.id=p_project and p.owner_id=u.id) or exists(select 1 from public.cb_members m where m.project_id=p_project and m.user_id=u.id));
 if recipient is null then raise exception 'Assign this to an accepted wedding team member'; end if;
 select * into result from public.cb_tasks where project_id=p_project and local_ref=p_ref for update;
 if found then
  if result.revision<>p_revision then raise exception 'CB_TASK_CONFLICT: This task changed. Refresh before saving.' using errcode='PT409'; end if;
  update public.cb_tasks set title=trim(p_title),assignee_email=lower(trim(p_assignee)),due_date=p_due,kind=p_kind,description=coalesce(p_description,''),revision=revision+1,updated_at=now() where id=result.id returning * into result;
 else
  if p_revision<>0 then raise exception 'Task no longer exists'; end if;
  insert into public.cb_tasks(project_id,local_ref,title,assignee_email,due_date,kind,description) values(p_project,p_ref,trim(p_title),lower(trim(p_assignee)),p_due,p_kind,coalesce(p_description,'')) returning * into result;
 end if;
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(p_project,auth.uid(),'Task details saved',array['task']);
 return result;
end; $$;
create or replace function public.cb_set_shared_task_done(p_task uuid,p_revision bigint,p_done boolean) returns public.cb_tasks language plpgsql security definer set search_path='' as $$
declare result public.cb_tasks; pid uuid;
begin
 select project_id into pid from public.cb_tasks where id=p_task;
 perform 1 from public.cb_projects where id=pid for update;
 select * into result from public.cb_tasks where id=p_task for update;
 if not found or not public.cb_project_access(pid,'read') or not (public.cb_task_manager(pid) or lower(result.assignee_email)=lower(coalesce(auth.jwt()->>'email',''))) then raise exception 'Task access denied'; end if;
 if exists(select 1 from public.cb_projects where id=pid and archived_at is not null) then raise exception 'Archived wedding: editing is paused'; end if;
 if result.revision<>p_revision then raise exception 'CB_TASK_CONFLICT: This task changed. Refresh before saving.' using errcode='PT409'; end if;
 if p_done is null then raise exception 'Completion state is required'; end if;
 update public.cb_tasks set done=p_done,revision=revision+1,updated_at=now() where id=p_task returning * into result;
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(pid,auth.uid(),case when p_done then 'Task completed' else 'Task reopened' end,array['task']);
 return result;
end; $$;
-- Preserve the original endpoint for older clients while enforcing archive and membership rules.
create or replace function public.cb_complete_task(task_id uuid,completed boolean) returns void language plpgsql security definer set search_path='' as $$
declare rev bigint; pid uuid;
begin
 select project_id into pid from public.cb_tasks where id=task_id;
 perform 1 from public.cb_projects where id=pid for update;
 select revision into rev from public.cb_tasks where id=task_id;
 perform public.cb_set_shared_task_done(task_id,rev,completed);
end; $$;
revoke all on function public.cb_task_manager(uuid),public.cb_save_shared_task(uuid,text,bigint,text,text,date,text,text),public.cb_set_shared_task_done(uuid,bigint,boolean) from public,anon;
grant execute on function public.cb_task_manager(uuid),public.cb_save_shared_task(uuid,text,bigint,text,text,date,text,text),public.cb_set_shared_task_done(uuid,bigint,boolean) to authenticated;
commit;
