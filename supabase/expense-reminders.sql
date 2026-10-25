-- Financially restricted payment deadlines; no payment is initiated.
begin;
alter table public.cb_planning_notifications drop constraint if exists cb_planning_notifications_source_kind_check;
alter table public.cb_planning_notifications add constraint cb_planning_notifications_source_kind_check check(source_kind in ('project','event','task','decision','chat','expense'));
create or replace function public.cb_expense_deadlines(p_expense uuid) returns table(milestone text,title text,due date,remaining numeric) language sql stable security definer set search_path='' as $$
 with expense as (
 select e.*,coalesce((select sum(case when p.kind='Payment' then p.amount else -p.amount end) from public.cb_shared_payments p where p.expense_id=e.id),0) as paid
 from public.cb_shared_expenses e join public.cb_vendor_bookings b on b.id=e.booking_id join public.cb_projects project on project.id=e.project_id
 where e.id=p_expense and not e.reconciled and b.status<>'Cancelled' and project.archived_at is null and coalesce(e.settlement_total,e.agreed_total)=e.agreed_total
 ),plan as (
 select s->>'id' as mid,s->>'title' as label,(s->>'due')::date as deadline,(s->>'amount')::numeric as amount,e.paid,
 sum((s->>'amount')::numeric) over(order by (s->>'due')::date,s->>'id') as running
 from expense e cross join lateral jsonb_array_elements(e.schedule) s
 ) select mid,label,deadline,least(amount,greatest(0,running-paid)) from plan where running>paid;
$$;
create or replace function public.cb_expense_user_access(p_user uuid,p_project uuid,p_expense uuid) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(public.cb_collab_user_access(p_user,p_project,'read') and public.cb_collab_user_access(p_user,p_project,'finance'),false)
 and exists(select 1 from public.cb_shared_expenses e join public.cb_projects p on p.id=e.project_id where e.id=p_expense and e.project_id=p_project and p.archived_at is null);
$$;
create or replace function public.cb_expense_notice_visible(p_user uuid,p_project uuid,p_expense uuid,p_date date,p_category text,p_kind text) returns boolean language sql stable security definer set search_path='' as $$
 select public.cb_expense_user_access(p_user,p_project,p_expense) and p_category='deadlines'
 and not exists(select 1 from public.cb_planning_preferences where user_id=p_user and not 'deadlines'=any(categories))
 and exists(select 1 from public.cb_expense_deadlines(p_expense) d where d.due=p_date and d.remaining>0 and p_kind=
 case when d.due<public.cb_decision_local_day(p_user) then 'expense_overdue:' when d.due=public.cb_decision_local_day(p_user) then 'expense_due_today:' when d.due<=public.cb_decision_local_day(p_user)+3 then 'expense_due_soon:' else '' end||d.milestone
 and d.due<=public.cb_decision_local_day(p_user)+3);
$$;
do $migration$ begin
 if to_regprocedure('public.cb_planning_can_view_before_expenses(uuid,uuid,text,uuid)') is null then alter function public.cb_planning_can_view(uuid,uuid,text,uuid) rename to cb_planning_can_view_before_expenses;end if;
 if to_regprocedure('public.cb_planning_notice_visible_before_expenses(uuid,text,uuid,date,text,text)') is null then alter function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) rename to cb_planning_notice_visible_before_expenses;end if;
 if to_regprocedure('public.cb_generate_planning_reminders_before_expenses(uuid)') is null then alter function public.cb_generate_planning_reminders(uuid) rename to cb_generate_planning_reminders_before_expenses;end if;
end;$migration$;
create or replace function public.cb_planning_can_view(p_user uuid,p_project uuid,p_kind text,p_source uuid) returns boolean language sql stable security definer set search_path='' as $$
 select case when p_kind='expense' then public.cb_expense_user_access(p_user,p_project,p_source) else public.cb_planning_can_view_before_expenses(p_user,p_project,p_kind,p_source) end;
$$;
create or replace function public.cb_planning_notice_visible(p_project uuid,p_kind text,p_source uuid,p_date date,p_category text,p_notice_kind text) returns boolean language sql stable security definer set search_path='' as $$
 select case when p_kind='expense' then public.cb_expense_notice_visible(auth.uid(),p_project,p_source,p_date,p_category,p_notice_kind) else public.cb_planning_notice_visible_before_expenses(p_project,p_kind,p_source,p_date,p_category,p_notice_kind) end;
