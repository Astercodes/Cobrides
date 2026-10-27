-- Shared shopping updates and date reminders; no carrier tracking or payments are inferred.
begin;
alter table public.cb_planning_notifications drop constraint if exists cb_planning_notifications_source_kind_check;
alter table public.cb_planning_notifications add constraint cb_planning_notifications_source_kind_check check(source_kind in ('project','event','task','decision','chat','expense','contribution','vendor_work','shopping'));
alter table public.cb_shopping_items add column if not exists notice_revision bigint not null default 1;
create or replace function public.cb_shopping_notice_access(p_user uuid,p_project uuid,p_item uuid) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(public.cb_collab_user_access(p_user,p_project,'read'),false) and exists(select 1 from public.cb_shopping_items i join public.cb_shopping_lists l on l.id=i.list_id join public.cb_projects p on p.id=l.project_id where i.id=p_item and l.project_id=p_project and not l.archived and p.archived_at is null and (public.cb_collab_user_access(p_user,p_project,'owner') or public.cb_collab_user_access(p_user,p_project,'write') or i.buyer_id=p_user and p_user=any(l.readers)));
$$;
create or replace function public.cb_shopping_deadline_rows(p_item uuid) returns table(kind text,due date) language sql stable security definer set search_path='' as $$
 select dates.kind,nullif(dates.value,'')::date from public.cb_shopping_items i cross join lateral (values
 ('purchase',case when i.status in ('Needed','Reserved') then i.data->>'due' end),
 ('delivery',case when i.status in ('Purchased','Shipped') then i.data->>'deliveryDue' end),
 ('return',case when i.status in ('Purchased','Shipped','Delivered','Return requested') then i.data->>'returnDue' end)) dates(kind,value) where i.id=p_item and coalesce(dates.value,'')<>'';
$$;
create or replace function public.cb_shopping_notice_visible(p_user uuid,p_project uuid,p_item uuid,p_date date,p_category text,p_kind text) returns boolean language sql stable security definer set search_path='' as $$
 select public.cb_shopping_notice_access(p_user,p_project,p_item) and not exists(select 1 from public.cb_planning_preferences where user_id=p_user and not p_category=any(categories)) and case
 when p_category='assignments' then exists(select 1 from public.cb_shopping_items where id=p_item and p_kind='shopping_updated:'||notice_revision)
 when p_category='deadlines' then exists(select 1 from public.cb_shopping_deadline_rows(p_item) d where d.due=p_date and d.due<=public.cb_decision_local_day(p_user)+3 and p_kind='shopping_'||d.kind||case when d.due<public.cb_decision_local_day(p_user) then '_overdue' when d.due=public.cb_decision_local_day(p_user) then '_today' else '_soon' end)
 else false end;
$$;
create or replace function public.cb_shopping_notice_target(p_item uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare pid uuid;lid uuid;
begin
 select l.project_id,l.id into pid,lid from public.cb_shopping_items i join public.cb_shopping_lists l on l.id=i.list_id where i.id=p_item;
 if not coalesce(public.cb_shopping_notice_access(auth.uid(),pid,p_item),false) then raise exception 'Shopping notification access required' using errcode='42501';end if;
 return jsonb_build_object('project',pid,'list',lid,'item',p_item);
end;$$;
do $migration$ begin
 if to_regprocedure('public.cb_planning_can_view_before_shopping(uuid,uuid,text,uuid)') is null then alter function public.cb_planning_can_view(uuid,uuid,text,uuid) rename to cb_planning_can_view_before_shopping;end if;
 if to_regprocedure('public.cb_planning_notice_visible_before_shopping(uuid,text,uuid,date,text,text)') is null then alter function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) rename to cb_planning_notice_visible_before_shopping;end if;
 if to_regprocedure('public.cb_generate_planning_reminders_before_shopping(uuid)') is null then alter function public.cb_generate_planning_reminders(uuid) rename to cb_generate_planning_reminders_before_shopping;end if;
end;$migration$;
create or replace function public.cb_planning_can_view(p_user uuid,p_project uuid,p_kind text,p_source uuid) returns boolean language sql stable security definer set search_path='' as $$select case when p_kind='shopping' then public.cb_shopping_notice_access(p_user,p_project,p_source) else public.cb_planning_can_view_before_shopping(p_user,p_project,p_kind,p_source) end$$;
create or replace function public.cb_planning_notice_visible(p_project uuid,p_kind text,p_source uuid,p_date date,p_category text,p_notice_kind text) returns boolean language sql stable security definer set search_path='' as $$select case when p_kind='shopping' then public.cb_shopping_notice_visible(auth.uid(),p_project,p_source,p_date,p_category,p_notice_kind) else public.cb_planning_notice_visible_before_shopping(p_project,p_kind,p_source,p_date,p_category,p_notice_kind) end$$;
drop policy if exists planning_inbox_own on public.cb_planning_notifications;
create policy planning_inbox_own on public.cb_planning_notifications for select to authenticated using(user_id=auth.uid() and public.cb_planning_notice_visible(project_id,source_kind,source_id,source_date,category,kind));
create or replace function public.cb_shopping_notice_revision() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_OP='INSERT' then new.notice_revision=1;
 elsif (new.data,new.buyer_id,new.status,new.progress_note) is distinct from (old.data,old.buyer_id,old.status,old.progress_note) then new.notice_revision=old.notice_revision+1;
 else new.notice_revision=old.notice_revision;end if;return new;
