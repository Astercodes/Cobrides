-- Chat inbox, personal delivery controls and private realtime invalidation signals.
begin;
alter table public.cb_chat_participants add column if not exists muted boolean not null default false;
alter table public.cb_chat_participants add column if not exists email_unread boolean not null default false;
create table if not exists public.cb_chat_signals(user_id uuid primary key references auth.users on delete cascade,revision bigint not null default 1,updated_at timestamptz not null default now());
alter table public.cb_chat_signals enable row level security;
revoke all on public.cb_chat_signals from public,anon,authenticated;
grant select on public.cb_chat_signals to authenticated;
drop policy if exists chat_signals_own on public.cb_chat_signals;
create policy chat_signals_own on public.cb_chat_signals for select to authenticated using(user_id=auth.uid());
alter table public.cb_planning_notifications drop constraint if exists cb_planning_notifications_category_check;
alter table public.cb_planning_notifications add constraint cb_planning_notifications_category_check check(category in ('assignments','approvals','deadlines','schedule','messages'));
alter table public.cb_planning_notifications drop constraint if exists cb_planning_notifications_source_kind_check;
alter table public.cb_planning_notifications add constraint cb_planning_notifications_source_kind_check check(source_kind in ('project','event','task','decision','chat'));
alter table public.cb_planning_preferences alter column categories set default array['assignments','approvals','deadlines','schedule','messages'];
-- A new category is enabled in-app; chat email requires a separate explicit opt-in.
alter table public.cb_planning_preferences add column if not exists chat_category_initialized boolean not null default false;
update public.cb_planning_preferences set categories=case when 'messages'=any(categories) then categories else array_append(categories,'messages') end,chat_category_initialized=true where not chat_category_initialized;
alter table public.cb_planning_preferences alter column chat_category_initialized set default true;
create or replace function public.cb_chat_user_access(p_user uuid,p_thread uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.cb_chat_threads t join public.cb_chat_participants x on x.thread_id=t.id and x.user_id=p_user join public.cb_projects p on p.id=t.project_id where t.id=p_thread and p.archived_at is null and public.cb_collab_user_access(p_user,t.project_id,'read'));
$$;
create or replace function public.cb_chat_notice_visible(p_user uuid,p_thread uuid,p_kind text) returns boolean language sql stable security definer set search_path='' as $$
 select public.cb_chat_user_access(p_user,p_thread) and exists(select 1 from public.cb_chat_participants x where x.thread_id=p_thread and x.user_id=p_user and not x.muted and exists(select 1 from public.cb_chat_messages m where m.thread_id=x.thread_id and m.author_id<>p_user and m.id>x.last_read_id and 'chat_message:'||m.id::text=p_kind)) and not exists(select 1 from public.cb_planning_preferences where user_id=p_user and not 'messages'=any(categories));
$$;
do $migration$ begin
 if to_regprocedure('public.cb_planning_can_view_before_chat(uuid,uuid,text,uuid)') is null then alter function public.cb_planning_can_view(uuid,uuid,text,uuid) rename to cb_planning_can_view_before_chat;end if;
 if to_regprocedure('public.cb_planning_notice_visible_before_chat(uuid,text,uuid,date,text,text)') is null then alter function public.cb_planning_notice_visible(uuid,text,uuid,date,text,text) rename to cb_planning_notice_visible_before_chat;end if;
end; $migration$;
create or replace function public.cb_planning_can_view(p_user uuid,p_project uuid,p_kind text,p_source uuid) returns boolean language sql stable security definer set search_path='' as $$
 select case when p_kind='chat' then public.cb_chat_user_access(p_user,p_source) and exists(select 1 from public.cb_chat_threads where id=p_source and project_id=p_project) else public.cb_planning_can_view_before_chat(p_user,p_project,p_kind,p_source) end;
$$;
create or replace function public.cb_planning_notice_visible(p_project uuid,p_kind text,p_source uuid,p_date date,p_category text,p_notice_kind text) returns boolean language sql stable security definer set search_path='' as $$
 select case when p_kind='chat' then public.cb_planning_can_view(auth.uid(),p_project,p_kind,p_source) and public.cb_chat_notice_visible(auth.uid(),p_source,p_notice_kind) else public.cb_planning_notice_visible_before_chat(p_project,p_kind,p_source,p_date,p_category,p_notice_kind) end;
