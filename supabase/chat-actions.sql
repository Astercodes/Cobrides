-- Convert messages into reviewed shared work without publishing private conversations.
begin;
create table if not exists public.cb_chat_actions(
 id uuid primary key default gen_random_uuid(),message_id bigint not null references public.cb_chat_messages on delete cascade,
 kind text not null check(kind in ('task','decision')),task_id uuid references public.cb_tasks on delete cascade,decision_id uuid references public.cb_decisions on delete cascade,
 created_by uuid not null references auth.users,client_id uuid not null,payload jsonb not null,created_at timestamptz not null default now(),
 unique(created_by,client_id),unique(message_id,kind),check((kind='task' and task_id is not null and decision_id is null) or (kind='decision' and decision_id is not null and task_id is null))
);
alter table public.cb_chat_actions enable row level security;
revoke all on public.cb_chat_actions from public,anon,authenticated;
create or replace function public.cb_chat_action_visible(p_kind text,p_target uuid) returns boolean language sql stable security definer set search_path='' as $$
 select case when p_kind='task' then public.cb_task_visible(p_target) when p_kind='decision' then public.cb_decision_access(p_target) else false end;
$$;
create or replace function public.cb_chat_action_source(p_kind text,p_target uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.cb_chat_action_visible(p_kind,p_target) then return null;end if;
 return (select jsonb_build_object('project',t.project_id,'thread',t.id,'message',m.id::text) from public.cb_chat_actions a join public.cb_chat_messages m on m.id=a.message_id join public.cb_chat_threads t on t.id=m.thread_id where a.kind=p_kind and coalesce(a.task_id,a.decision_id)=p_target and public.cb_chat_access(t.id));
end; $$;
create or replace function public.cb_chat_action_sources(p_project uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.cb_project_access(p_project,'read') then raise exception 'Wedding access denied' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('kind',a.kind,'target',coalesce(a.task_id,a.decision_id),'project',t.project_id,'thread',t.id,'message',m.id::text)),'[]') from public.cb_chat_actions a join public.cb_chat_messages m on m.id=a.message_id join public.cb_chat_threads t on t.id=m.thread_id where t.project_id=p_project and public.cb_chat_access(t.id) and public.cb_chat_action_visible(a.kind,coalesce(a.task_id,a.decision_id)));
end; $$;
create or replace function public.cb_chat_action_context(p_thread uuid,p_message bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare pid uuid;
begin
 select project_id into pid from public.cb_chat_threads where id=p_thread;
 if not public.cb_chat_access(p_thread) or not public.cb_project_access(pid,'write') or exists(select 1 from public.cb_projects where id=pid and archived_at is not null) then raise exception 'Action creation access denied' using errcode='42501';end if;
 if not exists(select 1 from public.cb_chat_messages where id=p_message and thread_id=p_thread) then raise exception 'Message is not in this conversation';end if;
 return jsonb_build_object('people',public.cb_decision_people(pid),'project',pid,'existing',(select coalesce(jsonb_agg(jsonb_build_object('kind',kind,'id',coalesce(task_id,decision_id))),'[]') from public.cb_chat_actions where message_id=p_message and public.cb_chat_action_visible(kind,coalesce(task_id,decision_id))));
end; $$;
create or replace function public.cb_create_chat_action(p_thread uuid,p_message bigint,p_kind text,p_client uuid,p_details jsonb,p_confirm boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare pid uuid;previous public.cb_chat_actions;task public.cb_tasks;decision jsonb;target uuid;recipient text;approvers uuid[];r record;
begin
 pid=public.cb_chat_lock(p_thread);
 if not public.cb_project_access(pid,'write') or exists(select 1 from public.cb_projects where id=pid and archived_at is not null) then raise exception 'Action creation access denied' using errcode='42501';end if;
 if not exists(select 1 from public.cb_chat_messages where id=p_message and thread_id=p_thread) then raise exception 'Message is not in this conversation';end if;
 if p_confirm is distinct from true then raise exception 'Review and confirm the details you are sharing';end if;
 if p_client is null or p_kind not in ('task','decision') or p_kind is null or jsonb_typeof(p_details) is distinct from 'object' or octet_length(p_details::text)>30000 then raise exception 'Choose a task or decision and valid details';end if;
 select * into previous from public.cb_chat_actions where created_by=auth.uid() and client_id=p_client;
 if found then
  if previous.message_id<>p_message or previous.kind<>p_kind or previous.payload is distinct from p_details then raise exception 'Action changed during retry. Review before saving.' using errcode='PT409';end if;
  return jsonb_build_object('kind',previous.kind,'id',coalesce(previous.task_id,previous.decision_id),'project',pid);
 end if;
 select * into previous from public.cb_chat_actions where message_id=p_message and kind=p_kind;
 if found then raise exception 'This message already has a linked action. Open it from the conversation.' using errcode='PT409';end if;
 if length(btrim(coalesce(p_details->>'title',''))) not between 1 and 200 then raise exception 'Give the action a name';end if;
 if p_kind='task' then
  if p_details-array['title','notes','assignee','due']::text[]<>'{}' then raise exception 'Use the supported task fields';end if;
  if not public.cb_collab_user_access((p_details->>'assignee')::uuid,pid,'read') then raise exception 'Choose an active accepted teammate';end if;
  select email into recipient from auth.users where id=(p_details->>'assignee')::uuid;
  select * into task from public.cb_save_shared_task(pid,'chat-action:'||auth.uid()||':'||p_client,0,p_details->>'title',recipient,nullif(p_details->>'due','')::date,'task',coalesce(p_details->>'notes',''));
  target=task.id;
 else
  if p_details-array['title','notes','options','approvers','currency','due']::text[]<>'{}' then raise exception 'Use the supported decision fields';end if;
  if jsonb_typeof(p_details->'approvers') is distinct from 'array' then raise exception 'Choose approvers';end if;
  select array_agg(value::uuid) into approvers from jsonb_array_elements_text(p_details->'approvers');
  decision=public.cb_save_decision(pid,null,p_client,0,p_details->>'title',coalesce(p_details->>'notes',''),p_details->'options',approvers,upper(coalesce(p_details->>'currency','USD')),nullif(p_details->>'due','')::date);target=(decision->>'id')::uuid;
 end if;
 insert into public.cb_chat_actions(message_id,kind,task_id,decision_id,created_by,client_id,payload) values(p_message,p_kind,case when p_kind='task' then target end,case when p_kind='decision' then target end,auth.uid(),p_client,p_details);
 for r in select user_id from public.cb_chat_participants where thread_id=p_thread order by user_id loop perform public.cb_chat_signal_user(r.user_id);end loop;
 return jsonb_build_object('kind',p_kind,'id',target,'project',pid);
end; $$;
do $migration$ begin
 if to_regprocedure('public.cb_chat_history_before_actions(uuid,bigint)') is null then alter function public.cb_chat_history(uuid,bigint) rename to cb_chat_history_before_actions;end if;
 if to_regprocedure('public.cb_decision_detail_before_actions(uuid,bigint)') is null then alter function public.cb_decision_detail(uuid,bigint) rename to cb_decision_detail_before_actions;end if;
end; $migration$;
create or replace function public.cb_chat_history(p_thread uuid,p_before bigint default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;rows jsonb;pid uuid;
begin
 result=public.cb_chat_history_before_actions(p_thread,p_before);select project_id into pid from public.cb_chat_threads where id=p_thread;
 select coalesce(jsonb_agg(m||jsonb_build_object('can_create_actions',public.cb_project_access(pid,'write') and not exists(select 1 from public.cb_projects where id=pid and archived_at is not null),'actions',(select coalesce(jsonb_agg(jsonb_build_object('kind',a.kind,'id',coalesce(a.task_id,a.decision_id),'project',pid)),'[]') from public.cb_chat_actions a where a.message_id=(m->>'id')::bigint and public.cb_chat_action_visible(a.kind,coalesce(a.task_id,a.decision_id)))) order by (m->>'id')::bigint),'[]') into rows from jsonb_array_elements(result->'messages') m;
 return jsonb_set(result,'{messages}',rows);
end; $$;
create or replace function public.cb_decision_detail(p_id uuid,p_before bigint default null) returns jsonb language plpgsql security definer set search_path='' as $$
begin return public.cb_decision_detail_before_actions(p_id,p_before)||jsonb_build_object('chat_source',public.cb_chat_action_source('decision',p_id));end; $$;
revoke all on function public.cb_chat_action_visible(text,uuid),public.cb_chat_action_source(text,uuid),public.cb_chat_action_sources(uuid),public.cb_chat_action_context(uuid,bigint),public.cb_create_chat_action(uuid,bigint,text,uuid,jsonb,boolean),public.cb_chat_history_before_actions(uuid,bigint),public.cb_decision_detail_before_actions(uuid,bigint),public.cb_chat_history(uuid,bigint),public.cb_decision_detail(uuid,bigint) from public,anon,authenticated;
grant execute on function public.cb_chat_action_source(text,uuid),public.cb_chat_action_sources(uuid),public.cb_chat_action_context(uuid,bigint),public.cb_create_chat_action(uuid,bigint,text,uuid,jsonb,boolean),public.cb_chat_history(uuid,bigint),public.cb_decision_detail(uuid,bigint) to authenticated;
create or replace function public.cb_chat_action_task(p_task uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin if not public.cb_task_visible(p_task) then raise exception 'Task access denied' using errcode='42501';end if;
 return (select jsonb_build_object('id',id,'project',project_id,'title',title,'notes',description,'assignee',assignee_email,'due',due_date,'done',done,'source',public.cb_chat_action_source('task',id)) from public.cb_tasks where id=p_task);
end; $$;
revoke all on function public.cb_chat_action_task(uuid) from public,anon,authenticated;
grant execute on function public.cb_chat_action_task(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
