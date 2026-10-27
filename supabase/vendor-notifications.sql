-- Scoped vendor assignment, readiness, deliverable and deadline notices.
begin;
alter table public.cb_planning_notifications drop constraint if exists cb_planning_notifications_source_kind_check;
alter table public.cb_planning_notifications add constraint cb_planning_notifications_source_kind_check check(source_kind in ('project','event','task','decision','chat','expense','contribution','vendor_work','shopping'));
create or replace function public.cb_vendor_work_user_access(p_user uuid,p_project uuid,p_work uuid) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(public.cb_collab_user_access(p_user,p_project,'read'),false) and exists(select 1 from public.cb_vendor_work w join public.cb_shared_vendors v on v.id=w.vendor_id join public.cb_projects p on p.id=v.project_id where w.id=p_work and v.project_id=p_project and not v.archived and p.archived_at is null
 and (public.cb_collab_user_access(p_user,p_project,'owner') or public.cb_collab_user_access(p_user,p_project,'write') or w.assigned_to=p_user and p_user=any(v.readers)));
$$;
create or replace function public.cb_vendor_notice_visible(p_user uuid,p_project uuid,p_work uuid,p_date date,p_category text,p_kind text) returns boolean language sql stable security definer set search_path='' as $$
 select public.cb_vendor_work_user_access(p_user,p_project,p_work) and not exists(select 1 from public.cb_planning_preferences where user_id=p_user and not p_category=any(categories)) and exists(select 1 from public.cb_vendor_work w where w.id=p_work and case
 when p_category='deadlines' then w.status not in ('Complete','Cancelled') and w.due_date=p_date and w.due_date<=public.cb_decision_local_day(p_user)+3 and p_kind=case when w.due_date<public.cb_decision_local_day(p_user) then 'vendor_work_overdue' when w.due_date=public.cb_decision_local_day(p_user) then 'vendor_work_due_today' else 'vendor_work_due_soon' end
 when p_category='assignments' and p_kind='vendor_work_updated:'||w.revision then true
 when p_category='assignments' then w.status<>'Cancelled' and exists(select 1 from public.cb_vendor_submissions s where s.work_id=w.id and not exists(select 1 from public.cb_vendor_submissions n where n.work_id=w.id and n.version>s.version)
 and (p_kind='vendor_submission_received:'||s.id::text and s.status='Pending' or p_kind='vendor_submission_approved:'||s.id::text and s.status='Approved' or p_kind='vendor_submission_changes:'||s.id::text and s.status='Changes requested'))
 else false end);
$$;
create or replace function public.cb_vendor_notice_target(p_work uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v public.cb_shared_vendors;
begin
 select v2.* into v from public.cb_vendor_work w join public.cb_shared_vendors v2 on v2.id=w.vendor_id where w.id=p_work;
 if not public.cb_vendor_work_user_access(auth.uid(),v.project_id,p_work) then raise exception 'Vendor work access required' using errcode='42501';end if;
 return jsonb_build_object('project',v.project_id,'vendor',v.id,'work',p_work);
end;$$;
do $migration$ begin
 if to_regprocedure('public.cb_planning_can_view_before_vendor_work(uuid,uuid,text,uuid)') is null then alter function public.cb_planning_can_view(uuid,uuid,text,uuid) rename to cb_planning_can_view_before_vendor_work;end if;
 if to_regprocedure('public.cb_planning_notice_visible_before_vendor_work(uuid,text,uuid,date,text,text)') is null then alter function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) rename to cb_planning_notice_visible_before_vendor_work;end if;
 if to_regprocedure('public.cb_generate_planning_reminders_before_vendor_work(uuid)') is null then alter function public.cb_generate_planning_reminders(uuid) rename to cb_generate_planning_reminders_before_vendor_work;end if;
