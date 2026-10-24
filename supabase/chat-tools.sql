-- Shared chat participant management, literal message search, pins and single-choice polls.
begin;
alter table public.cb_chat_participants add column if not exists is_admin boolean not null default false;
update public.cb_chat_participants x set is_admin=true from public.cb_chat_threads t where t.id=x.thread_id and t.created_by=x.user_id and not exists(select 1 from public.cb_chat_participants a where a.thread_id=t.id and a.is_admin);
create table if not exists public.cb_chat_pins(thread_id uuid references public.cb_chat_threads on delete cascade,message_id bigint references public.cb_chat_messages on delete cascade,created_by uuid not null references auth.users,created_at timestamptz not null default now(),primary key(thread_id,message_id));
create table if not exists public.cb_chat_polls(id uuid primary key default gen_random_uuid(),message_id bigint unique not null references public.cb_chat_messages on delete cascade,created_by uuid not null references auth.users,question text not null check(length(btrim(question)) between 1 and 200),options jsonb not null,closed boolean not null default false,revision bigint not null default 1);
create table if not exists public.cb_chat_poll_votes(poll_id uuid references public.cb_chat_polls on delete cascade,user_id uuid references auth.users,option_id text not null,updated_at timestamptz not null default now(),primary key(poll_id,user_id));
alter table public.cb_chat_pins enable row level security;alter table public.cb_chat_polls enable row level security;alter table public.cb_chat_poll_votes enable row level security;
revoke all on public.cb_chat_pins,public.cb_chat_polls,public.cb_chat_poll_votes from public,anon,authenticated;
create or replace function public.cb_chat_lock(p_thread uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare pid uuid;
begin
 if not public.cb_chat_access(p_thread) then raise exception 'Conversation access denied' using errcode='42501';end if;
 select project_id into pid from public.cb_chat_threads where id=p_thread;perform 1 from public.cb_projects where id=pid for update;perform 1 from public.cb_chat_threads where id=p_thread for update;
 if not public.cb_chat_access(p_thread) then raise exception 'Conversation access denied' using errcode='42501';end if;return pid;
end; $$;
revoke all on function public.cb_chat_lock(uuid) from public,anon,authenticated;
create or replace function public.cb_chat_manage(p_thread uuid) returns boolean language sql stable security definer set search_path='' as $$
 select public.cb_chat_access(p_thread) and exists(select 1 from public.cb_chat_threads t join public.cb_chat_participants x on x.thread_id=t.id and x.user_id=auth.uid() join public.cb_projects p on p.id=t.project_id where t.id=p_thread and p.archived_at is null and (x.is_admin or p.owner_id=auth.uid()));
$$;
create or replace function public.cb_chat_tools(p_thread uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not public.cb_chat_access(p_thread) then raise exception 'Conversation access denied' using errcode='42501';end if;
 select jsonb_build_object('can_manage',public.cb_chat_manage(p_thread),'eligible',case when public.cb_chat_manage(p_thread) then (select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'name',coalesce(p.full_name,'Wedding teammate'))),'[]') from (select owner_id id from public.cb_projects where id=t.project_id union select user_id from public.cb_members where project_id=t.project_id) u left join public.cb_profiles p on p.user_id=u.id where public.cb_collab_user_access(u.id,t.project_id,'read') and not exists(select 1 from public.cb_chat_participants x where x.thread_id=t.id and x.user_id=u.id)) else '[]'::jsonb end,'people',(select coalesce(jsonb_agg(jsonb_build_object('id',x.user_id,'name',coalesce(p.full_name,'Wedding teammate'),'admin',x.is_admin,'active',public.cb_collab_user_access(x.user_id,t.project_id,'read'))),'[]') from public.cb_chat_participants x left join public.cb_profiles p on p.user_id=x.user_id where x.thread_id=t.id),
 'pins',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id::text,'body',m.body,'at',m.created_at) order by pin.created_at desc),'[]') from public.cb_chat_pins pin join public.cb_chat_messages m on m.id=pin.message_id where pin.thread_id=t.id),
 'archived',exists(select 1 from public.cb_projects where id=t.project_id and archived_at is not null)) into result from public.cb_chat_threads t where t.id=p_thread;
 return result;
