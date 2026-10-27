-- Decision notices extend the existing inbox, cron and opt-in daily email digest.
begin;
alter table public.cb_planning_notifications drop constraint if exists cb_planning_notifications_source_kind_check;
alter table public.cb_planning_notifications add constraint cb_planning_notifications_source_kind_check check(source_kind in ('project','event','task','decision','chat','expense','contribution','vendor_work','shopping'));
create index if not exists cb_decisions_due on public.cb_decisions(due_date) where due_date is not null;
create or replace function public.cb_decision_user_access(p_user uuid,p_project uuid,p_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select public.cb_collab_user_access(p_user,p_project,'read') and exists(select 1 from public.cb_projects p join public.cb_decisions d on d.project_id=p.id where p.id=p_project and d.id=p_id and p.archived_at is null and (d.created_by=p_user or public.cb_collab_user_access(p_user,p_project,'write') or p_user=any(d.approvers)));
$$;
do $migration$ begin
 if to_regprocedure('public.cb_planning_can_view_before_decisions(uuid,uuid,text,uuid)') is null then alter function public.cb_planning_can_view(uuid,uuid,text,uuid) rename to cb_planning_can_view_before_decisions;end if;
 if to_regprocedure('public.cb_planning_notice_visible_before_decisions(uuid,text,uuid,date,text,text)') is null then alter function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) rename to cb_planning_notice_visible_before_decisions;end if;
 if to_regprocedure('public.cb_generate_planning_reminders_before_decisions(uuid)') is null then alter function public.cb_generate_planning_reminders(uuid) rename to cb_generate_planning_reminders_before_decisions;end if;
end; $migration$;
create or replace function public.cb_planning_can_view(p_user uuid,p_project uuid,p_kind text,p_source uuid) returns boolean language sql stable security definer set search_path='' as $$
 select case when p_kind='decision' then public.cb_decision_user_access(p_user,p_project,p_source) else public.cb_planning_can_view_before_decisions(p_user,p_project,p_kind,p_source) end;
$$;
create or replace function public.cb_decision_local_day(p_user uuid) returns date language sql stable security definer set search_path='' as $$select (now() at time zone coalesce((select time_zone from public.cb_planning_preferences where user_id=p_user),'UTC'))::date$$;
create or replace function public.cb_decision_notice_visible(p_user uuid,p_project uuid,p_id uuid,p_date date,p_category text,p_kind text) returns boolean language sql stable security definer set search_path='' as $$
 select public.cb_decision_user_access(p_user,p_project,p_id)
 and not exists(select 1 from public.cb_planning_preferences where user_id=p_user and not p_category=any(categories))
 and exists(select 1 from public.cb_decisions d where d.id=p_id and d.project_id=p_project and split_part(p_kind,':',2)=d.revision::text and
 case split_part(p_kind,':',1)
 when 'decision_requested' then p_user=any(d.approvers) and not exists(select 1 from public.cb_decision_responses r where r.decision_id=d.id and r.revision=d.revision and r.user_id=p_user and r.approved)
 when 'decision_due_soon' then p_date>public.cb_decision_local_day(p_user) and p_date<=public.cb_decision_local_day(p_user)+3 and d.due_date=p_date and p_user=any(d.approvers) and not exists(select 1 from public.cb_decision_responses r where r.decision_id=d.id and r.revision=d.revision and r.user_id=p_user and r.approved)
 when 'decision_due_today' then p_date=public.cb_decision_local_day(p_user) and d.due_date=p_date and p_user=any(d.approvers) and not exists(select 1 from public.cb_decision_responses r where r.decision_id=d.id and r.revision=d.revision and r.user_id=p_user and r.approved)
 when 'decision_overdue' then p_date<public.cb_decision_local_day(p_user) and d.due_date=p_date and p_user=any(d.approvers) and not exists(select 1 from public.cb_decision_responses r where r.decision_id=d.id and r.revision=d.revision and r.user_id=p_user and r.approved)
 when 'decision_approved' then public.cb_decision_summary(d.id)->>'status'='Approved'
 when 'decision_response' then true
 when 'decision_comment' then true
 else false end);