end;$migration$;
create or replace function public.cb_planning_can_view(p_user uuid,p_project uuid,p_kind text,p_source uuid) returns boolean language sql stable security definer set search_path='' as $$select case when p_kind='vendor_work' then public.cb_vendor_work_user_access(p_user,p_project,p_source) else public.cb_planning_can_view_before_vendor_work(p_user,p_project,p_kind,p_source) end$$;
create or replace function public.cb_planning_notice_visible(p_project uuid,p_kind text,p_source uuid,p_date date,p_category text,p_notice_kind text) returns boolean language sql stable security definer set search_path='' as $$select case when p_kind='vendor_work' then public.cb_vendor_notice_visible(auth.uid(),p_project,p_source,p_date,p_category,p_notice_kind) else public.cb_planning_notice_visible_before_vendor_work(p_project,p_kind,p_source,p_date,p_category,p_notice_kind) end$$;
drop policy if exists planning_inbox_own on public.cb_planning_notifications;
create policy planning_inbox_own on public.cb_planning_notifications for select to authenticated using(user_id=auth.uid() and public.cb_planning_notice_visible(project_id,source_kind,source_id,source_date,category,kind));
create or replace function public.cb_vendor_change_notice() returns trigger language plpgsql security definer set search_path='' as $$
declare w public.cb_vendor_work;pid uuid;recipient record;kind text;label text;actor uuid;
begin
 if TG_TABLE_NAME='cb_vendor_work' then w=new;kind='vendor_work_updated:'||w.revision;label=case w.status when 'Blocked' then 'Vendor work needs attention' when 'Ready' then 'Vendor work is ready' when 'Complete' then 'Vendor work was completed' else 'Vendor work was updated' end;actor=auth.uid();
 else select * into w from public.cb_vendor_work where id=new.work_id;
 if TG_OP='INSERT' then kind='vendor_submission_received:'||new.id::text;label='A vendor file is ready for review';actor=new.uploaded_by;
 else if old.status=new.status then return new;end if;kind=case new.status when 'Approved' then 'vendor_submission_approved:' else 'vendor_submission_changes:' end||new.id::text;label=case new.status when 'Approved' then 'A vendor submission was approved' else 'Changes were requested on a vendor file' end;actor=new.reviewed_by;end if;end if;
 select project_id into pid from public.cb_shared_vendors where id=w.vendor_id;
 for recipient in select u.id from (select owner_id as id from public.cb_projects where id=pid union select user_id from public.cb_members where project_id=pid) u where u.id is distinct from actor and public.cb_vendor_work_user_access(u.id,pid,w.id) loop
 perform public.cb_queue_planning_notice(recipient.id,pid,'assignments',kind,'vendor_work',w.id,null,label,'Review the latest shared work details in vendor coordination.','vendor-work:'||w.id||':'||kind);
 end loop;return new;
end;$$;
drop trigger if exists cb_vendor_work_notices on public.cb_vendor_work;
create trigger cb_vendor_work_notices after insert or update on public.cb_vendor_work for each row execute function public.cb_vendor_change_notice();
drop trigger if exists cb_vendor_submission_notices on public.cb_vendor_submissions;
create trigger cb_vendor_submission_notices after insert or update on public.cb_vendor_submissions for each row execute function public.cb_vendor_change_notice();
create or replace function public.cb_generate_vendor_reminders(p_user uuid default null) returns integer language plpgsql security definer set search_path='' as $$
declare r record;kind text;n integer:=0;
begin
 for r in select w.*,v.project_id,u.id as recipient,public.cb_decision_local_day(u.id) as today from public.cb_vendor_work w join public.cb_shared_vendors v on v.id=w.vendor_id join lateral (select owner_id as id from public.cb_projects where id=v.project_id union select user_id from public.cb_members where project_id=v.project_id) u on public.cb_vendor_work_user_access(u.id,v.project_id,w.id)
 where (p_user is null or u.id=p_user) and w.status not in ('Complete','Cancelled') and w.due_date<=public.cb_decision_local_day(u.id)+3 loop
 kind=case when r.due_date<r.today then 'vendor_work_overdue' when r.due_date=r.today then 'vendor_work_due_today' else 'vendor_work_due_soon' end;
 perform public.cb_queue_planning_notice(r.recipient,r.project_id,'deadlines',kind,'vendor_work',r.id,r.due_date,case kind when 'vendor_work_overdue' then 'Vendor work deadline passed' when 'vendor_work_due_today' then 'Vendor work is due today' else 'Vendor work deadline approaching' end,'Review the assigned work and its latest progress.','vendor-deadline:'||r.id||':'||r.due_date||':'||kind);n=n+1;
 end loop;return n;
