-- Run after task-board.sql and celebration-workspace.sql.
begin;
create table if not exists public.cb_schedule_rules(project_id uuid not null references public.cb_projects on delete cascade,kind text not null check(kind in ('event','task')),target_id uuid not null,anchor_event uuid references public.cb_project_events on delete cascade,offset_days integer not null check(offset_days between -3650 and 3650),updated_at timestamptz not null default now(),primary key(project_id,kind,target_id));
create table if not exists public.cb_schedule_previews(id uuid primary key default gen_random_uuid(),project_id uuid not null references public.cb_projects on delete cascade,user_id uuid not null references auth.users on delete cascade,fingerprint text not null,payload jsonb not null,expires_at timestamptz not null default now()+interval '15 minutes',applied_at timestamptz);
alter table public.cb_schedule_rules enable row level security;
alter table public.cb_schedule_previews enable row level security;
revoke all on public.cb_schedule_rules,public.cb_schedule_previews from public,anon,authenticated;
grant select on public.cb_schedule_rules,public.cb_schedule_previews to authenticated;
drop policy if exists schedule_rules_read on public.cb_schedule_rules;
create policy schedule_rules_read on public.cb_schedule_rules for select to authenticated using(public.cb_task_manager(project_id));
drop policy if exists schedule_previews_read on public.cb_schedule_previews;
create policy schedule_previews_read on public.cb_schedule_previews for select to authenticated using(user_id=auth.uid() and public.cb_task_manager(project_id));
create or replace function public.cb_schedule_fingerprint(pid uuid) returns text language sql stable security definer set search_path='' as $$
 select md5(jsonb_build_array((select jsonb_build_array(revision,archived_at) from public.cb_projects where id=pid),(select coalesce(jsonb_agg(jsonb_build_array(id,revision) order by id),'[]') from public.cb_project_events where project_id=pid),(select coalesce(jsonb_agg(jsonb_build_array(id,revision) order by id),'[]') from public.cb_tasks where project_id=pid),(select coalesce(jsonb_agg(to_jsonb(r) order by kind,target_id),'[]') from public.cb_schedule_rules r where project_id=pid))::text);
$$;
create or replace function public.cb_set_schedule_rule(p_project uuid,p_kind text,p_target uuid,p_anchor_event uuid,p_offset integer,p_enabled boolean) returns void language plpgsql security definer set search_path='' as $$
declare anchor_date date;
begin
 perform 1 from public.cb_projects where id=p_project for update;
 if not public.cb_project_access(p_project,'write') then raise exception 'Timeline editing access denied';end if;
 if p_kind not in ('event','task') or p_kind is null then raise exception 'Choose a task or celebration';end if;
 if p_kind='event' and not exists(select 1 from public.cb_project_events where id=p_target and project_id=p_project and coalesce(details->>'status','Draft') not in ('Completed','Complete')) then raise exception 'Choose an unfinished celebration in this wedding';end if;
 if p_kind='task' and not exists(select 1 from public.cb_tasks where id=p_target and project_id=p_project and not done) then raise exception 'Choose an unfinished task in this wedding';end if;
 if not p_enabled then delete from public.cb_schedule_rules where project_id=p_project and kind=p_kind and target_id=p_target;
 else
  if p_kind='event' and p_anchor_event is not null then raise exception 'Celebrations follow the wedding date';end if;
  if p_anchor_event is null then select nullif(details->>'date','')::date into anchor_date from public.cb_projects where id=p_project;
  else select nullif(details->>'date','')::date into anchor_date from public.cb_project_events where id=p_anchor_event and project_id=p_project;end if;
  if anchor_date is null then raise exception 'Set the anchor date before linking this item';end if;
  if p_offset is null or p_offset not between -3650 and 3650 then raise exception 'Choose a date offset within ten years';end if;
  insert into public.cb_schedule_rules(project_id,kind,target_id,anchor_event,offset_days) values(p_project,p_kind,p_target,p_anchor_event,p_offset) on conflict(project_id,kind,target_id) do update set anchor_event=excluded.anchor_event,offset_days=excluded.offset_days,updated_at=now();
 end if;
 insert into public.cb_project_activity(project_id,actor_id,action) values(p_project,auth.uid(),'Timeline date link updated');