$$;
drop policy if exists planning_inbox_own on public.cb_planning_notifications;
create policy planning_inbox_own on public.cb_planning_notifications for select to authenticated using(user_id=auth.uid() and public.cb_planning_notice_visible(project_id,source_kind,source_id,source_date,category,kind));
create or replace function public.cb_chat_signal_user(p_user uuid) returns void language sql security definer set search_path='' as $$
 insert into public.cb_chat_signals(user_id) values(p_user) on conflict(user_id) do update set revision=public.cb_chat_signals.revision+1,updated_at=now();
$$;
create or replace function public.cb_chat_message_notice() returns trigger language plpgsql security definer set search_path='' as $$
declare r record;pid uuid;label text;
begin
 select project_id,title into pid,label from public.cb_chat_threads where id=new.thread_id;
 for r in select x.user_id,x.muted from public.cb_chat_participants x where x.thread_id=new.thread_id order by x.user_id loop
  perform public.cb_chat_signal_user(r.user_id);
  if r.user_id=new.author_id or r.muted or not public.cb_chat_user_access(r.user_id,new.thread_id) or exists(select 1 from public.cb_planning_preferences where user_id=r.user_id and not 'messages'=any(categories)) then continue;end if;
  insert into public.cb_planning_notifications(user_id,project_id,category,kind,source_kind,source_id,title,body,dedupe_key)
  values(r.user_id,pid,'messages','chat_message:'||new.id,'chat',new.thread_id,'New messages in '||left(label,120),'Your wedding conversation has unread messages.','chat:'||new.thread_id)
  on conflict(user_id,dedupe_key) do update set kind=excluded.kind,title=excluded.title,body=excluded.body,created_at=now(),read_at=null;
 end loop;return new;
end; $$;
drop trigger if exists cb_chat_message_notifications on public.cb_chat_messages;
create trigger cb_chat_message_notifications after insert on public.cb_chat_messages for each row execute function public.cb_chat_message_notice();
create or replace function public.cb_chat_participant_signal() returns trigger language plpgsql security definer set search_path='' as $$
begin perform public.cb_chat_signal_user(case when TG_OP='DELETE' then old.user_id else new.user_id end);return null;end; $$;
drop trigger if exists cb_chat_participant_updates on public.cb_chat_participants;
create trigger cb_chat_participant_updates after insert or update or delete on public.cb_chat_participants for each row execute function public.cb_chat_participant_signal();
create or replace function public.cb_chat_poll_signal() returns trigger language plpgsql security definer set search_path='' as $$
declare tid uuid;r record;
begin
 if TG_TABLE_NAME='cb_chat_pins' then tid=case when TG_OP='DELETE' then old.thread_id else new.thread_id end;
 elsif TG_TABLE_NAME='cb_chat_polls' then select thread_id into tid from public.cb_chat_messages where id=new.message_id;
 else select m.thread_id into tid from public.cb_chat_polls p join public.cb_chat_messages m on m.id=p.message_id where p.id=new.poll_id;end if;
 for r in select user_id from public.cb_chat_participants where thread_id=tid order by user_id loop perform public.cb_chat_signal_user(r.user_id);end loop;return null;