$$;
create or replace function public.cb_planning_notice_visible(p_project uuid,p_kind text,p_source uuid,p_date date,p_category text,p_notice_kind text) returns boolean language sql stable security definer set search_path='' as $$
 select case when p_kind='decision' then public.cb_decision_notice_visible(auth.uid(),p_project,p_source,p_date,p_category,p_notice_kind) else public.cb_planning_notice_visible_before_decisions(p_project,p_kind,p_source,p_date,p_category,p_notice_kind) end;
$$;
-- Existing policy binds to the renamed function's OID, so replace it explicitly.
drop policy if exists planning_inbox_own on public.cb_planning_notifications;
create policy planning_inbox_own on public.cb_planning_notifications for select to authenticated using(user_id=auth.uid() and public.cb_planning_notice_visible(project_id,source_kind,source_id,source_date,category,kind));
create or replace function public.cb_queue_decision_notice(p_user uuid,p_id uuid,p_kind text,p_event text default '') returns void language plpgsql security definer set search_path='' as $$
declare d public.cb_decisions; category text; title text;
begin
 select * into d from public.cb_decisions where id=p_id;if not found then return;end if;
 category=case when p_kind in ('decision_due_soon','decision_due_today','decision_overdue') then 'deadlines' else 'approvals' end;
 title=case p_kind when 'decision_requested' then 'A decision needs your approval' when 'decision_response' then 'A teammate responded to a decision' when 'decision_approved' then 'Your team agreed on a decision' when 'decision_comment' then 'A new comment on your decision' when 'decision_due_soon' then 'A decision deadline is coming up' when 'decision_due_today' then 'Your decision response is due today' when 'decision_overdue' then 'A decision is waiting for your response' else null end;
 if title is null or not public.cb_decision_notice_visible(p_user,d.project_id,d.id,d.due_date,category,p_kind||':'||d.revision) then return;end if;
 perform public.cb_queue_planning_notice(p_user,d.project_id,category,p_kind||':'||d.revision,'decision',d.id,d.due_date,title,d.title,
 'decision:'||d.id||':'||d.revision||':'||p_kind||':'||coalesce(p_event,''));
end; $$;
create or replace function public.cb_decision_proposal_notice() returns trigger language plpgsql security definer set search_path='' as $$
declare recipient uuid;
begin
 if TG_OP='UPDATE' and old.revision=new.revision then return new;end if;
 foreach recipient in array new.approvers loop
 perform public.cb_queue_decision_notice(recipient,new.id,'decision_requested');end loop;
 return new;
end; $$;
create or replace function public.cb_decision_discussion_notice() returns trigger language plpgsql security definer set search_path='' as $$
declare d public.cb_decisions;recipient uuid;actor uuid;kind text;
begin
 select * into d from public.cb_decisions where id=new.decision_id;
 if TG_TABLE_NAME='cb_decision_comments' then actor=new.author_id;kind='decision_comment';else actor=new.user_id;kind=case when public.cb_decision_summary(d.id)->>'status'='Approved' then 'decision_approved' else 'decision_response' end;end if;
 for recipient in select distinct x from unnest(d.approvers||array[d.created_by,(select owner_id from public.cb_projects where id=d.project_id)]) x where x<>actor loop
 perform public.cb_queue_decision_notice(recipient,d.id,kind,new.id::text);end loop;
 return new;
end; $$;
drop trigger if exists cb_decision_proposal_notifications on public.cb_decisions;
create trigger cb_decision_proposal_notifications after insert or update on public.cb_decisions for each row execute function public.cb_decision_proposal_notice();
drop trigger if exists cb_decision_response_notifications on public.cb_decision_response_log;
create trigger cb_decision_response_notifications after insert on public.cb_decision_response_log for each row execute function public.cb_decision_discussion_notice();
drop trigger if exists cb_decision_comment_notifications on public.cb_decision_comments;
create trigger cb_decision_comment_notifications after insert on public.cb_decision_comments for each row execute function public.cb_decision_discussion_notice();
create or replace function public.cb_generate_decision_reminders(p_user uuid default null) returns integer language plpgsql security definer set search_path='' as $$
declare r record;today date;kind text;n integer:=0;
begin
 for r in select d.id,d.due_date,u.recipient,coalesce(pref.time_zone,'UTC') as zone from public.cb_decisions d cross join lateral unnest(d.approvers) u(recipient)
 left join public.cb_planning_preferences pref on pref.user_id=u.recipient
 where (p_user is null or u.recipient=p_user) and public.cb_decision_user_access(u.recipient,d.project_id,d.id)
 and not exists(select 1 from public.cb_decision_responses response where response.decision_id=d.id and response.revision=d.revision and response.user_id=u.recipient and response.approved) loop
 perform public.cb_queue_decision_notice(r.recipient,r.id,'decision_requested');
 if r.due_date is null then continue;end if;today=(now() at time zone r.zone)::date;
 if r.due_date>today+3 then continue;end if;
 kind=case when r.due_date<today then 'decision_overdue' when r.due_date=today then 'decision_due_today' else 'decision_due_soon' end;
 perform public.cb_queue_decision_notice(r.recipient,r.id,kind);n=n+1;
 end loop;return n;