end; $$;
create or replace function public.cb_preview_shared_schedule(p_project uuid,p_date date,p_anchor_event uuid default null,p_move_events uuid[] default '{}',p_move_tasks uuid[] default '{}',p_status text default 'Confirmed') returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.cb_projects; root public.cb_project_events; e record;t record; old_date date; new_date date; anchor_date date; delta integer; changes jsonb:='[]'; skipped jsonb:='[]'; conflicts jsonb:='[]'; affected uuid[]:='{}'; candidate jsonb; dep record; dep_date date; task_date date; preview public.cb_schedule_previews; rule public.cb_schedule_rules;
begin
 select * into p from public.cb_projects where id=p_project for update;
 if not found or not public.cb_project_access(p_project,'write') then raise exception 'Timeline editing access denied';end if;
 if p_date is null or p_date not between date '1900-01-01' and date '2200-12-31' or p_status not in ('Projected','Tentative','Confirmed') or p_status is null then raise exception 'Choose a valid date and date status';end if;
 if p_anchor_event is null then old_date=nullif(p.details->>'date','')::date;
  if old_date is distinct from p_date or coalesce(p.details->>'dateStatus','Projected')<>p_status then changes=changes||jsonb_build_array(jsonb_build_object('kind','project','id',p.id,'title',p.title,'before',old_date,'after',p_date,'revision',p.revision,'reason','Wedding date','date_status',p_status));end if;
 else
  select * into root from public.cb_project_events where id=p_anchor_event and project_id=p_project;
  if not found or coalesce(root.details->>'status','Draft') in ('Completed','Complete') then raise exception 'Choose an unfinished celebration in this wedding';end if;
  if exists(select 1 from public.cb_schedule_rules where project_id=p_project and kind='event' and target_id=root.id) and abs(p_date-(p.details->>'date')::date)>3650 then raise exception 'This celebration is linked to the wedding. Choose a date within ten years or unlink it first';end if;
  old_date=nullif(root.details->>'date','')::date;affected=array_append(affected,root.id);
  if old_date is distinct from p_date or coalesce(root.details->>'dateStatus','Projected')<>p_status then changes=changes||jsonb_build_array(jsonb_build_object('kind','event','id',root.id,'title',root.title,'before',old_date,'after',p_date,'revision',root.revision,'reason','Celebration date','date_status',p_status));end if;
 end if;
 delta=p_date-old_date;
 if cardinality(coalesce(p_move_events,'{}'))>2000 or cardinality(coalesce(p_move_tasks,'{}'))>10000 then raise exception 'Choose a smaller date change';end if;
 if exists(select 1 from unnest(coalesce(p_move_events,'{}')) x where not exists(select 1 from public.cb_project_events where id=x and project_id=p_project)) or exists(select 1 from unnest(coalesce(p_move_tasks,'{}')) x where not exists(select 1 from public.cb_tasks where id=x and project_id=p_project)) then raise exception 'Choose records from this wedding';end if;
 for e in select x.*,r.target_id linked,r.offset_days from public.cb_project_events x left join public.cb_schedule_rules r on r.project_id=p_project and r.kind='event' and r.target_id=x.id where x.project_id=p_project and x.id is distinct from p_anchor_event order by x.id loop
  if coalesce(e.details->>'status','Draft') in ('Completed','Complete') then skipped=skipped||jsonb_build_array(jsonb_build_object('kind','event','title',e.title,'reason','Completed'));continue;end if;
  new_date=null;
  if p_anchor_event is null and e.linked is not null then new_date=p_date+e.offset_days;affected=array_append(affected,e.id);
  elsif e.id=any(coalesce(p_move_events,'{}')) then
   if e.linked is not null then raise exception 'This celebration follows the wedding date. Reschedule its anchor instead';end if;
   if delta is null or nullif(e.details->>'date','') is null then raise exception 'A fixed date needs an existing anchor and target date to move';end if;
   new_date=(e.details->>'date')::date+delta;affected=array_append(affected,e.id);
  end if;
  if new_date is not null and new_date is distinct from nullif(e.details->>'date','')::date then changes=changes||jsonb_build_array(jsonb_build_object('kind','event','id',e.id,'title',e.title,'before',nullif(e.details->>'date','')::date,'after',new_date,'revision',e.revision,'reason',case when e.linked is not null then 'Linked to wedding date' else 'Keep the same gap' end));end if;
 end loop;
 for t in select x.*,r.target_id linked,r.anchor_event,r.offset_days from public.cb_tasks x left join public.cb_schedule_rules r on r.project_id=p_project and r.kind='task' and r.target_id=x.id where x.project_id=p_project order by x.id loop
  if t.done then skipped=skipped||jsonb_build_array(jsonb_build_object('kind','task','title',t.title,'reason','Completed'));continue;end if;
  new_date=null;anchor_date=null;
  if t.linked is not null and ((p_anchor_event is null and t.anchor_event is null) or t.anchor_event=any(affected)) then
   if t.anchor_event is null then anchor_date=p_date;
   elsif t.anchor_event=p_anchor_event then anchor_date=p_date;
   else select (c->>'after')::date into anchor_date from jsonb_array_elements(changes) c where c->>'kind'='event' and (c->>'id')::uuid=t.anchor_event; if anchor_date is null then select nullif(details->>'date','')::date into anchor_date from public.cb_project_events where id=t.anchor_event;end if;end if;
   new_date=anchor_date+t.offset_days;
  elsif t.id=any(coalesce(p_move_tasks,'{}')) then
   if t.linked is not null then raise exception 'This task follows another date. Reschedule its anchor instead';end if;
   if delta is null or t.due_date is null then raise exception 'A fixed deadline needs existing dates to move';end if;
   new_date=t.due_date+delta;
  end if;
  if new_date is not null and new_date is distinct from t.due_date then changes=changes||jsonb_build_array(jsonb_build_object('kind','task','id',t.id,'title',t.title,'before',t.due_date,'after',new_date,'revision',t.revision,'reason',case when t.linked is not null then 'Linked deadline' else 'Keep the same gap' end,'approval_resets',t.approved_by is not null));end if;
 end loop;
 -- Check only dependency pairs touched by this proposal; unrelated existing conflicts do not block it.
 for t in select * from public.cb_tasks where project_id=p_project and not done loop
  select coalesce((select (c->>'after')::date from jsonb_array_elements(changes) c where c->>'kind'='task' and (c->>'id')::uuid=t.id),t.due_date) into task_date;
  for dep in select x.* from jsonb_array_elements_text(coalesce(t.plan->'dependencies','[]')) d join public.cb_tasks x on x.id=d.value::uuid loop
   select coalesce((select (c->>'after')::date from jsonb_array_elements(changes) c where c->>'kind'='task' and (c->>'id')::uuid=dep.id),dep.due_date) into dep_date;
   if task_date<dep_date and exists(select 1 from jsonb_array_elements(changes) c where c->>'kind'='task' and (c->>'id')::uuid in (t.id,dep.id)) then conflicts=conflicts||jsonb_build_array(jsonb_build_object('task',t.title,'prerequisite',dep.title,'message','Deadline is before its prerequisite'));end if;
  end loop;
 end loop;
 delete from public.cb_schedule_previews where user_id=auth.uid() and expires_at<now()-interval '1 day';
 insert into public.cb_schedule_previews(project_id,user_id,fingerprint,payload) values(p_project,auth.uid(),public.cb_schedule_fingerprint(p_project),jsonb_build_object('project_id',p_project,'anchor_event',p_anchor_event,'new_date',p_date,'changes',changes,'skipped',skipped,'conflicts',conflicts)) returning * into preview;
 return preview.payload||jsonb_build_object('preview_id',preview.id,'expires_at',preview.expires_at);