end; $$;
drop trigger if exists cb_chat_poll_updates on public.cb_chat_polls;
create trigger cb_chat_poll_updates after insert or update on public.cb_chat_polls for each row execute function public.cb_chat_poll_signal();
drop trigger if exists cb_chat_vote_updates on public.cb_chat_poll_votes;
create trigger cb_chat_vote_updates after insert or update on public.cb_chat_poll_votes for each row execute function public.cb_chat_poll_signal();
drop trigger if exists cb_chat_pin_updates on public.cb_chat_pins;
create trigger cb_chat_pin_updates after insert or delete on public.cb_chat_pins for each row execute function public.cb_chat_poll_signal();
create or replace function public.cb_chat_delivery(p_thread uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin if not public.cb_chat_access(p_thread) then raise exception 'Conversation access denied' using errcode='42501';end if;return (select jsonb_build_object('muted',muted,'email_unread',email_unread) from public.cb_chat_participants where thread_id=p_thread and user_id=auth.uid());end; $$;
create or replace function public.cb_set_chat_delivery(p_thread uuid,p_muted boolean,p_email boolean) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform public.cb_chat_lock(p_thread);
 if p_muted is null or p_email is null then raise exception 'Choose your delivery preferences';end if;
 update public.cb_chat_participants set muted=p_muted,email_unread=p_email where thread_id=p_thread and user_id=auth.uid();
 return public.cb_chat_delivery(p_thread);
end; $$;
create or replace function public.cb_set_planning_preferences(p_categories text[],p_time_zone text) returns public.cb_planning_preferences language plpgsql security definer set search_path='' as $$
declare result public.cb_planning_preferences;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 if p_categories is null or not p_categories <@ array['assignments','approvals','deadlines','schedule','messages']::text[] then raise exception 'Choose valid notification categories';end if;
 if not exists(select 1 from pg_timezone_names where name=p_time_zone) then raise exception 'Choose a valid time zone';end if;
 insert into public.cb_planning_preferences(user_id,categories,time_zone) values(auth.uid(),p_categories,p_time_zone) on conflict(user_id) do update set categories=excluded.categories,time_zone=excluded.time_zone,updated_at=now() returning * into result;return result;
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
 'preferences',coalesce((select to_jsonb(pref) from public.cb_planning_preferences pref where user_id=auth.uid()),jsonb_build_object('categories',array['assignments','approvals','deadlines','schedule','messages'],'time_zone','UTC')),
 'scheduled',exists(select 1 from pg_extension where extname='pg_cron')
 ) into result;
 return result;
end; $$;

-- Existing accounts keep their daily email consent. Messages additionally require per-chat consent.
create or replace function public.cb_planning_digest_items(p_user uuid,p_since timestamptz,p_until timestamptz)
returns table(quantity bigint,latest timestamptz) language sql stable security definer set search_path='' as $$
 select count(*),max(n.created_at) from public.cb_planning_notifications n
 join public.cb_planning_preferences pref on pref.user_id=n.user_id and pref.email_opt_in and n.category=any(pref.categories)
 join auth.users u on u.id=n.user_id and u.email_confirmed_at is not null
 where n.user_id=p_user and n.read_at is null and n.created_at>p_since and n.created_at<=p_until
 and case when n.source_kind='chat' then public.cb_chat_notice_visible(p_user,n.source_id,n.kind) and exists(select 1 from public.cb_chat_participants x where x.thread_id=n.source_id and x.user_id=p_user and x.email_unread) when n.source_kind='decision' then public.cb_decision_notice_visible(p_user,n.project_id,n.source_id,n.source_date,n.category,n.kind)
 else public.cb_planning_can_view(p_user,n.project_id,n.source_kind,n.source_id)
 and (n.category<>'deadlines' or (n.source_kind='task' and exists(select 1 from public.cb_tasks t where t.id=n.source_id and not t.done and t.due_date=n.source_date)) or (n.source_kind='event' and exists(select 1 from public.cb_project_events e where e.id=n.source_id and e.details->>'date'=n.source_date::text and coalesce(e.details->>'status','') not in ('Completed','Complete'))))
 and (n.kind<>'approval_requested' or exists(select 1 from public.cb_tasks t where t.id=n.source_id and not t.done and t.approval_required and t.approved_by is null and lower(t.approver_email)=lower(u.email)))
 and (n.kind<>'assigned' or exists(select 1 from public.cb_tasks t where t.id=n.source_id and lower(t.assignee_email)=lower(u.email))) end;
$$;
revoke all on function public.cb_chat_user_access(uuid,uuid),public.cb_chat_notice_visible(uuid,uuid,text),public.cb_chat_signal_user(uuid),public.cb_chat_message_notice(),public.cb_chat_participant_signal(),public.cb_chat_poll_signal(),public.cb_planning_can_view_before_chat(uuid,uuid,text,uuid),public.cb_planning_notice_visible_before_chat(uuid,text,uuid,date,text,text),public.cb_planning_can_view(uuid,uuid,text,uuid),public.cb_planning_digest_items(uuid,timestamptz,timestamptz),public.cb_chat_delivery(uuid),public.cb_set_chat_delivery(uuid,boolean,boolean) from public,anon,authenticated;
grant execute on function public.cb_chat_delivery(uuid),public.cb_set_chat_delivery(uuid,boolean,boolean) to authenticated;
do $publication$ begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') and not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='cb_chat_signals') then alter publication supabase_realtime add table public.cb_chat_signals;end if;
end; $publication$;
notify pgrst,'reload schema';
commit;
