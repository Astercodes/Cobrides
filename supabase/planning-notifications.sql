-- Shared planning inbox. Run after shared-timeline.sql. Existing private records are untouched.
begin;
create table if not exists public.cb_planning_preferences(
 user_id uuid primary key references auth.users on delete cascade,
 categories text[] not null default array['assignments','approvals','deadlines','schedule'],
 time_zone text not null default 'UTC', updated_at timestamptz not null default now()
);
create table if not exists public.cb_planning_notifications(
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users on delete cascade,
 project_id uuid not null references public.cb_projects on delete cascade,
 category text not null check(category in ('assignments','approvals','deadlines','schedule')),
 kind text not null, source_kind text not null check(source_kind in ('project','event','task')),
 source_id uuid not null, source_date date, title text not null, body text not null,
 dedupe_key text not null, created_at timestamptz not null default now(), read_at timestamptz,
 unique(user_id,dedupe_key)
);
create index if not exists cb_planning_inbox_user on public.cb_planning_notifications(user_id,created_at desc);
create index if not exists cb_planning_due_tasks on public.cb_tasks(due_date) where not done;
-- Explicit recipient checks also run outside a browser session during scheduled processing.
create or replace function public.cb_planning_can_view(p_user uuid,p_project uuid,p_kind text,p_source uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(
 select 1 from public.cb_projects p join auth.users u on u.id=p_user
 left join public.cb_members m on m.project_id=p.id and m.user_id=u.id
 where p.id=p_project and p.archived_at is null and (p.owner_id=u.id or m.user_id is not null)
 and case p_kind
 when 'project' then p_source=p.id
 when 'task' then exists(select 1 from public.cb_tasks t where t.id=p_source and t.project_id=p.id and
 (p.owner_id=u.id or m.role in ('bride','planner','partner') or lower(t.assignee_email)=lower(u.email) or (t.approval_required and lower(t.approver_email)=lower(u.email))))
 when 'event' then exists(select 1 from public.cb_project_events e where e.id=p_source and e.project_id=p.id and
 (p.owner_id=u.id or m.role in ('bride','planner','partner') or (e.visibility='team' and m.role in ('family','bridal-party')) or
 exists(select 1 from public.cb_project_event_members em where em.event_id=e.id and em.user_id=u.id)))
 else false end);
$$;
create or replace function public.cb_planning_notice_visible(p_project uuid,p_kind text,p_source uuid,p_date date,p_category text,p_notice_kind text)
returns boolean language sql stable security definer set search_path='' as $$
 select public.cb_planning_can_view(auth.uid(),p_project,p_kind,p_source)
 and (p_category<>'deadlines' or (p_kind='task' and exists(select 1 from public.cb_tasks t where t.id=p_source and not t.done and t.due_date=p_date)) or (p_kind='event' and exists(select 1 from public.cb_project_events e where e.id=p_source and e.details->>'date'=p_date::text and coalesce(e.details->>'status','') not in ('Completed','Complete'))))
 and (p_notice_kind<>'approval_requested' or exists(select 1 from public.cb_tasks t join auth.users u on u.id=auth.uid() where t.id=p_source and not t.done and t.approval_required and t.approved_by is null and lower(t.approver_email)=lower(u.email)))
 and (p_notice_kind<>'assigned' or exists(select 1 from public.cb_tasks t join auth.users u on u.id=auth.uid() where t.id=p_source and lower(t.assignee_email)=lower(u.email)))
 and not exists(select 1 from public.cb_planning_preferences pref where pref.user_id=auth.uid() and not p_category=any(pref.categories));
$$;
alter table public.cb_planning_notifications enable row level security;
alter table public.cb_planning_preferences enable row level security;
revoke all on public.cb_planning_notifications,public.cb_planning_preferences from public,anon,authenticated;
grant select on public.cb_planning_notifications,public.cb_planning_preferences to authenticated;
drop policy if exists planning_inbox_own on public.cb_planning_notifications;
create policy planning_inbox_own on public.cb_planning_notifications for select to authenticated using(
 user_id=auth.uid() and public.cb_planning_notice_visible(project_id,source_kind,source_id,source_date,category,kind));
drop policy if exists planning_preferences_own on public.cb_planning_preferences;
create policy planning_preferences_own on public.cb_planning_preferences for select to authenticated using(user_id=auth.uid());

create or replace function public.cb_queue_planning_notice(p_user uuid,p_project uuid,p_category text,p_kind text,p_source_kind text,p_source uuid,p_date date,p_title text,p_body text,p_key text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.cb_planning_can_view(p_user,p_project,p_source_kind,p_source) then return;end if;
 if exists(select 1 from public.cb_planning_preferences where user_id=p_user and not p_category=any(categories)) then return;end if;
 insert into public.cb_planning_notifications(user_id,project_id,category,kind,source_kind,source_id,source_date,title,body,dedupe_key)
 values(p_user,p_project,p_category,p_kind,p_source_kind,p_source,p_date,left(p_title,300),left(p_body,600),p_key)
 on conflict(user_id,dedupe_key) do nothing;
end; $$;

create or replace function public.cb_planning_task_notice() returns trigger language plpgsql security definer set search_path='' as $$
declare r record; key text; changed_assignment boolean; changed_date boolean; needs_approval boolean; finished boolean; approved boolean;
begin
 key='task:'||new.id||':'||txid_current()::text;
 changed_assignment=TG_OP='INSERT';changed_date=false;needs_approval=new.approval_required and new.approved_by is null;finished=false;approved=false;
 if TG_OP='UPDATE' then
  changed_assignment=old.assignee_email is distinct from new.assignee_email;
  changed_date=old.due_date is distinct from new.due_date;
  needs_approval=needs_approval and (not old.approval_required or old.approver_email is distinct from new.approver_email or old.approved_by is not null);
  finished=not old.done and new.done;
  approved=old.approved_by is null and new.approved_by is not null;
 end if;
 for r in select u.id,u.email,p.owner_id,m.role from public.cb_projects p join auth.users u on
 (u.id=p.owner_id or exists(select 1 from public.cb_members mm where mm.project_id=p.id and mm.user_id=u.id))
 left join public.cb_members m on m.project_id=p.id and m.user_id=u.id
 where p.id=new.project_id and u.id is distinct from auth.uid() loop
  if changed_assignment and lower(r.email)=lower(new.assignee_email) and not new.done then
   perform public.cb_queue_planning_notice(r.id,new.project_id,'assignments','assigned','task',new.id,new.due_date,'A task for you',new.title,key||':assigned');
  end if;
  if needs_approval and lower(r.email)=lower(new.approver_email) and not new.done then
   perform public.cb_queue_planning_notice(r.id,new.project_id,'approvals','approval_requested','task',new.id,new.due_date,'Your approval is needed',new.title,key||':approval');
  end if;
  if approved and lower(r.email)=lower(new.assignee_email) then
   perform public.cb_queue_planning_notice(r.id,new.project_id,'approvals','approved','task',new.id,new.due_date,'Your task was approved',new.title,key||':approved');
  end if;
  if changed_date and not new.done then
   perform public.cb_queue_planning_notice(r.id,new.project_id,'schedule','date_changed','task',new.id,new.due_date,'A task deadline changed',new.title||case when new.due_date is null then ' · deadline removed' else ' · '||new.due_date::text end,key||':date');
  end if;
  if finished and (r.id=r.owner_id or r.role in ('bride','planner','partner')) then
   perform public.cb_queue_planning_notice(r.id,new.project_id,'assignments','completed','task',new.id,new.due_date,'A team task is complete',new.title,key||':complete');
  end if;
 end loop;
 return new;
end; $$;
drop trigger if exists cb_planning_task_notifications on public.cb_tasks;
create trigger cb_planning_task_notifications after insert or update on public.cb_tasks for each row execute function public.cb_planning_task_notice();

create or replace function public.cb_planning_date_notice() returns trigger language plpgsql security definer set search_path='' as $$
declare r record; pid uuid; sk text;
begin
 if (old.details->>'date') is not distinct from (new.details->>'date') then return new;end if;
 sk=case when TG_TABLE_NAME='cb_projects' then 'project' else 'event' end;
 if sk='project' then pid=new.id;else pid=new.project_id;end if;
 for r in select u.id from public.cb_projects p join auth.users u on (u.id=p.owner_id or exists(select 1 from public.cb_members m where m.project_id=p.id and m.user_id=u.id)) where p.id=pid and u.id is distinct from auth.uid() loop
  perform public.cb_queue_planning_notice(r.id,pid,'schedule','date_changed',sk,new.id,nullif(new.details->>'date','')::date,
  case when sk='project' then 'Your wedding date changed' else 'A celebration date changed' end,
  new.title||' · '||coalesce(nullif(new.details->>'date',''),'Date to be decided'),
  sk||':'||new.id||':'||txid_current()::text||':date');
 end loop;
 return new;
end; $$;
drop trigger if exists cb_planning_project_date on public.cb_projects;
create trigger cb_planning_project_date after update on public.cb_projects for each row execute function public.cb_planning_date_notice();
drop trigger if exists cb_planning_event_date on public.cb_project_events;
create trigger cb_planning_event_date after update on public.cb_project_events for each row execute function public.cb_planning_date_notice();

create or replace function public.cb_generate_planning_reminders(p_user uuid default null) returns integer language plpgsql security definer set search_path='' as $$
declare r record; today date; category_kind text; n integer:=0;
begin
 for r in select t.*,u.id as recipient,coalesce(pref.time_zone,'UTC') as zone from public.cb_tasks t
 join public.cb_projects p on p.id=t.project_id and p.archived_at is null
 join auth.users u on (u.id=p.owner_id or exists(select 1 from public.cb_members m where m.project_id=p.id and m.user_id=u.id))
 left join public.cb_planning_preferences pref on pref.user_id=u.id
 where not t.done and t.due_date is not null and t.due_date<=(now() at time zone 'UTC')::date+4 and (p_user is null or u.id=p_user)
 and (pref.user_id is null or 'deadlines'=any(pref.categories))
 and public.cb_planning_can_view(u.id,t.project_id,'task',t.id) loop
  today=(now() at time zone r.zone)::date;
  if r.due_date>today+3 then continue;end if;
  category_kind=case when r.due_date<today then 'overdue' when r.due_date=today then 'due_today' else 'due_soon' end;
  perform public.cb_queue_planning_notice(r.recipient,r.project_id,'deadlines',category_kind,'task',r.id,r.due_date,
   case when r.kind='milestone' then 'Milestone' else 'Task' end||case category_kind when 'overdue' then ' overdue' when 'due_today' then ' due today' else ' coming up' end,
   r.title||' · '||r.due_date::text,'reminder:'||r.id||':'||r.due_date||':'||category_kind);
  n=n+1;
 end loop;
 for r in select e.*,u.id as recipient,coalesce(pref.time_zone,'UTC') as zone from public.cb_project_events e
 join public.cb_projects p on p.id=e.project_id and p.archived_at is null
 join auth.users u on (u.id=p.owner_id or exists(select 1 from public.cb_members m where m.project_id=p.id and m.user_id=u.id))
 left join public.cb_planning_preferences pref on pref.user_id=u.id
 where nullif(e.details->>'date','') is not null and coalesce(e.details->>'status','') not in ('Completed','Complete')
 and (p_user is null or u.id=p_user) and (pref.user_id is null or 'deadlines'=any(pref.categories))
 and public.cb_planning_can_view(u.id,e.project_id,'event',e.id) loop
  today=(now() at time zone r.zone)::date;
  if (r.details->>'date')::date<today or (r.details->>'date')::date>today+3 then continue;end if;
  category_kind=case when (r.details->>'date')::date=today then 'due_today' else 'due_soon' end;
  perform public.cb_queue_planning_notice(r.recipient,r.project_id,'deadlines',category_kind,'event',r.id,(r.details->>'date')::date,
   case when category_kind='due_today' then 'Your celebration is today' else 'A celebration is coming up' end,
   r.title||' · '||(r.details->>'date'),'event-reminder:'||r.id||':'||(r.details->>'date')||':'||category_kind);
  n=n+1;
 end loop;
 return n;
end; $$;

create or replace function public.cb_set_planning_preferences(p_categories text[],p_time_zone text) returns public.cb_planning_preferences language plpgsql security definer set search_path='' as $$
declare result public.cb_planning_preferences;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 if p_categories is null or not p_categories <@ array['assignments','approvals','deadlines','schedule']::text[] then raise exception 'Choose valid notification categories';end if;
 if not exists(select 1 from pg_timezone_names where name=p_time_zone) then raise exception 'Choose a valid time zone';end if;
 insert into public.cb_planning_preferences(user_id,categories,time_zone) values(auth.uid(),p_categories,p_time_zone)
 on conflict(user_id) do update set categories=excluded.categories,time_zone=excluded.time_zone,updated_at=now() returning * into result;
 return result;
end; $$;
create or replace function public.cb_planning_inbox() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 perform public.cb_generate_planning_reminders(auth.uid());
 select jsonb_build_object(
 'items',coalesce((select jsonb_agg(x order by x.created_at desc,x.id) from (select n.* from public.cb_planning_notifications n
 where n.user_id=auth.uid() and public.cb_planning_notice_visible(n.project_id,n.source_kind,n.source_id,n.source_date,n.category,n.kind)
 order by n.created_at desc,n.id limit 100) x),'[]'::jsonb),
 'unread',(select count(*) from public.cb_planning_notifications n where n.user_id=auth.uid() and n.read_at is null and public.cb_planning_notice_visible(n.project_id,n.source_kind,n.source_id,n.source_date,n.category,n.kind)),
 'preferences',coalesce((select to_jsonb(pref) from public.cb_planning_preferences pref where user_id=auth.uid()),jsonb_build_object('categories',array['assignments','approvals','deadlines','schedule'],'time_zone','UTC')),
 'scheduled',exists(select 1 from pg_extension where extname='pg_cron')
 ) into result;
 return result;
end; $$;
create or replace function public.cb_read_planning_notifications(p_id uuid default null,p_all boolean default false) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 update public.cb_planning_notifications n set read_at=coalesce(read_at,now()) where n.user_id=auth.uid() and (p_all or n.id=p_id)
 and public.cb_planning_notice_visible(n.project_id,n.source_kind,n.source_id,n.source_date,n.category,n.kind);
end; $$;
revoke all on function public.cb_planning_can_view(uuid,uuid,text,uuid),public.cb_queue_planning_notice(uuid,uuid,text,text,text,uuid,date,text,text,text),
 public.cb_planning_task_notice(),public.cb_planning_date_notice(),public.cb_generate_planning_reminders(uuid),
 public.cb_planning_notice_visible(uuid,text,uuid,date,text,text),public.cb_set_planning_preferences(text[],text),public.cb_planning_inbox(),public.cb_read_planning_notifications(uuid,boolean)
 from public,anon,authenticated;
grant execute on function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text),public.cb_set_planning_preferences(text[],text),public.cb_planning_inbox(),public.cb_read_planning_notifications(uuid,boolean) to authenticated;
-- Supabase Cron performs the same work even when no browser is open.
do $setup$
begin
 if exists(select 1 from pg_available_extensions where name='pg_cron') then
  create extension if not exists pg_cron;
  perform cron.schedule('cb-planning-reminders','15 * * * *','select public.cb_generate_planning_reminders();');
 end if;
end; $setup$;
notify pgrst,'reload schema';
commit;