end;$$;
drop trigger if exists cb_shopping_notice_revision on public.cb_shopping_items;
create trigger cb_shopping_notice_revision before insert or update on public.cb_shopping_items for each row execute function public.cb_shopping_notice_revision();
create or replace function public.cb_shopping_change_notice() returns trigger language plpgsql security definer set search_path='' as $$
declare pid uuid;r record;label text;
begin
 if TG_OP='UPDATE' and new.notice_revision=old.notice_revision then return new;end if;
 label=case new.status when 'Purchased' then 'A shopping purchase was recorded' when 'Shipped' then 'A shopping delivery update is ready' when 'Delivered' then 'A shopping item was delivered' when 'Return requested' then 'A shopping return needs attention' when 'Returned' then 'A shopping return was recorded' when 'Refunded' then 'A shopping refund update was recorded' when 'Cancelled' then 'A shopping item was cancelled' else 'A shopping responsibility was updated' end;
 select project_id into pid from public.cb_shopping_lists where id=new.list_id;
 for r in select u.id from (select owner_id as id from public.cb_projects where id=pid union select user_id from public.cb_members where project_id=pid) u where u.id is distinct from auth.uid() and public.cb_shopping_notice_access(u.id,pid,new.id) loop
 perform public.cb_queue_planning_notice(r.id,pid,'assignments','shopping_updated:'||new.notice_revision,'shopping',new.id,null,label,'Open team shopping to review the latest item and responsibility.','shopping-update:'||new.id||':'||new.notice_revision);
 end loop;return new;
end;$$;
drop trigger if exists cb_shopping_change_notices on public.cb_shopping_items;
create trigger cb_shopping_change_notices after insert or update on public.cb_shopping_items for each row execute function public.cb_shopping_change_notice();
create or replace function public.cb_generate_shopping_reminders(p_user uuid default null) returns integer language plpgsql security definer set search_path='' as $$
declare r record;notice_kind text;label text;n integer:=0;
begin
 for r in select i.id,l.project_id,d.*,u.id as recipient,public.cb_decision_local_day(u.id) as today from public.cb_shopping_items i join public.cb_shopping_lists l on l.id=i.list_id cross join lateral public.cb_shopping_deadline_rows(i.id) d join lateral (select owner_id as id from public.cb_projects where id=l.project_id union select user_id from public.cb_members where project_id=l.project_id) u on public.cb_shopping_notice_access(u.id,l.project_id,i.id) where (p_user is null or u.id=p_user) and d.due<=public.cb_decision_local_day(u.id)+3 loop
 notice_kind='shopping_'||r.kind||case when r.due<r.today then '_overdue' when r.due=r.today then '_today' else '_soon' end;
 label=case r.kind when 'purchase' then 'Shopping purchase deadline' when 'delivery' then 'Expected shopping delivery' else 'Shopping return window' end||case when r.due<r.today then ' needs review' when r.due=r.today then ' is today' else ' is coming up' end;
 perform public.cb_queue_planning_notice(r.recipient,r.project_id,'deadlines',notice_kind,'shopping',r.id,r.due,label,'Review your recorded date and current progress in team shopping.','shopping-deadline:'||r.id||':'||r.kind||':'||r.due||':'||notice_kind);n=n+1;
 end loop;return n;
end;$$;
create or replace function public.cb_generate_planning_reminders(p_user uuid default null) returns integer language plpgsql security definer set search_path='' as $$begin return public.cb_generate_planning_reminders_before_shopping(p_user)+public.cb_generate_shopping_reminders(p_user);end;$$;
do $digest$
declare body text;
begin
 body=pg_get_functiondef('public.cb_planning_digest_items(uuid,timestamptz,timestamptz)'::regprocedure);
 if strpos(body,'public.cb_shopping_notice_visible')=0 then
 if strpos(body,'case when n.source_kind=''vendor_work'' then')=0 then raise exception 'Apply vendor-notifications.sql before shopping-notifications.sql';end if;
 body=replace(body,'case when n.source_kind=''vendor_work'' then','case when n.source_kind=''shopping'' then public.cb_shopping_notice_visible(p_user,n.project_id,n.source_id,n.source_date,n.category,n.kind) when n.source_kind=''vendor_work'' then');execute body;
 end if;
end;$digest$;
revoke all on function public.cb_shopping_notice_access(uuid,uuid,uuid),public.cb_shopping_deadline_rows(uuid),public.cb_shopping_notice_visible(uuid,uuid,uuid,date,text,text),public.cb_shopping_notice_revision(),public.cb_shopping_change_notice(),public.cb_generate_shopping_reminders(uuid),public.cb_generate_planning_reminders(uuid),public.cb_planning_can_view(uuid,uuid,text,uuid),public.cb_planning_can_view_before_shopping(uuid,uuid,text,uuid),public.cb_planning_notice_visible_before_shopping(uuid,text,uuid,date,text,text),public.cb_generate_planning_reminders_before_shopping(uuid),public.cb_planning_digest_items(uuid,timestamptz,timestamptz) from public,anon,authenticated;
revoke all on function public.cb_shopping_notice_target(uuid) from public,anon,authenticated;
grant execute on function public.cb_shopping_notice_target(uuid) to authenticated;
revoke all on function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) from public,anon;
grant execute on function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) to authenticated;
do $refresh$ declare signature text;body text;begin foreach signature in array array['public.cb_queue_planning_notice(uuid,uuid,text,text,text,uuid,date,text,text,text)','public.cb_planning_inbox()','public.cb_read_planning_notifications(uuid,boolean)','public.cb_process_planning_email()'] loop if to_regprocedure(signature) is not null then body=pg_get_functiondef(to_regprocedure(signature));execute body;end if;end loop;end;$refresh$;
notify pgrst,'reload schema';
commit;