end; $$;
create or replace function public.cb_chat_add_person(p_thread uuid,p_user uuid,p_share_history boolean) returns void language plpgsql security definer set search_path='' as $$
declare pid uuid;
begin
 pid=public.cb_chat_lock(p_thread);
 if not public.cb_chat_manage(p_thread) then raise exception 'Conversation admin access denied' using errcode='42501';end if;
 if p_share_history is distinct from true then raise exception 'Confirm that earlier messages and files will be shared';end if;
 if not public.cb_collab_user_access(p_user,pid,'read') then raise exception 'Choose an active accepted wedding teammate';end if;
 if exists(select 1 from public.cb_chat_participants where thread_id=p_thread and user_id=p_user) then return;end if;
 if (select count(*) from public.cb_chat_participants where thread_id=p_thread)>=51 then raise exception 'A conversation can include up to 51 people';end if;
 insert into public.cb_chat_participants(thread_id,user_id) values(p_thread,p_user);
 insert into public.cb_project_activity(project_id,actor_id,action) values(pid,auth.uid(),'Conversation participant added');
end; $$;
create or replace function public.cb_chat_set_admin(p_thread uuid,p_user uuid,p_admin boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 perform public.cb_chat_lock(p_thread);
 if not public.cb_chat_manage(p_thread) then raise exception 'Conversation admin access denied' using errcode='42501';end if;
 if p_admin is null or not exists(select 1 from public.cb_chat_participants x join public.cb_chat_threads t on t.id=x.thread_id where x.thread_id=p_thread and x.user_id=p_user and public.cb_collab_user_access(p_user,t.project_id,'read')) then raise exception 'Choose an active conversation participant';end if;
 if not p_admin and not exists(select 1 from public.cb_chat_participants x join public.cb_chat_threads t on t.id=x.thread_id where x.thread_id=p_thread and x.user_id<>p_user and x.is_admin and public.cb_collab_user_access(x.user_id,t.project_id,'read')) then raise exception 'Keep at least one active conversation admin';end if;
 update public.cb_chat_participants set is_admin=p_admin where thread_id=p_thread and user_id=p_user;
 insert into public.cb_project_activity(project_id,actor_id,action) select project_id,auth.uid(),'Conversation admin updated' from public.cb_chat_threads where id=p_thread;
end; $$;
create or replace function public.cb_chat_remove_person(p_thread uuid,p_user uuid) returns void language plpgsql security definer set search_path='' as $$
declare pid uuid;
begin
 pid=public.cb_chat_lock(p_thread);
 if not public.cb_chat_access(p_thread) or not (p_user=auth.uid() or public.cb_chat_manage(p_thread)) or exists(select 1 from public.cb_projects where id=pid and archived_at is not null) then raise exception 'Conversation access denied' using errcode='42501';end if;
 if exists(select 1 from public.cb_chat_participants where thread_id=p_thread and user_id=p_user and is_admin) and exists(select 1 from public.cb_chat_participants where thread_id=p_thread and user_id<>p_user) and not exists(select 1 from public.cb_chat_participants where thread_id=p_thread and user_id<>p_user and is_admin and public.cb_collab_user_access(user_id,pid,'read')) then raise exception 'Choose another active admin before leaving or removing this admin';end if;
 delete from public.cb_chat_participants where thread_id=p_thread and user_id=p_user;
 if found then insert into public.cb_project_activity(project_id,actor_id,action) values(pid,auth.uid(),'Conversation participant removed');end if;
end; $$;
create or replace function public.cb_chat_pin(p_thread uuid,p_message bigint,p_pin boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 perform public.cb_chat_lock(p_thread);
 if not public.cb_chat_access(p_thread) or exists(select 1 from public.cb_chat_threads t join public.cb_projects p on p.id=t.project_id where t.id=p_thread and p.archived_at is not null) then raise exception 'Conversation access denied' using errcode='42501';end if;
 if p_pin is null or not exists(select 1 from public.cb_chat_messages where id=p_message and thread_id=p_thread) then raise exception 'Choose a message from this conversation';end if;
 if p_pin then
 if not exists(select 1 from public.cb_chat_pins where thread_id=p_thread and message_id=p_message) and (select count(*) from public.cb_chat_pins where thread_id=p_thread)>=20 then raise exception 'Keep up to twenty pinned messages';end if;
 insert into public.cb_chat_pins(thread_id,message_id,created_by) values(p_thread,p_message,auth.uid()) on conflict do nothing;
 else delete from public.cb_chat_pins where thread_id=p_thread and message_id=p_message;end if;
end; $$;
create or replace function public.cb_search_chat(p_thread uuid,p_query text,p_before bigint default null) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.cb_chat_access(p_thread) then raise exception 'Conversation access denied' using errcode='42501';end if;
 if length(btrim(coalesce(p_query,''))) not between 2 and 100 then raise exception 'Search using two to one hundred characters';end if;
 return (select coalesce(jsonb_agg(row order by id desc),'[]') from (select m.id,jsonb_build_object('id',m.id::text,'body',m.body,'at',m.created_at,'name',coalesce(p.full_name,'Wedding teammate')) row from public.cb_chat_messages m left join public.cb_profiles p on p.user_id=m.author_id where m.thread_id=p_thread and (p_before is null or m.id<p_before) and (strpos(lower(m.body),lower(btrim(p_query)))>0 or exists(select 1 from public.cb_chat_files f where f.message_id=m.id and strpos(lower(f.name),lower(btrim(p_query)))>0)) order by m.id desc limit 50) batch);
end; $$;
create or replace function public.cb_chat_poll_data(p_poll uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',p.id,'question',p.question,'options',p.options,'closed',p.closed,'revision',p.revision,
 'choice',(select option_id from public.cb_chat_poll_votes where poll_id=p.id and user_id=auth.uid()),
 'counts',(select coalesce(jsonb_object_agg(option_id,n),'{}') from (select option_id,count(*) n from public.cb_chat_poll_votes where poll_id=p.id group by option_id) votes),
 'can_close',p.created_by=auth.uid() or public.cb_chat_manage(m.thread_id)) from public.cb_chat_polls p join public.cb_chat_messages m on m.id=p.message_id where p.id=p_poll;
$$;
create or replace function public.cb_create_chat_poll(p_thread uuid,p_client uuid,p_question text,p_options jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare mid text;poll public.cb_chat_polls;o jsonb;
begin
 perform public.cb_chat_lock(p_thread);
 if not public.cb_chat_access(p_thread) then raise exception 'Conversation access denied' using errcode='42501';end if;
 if length(btrim(coalesce(p_question,''))) not between 1 and 200 or jsonb_typeof(p_options)<>'array' or p_options is null or jsonb_array_length(p_options) not between 2 and 8 or octet_length(p_options::text)>4000 then raise exception 'Add a question and two to eight choices';end if;
 for o in select jsonb_array_elements(p_options) loop if jsonb_typeof(o)<>'object' or o-array['id','title']::text[]<>'{}' or coalesce(o->>'id','') !~ '^[a-zA-Z0-9_-]{1,80}$' or length(btrim(coalesce(o->>'title',''))) not between 1 and 100 then raise exception 'Give every poll choice a valid name and ID';end if;end loop;
 if (select count(distinct choice->>'id') from jsonb_array_elements(p_options) choice)<>jsonb_array_length(p_options) then raise exception 'Poll choice IDs must be unique';end if;
 mid=public.cb_send_chat_message(p_thread,p_client,'Poll: '||btrim(p_question),'[]');
 select * into poll from public.cb_chat_polls where message_id=mid::bigint;
 if found then if poll.options is distinct from p_options or poll.question<>btrim(p_question) then raise exception 'Poll changed during retry' using errcode='PT409';end if;return public.cb_chat_poll_data(poll.id);end if;
 insert into public.cb_chat_polls(message_id,created_by,question,options) values(mid::bigint,auth.uid(),btrim(p_question),p_options) returning * into poll;
 return public.cb_chat_poll_data(poll.id);
end; $$;
create or replace function public.cb_vote_chat_poll(p_poll uuid,p_revision bigint,p_option text) returns jsonb language plpgsql security definer set search_path='' as $$
declare poll public.cb_chat_polls;tid uuid;
begin
 select m.thread_id into tid from public.cb_chat_polls p join public.cb_chat_messages m on m.id=p.message_id where p.id=p_poll;if not found then raise exception 'Poll access denied' using errcode='42501';end if;perform public.cb_chat_lock(tid);select * into poll from public.cb_chat_polls where id=p_poll for update;
 if not found or not public.cb_chat_access(tid) or exists(select 1 from public.cb_chat_threads t join public.cb_projects p on p.id=t.project_id where t.id=tid and p.archived_at is not null) then raise exception 'Poll access denied' using errcode='42501';end if;
 if poll.revision is distinct from p_revision then raise exception 'Poll changed. Refresh before voting.' using errcode='PT409';end if;
 if poll.closed then raise exception 'This poll is closed';end if;
 if not exists(select 1 from jsonb_array_elements(poll.options) o where o->>'id'=p_option) then raise exception 'Choose an existing poll option';end if;
 insert into public.cb_chat_poll_votes(poll_id,user_id,option_id) values(p_poll,auth.uid(),p_option) on conflict(poll_id,user_id) do update set option_id=excluded.option_id,updated_at=now();
 return public.cb_chat_poll_data(p_poll);
end; $$;
create or replace function public.cb_close_chat_poll(p_poll uuid,p_revision bigint,p_closed boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare poll public.cb_chat_polls;tid uuid;
begin
 select m.thread_id into tid from public.cb_chat_polls p join public.cb_chat_messages m on m.id=p.message_id where p.id=p_poll;if not found then raise exception 'Poll access denied' using errcode='42501';end if;perform public.cb_chat_lock(tid);select * into poll from public.cb_chat_polls where id=p_poll for update;
 if not public.cb_chat_access(tid) or not (poll.created_by=auth.uid() or public.cb_chat_manage(tid)) or exists(select 1 from public.cb_chat_threads t join public.cb_projects p on p.id=t.project_id where t.id=tid and p.archived_at is not null) then raise exception 'Poll management access denied' using errcode='42501';end if;
 if poll.revision is distinct from p_revision then raise exception 'Poll changed. Refresh before updating.' using errcode='PT409';end if;
 if p_closed is null then raise exception 'Choose a poll status';end if;
 if poll.closed is distinct from p_closed then update public.cb_chat_polls set closed=p_closed,revision=revision+1 where id=p_poll;end if;
 return public.cb_chat_poll_data(p_poll);
end; $$;
do $migration$ begin
 if to_regprocedure('public.cb_chat_history_before_tools(uuid,bigint)') is null then alter function public.cb_chat_history(uuid,bigint) rename to cb_chat_history_before_tools;end if;
 if to_regprocedure('public.cb_create_chat_before_tools(uuid,text,uuid[])') is null then alter function public.cb_create_chat(uuid,text,uuid[]) rename to cb_create_chat_before_tools;end if;
end; $migration$;
create or replace function public.cb_chat_history(p_thread uuid,p_before bigint default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;rows jsonb;
begin
 result=public.cb_chat_history_before_tools(p_thread,p_before);
 select coalesce(jsonb_agg(m||jsonb_build_object('pinned',exists(select 1 from public.cb_chat_pins pin where pin.thread_id=p_thread and pin.message_id=(m->>'id')::bigint),'poll',(select public.cb_chat_poll_data(id) from public.cb_chat_polls where message_id=(m->>'id')::bigint)) order by (m->>'id')::bigint),'[]') into rows from jsonb_array_elements(result->'messages') m;
 return jsonb_set(result,'{messages}',rows);
end; $$;
create or replace function public.cb_create_chat(p_project uuid,p_title text,p_people uuid[]) returns uuid language plpgsql security definer set search_path='' as $$
declare tid uuid;
begin
 if not public.cb_project_access(p_project,'read') then raise exception 'Wedding access denied' using errcode='42501';end if;
 if exists(select 1 from unnest(p_people) person where not public.cb_collab_user_access(person,p_project,'read')) then raise exception 'Choose active accepted wedding teammates';end if;
 tid=public.cb_create_chat_before_tools(p_project,p_title,p_people);update public.cb_chat_participants set is_admin=true where thread_id=tid and user_id=auth.uid();return tid;
end; $$;
revoke all on function public.cb_chat_manage(uuid),public.cb_chat_poll_data(uuid),public.cb_chat_history_before_tools(uuid,bigint),public.cb_create_chat_before_tools(uuid,text,uuid[]),public.cb_chat_tools(uuid),public.cb_chat_add_person(uuid,uuid,boolean),public.cb_chat_set_admin(uuid,uuid,boolean),public.cb_chat_remove_person(uuid,uuid),public.cb_chat_pin(uuid,bigint,boolean),public.cb_search_chat(uuid,text,bigint),public.cb_create_chat_poll(uuid,uuid,text,jsonb),public.cb_vote_chat_poll(uuid,bigint,text),public.cb_close_chat_poll(uuid,bigint,boolean),public.cb_chat_history(uuid,bigint),public.cb_create_chat(uuid,text,uuid[]) from public,anon,authenticated;
grant execute on function public.cb_chat_tools(uuid),public.cb_chat_add_person(uuid,uuid,boolean),public.cb_chat_set_admin(uuid,uuid,boolean),public.cb_chat_remove_person(uuid,uuid),public.cb_chat_pin(uuid,bigint,boolean),public.cb_search_chat(uuid,text,bigint),public.cb_create_chat_poll(uuid,uuid,text,jsonb),public.cb_vote_chat_poll(uuid,bigint,text),public.cb_close_chat_poll(uuid,bigint,boolean),public.cb_chat_history(uuid,bigint),public.cb_create_chat(uuid,text,uuid[]) to authenticated;
notify pgrst,'reload schema';
commit;