end;$$;
create or replace function public.cb_generate_planning_reminders(p_user uuid default null) returns integer language plpgsql security definer set search_path='' as $$begin return public.cb_generate_planning_reminders_before_vendor_work(p_user)+public.cb_generate_vendor_reminders(p_user);end;$$;

create or replace function public.cb_planning_digest_items(p_user uuid,p_since timestamptz,p_until timestamptz)
returns table(quantity bigint,latest timestamptz) language sql stable security definer set search_path='' as $$
 select count(*),max(n.created_at) from public.cb_planning_notifications n
 join public.cb_planning_preferences pref on pref.user_id=n.user_id and pref.email_opt_in and n.category=any(pref.categories)
 join auth.users u on u.id=n.user_id and u.email_confirmed_at is not null
 where n.user_id=p_user and n.read_at is null and n.created_at>p_since and n.created_at<=p_until
 and case when n.source_kind='vendor_work' then public.cb_vendor_notice_visible(p_user,n.project_id,n.source_id,n.source_date,n.category,n.kind) when n.source_kind='contribution' then public.cb_contribution_notice_visible(p_user,n.project_id,n.source_id,n.source_date,n.category,n.kind) when n.source_kind='expense' then public.cb_expense_notice_visible(p_user,n.project_id,n.source_id,n.source_date,n.category,n.kind) when n.source_kind='chat' then public.cb_chat_notice_visible(p_user,n.source_id,n.kind) and exists(select 1 from public.cb_chat_participants x where x.thread_id=n.source_id and x.user_id=p_user and x.email_unread) when n.source_kind='decision' then public.cb_decision_notice_visible(p_user,n.project_id,n.source_id,n.source_date,n.category,n.kind)
 else public.cb_planning_can_view(p_user,n.project_id,n.source_kind,n.source_id)
 and (n.category<>'deadlines' or (n.source_kind='task' and exists(select 1 from public.cb_tasks t where t.id=n.source_id and not t.done and t.due_date=n.source_date)) or (n.source_kind='event' and exists(select 1 from public.cb_project_events e where e.id=n.source_id and e.details->>'date'=n.source_date::text and coalesce(e.details->>'status','') not in ('Completed','Complete'))))
 and (n.kind<>'approval_requested' or exists(select 1 from public.cb_tasks t where t.id=n.source_id and not t.done and t.approval_required and t.approved_by is null and lower(t.approver_email)=lower(u.email)))
 and (n.kind<>'assigned' or exists(select 1 from public.cb_tasks t where t.id=n.source_id and lower(t.assignee_email)=lower(u.email))) end;
$$;
revoke all on function public.cb_vendor_work_user_access(uuid,uuid,uuid),public.cb_vendor_notice_visible(uuid,uuid,uuid,date,text,text),public.cb_vendor_change_notice(),public.cb_generate_vendor_reminders(uuid),public.cb_generate_planning_reminders(uuid),public.cb_planning_can_view(uuid,uuid,text,uuid),public.cb_planning_digest_items(uuid,timestamptz,timestamptz),public.cb_planning_can_view_before_vendor_work(uuid,uuid,text,uuid),public.cb_planning_notice_visible_before_vendor_work(uuid,text,uuid,date,text,text),public.cb_generate_planning_reminders_before_vendor_work(uuid) from public,anon,authenticated;
revoke all on function public.cb_vendor_notice_target(uuid) from public,anon,authenticated;
grant execute on function public.cb_vendor_notice_target(uuid) to authenticated;
revoke all on function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) from public,anon;
grant execute on function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) to authenticated;
do $refresh$ declare signature text;definition text;begin foreach signature in array array['public.cb_queue_planning_notice(uuid,uuid,text,text,text,uuid,date,text,text,text)','public.cb_planning_inbox()','public.cb_read_planning_notifications(uuid,boolean)','public.cb_process_planning_email()'] loop if to_regprocedure(signature) is not null then select pg_get_functiondef(to_regprocedure(signature)) into definition;execute definition;end if;end loop;end;$refresh$;
notify pgrst,'reload schema';
commit;
