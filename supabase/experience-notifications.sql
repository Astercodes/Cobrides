-- Shared service assignments and operational issue updates in the existing inbox.
begin;
do $constraint$ declare d text;begin
 select pg_get_constraintdef(oid) into d from pg_constraint where conrelid='public.cb_planning_notifications'::regclass and conname='cb_planning_notifications_source_kind_check';
 if d is null then raise exception 'Install planning notifications first';end if;
 if strpos(d,'''experience''')=0 then
  alter table public.cb_planning_notifications drop constraint cb_planning_notifications_source_kind_check;
  execute 'alter table public.cb_planning_notifications add constraint cb_planning_notifications_source_kind_check CHECK (('||substring(d from 8 for length(d)-8)||') OR source_kind = ''experience'')';
 end if;
end;$constraint$;
create or replace function public.cb_experience_notice_access(p_user uuid,p_project uuid,p_source uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_project_events e join public.cb_projects p on p.id=e.project_id where e.project_id=p_project and p.archived_at is null and public.cb_experience_member(e.id,p_user) and
 (exists(select 1 from public.cb_experience_items i where i.id=p_source and i.event_id=e.id and (i.assignee=p_user or public.cb_collab_user_access(p_user,e.project_id,'write')))
 or exists(select 1 from public.cb_experience_issues i where i.id=p_source and i.event_id=e.id and (i.assignee=p_user or public.cb_collab_user_access(p_user,e.project_id,'write')))));
$$;
create or replace function public.cb_experience_notice_visible(p_user uuid,p_project uuid,p_source uuid,p_category text,p_kind text) returns boolean language sql stable security definer set search_path='' as $$
 select public.cb_experience_notice_access(p_user,p_project,p_source) and p_category='assignments'
 and not exists(select 1 from public.cb_planning_preferences where user_id=p_user and not p_category=any(categories))
 and (exists(select 1 from public.cb_experience_items i where i.id=p_source and p_kind='experience_service:'||i.revision)
 or exists(select 1 from public.cb_experience_issues i where i.id=p_source and p_kind='experience_issue:'||i.revision));
$$;
do $wrap$ begin
 if to_regprocedure('public.cb_planning_can_view_before_experience(uuid,uuid,text,uuid)') is null then alter function public.cb_planning_can_view(uuid,uuid,text,uuid) rename to cb_planning_can_view_before_experience;end if;
 if to_regprocedure('public.cb_planning_notice_visible_before_experience(uuid,text,uuid,date,text,text)') is null then alter function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) rename to cb_planning_notice_visible_before_experience;end if;
end;$wrap$;
create or replace function public.cb_planning_can_view(p_user uuid,p_project uuid,p_kind text,p_source uuid) returns boolean language sql stable security definer set search_path='' as $$select case when p_kind='experience' then public.cb_experience_notice_access(p_user,p_project,p_source) else public.cb_planning_can_view_before_experience(p_user,p_project,p_kind,p_source) end$$;
create or replace function public.cb_planning_notice_visible(p_project uuid,p_kind text,p_source uuid,p_date date,p_category text,p_notice_kind text) returns boolean language sql stable security definer set search_path='' as $$select case when p_kind='experience' then public.cb_experience_notice_visible(auth.uid(),p_project,p_source,p_category,p_notice_kind) else public.cb_planning_notice_visible_before_experience(p_project,p_kind,p_source,p_date,p_category,p_notice_kind) end$$;
drop policy if exists planning_inbox_own on public.cb_planning_notifications;
create policy planning_inbox_own on public.cb_planning_notifications for select to authenticated using(user_id=auth.uid() and public.cb_planning_notice_visible(project_id,source_kind,source_id,source_date,category,kind));
create or replace function public.cb_experience_change_notice() returns trigger language plpgsql security definer set search_path='' as $$
declare pid uuid;r record;token text;label text;
begin
 if TG_TABLE_NAME='cb_experience_items' then
  token='experience_service:'||new.revision;label='A celebration service plan was updated';
 else
  token='experience_issue:'||new.revision;label=case when new.data->>'status'='Resolved' then 'A celebration issue was resolved' when new.blocks then 'A blocking celebration issue needs attention' else 'A celebration issue needs review' end;
 end if;
 select project_id into pid from public.cb_project_events where id=new.event_id;
 for r in select u.id from (select owner_id id from public.cb_projects where id=pid union select user_id from public.cb_members where project_id=pid) u where u.id is distinct from auth.uid() and public.cb_experience_notice_access(u.id,pid,new.id) loop
  perform public.cb_queue_planning_notice(r.id,pid,'assignments',token,'experience',new.id,null,label,'Open the celebration plan to review the current details.','experience:'||new.id||':'||new.revision);
 end loop;
 return new;
