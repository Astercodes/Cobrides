-- Private pledge, receipt and deadline notices. Existing email consent is preserved.
begin;
alter table public.cb_planning_notifications drop constraint if exists cb_planning_notifications_source_kind_check;
alter table public.cb_planning_notifications add constraint cb_planning_notifications_source_kind_check check(source_kind in ('project','event','task','decision','chat','expense','contribution'));
create or replace function public.cb_contribution_user_access(p_user uuid,p_project uuid,p_contribution uuid) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(public.cb_collab_user_access(p_user,p_project,'read'),false) and exists(select 1 from public.cb_shared_contributions c join public.cb_projects p on p.id=c.project_id where c.id=p_contribution and c.project_id=p_project and p.archived_at is null and (public.cb_collab_user_access(p_user,p_project,'finance') or c.contributor=p_user));
$$;
create or replace function public.cb_contribution_notice_visible(p_user uuid,p_project uuid,p_contribution uuid,p_date date,p_category text,p_kind text) returns boolean language sql stable security definer set search_path='' as $$
 select public.cb_contribution_user_access(p_user,p_project,p_contribution)
 and not exists(select 1 from public.cb_planning_preferences where user_id=p_user and not p_category=any(categories))
 and exists(select 1 from public.cb_shared_contributions c where c.id=p_contribution and case
 when p_category='assignments' and p_kind='contribution_updated:'||c.revision then true
 when p_category='assignments' then exists(select 1 from public.cb_contribution_receipts r where r.contribution_id=c.id and (p_kind='contribution_received:'||r.id::text and r.voided_at is null or p_kind='contribution_corrected:'||r.id::text and r.voided_at is not null))
 when p_category='deadlines' then c.status='Active' and c.due=p_date and c.due<=public.cb_decision_local_day(p_user)+3
 and coalesce((select sum(amount) from public.cb_contribution_receipts where contribution_id=c.id and voided_at is null),0)<c.amount
 and p_kind=case when c.due<public.cb_decision_local_day(p_user) then 'contribution_overdue' when c.due=public.cb_decision_local_day(p_user) then 'contribution_due_today' else 'contribution_due_soon' end
 else false end);
$$;
do $migration$ begin
 if to_regprocedure('public.cb_planning_can_view_before_contributions(uuid,uuid,text,uuid)') is null then alter function public.cb_planning_can_view(uuid,uuid,text,uuid) rename to cb_planning_can_view_before_contributions;end if;
 if to_regprocedure('public.cb_planning_notice_visible_before_contributions(uuid,text,uuid,date,text,text)') is null then alter function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) rename to cb_planning_notice_visible_before_contributions;end if;
 if to_regprocedure('public.cb_generate_planning_reminders_before_contributions(uuid)') is null then alter function public.cb_generate_planning_reminders(uuid) rename to cb_generate_planning_reminders_before_contributions;end if;
end;$migration$;
create or replace function public.cb_planning_can_view(p_user uuid,p_project uuid,p_kind text,p_source uuid) returns boolean language sql stable security definer set search_path='' as $$
 select case when p_kind='contribution' then public.cb_contribution_user_access(p_user,p_project,p_source) else public.cb_planning_can_view_before_contributions(p_user,p_project,p_kind,p_source) end;
$$;
create or replace function public.cb_planning_notice_visible(p_project uuid,p_kind text,p_source uuid,p_date date,p_category text,p_notice_kind text) returns boolean language sql stable security definer set search_path='' as $$
 select case when p_kind='contribution' then public.cb_contribution_notice_visible(auth.uid(),p_project,p_source,p_date,p_category,p_notice_kind) else public.cb_planning_notice_visible_before_contributions(p_project,p_kind,p_source,p_date,p_category,p_notice_kind) end;
$$;
drop policy if exists planning_inbox_own on public.cb_planning_notifications;
create policy planning_inbox_own on public.cb_planning_notifications for select to authenticated using(user_id=auth.uid() and public.cb_planning_notice_visible(project_id,source_kind,source_id,source_date,category,kind));
create or replace function public.cb_contribution_change_notice() returns trigger language plpgsql security definer set search_path='' as $$
declare c public.cb_shared_contributions;recipient record;kind text;label text;actor uuid;
begin
 if TG_TABLE_NAME='cb_shared_contributions' then
  if TG_OP='UPDATE' and (old.title,old.sponsor,old.contributor,old.currency,old.amount,old.kind,old.due,old.notes,old.status) is not distinct from (new.title,new.sponsor,new.contributor,new.currency,new.amount,new.kind,new.due,new.notes,new.status) then return new;end if;
  c=new;kind='contribution_updated:'||c.revision;label='Your shared contribution was updated';actor=auth.uid();
 else
  select * into c from public.cb_shared_contributions where id=new.contribution_id;
  if TG_OP='UPDATE' then if old.voided_at is not null or new.voided_at is null then return new;end if;kind='contribution_corrected:'||new.id::text;label='A contribution receipt was corrected';actor=new.voided_by;
  else kind='contribution_received:'||new.id::text;label='A contribution receipt was recorded';actor=new.created_by;end if;
 end if;
 for recipient in select u.id from auth.users u where u.id is distinct from actor and public.cb_contribution_user_access(u.id,c.project_id,c.id) loop
 perform public.cb_queue_planning_notice(recipient.id,c.project_id,'assignments',kind,'contribution',c.id,null,label,'Review the latest contribution record in your wedding workspace.','contribution:'||c.id||':'||kind);
 end loop;return new;
