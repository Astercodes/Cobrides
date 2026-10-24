-- Link existing shared records without copying their content or widening access.
begin;
create table if not exists public.cb_chat_record_links(
 id uuid primary key default gen_random_uuid(),message_id bigint not null references public.cb_chat_messages on delete cascade,
 kind text not null check(kind in ('task','decision','event')),target_id uuid not null,created_by uuid not null references auth.users,created_at timestamptz not null default now(),unique(message_id,kind,target_id)
);
create index if not exists cb_chat_record_target on public.cb_chat_record_links(kind,target_id);
alter table public.cb_chat_record_links enable row level security;
revoke all on public.cb_chat_record_links from public,anon,authenticated;
create or replace function public.cb_chat_record_project(p_kind text,p_target uuid) returns uuid language sql stable security definer set search_path='' as $$
 select case when p_kind='task' and public.cb_task_visible(p_target) then (select project_id from public.cb_tasks where id=p_target) when p_kind='decision' and public.cb_decision_access(p_target) then (select project_id from public.cb_decisions where id=p_target) when p_kind='event' and public.cb_project_event_access(p_target) then (select project_id from public.cb_project_events where id=p_target) else null end;
$$;
create or replace function public.cb_chat_record_context(p_thread uuid,p_message bigint,p_kind text,p_query text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare pid uuid;result jsonb;
begin
 select project_id into pid from public.cb_chat_threads where id=p_thread;
 if not public.cb_chat_access(p_thread) or not public.cb_project_access(pid,'write') then raise exception 'Record linking access denied' using errcode='42501';end if;
 if not exists(select 1 from public.cb_chat_messages where id=p_message and thread_id=p_thread) then raise exception 'Message is not in this conversation';end if;
 if p_kind is null or p_kind not in ('task','decision','event') or length(coalesce(p_query,''))>100 then raise exception 'Choose a supported record and search using up to 100 characters';end if;
 select coalesce(jsonb_agg(row order by title,id),'[]') into result from (
 select id,title,jsonb_build_object('id',id,'title',title,'detail',coalesce(due_date::text,'No deadline')) row from public.cb_tasks where p_kind='task' and project_id=pid and public.cb_task_visible(id) and strpos(lower(title),lower(coalesce(p_query,'')))>0
 union all select id,title,jsonb_build_object('id',id,'title',title,'detail',coalesce(due_date::text,'No deadline')) from public.cb_decisions where p_kind='decision' and project_id=pid and public.cb_decision_access(id) and strpos(lower(title),lower(coalesce(p_query,'')))>0
 union all select id,title,jsonb_build_object('id',id,'title',title,'detail',coalesce(details->>'date','Date to be decided')) from public.cb_project_events where p_kind='event' and project_id=pid and public.cb_project_event_access(id) and strpos(lower(title),lower(coalesce(p_query,'')))>0
 order by title,id limit 50) records;
 return result;
end; $$;
create or replace function public.cb_link_chat_record(p_thread uuid,p_message bigint,p_kind text,p_target uuid,p_link boolean) returns void language plpgsql security definer set search_path='' as $$
declare pid uuid;r record;
begin
 pid=public.cb_chat_lock(p_thread);
 if not public.cb_project_access(pid,'write') or exists(select 1 from public.cb_projects where id=pid and archived_at is not null) then raise exception 'Record linking access denied' using errcode='42501';end if;
 if not exists(select 1 from public.cb_chat_messages where id=p_message and thread_id=p_thread) then raise exception 'Message is not in this conversation';end if;
 if p_link is null or public.cb_chat_record_project(p_kind,p_target) is distinct from pid then raise exception 'Choose a permitted record in this wedding' using errcode='42501';end if;
 if p_link then
  if (select count(*) from public.cb_chat_record_links where message_id=p_message)>=12 and not exists(select 1 from public.cb_chat_record_links where message_id=p_message and kind=p_kind and target_id=p_target) then raise exception 'Keep up to twelve linked records per message';end if;
  insert into public.cb_chat_record_links(message_id,kind,target_id,created_by) values(p_message,p_kind,p_target,auth.uid()) on conflict(message_id,kind,target_id) do nothing;
 else delete from public.cb_chat_record_links where message_id=p_message and kind=p_kind and target_id=p_target;end if;
 for r in select user_id from public.cb_chat_participants where thread_id=p_thread order by user_id loop perform public.cb_chat_signal_user(r.user_id);end loop;
end; $$;
create or replace function public.cb_chat_record_sources(p_kind text,p_target uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select case when public.cb_chat_record_project(p_kind,p_target) is null then '[]'::jsonb else (select coalesce(jsonb_agg(jsonb_build_object('thread',t.id,'project',t.project_id,'message',m.id::text) order by l.created_at desc),'[]') from public.cb_chat_record_links l join public.cb_chat_messages m on m.id=l.message_id join public.cb_chat_threads t on t.id=m.thread_id where l.kind=p_kind and l.target_id=p_target and public.cb_chat_access(t.id)) end;
$$;
create or replace function public.cb_chat_record_detail(p_kind text,p_target uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare pid uuid;sources jsonb;record jsonb;
begin
 pid=public.cb_chat_record_project(p_kind,p_target);if pid is null then raise exception 'Record access denied' using errcode='42501';end if;
 if p_kind='task' then record=public.cb_chat_action_task(p_target);
 elsif p_kind='decision' then record=public.cb_decision_detail(p_target,null);
 else select jsonb_build_object('id',id,'title',title,'date',details->>'date','time',details->>'time','venue',details->>'venue','status',details->>'status') into record from public.cb_project_events where id=p_target;end if;
 select coalesce(jsonb_agg(jsonb_build_object('thread',t.id,'project',pid,'message',m.id::text) order by l.created_at desc),'[]') into sources from public.cb_chat_record_links l join public.cb_chat_messages m on m.id=l.message_id join public.cb_chat_threads t on t.id=m.thread_id where l.kind=p_kind and l.target_id=p_target and public.cb_chat_access(t.id);
 return jsonb_build_object('kind',p_kind,'project',pid,'record',record,'conversations',public.cb_chat_record_sources(p_kind,p_target));
end; $$;
do $migration$ begin
 if to_regprocedure('public.cb_chat_history_before_record_links(uuid,bigint)') is null then alter function public.cb_chat_history(uuid,bigint) rename to cb_chat_history_before_record_links;end if;
end; $migration$;
create or replace function public.cb_chat_history(p_thread uuid,p_before bigint default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;rows jsonb;pid uuid;
begin
 result=public.cb_chat_history_before_record_links(p_thread,p_before);select project_id into pid from public.cb_chat_threads where id=p_thread;
 select coalesce(jsonb_agg(m||jsonb_build_object('record_links',(select coalesce(jsonb_agg(jsonb_build_object('kind',l.kind,'id',l.target_id,'project',pid,'title',case l.kind when 'task' then (select title from public.cb_tasks where id=l.target_id) when 'decision' then (select title from public.cb_decisions where id=l.target_id) else (select title from public.cb_project_events where id=l.target_id) end)),'[]') from public.cb_chat_record_links l where l.message_id=(m->>'id')::bigint and public.cb_chat_record_project(l.kind,l.target_id)=pid)) order by (m->>'id')::bigint),'[]') into rows from jsonb_array_elements(result->'messages') m;
 return jsonb_set(result,'{messages}',rows);
end; $$;
revoke all on function public.cb_chat_record_project(text,uuid),public.cb_chat_record_context(uuid,bigint,text,text),public.cb_link_chat_record(uuid,bigint,text,uuid,boolean),public.cb_chat_record_detail(text,uuid),public.cb_chat_history_before_record_links(uuid,bigint),public.cb_chat_history(uuid,bigint) from public,anon,authenticated;
grant execute on function public.cb_chat_record_context(uuid,bigint,text,text),public.cb_link_chat_record(uuid,bigint,text,uuid,boolean),public.cb_chat_record_detail(text,uuid),public.cb_chat_history(uuid,bigint) to authenticated;
do $sources$ begin
 if to_regprocedure('public.cb_decision_detail_before_record_links(uuid,bigint)') is null then alter function public.cb_decision_detail(uuid,bigint) rename to cb_decision_detail_before_record_links;end if;
 if to_regprocedure('public.cb_chat_action_sources_before_record_links(uuid)') is null then alter function public.cb_chat_action_sources(uuid) rename to cb_chat_action_sources_before_record_links;end if;
end; $sources$;
create or replace function public.cb_decision_detail(p_id uuid,p_before bigint default null) returns jsonb language plpgsql security definer set search_path='' as $$begin return public.cb_decision_detail_before_record_links(p_id,p_before)||jsonb_build_object('chat_conversations',public.cb_chat_record_sources('decision',p_id));end; $$;
create or replace function public.cb_chat_action_sources(p_project uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare original jsonb;extra jsonb;
begin original=public.cb_chat_action_sources_before_record_links(p_project);
 select coalesce(jsonb_agg(jsonb_build_object('kind',l.kind,'target',l.target_id,'project',p_project,'thread',t.id,'message',m.id::text)),'[]') into extra from public.cb_chat_record_links l join public.cb_chat_messages m on m.id=l.message_id join public.cb_chat_threads t on t.id=m.thread_id where t.project_id=p_project and public.cb_chat_access(t.id) and public.cb_chat_record_project(l.kind,l.target_id)=p_project;return original||extra;end; $$;
create or replace function public.cb_chat_record_deleted() returns trigger language plpgsql security definer set search_path='' as $$begin delete from public.cb_chat_record_links where target_id=old.id and kind=case TG_TABLE_NAME when 'cb_tasks' then 'task' when 'cb_decisions' then 'decision' else 'event' end;return old;end; $$;
drop trigger if exists cb_chat_task_deleted on public.cb_tasks;
create trigger cb_chat_task_deleted after delete on public.cb_tasks for each row execute function public.cb_chat_record_deleted();
drop trigger if exists cb_chat_decision_deleted on public.cb_decisions;
create trigger cb_chat_decision_deleted after delete on public.cb_decisions for each row execute function public.cb_chat_record_deleted();
drop trigger if exists cb_chat_event_deleted on public.cb_project_events;
create trigger cb_chat_event_deleted after delete on public.cb_project_events for each row execute function public.cb_chat_record_deleted();
revoke all on function public.cb_chat_record_sources(text,uuid),public.cb_decision_detail_before_record_links(uuid,bigint),public.cb_chat_action_sources_before_record_links(uuid),public.cb_chat_record_deleted() from public,anon,authenticated;
revoke all on function public.cb_decision_detail(uuid,bigint),public.cb_chat_action_sources(uuid) from public,anon,authenticated;
grant execute on function public.cb_decision_detail(uuid,bigint),public.cb_chat_action_sources(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