end; $$;
create or replace function public.cb_generate_planning_reminders(p_user uuid default null) returns integer language plpgsql security definer set search_path='' as $$
begin return public.cb_generate_planning_reminders_before_decisions(p_user)+public.cb_generate_decision_reminders(p_user);end; $$;
-- Preserve daily email opt-in, verified addresses and all original task/event rules.
create or replace function public.cb_planning_digest_items(p_user uuid,p_since timestamptz,p_until timestamptz)
returns table(quantity bigint,latest timestamptz) language sql stable security definer set search_path='' as $$
 select count(*),max(n.created_at) from public.cb_planning_notifications n
 join public.cb_planning_preferences pref on pref.user_id=n.user_id and pref.email_opt_in and n.category=any(pref.categories)
 join auth.users u on u.id=n.user_id and u.email_confirmed_at is not null
 where n.user_id=p_user and n.read_at is null and n.created_at>p_since and n.created_at<=p_until
 and case when n.source_kind='decision' then public.cb_decision_notice_visible(p_user,n.project_id,n.source_id,n.source_date,n.category,n.kind)
 else public.cb_planning_can_view(p_user,n.project_id,n.source_kind,n.source_id)
 and (n.category<>'deadlines' or (n.source_kind='task' and exists(select 1 from public.cb_tasks t where t.id=n.source_id and not t.done and t.due_date=n.source_date)) or (n.source_kind='event' and exists(select 1 from public.cb_project_events e where e.id=n.source_id and e.details->>'date'=n.source_date::text and coalesce(e.details->>'status','') not in ('Completed','Complete'))))
 and (n.kind<>'approval_requested' or exists(select 1 from public.cb_tasks t where t.id=n.source_id and not t.done and t.approval_required and t.approved_by is null and lower(t.approver_email)=lower(u.email)))
 and (n.kind<>'assigned' or exists(select 1 from public.cb_tasks t where t.id=n.source_id and lower(t.assignee_email)=lower(u.email))) end;
$$;
revoke all on function public.cb_decision_user_access(uuid,uuid,uuid),public.cb_decision_notice_visible(uuid,uuid,uuid,date,text,text),public.cb_queue_decision_notice(uuid,uuid,text,text),public.cb_decision_proposal_notice(),public.cb_decision_discussion_notice(),public.cb_generate_decision_reminders(uuid),public.cb_generate_planning_reminders(uuid),public.cb_planning_can_view(uuid,uuid,text,uuid),public.cb_planning_digest_items(uuid,timestamptz,timestamptz),public.cb_planning_can_view_before_decisions(uuid,uuid,text,uuid),public.cb_generate_planning_reminders_before_decisions(uuid),public.cb_planning_notice_visible_before_decisions(uuid,text,uuid,date,text,text) from public,anon,authenticated;
revoke all on function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) from public,anon;
grant execute on function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) to authenticated;
revoke all on function public.cb_decision_local_day(uuid) from public,anon,authenticated;
-- Recompile dependent PL/pgSQL bodies after renaming wrapper functions.
do $refresh$
declare signature text;definition text;
begin
 foreach signature in array array['public.cb_queue_planning_notice(uuid,uuid,text,text,text,uuid,date,text,text,text)','public.cb_planning_inbox()','public.cb_read_planning_notifications(uuid,boolean)','public.cb_process_planning_email()'] loop
 if to_regprocedure(signature) is not null then select pg_get_functiondef(to_regprocedure(signature)) into definition;execute definition;end if;
 end loop;
end; $refresh$;
notify pgrst,'reload schema';
commit;