end;$$;
drop trigger if exists cb_shared_contribution_notices on public.cb_shared_contributions;
create trigger cb_shared_contribution_notices after insert or update on public.cb_shared_contributions for each row execute function public.cb_contribution_change_notice();
drop trigger if exists cb_shared_contribution_receipt_notices on public.cb_contribution_receipts;
create trigger cb_shared_contribution_receipt_notices after insert or update on public.cb_contribution_receipts for each row execute function public.cb_contribution_change_notice();
create or replace function public.cb_generate_contribution_reminders(p_user uuid default null) returns integer language plpgsql security definer set search_path='' as $$
declare r record;kind text;n integer:=0;
begin
 for r in select c.*,u.id as recipient,public.cb_decision_local_day(u.id) as today from public.cb_shared_contributions c join auth.users u on public.cb_contribution_user_access(u.id,c.project_id,c.id)
 where (p_user is null or u.id=p_user) and c.status='Active' and c.due<=public.cb_decision_local_day(u.id)+3 and coalesce((select sum(amount) from public.cb_contribution_receipts where contribution_id=c.id and voided_at is null),0)<c.amount loop
 kind=case when r.due<r.today then 'contribution_overdue' when r.due=r.today then 'contribution_due_today' else 'contribution_due_soon' end;
 perform public.cb_queue_planning_notice(r.recipient,r.project_id,'deadlines',kind,'contribution',r.id,r.due,
 case kind when 'contribution_overdue' then 'Contribution deadline passed' when 'contribution_due_today' then 'Contribution expected today' else 'Contribution deadline approaching' end,
 'Review the expected contribution and recorded receipts.','contribution:'||r.id||':'||r.due||':'||kind);n=n+1;
 end loop;return n;
end;$$;
create or replace function public.cb_generate_planning_reminders(p_user uuid default null) returns integer language plpgsql security definer set search_path='' as $$
begin return public.cb_generate_planning_reminders_before_contributions(p_user)+public.cb_generate_contribution_reminders(p_user);end;$$;

create or replace function public.cb_planning_digest_items(p_user uuid,p_since timestamptz,p_until timestamptz)
returns table(quantity bigint,latest timestamptz) language sql stable security definer set search_path='' as $$
 select count(*),max(n.created_at) from public.cb_planning_notifications n
 join public.cb_planning_preferences pref on pref.user_id=n.user_id and pref.email_opt_in and n.category=any(pref.categories)
 join auth.users u on u.id=n.user_id and u.email_confirmed_at is not null
 where n.user_id=p_user and n.read_at is null and n.created_at>p_since and n.created_at<=p_until
 and case when n.source_kind='contribution' then public.cb_contribution_notice_visible(p_user,n.project_id,n.source_id,n.source_date,n.category,n.kind) when n.source_kind='expense' then public.cb_expense_notice_visible(p_user,n.project_id,n.source_id,n.source_date,n.category,n.kind) when n.source_kind='chat' then public.cb_chat_notice_visible(p_user,n.source_id,n.kind) and exists(select 1 from public.cb_chat_participants x where x.thread_id=n.source_id and x.user_id=p_user and x.email_unread) when n.source_kind='decision' then public.cb_decision_notice_visible(p_user,n.project_id,n.source_id,n.source_date,n.category,n.kind)
 else public.cb_planning_can_view(p_user,n.project_id,n.source_kind,n.source_id)
 and (n.category<>'deadlines' or (n.source_kind='task' and exists(select 1 from public.cb_tasks t where t.id=n.source_id and not t.done and t.due_date=n.source_date)) or (n.source_kind='event' and exists(select 1 from public.cb_project_events e where e.id=n.source_id and e.details->>'date'=n.source_date::text and coalesce(e.details->>'status','') not in ('Completed','Complete'))))
 and (n.kind<>'approval_requested' or exists(select 1 from public.cb_tasks t where t.id=n.source_id and not t.done and t.approval_required and t.approved_by is null and lower(t.approver_email)=lower(u.email)))
 and (n.kind<>'assigned' or exists(select 1 from public.cb_tasks t where t.id=n.source_id and lower(t.assignee_email)=lower(u.email))) end;
$$;
revoke all on function public.cb_contribution_user_access(uuid,uuid,uuid),public.cb_contribution_notice_visible(uuid,uuid,uuid,date,text,text),public.cb_contribution_change_notice(),public.cb_generate_contribution_reminders(uuid),public.cb_generate_planning_reminders(uuid),public.cb_planning_can_view(uuid,uuid,text,uuid),public.cb_planning_digest_items(uuid,timestamptz,timestamptz),public.cb_planning_can_view_before_contributions(uuid,uuid,text,uuid),public.cb_planning_notice_visible_before_contributions(uuid,text,uuid,date,text,text),public.cb_generate_planning_reminders_before_contributions(uuid) from public,anon,authenticated;
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