end;$$;
drop trigger if exists cb_experience_service_notice on public.cb_experience_items;
create trigger cb_experience_service_notice after insert or update on public.cb_experience_items for each row execute function public.cb_experience_change_notice();
drop trigger if exists cb_experience_issue_notice on public.cb_experience_issues;
create trigger cb_experience_issue_notice after insert or update on public.cb_experience_issues for each row execute function public.cb_experience_change_notice();
create or replace function public.cb_experience_notice_target(p_notice uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare n public.cb_planning_notifications;eid uuid;mode text;
begin
 select * into n from public.cb_planning_notifications where id=p_notice and user_id=auth.uid() and source_kind='experience';
 if n.id is null or not coalesce(public.cb_experience_notice_visible(auth.uid(),n.project_id,n.source_id,n.category,n.kind),false) then raise exception 'This celebration update is no longer available' using errcode='42501';end if;
 select event_id,'service' into eid,mode from public.cb_experience_items where id=n.source_id;
 if eid is null then select event_id,'issue' into eid,mode from public.cb_experience_issues where id=n.source_id;end if;
 return jsonb_build_object('project',n.project_id,'event',eid,'mode',mode,'source',n.source_id);
end;$$;
-- Keep existing digest rules; add an explicit current-recipient/current-revision filter.
do $digest$ declare body text;begin
 if to_regprocedure('public.cb_planning_digest_items(uuid,timestamptz,timestamptz)') is not null then
  body=pg_get_functiondef('public.cb_planning_digest_items(uuid,timestamptz,timestamptz)'::regprocedure);
  if strpos(body,'public.cb_experience_notice_visible')=0 then
   if strpos(body,'n.user_id=p_user')=0 then raise exception 'Digest visibility needs review';end if;
   body=replace(body,'n.user_id=p_user','n.user_id=p_user and (n.source_kind<>''experience'' or public.cb_experience_notice_visible(p_user,n.project_id,n.source_id,n.category,n.kind))');execute body;
  end if;
 end if;
end;$digest$;
revoke all on function public.cb_experience_notice_access(uuid,uuid,uuid),public.cb_experience_notice_visible(uuid,uuid,uuid,text,text),public.cb_experience_change_notice(),public.cb_experience_notice_target(uuid),public.cb_planning_can_view(uuid,uuid,text,uuid),public.cb_planning_can_view_before_experience(uuid,uuid,text,uuid),public.cb_planning_notice_visible_before_experience(uuid,text,uuid,date,text,text) from public,anon,authenticated;
grant execute on function public.cb_experience_notice_target(uuid) to authenticated;
revoke all on function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) from public,anon;
grant execute on function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) to authenticated;
do $refresh$ declare signature text;body text;begin foreach signature in array array['public.cb_queue_planning_notice(uuid,uuid,text,text,text,uuid,date,text,text,text)','public.cb_planning_inbox()','public.cb_read_planning_notifications(uuid,boolean)','public.cb_process_planning_email()'] loop if to_regprocedure(signature) is not null then body=pg_get_functiondef(to_regprocedure(signature));execute body;end if;end loop;end;$refresh$;
notify pgrst,'reload schema';
commit;