end; $$;
create or replace function public.cb_apply_shared_schedule(p_preview uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare draft public.cb_schedule_previews;pid uuid;change jsonb; p public.cb_projects;e public.cb_project_events; t public.cb_tasks; out_changes jsonb:='[]';anchor_id uuid;
begin
 select project_id into pid from public.cb_schedule_previews where id=p_preview and user_id=auth.uid();
 perform 1 from public.cb_projects where id=pid for update;
 select * into draft from public.cb_schedule_previews where id=p_preview and user_id=auth.uid() for update;
 if not found or not public.cb_task_manager(pid) then raise exception 'Schedule preview access denied';end if;
 if draft.applied_at is not null then return draft.payload;end if;
 if not public.cb_project_access(pid,'write') then raise exception 'Timeline editing access denied';end if;
 if draft.expires_at<now() then raise exception 'This preview expired. Create a fresh preview';end if;
 if draft.fingerprint<>public.cb_schedule_fingerprint(pid) then raise exception 'CB_SCHEDULE_CONFLICT: Plans changed after this preview. Review a fresh preview' using errcode='40001';end if;
 if jsonb_array_length(draft.payload->'conflicts')>0 then raise exception 'Resolve the prerequisite conflicts before applying';end if;
 if jsonb_array_length(draft.payload->'changes')=0 then raise exception 'No dates need to change';end if;
 perform set_config('cb.schedule.apply','1',true);
 for change in select value from jsonb_array_elements(draft.payload->'changes') loop
  if change->>'kind'='project' then
   select * into p from public.cb_projects where id=pid;
   select * into p from public.cb_update_wedding_project(pid,p.revision,p.title,p.details||jsonb_build_object('date',change->>'after','dateStatus',change->>'date_status'),null,null);
   change=change||jsonb_build_object('new_revision',p.revision);
  elsif change->>'kind'='event' then
   select * into e from public.cb_project_events where id=(change->>'id')::uuid and project_id=pid;
   select * into e from public.cb_save_project_event(pid,e.local_ref,e.revision,e.title,e.details||jsonb_build_object('date',change->>'after')||case when change ? 'date_status' then jsonb_build_object('dateStatus',change->>'date_status') else '{}'::jsonb end,e.visibility);
   change=change||jsonb_build_object('new_revision',e.revision);
  else
   update public.cb_tasks set due_date=(change->>'after')::date,revision=revision+1,updated_at=now() where id=(change->>'id')::uuid and project_id=pid returning * into t;
   change=change||jsonb_build_object('new_revision',t.revision);
  end if;
  out_changes=out_changes||jsonb_build_array(change);
 end loop;
 anchor_id=nullif(draft.payload->>'anchor_event','')::uuid;
 if anchor_id is not null then
  select * into p from public.cb_projects where id=pid;
  update public.cb_schedule_rules set offset_days=((draft.payload->>'new_date')::date-(p.details->>'date')::date),updated_at=now() where project_id=pid and kind='event' and target_id=anchor_id;
 end if;
 perform set_config('cb.schedule.apply','0',true);
 insert into public.cb_project_activity(project_id,actor_id,action,changed_fields) values(pid,auth.uid(),'Shared timeline rescheduled',array['Dates','Linked deadlines']);
 update public.cb_schedule_previews set applied_at=now(),payload=payload||jsonb_build_object('changes',out_changes,'applied',true) where id=p_preview returning * into draft;
 return draft.payload;
end; $$;
create or replace function public.cb_guard_linked_dates() returns trigger language plpgsql set search_path='' as $$
begin
 if coalesce(current_setting('cb.schedule.apply',true),'0')='1' then return new;end if;
 if tg_table_name='cb_projects' then
  if (new.details->>'date') is distinct from (old.details->>'date') and exists(select 1 from public.cb_schedule_rules where project_id=new.id) then raise exception 'Use timeline rescheduling to change a date with linked plans';end if;
 elsif tg_table_name='cb_project_events' then
  if (new.details->>'date') is distinct from (old.details->>'date') and exists(select 1 from public.cb_schedule_rules where project_id=new.project_id and ((kind='event' and target_id=new.id) or anchor_event=new.id)) then raise exception 'Use timeline rescheduling to change this linked celebration date';end if;
 elsif new.due_date is distinct from old.due_date and exists(select 1 from public.cb_schedule_rules where project_id=new.project_id and kind='task' and target_id=new.id) then raise exception 'This deadline follows a timeline rule. Change the rule or reschedule its anchor';end if;
 return new;
end; $$;
drop trigger if exists cb_guard_linked_project_date on public.cb_projects;
create trigger cb_guard_linked_project_date before update on public.cb_projects for each row execute function public.cb_guard_linked_dates();
drop trigger if exists cb_guard_linked_event_date on public.cb_project_events;
create trigger cb_guard_linked_event_date before update on public.cb_project_events for each row execute function public.cb_guard_linked_dates();
drop trigger if exists cb_guard_linked_task_date on public.cb_tasks;
create trigger cb_guard_linked_task_date before update on public.cb_tasks for each row execute function public.cb_guard_linked_dates();
revoke all on function public.cb_schedule_fingerprint(uuid) from public,anon,authenticated;
revoke all on function public.cb_set_schedule_rule(uuid,text,uuid,uuid,integer,boolean),public.cb_preview_shared_schedule(uuid,date,uuid,uuid[],uuid[],text),public.cb_apply_shared_schedule(uuid) from public,anon;
grant execute on function public.cb_set_schedule_rule(uuid,text,uuid,uuid,integer,boolean),public.cb_preview_shared_schedule(uuid,date,uuid,uuid[],uuid[],text),public.cb_apply_shared_schedule(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