$$;
drop policy if exists planning_inbox_own on public.cb_planning_notifications;
create policy planning_inbox_own on public.cb_planning_notifications for select to authenticated using(user_id=auth.uid() and public.cb_planning_notice_visible(project_id,source_kind,source_id,source_date,category,kind));
create or replace function public.cb_generate_expense_reminders(p_user uuid default null) returns integer language plpgsql security definer set search_path='' as $$
declare r record;phase text;n integer:=0;
begin
 for r in select e.id,e.project_id,d.*,u.id as recipient,public.cb_decision_local_day(u.id) as today
 from public.cb_shared_expenses e cross join lateral public.cb_expense_deadlines(e.id) d
 join auth.users u on public.cb_expense_user_access(u.id,e.project_id,e.id)
 where (p_user is null or u.id=p_user) and d.due<=public.cb_decision_local_day(u.id)+3 loop
 phase=case when r.due<r.today then 'expense_overdue:' when r.due=r.today then 'expense_due_today:' else 'expense_due_soon:' end;
 perform public.cb_queue_planning_notice(r.recipient,r.project_id,'deadlines',phase||r.milestone,'expense',r.id,r.due,
 case when r.due<r.today then 'Vendor payment overdue' when r.due=r.today then 'Vendor payment due today' else 'Vendor payment coming up' end,
 'Review the payment deadline and remaining obligation in your shared ledger.',
 'expense:'||r.id||':'||r.milestone||':'||r.due||':'||phase);n=n+1;
 end loop;return n;
end;$$;
create or replace function public.cb_generate_planning_reminders(p_user uuid default null) returns integer language plpgsql security definer set search_path='' as $$
begin return public.cb_generate_planning_reminders_before_expenses(p_user)+public.cb_generate_expense_reminders(p_user);end;$$;

create or replace function public.cb_planning_digest_items(p_user uuid,p_since timestamptz,p_until timestamptz)
returns table(quantity bigint,latest timestamptz) language sql stable security definer set search_path='' as $$
 select count(*),max(n.created_at) from public.cb_planning_notifications n
 join public.cb_planning_preferences pref on pref.user_id=n.user_id and pref.email_opt_in and n.category=any(pref.categories)
 join auth.users u on u.id=n.user_id and u.email_confirmed_at is not null
 where n.user_id=p_user and n.read_at is null and n.created_at>p_since and n.created_at<=p_until
 and case when n.source_kind='expense' then public.cb_expense_notice_visible(p_user,n.project_id,n.source_id,n.source_date,n.category,n.kind) when n.source_kind='chat' then public.cb_chat_notice_visible(p_user,n.source_id,n.kind) and exists(select 1 from public.cb_chat_participants x where x.thread_id=n.source_id and x.user_id=p_user and x.email_unread) when n.source_kind='decision' then public.cb_decision_notice_visible(p_user,n.project_id,n.source_id,n.source_date,n.category,n.kind)
 else public.cb_planning_can_view(p_user,n.project_id,n.source_kind,n.source_id)
 and (n.category<>'deadlines' or (n.source_kind='task' and exists(select 1 from public.cb_tasks t where t.id=n.source_id and not t.done and t.due_date=n.source_date)) or (n.source_kind='event' and exists(select 1 from public.cb_project_events e where e.id=n.source_id and e.details->>'date'=n.source_date::text and coalesce(e.details->>'status','') not in ('Completed','Complete'))))
 and (n.kind<>'approval_requested' or exists(select 1 from public.cb_tasks t where t.id=n.source_id and not t.done and t.approval_required and t.approved_by is null and lower(t.approver_email)=lower(u.email)))
 and (n.kind<>'assigned' or exists(select 1 from public.cb_tasks t where t.id=n.source_id and lower(t.assignee_email)=lower(u.email))) end;
$$;

revoke all on function public.cb_expense_deadlines(uuid),public.cb_expense_user_access(uuid,uuid,uuid),public.cb_expense_notice_visible(uuid,uuid,uuid,date,text,text),public.cb_generate_expense_reminders(uuid),public.cb_generate_planning_reminders(uuid),public.cb_planning_can_view(uuid,uuid,text,uuid),public.cb_planning_digest_items(uuid,timestamptz,timestamptz),public.cb_planning_can_view_before_expenses(uuid,uuid,text,uuid),public.cb_planning_notice_visible_before_expenses(uuid,text,uuid,date,text,text),public.cb_generate_planning_reminders_before_expenses(uuid) from public,anon,authenticated;
revoke all on function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) from public,anon;
grant execute on function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) to authenticated;
do $refresh$
declare signature text;definition text;
begin
 foreach signature in array array['public.cb_queue_planning_notice(uuid,uuid,text,text,text,uuid,date,text,text,text)','public.cb_planning_inbox()','public.cb_read_planning_notifications(uuid,boolean)','public.cb_process_planning_email()'] loop
 if to_regprocedure(signature) is not null then select pg_get_functiondef(to_regprocedure(signature)) into definition;execute definition;end if;
 end loop;
end;$refresh$;
notify pgrst,'reload schema';
commit;
